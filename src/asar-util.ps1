#Requires -Version 5.1
# asar 解包/打包工具（纯 .NET，PowerShell 5.1 兼容，无第三方依赖）

function Get-AsarProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# 长路径支持：Windows 传统 API 限 260 字符，asar 内 node_modules 嵌套很深，需 \\?\ 前缀
function ConvertTo-LongPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { return $full }
    return '\\?\' + $full
}

# 长路径安全删除目录（Remove-Item 对 >260 字符路径会失败）
function Remove-TreeLong {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $p = ConvertTo-LongPath $Path
    & cmd.exe /c "rd /s /q `"$p`"" 2>$null | Out-Null
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Read-AsarHeader {
    param([string]$AsarPath)
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $u0 = $br.ReadUInt32(); $u1 = $br.ReadUInt32(); $u2 = $br.ReadUInt32(); $u3 = $br.ReadUInt32()
        foreach ($len in @($u3, $u2, $u1)) {
            if ($len -le 0 -or $len -gt 256MB) { continue }
            $fs.Seek(16, [System.IO.SeekOrigin]::Begin) | Out-Null
            $jsonBytes = $br.ReadBytes([int]$len)
            $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
            try {
                $obj = $json | ConvertFrom-Json
                return @{ JsonLen = [long]$len; Json = $obj; DataOffset = [long](16 + $len) }
            } catch { }
        }
        throw "无法解析 asar 头部: $AsarPath"
    } finally { $fs.Dispose() }
}

function Expand-Asar {
    param([string]$AsarPath, [string]$OutDir, [switch]$Force)
    if (Test-Path -LiteralPath $OutDir) {
        if ($Force) {
            $full = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\')
            $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\')
            if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or $full -ieq $env:USERPROFILE -or $full -like '*\WindowsApps\*') {
                throw "拒绝删除危险路径: $full"
            }
            Remove-TreeLong -Path $full
        } else {
            throw "目标已存在: $OutDir（用 -Force 覆盖）"
        }
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $hdr = Read-AsarHeader -AsarPath $AsarPath
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $script:expandedFiles = 0
        $script:expandedBytes = [long]0
        $script:expandedUnpacked = 0

        function Walk-Node {
            param($Node, [string]$Rel, $Stream, [long]$DataOffset, [string]$OutRoot)
            $files = Get-AsarProp $Node 'files'
            if ($null -ne $files) {
                foreach ($p in $files.PSObject.Properties) {
                    Walk-Node -Node $p.Value -Rel $(if ([string]::IsNullOrEmpty($Rel)) { $p.Name } else { Join-Path $Rel $p.Name }) -Stream $Stream -DataOffset $DataOffset -OutRoot $OutRoot
                }
                return
            }
            $unpacked = Get-AsarProp $Node 'unpacked'
            if ($unpacked) { $script:expandedUnpacked++; return }
            $offset = [long](Get-AsarProp $Node 'offset')
            $size = [long](Get-AsarProp $Node 'size')
            $outPath = Join-Path $OutRoot $Rel
            $dir = Split-Path $outPath
            if (-not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory((ConvertTo-LongPath $dir)) | Out-Null }
            $Stream.Seek($DataOffset + $offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $out = [System.IO.File]::Create((ConvertTo-LongPath $outPath))
            try {
                $buf = New-Object byte[] (8MB)
                $remaining = $size
                while ($remaining -gt 0) {
                    $toRead = [int][Math]::Min($remaining, $buf.Length)
                    $r = $Stream.Read($buf, 0, $toRead)
                    if ($r -le 0) { throw "读取失败 @ $Rel" }
                    $out.Write($buf, 0, $r)
                    $remaining -= $r
                    $script:expandedBytes += $r
                }
                $script:expandedFiles++
            } finally { $out.Dispose() }
        }

        Walk-Node -Node $hdr.Json -Rel '' -Stream $fs -DataOffset $hdr.DataOffset -OutRoot $OutDir
        Write-Output ("解包完成: 文件 {0} 个, 字节 {1:N1} MB, unpacked 标记 {2} 个" -f $script:expandedFiles, ($script:expandedBytes/1MB), $script:expandedUnpacked)
    } finally { $fs.Dispose() }
}

function New-Asar {
    param([string]$InDir, [string]$OutPath, [string]$OriginalAsar, [switch]$Force)
    if ((Test-Path -LiteralPath $OutPath) -and -not $Force) { throw "输出已存在: $OutPath" }

    # 收集原 asar 中 unpacked 标记的相对路径
    $script:unpackedSet = @{}
    if ($OriginalAsar) {
        $ohdr = Read-AsarHeader -AsarPath $OriginalAsar
        function Collect-Unpacked {
            param($Node, [string]$Rel)
            $files = Get-AsarProp $Node 'files'
            if ($null -ne $files) {
                foreach ($p in $files.PSObject.Properties) {
                    $childRel = if ([string]::IsNullOrEmpty($Rel)) { $p.Name } else { Join-Path $Rel $p.Name }
                    Collect-Unpacked -Node $p.Value -Rel $childRel
                }
                return
            }
            if (Get-AsarProp $Node 'unpacked') {
                $sz = Get-AsarProp $Node 'size'
                $script:unpackedSet[$Rel] = if ($null -ne $sz) { [long]$sz } else { 0 }
            }
        }
        Collect-Unpacked -Node $ohdr.Json -Rel ''
        Write-Output ("unpacked 条目: " + $script:unpackedSet.Count)
    }

    $script:packedFiles = 0
    $script:packedBytes = [long]0

    function Build-Node {
        param([string]$Path, [string]$Rel)
        $item = Get-Item -LiteralPath (ConvertTo-LongPath $Path)
        if ($item.PSIsContainer) {
            $children = Get-ChildItem -LiteralPath (ConvertTo-LongPath $Path) -Force
            $files = @{}
            foreach ($c in $children) {
                $childRel = if ([string]::IsNullOrEmpty($Rel)) { $c.Name } else { Join-Path $Rel $c.Name }
                $files[$c.Name] = Build-Node -Path $c.FullName -Rel $childRel
            }
            return @{ 'files' = $files }
        } else {
            $len = $item.Length
            if ($script:unpackedSet.ContainsKey($Rel)) {
                return @{ 'size' = $len; 'unpacked' = $true }
            } else {
                $off = $script:packedBytes
                $script:packedBytes += $len
                $script:packedFiles++
                return @{ 'size' = $len; 'offset' = [string]$off }
            }
        }
    }

    $header = Build-Node -Path $InDir -Rel ''

    # 把 unpacked 文件条目补回头部（这些文件不在 asar 数据内，在 app.asar.unpacked）
    # 把 unpacked 文件条目补回头部（这些文件不在 asar 数据内，在 app.asar.unpacked）
    function Add-UnpackedEntries {
        param($Root, [hashtable]$Map)
        foreach ($uRel in @($Map.Keys)) {
            $parts = $uRel -split '\\'
            $node = $Root
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if (-not $node.ContainsKey('files')) { $node['files'] = @{} }
                $files = $node['files']
                $seg = $parts[$i]
                if (-not $files.ContainsKey($seg)) { $files[$seg] = @{ 'files' = @{} } }
                $node = $files[$seg]
            }
            if (-not $node.ContainsKey('files')) { $node['files'] = @{} }
            $files = $node['files']
            $leaf = $parts[-1]
            if (-not $files.ContainsKey($leaf)) {
                $files[$leaf] = @{ 'size' = $Map[$uRel]; 'unpacked' = $true }
            }
        }
    }
    Add-UnpackedEntries -Root $header -Map $script:unpackedSet
    $json = $header | ConvertTo-Json -Depth 100 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $out = [System.IO.File]::Create($OutPath)
    try {
        $bw = New-Object System.IO.BinaryWriter($out)
        $bw.Write([uint32]4)
        $bw.Write([uint32]($jsonBytes.Length + 8))
        $bw.Write([uint32]($jsonBytes.Length + 4))
        $bw.Write([uint32]$jsonBytes.Length)
        $bw.Write($jsonBytes)

    function Write-Data {
        param([string]$Path, [string]$Rel, $Writer)
        $item = Get-Item -LiteralPath (ConvertTo-LongPath $Path)
        if ($item.PSIsContainer) {
            foreach ($c in (Get-ChildItem -LiteralPath (ConvertTo-LongPath $Path) -Force)) {
                $childRel = if ([string]::IsNullOrEmpty($Rel)) { $c.Name } else { Join-Path $Rel $c.Name }
                Write-Data -Path $c.FullName -Rel $childRel -Writer $Writer
            }
        } else {
            if (-not $script:unpackedSet.ContainsKey($Rel)) {
                $in = [System.IO.File]::OpenRead((ConvertTo-LongPath $Path))
                    try {
                        $buf = New-Object byte[] (8MB)
                        while (($r = $in.Read($buf,0,$buf.Length)) -gt 0) { $Writer.Write($buf,0,$r) }
                    } finally { $in.Dispose() }
                }
            }
        }
        Write-Data -Path $InDir -Rel '' -Writer $bw
        $bw.Flush()
    } finally { $out.Dispose() }

    $fi = Get-Item -LiteralPath $OutPath
    Write-Output ("打包完成: {0} 个打包文件, {1:N1} MB, 输出 {2}" -f $script:packedFiles, ($fi.Length/1MB), $OutPath)
}








