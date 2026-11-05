#Requires -Version 5.1
<#
.SYNOPSIS
  Codex 本地化版启动器（开源通用版）
.DESCRIPTION
  1) 读取安装配置 install.json（由 install.ps1 生成）
  2) 自动检测 Codex 版本变化，变化时静默重新打补丁（无需任何权限）
  3) 关闭正在运行的 Codex 进程（路径校验后）
  4) 启动本地化副本/目录
.PARAMETER ForceUpdate  强制先重新本地化再启动
.PARAMETER Language     覆盖启动语言（如 zh-CN / en，默认用安装时配置）
#>
[CmdletBinding()]
param(
    [switch]$ForceUpdate,
    [string]$Language
)

$ErrorActionPreference = 'Stop'

# 输出加兜底：控制台 UTF-8 代码页下彩色中文输出可能触发 conhost bug（见 install.ps1 注释）
function Write-Info { param([string]$m) try { Write-Host "[信息] $m" -ForegroundColor Cyan } catch { try { [System.Console]::WriteLine("[信息] $m") } catch {} } }
function Write-Ok   { param([string]$m) try { Write-Host "[成功] $m" -ForegroundColor Green } catch { try { [System.Console]::WriteLine("[成功] $m") } catch {} } }
function Write-Warn { param([string]$m) try { Write-Host "[警告] $m" -ForegroundColor Yellow } catch { try { [System.Console]::WriteLine("[警告] $m") } catch {} } }
function Write-Err  { param([string]$m) try { Write-Host "[错误] $m" -ForegroundColor Red } catch { try { [System.Console]::WriteLine("[错误] $m") } catch {} } }

$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $env:USERPROFILE }
$localizeRoot = $env:CODEX_LOCALIZE_ROOT
if ([string]::IsNullOrWhiteSpace($localizeRoot)) { $localizeRoot = Join-Path $userProfile '.codex\codex-localized' }
$localizeRoot = [System.IO.Path]::GetFullPath($localizeRoot)
$legacyRoot   = Join-Path $userProfile '.codex\zh-cn-patched'
$configFile   = Join-Path $localizeRoot 'install.json'
$scriptDir    = $PSScriptRoot

. (Join-Path $scriptDir 'asar-util.ps1')
. (Join-Path $scriptDir 'smo-banner.ps1')

function Get-CodexVersionFromDir {
    param([string]$AppDir)
    $leaf = Split-Path (Split-Path $AppDir -Parent) -Leaf
    if ($leaf -match 'OpenAI\.Codex_([0-9][0-9.]*)') { return $Matches[1] }
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
    if ($pkg -and $pkg.Version) { return $pkg.Version }
    return 'unknown'
}

function Get-StoreAppDir {
    try {
        $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            foreach ($p in @((Join-Path $pkg.InstallLocation 'app'), $pkg.InstallLocation)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return (Get-Item -LiteralPath $p).FullName
                }
            }
        }
    } catch {}
    try {
        $dirs = Get-ChildItem -LiteralPath "$env:ProgramFiles\WindowsApps" -Directory -Filter 'OpenAI.Codex*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            foreach ($p in @((Join-Path $d.FullName 'app'), $d.FullName)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return (Get-Item -LiteralPath $p).FullName
                }
            }
        }
    } catch {}
    return $null
}

function Stop-CodexProcesses {
    param([string[]]$Roots)
    # 按可执行文件路径匹配：副本目录下的 node.exe 等子进程也需一并关闭
    $procs = Get-Process -ErrorAction SilentlyContinue
    $victims = @()
    foreach ($p in $procs) {
        try {
            $pp = $p.Path
            if (-not $pp) { continue }
            foreach ($r in $Roots) {
                if ($pp.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { $victims += $p; break }
            }
        } catch {}
    }
    if ($victims.Count -eq 0) { return }
    Write-Info ("检测到 {0} 个 Codex 进程，准备关闭..." -f $victims.Count)
    foreach ($p in $victims) { try { $p.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 3
    # 循环强杀并验证清空：覆盖副本前必须确保目录下没有活进程
    $deadline = (Get-Date).AddSeconds(15)
    do {
        foreach ($p in $victims) {
            try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch {}
        }
        Start-Sleep -Seconds 2
        $alive = @()
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                $pp = $p.Path
                if (-not $pp) { continue }
                foreach ($r in $Roots) {
                    if ($pp.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { $alive += $p; break }
                }
            } catch {}
        }
    } while ($alive.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($alive.Count -gt 0) {
        Write-Warn ("仍有 {0} 个进程未能结束（可能以管理员身份运行）。" -f $alive.Count)
    }
}

# ---------- 主流程 ----------
try { Show-SmoBanner } catch {}
Write-Info "Codex 中文本地化版启动器  |  arronfan23/Codex-Chinese"

# 读取配置（兼容旧副本：无配置但存在 zh-cn-patched 时，提示先运行新安装器迁移）
$config = $null
if (Test-Path -LiteralPath $configFile) {
    try { $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if (-not $config) {
    $legacyApp = Join-Path $legacyRoot 'app'
    if (Test-Path -LiteralPath (Join-Path $legacyApp 'ChatGPT.exe')) {
        Write-Info "检测到旧版汉化副本（zh-cn-patched）。为使用新配置，请先运行一次 install.cmd 完成迁移。"
    } else {
        Write-Err "未找到本地化配置。请先运行 install.cmd。"
        exit 1
    }
}

$targetApp = $null
$sourceApp = $null
if ($config) {
    $targetApp = $config.installPath
    $sourceApp = $config.sourcePath
    $lang = if ($Language) { $Language } else { $config.language }
} else {
    $targetApp = $legacyApp
    $lang = 'zh-CN'
}

if (-not (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe'))) {
    Write-Err "本地化目标缺失：$targetApp。请重新运行 install.cmd。"
    exit 1
}

# 版本变化检测
$needReinstall = $ForceUpdate
if (-not $needReinstall -and $config) {
    try {
        $current = $null
        if ($config.mode -eq 'store-copy') {
            $storeDir = Get-StoreAppDir
            if ($storeDir) { $current = Get-CodexVersionFromDir -AppDir $storeDir }
        } else {
            $current = Get-CodexVersionFromDir -AppDir $targetApp
        }
        if ($current -and $current -ne $config.version) {
            Write-Info "版本变化：$($config.version) -> $current，需要重新本地化。"
            $needReinstall = $true
        }
    } catch {}
}

# 关闭旧进程（原版 + 本地化目标）
$roots = @($targetApp)
if ($sourceApp) { $roots += $sourceApp }
if ($config -and $config.mode -eq 'store-copy') { $storeDir = Get-StoreAppDir; if ($storeDir) { $roots += $storeDir } }
Stop-CodexProcesses -Roots $roots

if ($needReinstall) {
    Write-Info "正在自动重新本地化（静默）..."
    $installer = Join-Path $localizeRoot 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { $installer = Join-Path $scriptDir 'install.ps1' }
    if (-not (Test-Path -LiteralPath $installer)) { $installer = Join-Path $PSScriptRoot '..\src\install.ps1' }
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Err "找不到 install.ps1，无法自动更新。请重新运行 install.cmd。"
        exit 1
    }
    & $installer -Silent -NoShortcut -Language $lang
    if ($LASTEXITCODE -ne 0) { Write-Err "自动重新本地化失败（退出码 $LASTEXITCODE）。"; exit 1 }
    Write-Ok "自动重新本地化完成"
    # 重新读取配置（路径可能变化）
    if (Test-Path -LiteralPath $configFile) { try { $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if ($config) { $targetApp = $config.installPath }
}

$exePath = Join-Path $targetApp 'ChatGPT.exe'
if (-not (Test-Path -LiteralPath $exePath)) { Write-Err "启动文件缺失：$exePath"; exit 1 }

$argLine = ''
if ($lang) { $argLine = "--lang=$lang" }
Write-Info "启动：$exePath $argLine"
# 直接启动即可：asar 修复正确后副本不需要任何包身份注入。
# （早期"该进程没有程序包标识符"弹窗实为 asar 损坏的连带症状；
#  Invoke-CommandInDesktopPackage 在部分机器上会 AccessViolation 原生崩溃，已弃用）
$args = @()
if ($argLine) { $args += $argLine }
try {
    Start-Process -FilePath $exePath -ArgumentList $args
} catch {
    if ($_.Exception.Message -match 'Application Control|应用程序控制') {
        Write-Err "本机的应用程序控制策略（WDAC / Smart App Control / AppLocker）拦截了副本的启动。"
        Write-Warn "原因：汉化需要修改 app.asar 并同步 exe 哈希，这会使 ChatGPT.exe 的数字签名失效；"
        Write-Warn "开启应用控制的机器会拒绝运行签名失效的程序。这是系统安全策略，不是工具 bug。"
        Write-Warn "解决办法（任选其一）："
        Write-Warn "  1) Windows 11：设置 → 隐私和安全性 → Smart App Control → 关闭（关闭后不可再自动开启，请自行权衡）；"
        Write-Warn "  2) 企业/受管机器：请管理员在 WDAC/AppLocker 策略中将以下路径加入允许列表："
        Write-Warn "     $exePath"
        Write-Warn "  3) 使用原版 Codex（开始菜单入口不受影响，仅界面为英文）。"
    }
    throw
}
Write-Ok "已启动。语言可在 设置→General→Language 自由切换。"
exit 0
