#Requires -Version 5.1
<#
.SYNOPSIS
  asar 外科手术式定长补丁（快速通道）
.DESCRIPTION
  核心补丁点是定长替换（如 enable_i18n 的 !1 -> !0），因此可以：
    1) 流式扫描 asar 数据区，定位模式字节偏移；
    2) 反查命中位置属于哪个文件 entry（offset/size 区间）；
    3) 原地覆写字节（文件长度不变，所有 offset 保持有效）；
    4) 重算该文件的 integrity（整文件 SHA256 + 4MB 分块），在头部 JSON 文本中
       定长替换旧哈希值（64 hex 换 64 hex，头部长度不变）；
    5) 头部哈希由 Sync-ExeAsarIntegrity 重新同步进 exe。
  全程无需解包/重打包，秒级完成。任何一步不符合预期即返回 $false，
  调用方回退到全量解包重打包流程。
#>

# 规则要求：Pattern 与 Replace 必须等长
function Get-SurgicalRules {
    return @(
        @{
            Pattern  = [System.Text.Encoding]::UTF8.GetBytes('.get(`enable_i18n`,!1)')
            Replace  = [System.Text.Encoding]::UTF8.GetBytes('.get(`enable_i18n`,!0)')
            Already  = [System.Text.Encoding]::UTF8.GetBytes('.get(`enable_i18n`,!0)')
            Desc     = '开启官方多语言开关 enable_i18n'
        }
    )
}

# 流式搜索：在流中找所有 needle 偏移（分块 + 重叠处理）
function Find-AllOffsets {
    param([System.IO.Stream]$Stream, [byte[]]$Needle, [long]$StartAt, [long]$EndAt)
    $found = New-Object System.Collections.ArrayList
    $chunkSize = 64MB
    $buf = New-Object byte[] ($chunkSize + $Needle.Length)
    $carry = 0
    $pos = $StartAt
    $needleStr = [System.Text.Encoding]::ASCII.GetString($Needle)
    $Stream.Seek($StartAt, [System.IO.SeekOrigin]::Begin) | Out-Null
    while ($pos -lt $EndAt) {
        $toRead = [int][Math]::Min($chunkSize, $EndAt - $pos) + $carry
        $read = $Stream.Read($buf, $carry, $toRead - $carry)
        if ($read -le 0) { break }
        $total = $carry + $read
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $total)
        $idx = 0
        while (($idx = $text.IndexOf($needleStr, $idx)) -ge 0) {
            $p = ($pos - $carry) + $idx
            # 去重：完整落在上一个分块已搜索范围内的命中跳过
            if ($pos -eq $StartAt -or ($p + $needleStr.Length) -gt $pos) { [void]$found.Add($p) }
            $idx += $needleStr.Length
        }
        # 保留末尾 needle.Length-1 字节作为重叠
        $carry = [Math]::Min($Needle.Length - 1, $total)
        [Array]::Copy($buf, $total - $carry, $buf, 0, $carry)
        $pos += $read
    }
    return $found
}

function Invoke-SurgicalPatch {
    param([string]$AsarPath)
    $rules = Get-SurgicalRules
    foreach ($r in $rules) {
        if ($r.Pattern.Length -ne $r.Replace.Length) { return @{ Success = $false; Already = $false; Reason = '规则非定长' } }
    }

    $fs = [System.IO.File]::Open($AsarPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        # ---- 1) 头部 ----
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(0, 'Begin') | Out-Null
        $u0 = $br.ReadUInt32(); $u1 = $br.ReadUInt32(); $u2 = $br.ReadUInt32(); $u3 = $br.ReadUInt32()
        $jsonBytes = $br.ReadBytes([int]$u3)
        $jsonText = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
        $pad = [int]($u2 - $u3 - 4); if ($pad -lt 0 -or $pad -gt 3) { $pad = 0 }
        $dataOffset = [long](16 + $u3 + $pad)

        # ---- 2) 从头部文本提取全部文件 entry（带 integrity 的才有 offset+hash）----
        $rx = New-Object System.Text.RegularExpressions.Regex('"([^"]+)":\{"size":(\d+),"offset":"(\d+)","integrity":\{"algorithm":"SHA256","hash":"([0-9a-f]{64})","blockSize":(\d+),"blocks":\[([^\]]*)\]\}')
        $entries = @()
        foreach ($m in $rx.Matches($jsonText)) {
            $entries += @{
                Name       = $m.Groups[1].Value
                Size       = [long]$m.Groups[2].Value
                Offset     = [long]$m.Groups[3].Value
                HashIdx    = $m.Groups[4].Index
                Hash       = $m.Groups[4].Value
                BlockSize  = [int]$m.Groups[5].Value
                BlocksIdx  = $m.Groups[6].Index
                BlocksText = $m.Groups[6].Value
            }
        }
        if ($entries.Count -eq 0) { return @{ Success = $false; Already = $false; Reason = '头部无可解析 entry' } }

        # ---- 3) 逐规则扫描数据区 ----
        $fileLen = $fs.Length
        $dirtyFiles = @{}   # entry.Index -> 新内容 buffer
        foreach ($r in $rules) {
            $hits = Find-AllOffsets -Stream $fs -Needle $r.Pattern -StartAt $dataOffset -EndAt $fileLen
            if ($hits.Count -eq 0) {
                # 关键模式未命中：若"目标形态"存在，说明此前已打过补丁（幂等场景，秒回）
                if ($r.Already -and (Find-AllOffsets -Stream $fs -Needle $r.Already -StartAt $dataOffset -EndAt $fileLen).Count -gt 0) {
                    return @{ Success = $false; Already = $true; Reason = '已是补丁状态' }
                }
                return @{ Success = $false; Already = $false; Reason = '模式未命中' }
            }
            foreach ($absPos in $hits) {
                $rel = $absPos - $dataOffset
                $entry = $null
                foreach ($e in $entries) {
                    if ($rel -ge $e.Offset -and ($rel + $r.Pattern.Length) -le ($e.Offset + $e.Size)) { $entry = $e; break }
                }
                if ($null -eq $entry) { return @{ Success = $false; Already = $false; Reason = '命中位置不属于任何文件 entry' } }
                $key = $entry.Offset
                if (-not $dirtyFiles.ContainsKey($key)) {
                    $content = New-Object byte[] ($entry.Size)
                    $fs.Seek($dataOffset + $entry.Offset, 'Begin') | Out-Null
                    $got = 0
                    while ($got -lt $entry.Size) {
                        $n = $fs.Read($content, $got, [int][Math]::Min(8MB, $entry.Size - $got))
                        if ($n -le 0) { return @{ Success = $false; Already = $false; Reason = '读取文件内容失败' } }
                        $got += $n
                    }
                    $dirtyFiles[$key] = @{ Entry = $entry; Content = $content }
                }
                # 原地覆写（定长）
                [Array]::Copy($r.Replace, 0, $dirtyFiles[$key].Content, ($rel - $entry.Offset), $r.Replace.Length)
            }
        }
        if ($dirtyFiles.Count -eq 0) { return @{ Success = $false; Already = $false; Reason = '无可补丁文件' } }

        # ---- 4) 内存中完成全部校验与头部手术（此阶段不写盘，失败即安全回退）----
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $jsonMod = $jsonText
        $writePlan = @()
        foreach ($kvp in $dirtyFiles.Values) {
            $entry = $kvp.Entry
            $content = $kvp.Content
            # 重算哈希（内存 buffer）
            $whole = -join ($sha.ComputeHash($content) | ForEach-Object { $_.ToString('x2') })
            $bs = $entry.BlockSize
            $newBlocks = New-Object System.Collections.ArrayList
            for ($o = 0; $o -lt $content.Length; $o += $bs) {
                $len = [Math]::Min($bs, $content.Length - $o)
                $bh = $sha.ComputeHash($content, $o, $len)
                [void]$newBlocks.Add(-join ($bh | ForEach-Object { $_.ToString('x2') }))
            }
            # 头部文本：整文件 hash 定长替换
            if ($jsonMod.Substring($entry.HashIdx, 64) -ne $entry.Hash) { return @{ Success = $false; Already = $false; Reason = '头部哈希位置校验失败' } }
            $jsonMod = $jsonMod.Substring(0, $entry.HashIdx) + $whole + $jsonMod.Substring($entry.HashIdx + 64)
            # blocks：按顺序替换每个 64hex
            $brx = New-Object System.Text.RegularExpressions.Regex('[0-9a-f]{64}')
            $bmatches = $brx.Matches($jsonMod.Substring($entry.BlocksIdx, $entry.BlocksText.Length))
            if ($bmatches.Count -ne $newBlocks.Count) { return @{ Success = $false; Already = $false; Reason = '分块数不一致' } }
            for ($bi = 0; $bi -lt $bmatches.Count; $bi++) {
                $pos0 = $entry.BlocksIdx + $bmatches[$bi].Index
                $jsonMod = $jsonMod.Substring(0, $pos0) + $newBlocks[$bi] + $jsonMod.Substring($pos0 + 64)
            }
            $writePlan += @{ Offset = $entry.Offset; Content = $content }
            # 注意：本函数返回值承载状态，输出必须走 Write-Host 系（Write-Output 会污染返回值）
            Write-Host ("    外科补丁: {0}（{1:N1} MB，哈希已同步）" -f $entry.Name, ($content.Length / 1MB)) -ForegroundColor Cyan
        }
        $sha.Dispose()

        # ---- 5) 提交：一次性写盘（数据区 + 头部）----
        $newJsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonMod)
        if ($newJsonBytes.Length -ne $jsonBytes.Length) { return @{ Success = $false; Already = $false; Reason = '头部长度变化，外科不适用' } }
        foreach ($w in $writePlan) {
            $fs.Seek($dataOffset + $w.Offset, 'Begin') | Out-Null
            $fs.Write($w.Content, 0, $w.Content.Length)
        }
        $fs.Seek(16, 'Begin') | Out-Null
        $fs.Write($newJsonBytes, 0, $newJsonBytes.Length)
        $fs.Flush()
        return @{ Success = $true; Already = $false; Reason = '' }
    } catch {
        return @{ Success = $false; Already = $false; Reason = $_.Exception.Message }
    } finally { $fs.Dispose() }
}
