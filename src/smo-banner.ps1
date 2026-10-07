<#
.SYNOPSIS
  SMO 像素字终端横幅（MiniMax 风格：像素块大字 + 纵向真彩渐变 + 同位置暗化错位投影）
.DESCRIPTION
  两种用法：
    1) 直接运行:  powershell -File smo-banner.ps1
    2) 作为模块:  . .\smo-banner.ps1 ; Show-SmoBanner [-TopRgb '16,217,126'] [-BottomRgb '51,102,255']
  自动尝试开启控制台 ANSI 真彩色（Win10+ conhost / Windows Terminal），
  无控制台（管道/重定向）或开启失败时回退 16 色方案，不会输出乱码。
.NOTES
  需要 PowerShell 5.1+。文件必须保存为 UTF-8 with BOM（PS 5.1 才能正确读中文）。
#>

function Show-SmoBanner {
    param(
        [string]$TopRgb = '16,217,126',    # 顶部颜色 R,G,B（默认鲜绿）
        [string]$BottomRgb = '51,102,255'  # 底部颜色 R,G,B（默认亮蓝）
    )

    $smoRows = @(
        ' ██████   ███     ███   ██████ ',
        '██    ██  ████   ████  ██    ██',
        '██        ██ ██ ██ ██  ██    ██',
        ' ██████   ██  ███  ██  ██    ██',
        '      ██  ██   █   ██  ██    ██',
        '██    ██  ██       ██  ██    ██',
        ' ██████   ██       ██   ██████ '
    )

    # 尝试启用 ANSI 真彩色（ENABLE_VIRTUAL_TERMINAL_PROCESSING）
    $ansi = $false
    try {
        Add-Type -Namespace SmoBannerConsole -Name Native -ErrorAction Stop -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out int m);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, int m);
"@
        $stdOut = [SmoBannerConsole.Native]::GetStdHandle(-11)
        $mode = 0
        if ([SmoBannerConsole.Native]::GetConsoleMode($stdOut, [ref]$mode)) {
            $ansi = [SmoBannerConsole.Native]::SetConsoleMode($stdOut, $mode -bor 0x4)
        }
    } catch {}

    $top = $TopRgb -split ','    | ForEach-Object { [int]$_ }
    $bot = $BottomRgb -split ',' | ForEach-Object { [int]$_ }
    $esc = [char]27
    $fallback16 = 'Green', 'Green', 'DarkCyan', 'Cyan', 'Cyan', 'Blue', 'Blue'

    Write-Host ''
    for ($r = 0; $r -le $smoRows.Count; $r++) {
        # 合并本行方块与上一行的错位投影：B=方块 E=投影
        $block = if ($r -lt $smoRows.Count) { $smoRows[$r] } else { '' }
        $echo  = if ($r -ge 1) { $smoRows[$r - 1] } else { '' }
        $cells = @()
        for ($c = 0; $c -le $smoRows[0].Length; $c++) {
            if ($c -lt $block.Length -and $block[$c] -eq [char]0x2588) { $cells += 'B' }
            elseif ($c -ge 1 -and ($c - 1) -lt $echo.Length -and $echo[$c - 1] -eq [char]0x2588) { $cells += 'E' }
            else { $cells += ' ' }
        }

        $rr = [Math]::Min($r, 6)
        $gR = [int]($top[0] + ($bot[0] - $top[0]) * $rr / 6)
        $gG = [int]($top[1] + ($bot[1] - $top[1]) * $rr / 6)
        $gB = [int]($top[2] + ($bot[2] - $top[2]) * $rr / 6)

        if ($ansi) {
            $eR = [int]($gR * 0.38); $eG = [int]($gG * 0.38); $eB = [int]($gB * 0.38)
            $line = '   '; $prev = ' '
            foreach ($cell in $cells) {
                if ($cell -ne $prev) {
                    if ($cell -eq 'B') { $line += "$esc[38;2;${gR};${gG};${gB}m" }
                    elseif ($cell -eq 'E') { $line += "$esc[38;2;${eR};${eG};${eB}m" }
                    $prev = $cell
                }
                if ($cell -eq ' ' ) { $line += ' ' } else { $line += [char]0x2588 }
            }
            Write-Host ($line + "$esc[0m")
        } else {
            $curText = '   '; $curColor = $null
            foreach ($cell in $cells) {
                if ($cell -eq 'B') { $ch = [char]0x2588; $co = $fallback16[$rr] }
                elseif ($cell -eq 'E') { $ch = [char]0x2588; $co = 'DarkBlue' }
                else { $ch = ' '; $co = $null }
                if ($co -ne $curColor) {
                    if ($curColor) { Write-Host $curText -NoNewline -ForegroundColor $curColor }
                    else { Write-Host $curText -NoNewline }
                    $curText = ''; $curColor = $co
                }
                $curText += $ch
            }
            if ($curColor) { Write-Host $curText -ForegroundColor $curColor }
            else { Write-Host $curText }
        }
    }
    Write-Host ''
}

# 直接作为脚本运行时自动展示；被 . 引入时只定义函数
if ($MyInvocation.InvocationName -ne '.') { Show-SmoBanner @args }
