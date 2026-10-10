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

# 进度条节流：每 150ms 最多刷新一次
$script:progressSw = $null

# CJK 字符在控制台占 2 格，按显示宽度截断，避免行尾换行把画面搞花
function Get-DisplayWidth {
    param([string]$s)
    $w = 0
    foreach ($ch in $s.ToCharArray()) { $w += $(if ([int]$ch -gt 0x2E7F) { 2 } else { 1 }) }
    return $w
}

function Write-ThrottledProgress {
    param([string]$Activity, [string]$Status, [double]$Percent)
    if ($null -eq $script:progressSw) { $script:progressSw = [System.Diagnostics.Stopwatch]::StartNew() }
    if ($script:progressSw.ElapsedMilliseconds -lt 150) { return }
    $script:progressSw.Restart()
    if ($Percent -lt 0) { $Percent = 0 }; if ($Percent -gt 100) { $Percent = 100 }
    if ([Console]::IsOutputRedirected) {
        # 无控制台（管道/重定向）：用进度流，不影响画面
        try { Write-Progress -Activity $Activity -Status $Status -PercentComplete $Percent } catch {}
        return
    }
    # 有控制台：在光标当前行用 \r 自绘进度条。
    # 不用 Write-Progress——PS 5.1 会把它画在控制台顶部，覆盖之前输出的横幅。
    try {
        $winW = [Console]::WindowWidth
        $barWidth = 20
        $filled = [int]($barWidth * $Percent / 100)
        # 空段用 ASCII '-'：GBK 控制台映射不出 ░ 会显示成问号（█ 在 GBK 中可用）
        $bar = ([string][char]0x2588) * $filled + '-' * ($barWidth - $filled)
        $line = ("  {0} [{1}] {2,5:N1}%  {3}" -f $Activity, $bar, $Percent, $Status)
        # 按显示宽度截断到窗口宽以内（防换行）
        $maxW = $winW - 2
        while ((Get-DisplayWidth $line) -gt $maxW -and $line.Length -gt 0) { $line = $line.Substring(0, $line.Length - 1) }
        $tail = $maxW - (Get-DisplayWidth $line)
        if ($tail -gt 0) { $line += ' ' * $tail }
        [Console]::Write("`r" + $line)
    } catch {}
}

function Complete-UtilProgress {
    param([string]$Activity)
    if ([Console]::IsOutputRedirected) {
        try { Write-Progress -Activity $Activity -Completed } catch {}
        return
    }
    # 清掉进度行，把光标还给下一行
    try {
        $blank = ' ' * ([Math]::Max(10, [Console]::WindowWidth - 2))
        [Console]::Write("`r" + $blank + "`r`n")
    } catch {}
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
                # chromium pickle 会把头部 JSON 补零到 4 字节对齐，数据区起点 = 16 + jsonLen + pad
                $pad = 0
                if ($len -eq $u3) { $pad = [int]($u2 - $u3 - 4); if ($pad -lt 0 -or $pad -gt 3) { $pad = 0 } }
                return @{ JsonLen = [long]$len; Json = $obj; DataOffset = [long](16 + $len + $pad); Pad = $pad }
            } catch { }
        }
        throw "无法解析 asar 头部: $AsarPath"
    } finally { $fs.Dispose() }
}

# 计算单个文件的 asar integrity（整文件 SHA256 + 每 4MB 块 SHA256）
function Get-FileIntegrity {
    param([string]$Path)
    $blockSize = 4194304
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead((ConvertTo-LongPath $Path))
    try {
        $blocks = New-Object System.Collections.ArrayList
        $buf = New-Object byte[] ($blockSize)
        while (($r = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $sha.TransformBlock($buf, 0, $r, $buf, 0) | Out-Null
            $bsha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bh = $bsha.ComputeHash($buf, 0, $r)
                [void]$blocks.Add((-join ($bh | ForEach-Object { $_.ToString('x2') })))
            } finally { $bsha.Dispose() }
        }
        $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0) | Out-Null
        $whole = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
    } finally { $fs.Dispose(); $sha.Dispose() }
    return [ordered]@{ algorithm = 'SHA256'; hash = $whole; blockSize = $blockSize; blocks = @($blocks.ToArray()) }
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
    # 预统计文件总数用于进度条（只走头部 JSON，不读数据区）
    $script:expandTotal = 0
    function Measure-Node { param($Node)
        $files = Get-AsarProp $Node 'files'
        if ($null -ne $files) { foreach ($p in $files.PSObject.Properties) { Measure-Node $p.Value }; return }
        if (-not (Get-AsarProp $Node 'unpacked')) { $script:expandTotal++ }
    }
    Measure-Node $hdr.Json
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
            Write-ThrottledProgress -Activity '解包 app.asar' -Status ("{0}/{1} 个文件" -f $script:expandedFiles, $script:expandTotal) -Percent (100.0 * $script:expandedFiles / [Math]::Max(1, $script:expandTotal))
        }

        Walk-Node -Node $hdr.Json -Rel '' -Stream $fs -DataOffset $hdr.DataOffset -OutRoot $OutDir
        Complete-UtilProgress -Activity '解包 app.asar'
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
                # 保留原始 integrity（unpacked 文件内容不变，哈希依旧有效）
                $ig = Get-AsarProp $Node 'integrity'
                $script:unpackedSet[$Rel] = @{ Size = $(if ($null -ne $sz) { [long]$sz } else { 0 }); Integrity = $ig }
            }
        }
        Collect-Unpacked -Node $ohdr.Json -Rel ''
        Write-Output ("unpacked 条目: " + $script:unpackedSet.Count)
    }

    $script:packedFiles = 0
    $script:packedBytes = [long]0
    $script:hashedFiles = 0
    # 预统计文件总数用于进度条
    $script:hashTotal = 0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles((ConvertTo-LongPath $InDir), '*', [System.IO.SearchOption]::AllDirectories)) { $script:hashTotal++ }
    } catch {}

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
                $entry = @{ 'size' = $len; 'unpacked' = $true }
                $ig0 = $script:unpackedSet[$Rel].Integrity
                if ($null -ne $ig0) { $entry['integrity'] = $ig0 }
                return $entry
            } else {
                $off = $script:packedBytes
                $script:packedBytes += $len
                $script:packedFiles++
                # 逐文件 integrity：Electron 开启 asar 完整性校验后读文件会核对
                $ig = Get-FileIntegrity -Path $Path
                $script:hashedFiles++
                Write-ThrottledProgress -Activity '重打包 app.asar（1/2）计算文件校验' -Status ("{0}/{1} 个文件" -f $script:hashedFiles, $script:hashTotal) -Percent (100.0 * $script:hashedFiles / [Math]::Max(1, $script:hashTotal))
                return @{ 'size' = $len; 'offset' = [string]$off; 'integrity' = $ig }
            }
        }
    }

    $header = Build-Node -Path $InDir -Rel ''
    Complete-UtilProgress -Activity '重打包 app.asar（1/2）计算文件校验'

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
                $entry = @{ 'size' = $Map[$uRel].Size; 'unpacked' = $true }
                if ($null -ne $Map[$uRel].Integrity) { $entry['integrity'] = $Map[$uRel].Integrity }
                $files[$leaf] = $entry
            }
        }
    }
    Add-UnpackedEntries -Root $header -Map $script:unpackedSet
    $json = $header | ConvertTo-Json -Depth 100 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $out = [System.IO.File]::Create($OutPath)
    try {
        $bw = New-Object System.IO.BinaryWriter($out)
        # chromium pickle 布局：头部 JSON 补零到 4 字节对齐，三个长度字段需与实际一致
        $pad = (4 - ($jsonBytes.Length % 4)) % 4
        $bw.Write([uint32]4)
        $bw.Write([uint32]($jsonBytes.Length + $pad + 8))
        $bw.Write([uint32]($jsonBytes.Length + $pad + 4))
        $bw.Write([uint32]$jsonBytes.Length)
        $bw.Write($jsonBytes)
        for ($i = 0; $i -lt $pad; $i++) { $bw.Write([byte]0) }

    $script:writtenBytes = [long]0
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
                        while (($r = $in.Read($buf,0,$buf.Length)) -gt 0) {
                            $Writer.Write($buf,0,$r)
                            $script:writtenBytes += $r
                            Write-ThrottledProgress -Activity '重打包 app.asar（2/2）写入数据' -Status ("{0:N0}/{1:N0} MB" -f ($script:writtenBytes/1MB), ($script:packedBytes/1MB)) -Percent (100.0 * $script:writtenBytes / [Math]::Max([long]1, $script:packedBytes))
                        }
                    } finally { $in.Dispose() }
                }
            }
        }
        Write-Data -Path $InDir -Rel '' -Writer $bw
        $bw.Flush()
        Complete-UtilProgress -Activity '重打包 app.asar（2/2）写入数据'
    } finally { $out.Dispose() }

    $fi = Get-Item -LiteralPath $OutPath
    Write-Output ("打包完成: {0} 个打包文件, {1:N1} MB, 输出 {2}" -f $script:packedFiles, ($fi.Length/1MB), $OutPath)
}








