#Requires -Version 5.1
<#
.SYNOPSIS
  Codex 桌面版本地化安装器（开源通用版）
.DESCRIPTION
  - 自动检测 Codex 安装：
      * Microsoft Store 版（MSIX，目录受保护） -> 复制可写副本后打补丁
      * 官网安装版（EXE/MSI，目录可写）      -> 直接对安装目录打补丁（自动备份）
  - 通过补丁规则库开启官方多语言（默认中文；语言可在应用内设置切换，中英自由切换）
  - 支持自动更新适配：记录版本与补丁信息，更新后由启动器自动重新打补丁
  - 全程无需管理员权限；绝不修改 WindowsApps 原安装
.PARAMETER InstallPath  手动指定 app 目录或安装根目录（自动检测失败时使用）
.PARAMETER Language     目标语言代码，默认 zh-CN（用于快捷方式/启动参数与提示）
.PARAMETER CopyMode     强制"复制副本"模式（默认自动：受保护目录用副本，可写目录直接补丁）
.PARAMETER NoShortcut   不创建桌面快捷方式
.PARAMETER Silent       静默模式（供启动器自动调用）
.PARAMETER DryRun       只检测并报告，不执行复制/补丁
.PARAMETER Force        强制重新复制/补丁（忽略版本与哈希比较）
.PARAMETER Root         本地化副本根目录（默认 %USERPROFILE%\.codex\codex-localized；可用环境变量 CODEX_LOCALIZE_ROOT 覆盖）
#>
[CmdletBinding()]
param(
    [string]$InstallPath,
    [string]$Language = 'zh-CN',
    [switch]$CopyMode,
    [switch]$NoShortcut,
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$Force,
    [string]$Root   # 本地化副本根目录（默认 %USERPROFILE%\.codex\codex-localized；可用环境变量 CODEX_LOCALIZE_ROOT 覆盖）
)

$ErrorActionPreference = 'Stop'

# 注：PS 5.1 + 控制台 UTF-8 代码页(65001)下，彩色 Write-Host 输出中文在换行处
# 可能触发 conhost bug 抛 IndexOutOfRangeException——输出失败绝不应中断安装。
function Write-Info { param([string]$m) try { Write-Host "[信息] $m" -ForegroundColor Cyan } catch { try { [System.Console]::WriteLine("[信息] $m") } catch {} } }
function Write-Ok   { param([string]$m) try { Write-Host "[成功] $m" -ForegroundColor Green } catch { try { [System.Console]::WriteLine("[成功] $m") } catch {} } }
function Write-Warn { param([string]$m) try { Write-Host "[警告] $m" -ForegroundColor Yellow } catch { try { [System.Console]::WriteLine("[警告] $m") } catch {} } }
function Write-Err  { param([string]$m) try { Write-Host "[错误] $m" -ForegroundColor Red } catch { try { [System.Console]::WriteLine("[错误] $m") } catch {} } }

$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $env:USERPROFILE }
$localizeRoot = $Root
if ([string]::IsNullOrWhiteSpace($localizeRoot)) { $localizeRoot = $env:CODEX_LOCALIZE_ROOT }
if ([string]::IsNullOrWhiteSpace($localizeRoot)) { $localizeRoot = Join-Path $userProfile '.codex\codex-localized' }
$localizeRoot = [System.IO.Path]::GetFullPath($localizeRoot)
$legacyRoot   = Join-Path $userProfile '.codex\zh-cn-patched'
$configFile   = Join-Path $localizeRoot 'install.json'
$versionFile  = Join-Path $localizeRoot 'version.txt'
$logFile      = Join-Path $localizeRoot 'install.log'
$scriptDir    = $PSScriptRoot

# 简单日志
function Write-Log { param([string]$m) try { Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# ---------- 工具 ----------
. (Join-Path $scriptDir 'asar-util.ps1')
. (Join-Path $scriptDir 'patch-rules.ps1')
. (Join-Path $scriptDir 'smo-banner.ps1')

# ---------- 带重试的封装 ----------
function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$Retries = 3, [int]$DelaySec = 3, [string]$What = '操作')
    for ($i = 1; $i -le $Retries; $i++) {
        try { return (& $Action) }
        catch {
            Write-Warn "$What 第 $i/$Retries 次失败：$($_.Exception.Message)"
            if ($i -lt $Retries) { Write-Info "$DelaySec 秒后重试..."; Start-Sleep -Seconds $DelaySec }
            else { throw }
        }
    }
}

# ---------- 查找 Codex 安装 ----------
function Find-CodexInstall {
    param([string]$Override)
    $candidates = @()
    if ($Override) {
        foreach ($p in @($Override, (Join-Path $Override 'app'))) {
            if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and ((Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'codex.exe')))) {
                $full = (Get-Item -LiteralPath $p).FullName
                $kind = if ($full -like '*\WindowsApps\*') { 'store' } else { 'exe' }
                return @{ AppDir = $full; Kind = $kind }
            }
        }
    }
    # 1) Store 版（MSIX）
    try {
        $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
        if (-not $pkg) { try { $pkg = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1 } catch {} }
        if ($pkg -and $pkg.InstallLocation) {
            foreach ($p in @((Join-Path $pkg.InstallLocation 'app'), $pkg.InstallLocation)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'store' }
                }
            }
        }
    } catch {}
    try {
        $dirs = Get-ChildItem -LiteralPath "$env:ProgramFiles\WindowsApps" -Directory -Filter 'OpenAI.Codex*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            foreach ($p in @((Join-Path $d.FullName 'app'), $d.FullName)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'store' }
                }
            }
        }
    } catch {}
    # 2) 官网安装版（EXE/MSI，卸载注册表）
    try {
        $uninst = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($root in $uninst) {
            Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { ($_.DisplayName -match 'Codex') -and ($_.InstallLocation -or $_.DisplayIcon) } | ForEach-Object {
                $base = $null
                if ($_.InstallLocation) { $base = $_.InstallLocation }
                elseif ($_.DisplayIcon -and (Test-Path -LiteralPath $_.DisplayIcon)) { $base = Split-Path $_.DisplayIcon -Parent }
                if ($base) {
                    foreach ($p in @($base, (Join-Path $base 'app'), (Join-Path $base 'resources'))) {
                        if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                            return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'exe' }
                        }
                    }
                }
            }
        }
    } catch {}
    return $null
}

function Get-CodexVersion {
    param([string]$AppDir)
    $leaf = Split-Path (Split-Path $AppDir -Parent) -Leaf
    if ($leaf -match 'OpenAI\.Codex_([0-9][0-9.]*)') { return $Matches[1] }
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
    if ($pkg -and $pkg.Version) { return $pkg.Version }
    return 'unknown'
}

# ---------- 目录是否可写 ----------
function Test-DirWritable {
    param([string]$Dir)
    try {
        $probe = Join-Path $Dir ('.wtest-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# ---------- 字节流递归复制（EFS 安全）----------
function Copy-TreeBytes {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($Src)) {
        Copy-TreeBytes -Src $dir -Dst (Join-Path $Dst ([System.IO.Path]::GetFileName($dir)))
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($Src)) {
        $name = [System.IO.Path]::GetFileName($file)
        $target = Join-Path $Dst $name
        Copy-FileRobust -Src $file -Dst $target
    }
}

# 单文件复制（带重试）：目标已存在且只读/残留占用时，清属性删除后重试一次；
# 仍失败则记入 $script:copyFailed，最后统一报错提示（杀毒软件/勒索防护可能拦截 DLL 写入）
$script:copyFailed = @()
function Copy-FileRobust {
    param([string]$Src, [string]$Dst)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            if ($attempt -eq 2 -and [System.IO.File]::Exists($Dst)) {
                [System.IO.File]::SetAttributes($Dst, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($Dst)
            }
            $in = [System.IO.File]::OpenRead($Src)
            try {
                $out = [System.IO.File]::Create($Dst)
                try {
                    $buf = New-Object byte[] (8MB)
                    while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $r)
                        $script:copyBytes += $r
                        Write-ThrottledProgress -Activity '复制 Codex 副本' -Status ("{0:N0}/{1:N0} MB" -f ($script:copyBytes/1MB), ($script:copyTotalBytes/1MB)) -Percent (100.0 * $script:copyBytes / [Math]::Max([long]1, $script:copyTotalBytes))
                    }
                } finally { $out.Dispose() }
            } finally { $in.Dispose() }
            return
        } catch [System.UnauthorizedAccessException] {
            if ($attempt -eq 2) {
                $script:copyFailed += $Src
                return
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Copy-FileBytes {
    param([string]$Src, [string]$Dst)
    $in = [System.IO.File]::OpenRead($Src)
    try {
        $out = [System.IO.File]::Create($Dst)
        try {
            $buf = New-Object byte[] (8MB)
            while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $r) }
        } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

# ---------- 关闭目标目录下的 Codex 进程（路径校验后）----------
function Stop-CodexProcesses {
    param([string[]]$Roots)
    # 按可执行文件路径匹配（不按进程名）：副本目录下的 node.exe / codex-computer-use.exe
    # 等子进程也加载着副本的 DLL，进程名过滤杀不到它们，复制时会因文件被占用而 Access Denied
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
    foreach ($p in $victims) {
        try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    Start-Sleep -Seconds 1
}

# ---------- 补丁（解包 -> 规则库 -> 重打包(重试) -> 原子替换）----------

# 同步 exe 内嵌的 asar 完整性哈希。
# 新版 Electron 开启 EnableEmbeddedAsarIntegrityValidation：启动时计算 app.asar
# 头部 JSON 的 SHA256，与 exe 内嵌记录比对，不一致直接 FATAL 退出（进程秒退、无任何窗口）。
# 修改过 app.asar 后必须把新哈希写回 exe（定长 64 字符十六进制，原地替换）。
function Sync-ExeAsarIntegrity {
    param([string]$AppDir, [string]$AsarPath)
    $exe = Join-Path $AppDir 'ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return }
    # 1) 新头部哈希（offset 16 起的 jsonLen 字节）
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(12, [System.IO.SeekOrigin]::Begin) | Out-Null
        $jsonLen = [int]$br.ReadUInt32()
        $fs.Seek(16, [System.IO.SeekOrigin]::Begin) | Out-Null
        $jsonBytes = $br.ReadBytes($jsonLen)
    } finally { $fs.Dispose() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $newHash = -join ($sha.ComputeHash($jsonBytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }

    # 2) 定位 exe 内嵌记录并替换
    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $needle = '"file":"resources\\app.asar","alg":"SHA256","value":"'
    $idx = $text.IndexOf($needle)
    if ($idx -lt 0) { Write-Info "exe 内未发现 asar 完整性记录（该版本未启用校验），跳过。"; return }
    $hashStart = $idx + $needle.Length
    $oldHash = $text.Substring($hashStart, 64)
    if ($oldHash -notmatch '^[0-9a-f]{64}$') { Write-Warn "asar 完整性记录格式异常，跳过（可能导致无法启动）。"; return }
    if ($oldHash -eq $newHash) { Write-Info "exe 完整性记录已一致。"; return }
    $bak = $exe + '.bak'
    if (-not (Test-Path -LiteralPath $bak)) { Copy-FileBytes -Src $exe -Dst $bak }
    $newBytes = [System.Text.Encoding]::ASCII.GetBytes($newHash)
    $fs2 = [System.IO.File]::OpenWrite($exe)
    try {
        $fs2.Seek($hashStart, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fs2.Write($newBytes, 0, 64)
    } finally { $fs2.Dispose() }
    Write-Ok ("已同步 exe 内嵌 asar 完整性哈希（{0}... -> {1}...）" -f $oldHash.Substring(0, 12), $newHash.Substring(0, 12))
}

function Patch-App {
    param([string]$AppDir, [string]$Work)
    $asar = Join-Path $AppDir 'resources\app.asar'
    $extracted = Join-Path $Work 'asar-extracted'
    Write-Info "解包 app.asar ..."
    Expand-Asar -AsarPath $asar -OutDir $extracted -Force | Out-Null

    Write-Info "应用补丁规则 ..."
    $summary = Invoke-CodexAllPatches -ExtractedDir $extracted -Apply
    $criticalMiss = @($summary | Where-Object { $_.Critical -and $_.Hits -eq 0 })
    foreach ($s in $summary) {
        $mark = if ($s.Hits -gt 0) { '命中' } else { '未命中' }
        Write-Info ("补丁[{0}] {1}（{2}）" -f $mark, $s.Desc, $s.Scope)
        if ($s.Hits -gt 0 -and $s.Files) { Write-Info ("    文件: " + $s.Files) }
    }
    if ($criticalMiss.Count -gt 0) {
        Write-Warn "关键补丁点未命中，当前 Codex 版本可能已变更语言机制。"
        Write-Warn "以下为自动提取的上下文片段，可反馈给项目维护者以更新规则："
        foreach ($snip in (Find-LocaleContext -ExtractedDir $extracted)) {
            Write-Warn "    $snip"
        }
        Write-Warn "界面可能仍为英文（功能不受影响）。"
    }

    $newAsar = Join-Path $Work 'app.asar.new'
    Write-Info "重新打包 app.asar（失败自动重试）..."
    Invoke-WithRetry -What '重打包' -Action {
        New-Asar -InDir $extracted -OutPath $newAsar -OriginalAsar $asar -Force | Out-Null
    }
    $fi = Get-Item -LiteralPath $newAsar
    if ($fi.Length -le 0) { throw "重打包产物为空：$newAsar" }
    Write-Ok ("重打包完成：{0:N1} MB" -f ($fi.Length / 1MB))

    # 备份原始 asar（仅首次）
    $bak = Join-Path $AppDir 'resources\app.asar.bak'
    if (-not (Test-Path -LiteralPath $bak)) { Copy-FileBytes -Src $asar -Dst $bak }

    # 原子替换：先写 .tmp，校验头部，再 Move 覆盖
    $resDir = Join-Path $AppDir 'resources'
    $tmpAsar = Join-Path $resDir 'app.asar.tmp'
    Copy-FileBytes -Src $newAsar -Dst $tmpAsar
    $hdr = Read-AsarHeader -AsarPath $tmpAsar   # 校验
    try {
        Move-Item -LiteralPath $tmpAsar -Destination $asar -Force
    } catch {
        Write-Err "替换 app.asar 失败：$($_.Exception.Message)"
        if (Test-Path -LiteralPath $tmpAsar) { Remove-Item -LiteralPath $tmpAsar -Force -ErrorAction SilentlyContinue }
        throw "请确认 Codex（含本地化副本）已完全退出后重试。"
    }
    Write-Ok "补丁完成并已替换 app.asar"
    Sync-ExeAsarIntegrity -AppDir $AppDir -AsarPath $asar
    # 立即清理本次工作目录（解包文件 + 中间 asar，动辄数百 MB），别等下次运行
    try { Remove-TreeLong -Path $Work } catch {}
}

# ---------- 磁盘空间预检 ----------
# 峰值占用 ≈ 副本本身 + 解包文件 + 新 asar + 替换用 tmp ≈ 副本大小 + 3× asar 大小
function Test-DiskSpace {
    param([string]$RootDir, [long]$NeedBytes)
    try {
        $driveLetter = [System.IO.Path]::GetPathRoot($RootDir).TrimEnd('\')
        $free = (New-Object System.IO.DriveInfo($driveLetter)).AvailableFreeSpace
    } catch { return }  # 取不到就放行，失败时按磁盘错误提示
    if ($free -lt $NeedBytes) {
        Write-Err ("磁盘空间不足：{0} 盘剩余 {1:N1} GB，本次安装约需 {2:N1} GB（副本 + 临时解包/重打包文件）。" -f $driveLetter, ($free/1GB), ($NeedBytes/1GB))
        Write-Warn "解决办法：1) 清理该盘空间后重试；2) 用其他盘的目录作为工作目录，例如："
        Write-Warn "    setx CODEX_LOCALIZE_ROOT D:\codex-localized   （设置后重开终端再运行）"
        exit 1
    }
    Write-Info ("磁盘空间检查通过：{0} 盘剩余 {1:N1} GB，预计需 {2:N1} GB" -f $driveLetter, ($free/1GB), ($NeedBytes/1GB))
}

# ---------- 写/读配置 ----------
function Write-InstallConfig {
    param([hashtable]$Config)
    $json = $Config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($configFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-InstallConfig {
    if (-not (Test-Path -LiteralPath $configFile)) { return $null }
    try { return (Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------- 主流程 ----------
try { Show-SmoBanner } catch {}
Write-Info "Codex 中文本地化工具  |  arronfan23/Codex-Chinese"
Write-Log "启动安装器"
New-Item -ItemType Directory -Force -Path $localizeRoot | Out-Null

$found = Find-CodexInstall -Override $InstallPath
if (-not $found) {
    Write-Err "未找到 Codex。请确认已安装（Microsoft Store 或官网版），或用 -InstallPath 手动指定 app 目录。"
    Write-Log "未找到 Codex 安装"
    exit 1
}
$appDir = $found.AppDir
$kind = $found.Kind
$version = Get-CodexVersion -AppDir $appDir
Write-Ok "检测到 Codex：$appDir（形态：$(if($kind -eq 'store'){'Store/MSIX 受保护'}else{'官网版/可写'})，版本 $version）"
Write-Log "检测到 $appDir kind=$kind version=$version"

# 决定补丁目标目录
$writable = Test-DirWritable -Dir $appDir
$useCopy = $CopyMode -or (-not $writable)
if ($useCopy) {
    $targetApp = Join-Path $localizeRoot 'app'
    # 平滑迁移：若旧副本 zh-cn-patched\app 存在且版本一致，直接复用
    if (-not (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe'))) {
        $legacyApp = Join-Path $legacyRoot 'app'
        if ((Test-Path -LiteralPath (Join-Path $legacyApp 'ChatGPT.exe')) -and (Test-Path -LiteralPath (Join-Path $legacyApp 'resources\app.asar'))) {
            $lv = Get-CodexVersion -AppDir $legacyApp
            if ($lv -eq $version) {
                Write-Info "检测到旧版汉化副本（$legacyRoot），版本一致，将复用并迁移。"
                New-Item -ItemType Directory -Force -Path $localizeRoot | Out-Null
                Move-Item -LiteralPath $legacyApp -Destination $targetApp -Force
            }
        }
    }
    $mode = 'store-copy'
} else {
    $targetApp = $appDir
    $mode = 'direct'
}
Write-Info ("补丁模式：{0}" -f $(if($mode -eq 'store-copy'){'复制副本（推荐，不影响原版）'}else{'直接补丁安装目录（目录可写）'}))
Write-Info "目标目录：$targetApp"
Write-Log "模式=$mode 目标=$targetApp"

if ($DryRun) {
    $need = -not ((Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')) -and (Test-Path -LiteralPath (Join-Path $targetApp 'resources\app.asar')))
    Write-Info ("DryRun：{0}" -f $(if($need){'需要安装/更新'}else{'副本已存在'}))
    exit 0
}

# 关闭补丁目标目录下的进程。注意：副本模式下只关副本，绝不动正在运行的原版；
# 直补模式下 targetApp 即安装目录本身，此时才需要关闭原版进程。
Stop-CodexProcesses -Roots @($targetApp)

# 是否需要复制（仅 copy 模式）
$needCopy = $false
$asarSizeBytes = [long](Get-Item -LiteralPath (Join-Path $appDir 'resources\app.asar')).Length
if ($mode -eq 'store-copy') {
    $storeAsar = Join-Path $appDir 'resources\app.asar'
    $copyAsar  = Join-Path $targetApp 'resources\app.asar'
    $bakAsar   = Join-Path $targetApp 'resources\app.asar.bak'
    $needCopy = $Force -or (-not (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')))
    if (-not $needCopy) {
        $ref = $null
        if (Test-Path -LiteralPath $bakAsar) { $ref = $bakAsar }
        elseif (Test-Path -LiteralPath $copyAsar) { $ref = $copyAsar }
        if ($ref) {
            try {
                $h1 = (Get-FileHash -LiteralPath $storeAsar -Algorithm SHA256).Hash
                $h2 = (Get-FileHash -LiteralPath $ref -Algorithm SHA256).Hash
                if ($h1 -ne $h2) { $needCopy = $true }
            } catch { $needCopy = $true }
        }
    }
    if (-not $needCopy) {
        # 副本完整性校验：asar 一致不代表副本完整（上次复制被中断会留下半成品，
        # 缺 DLL 时启动报"找不到 chrome_elf.dll 系统错误"）。逐文件比对：源里有的，
        # 副本里必须存在且大小一致（app.asar 除外——补丁后大小会变，由上面的哈希逻辑负责）。
        Write-Info "校验副本完整性 ..."
        try {
            $dstMap = @{}
            foreach ($f in [System.IO.Directory]::EnumerateFiles($targetApp, '*', [System.IO.SearchOption]::AllDirectories)) {
                $fi = New-Object System.IO.FileInfo($f)
                $dstMap[$fi.FullName.Substring($targetApp.Length).TrimStart('\')] = $fi.Length
            }
            foreach ($f in [System.IO.Directory]::EnumerateFiles($appDir, '*', [System.IO.SearchOption]::AllDirectories)) {
                $fi = New-Object System.IO.FileInfo($f)
                $rel = $fi.FullName.Substring($appDir.Length).TrimStart('\')
                if ($rel -ieq 'resources\app.asar') { continue }
                if (-not $dstMap.ContainsKey($rel) -or $dstMap[$rel] -ne $fi.Length) {
                    Write-Warn "副本不完整：$rel"
                    $needCopy = $true
                    break
                }
            }
            if (-not $needCopy) { Write-Info "副本完整性校验通过（$($dstMap.Count) 个文件）。" }
        } catch { $needCopy = $true }
        if ($needCopy) { Write-Info "副本缺失或被截断，将重新复制。" }
    }
    if ($needCopy) {
        # 磁盘空间预检：峰值 ≈ 副本大小 + 3× asar 临时文件（解包/重打包/替换）
        $script:copyTotalBytes = [long]0
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($appDir, '*', [System.IO.SearchOption]::AllDirectories)) {
                $script:copyTotalBytes += (New-Object System.IO.FileInfo($f)).Length
            }
        } catch {}
        Test-DiskSpace -RootDir $targetApp -NeedBytes ($script:copyTotalBytes + ($asarSizeBytes * 3) + 200MB)
        if (-not $Silent) {
            $ans = Read-Host "将复制 Codex 到 $targetApp（约 1-2GB，仅首次），继续？[y/N]"
            if ($ans -notmatch '^[yY]') { Write-Warn "已取消"; exit 0 }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Info "复制 Codex 到 $targetApp ..."
        $script:copyBytes = [long]0
        Copy-TreeBytes -Src $appDir -Dst $targetApp
        Complete-UtilProgress -Activity '复制 Codex 副本'
        $sw.Stop()
        Write-Ok ("复制完成，耗时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
        $script:didCopy = $true
        if ($script:copyFailed.Count -gt 0) {
            Write-Err ("有 {0} 个文件复制失败：" -f $script:copyFailed.Count)
            $script:copyFailed | Select-Object -First 10 | ForEach-Object { Write-Err "    $_" }
            Write-Warn "常见原因：1) 本地化副本正在后台运行（请完全退出后重试）；2) 杀毒软件/Windows 勒索软件防护（Controlled Folder Access）拦截了 DLL 写入，请临时放行 powershell.exe 后重试。"
            throw "复制不完整，已中止。处理上述原因后重新运行本安装器即可。"
        }
    } else {
        Write-Info "副本与 Store 版一致，跳过复制。"
    }
}

# 是否需要补丁
$asarPath = Join-Path $targetApp 'resources\app.asar'
$needPatch = $Force -or (-not (Test-Path -LiteralPath $asarPath))
# 重新复制后副本是原版（未打补丁），必须重打，不能凭旧配置跳过
if ($script:didCopy) { $needPatch = $true }
$cfg = Read-InstallConfig
if (-not $needPatch) {
    # schemaVersion < 3 的副本是旧版工具打的（asar 对齐/完整性有 bug），必须重打
    $needPatch = -not ($cfg -and $cfg.schemaVersion -ge 3 -and $cfg.version -eq $version -and (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')))
}
if ($needPatch -and -not $needCopy) {
    # 不复制但需要重打补丁：仍需 3× asar 的临时空间
    Test-DiskSpace -RootDir $targetApp -NeedBytes (($asarSizeBytes * 3) + 200MB)
}
if ($needPatch -and $cfg -and $cfg.version -eq $version -and $cfg.schemaVersion -lt 3) {
    # 旧版工具打过的副本：当前 asar/exe 已损坏，先从备份还原原版再重新打补丁
    $bakAsar = Join-Path $targetApp 'resources\app.asar.bak'
    if (Test-Path -LiteralPath $bakAsar) {
        Write-Info "检测到旧版工具的补丁副本，先从备份还原原始 app.asar ..."
        Copy-FileBytes -Src $bakAsar -Dst $asarPath
    }
    $exeBak = Join-Path $targetApp 'ChatGPT.exe.bak'
    $exeCur = Join-Path $targetApp 'ChatGPT.exe'
    if ((Test-Path -LiteralPath $exeBak) -and (Test-Path -LiteralPath $exeCur)) {
        Copy-FileBytes -Src $exeBak -Dst $exeCur
    }
}
if ($needPatch) {
    $workDir = Join-Path $localizeRoot ("work-" + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    try {
        Patch-App -AppDir $targetApp -Work $workDir
    } catch {
        if ($_.Exception.Message -match 'space|空间|磁盘') {
            Write-Err "磁盘空间不足，补丁写入失败。清理空间后重试，或用 setx CODEX_LOCALIZE_ROOT D:\codex-localized 把工作目录换到其他盘（重开终端生效）。"
        }
        throw
    }
    # 清理旧的 work-*（只清本工具生成的）
    Get-ChildItem -LiteralPath $localizeRoot -Directory -Filter 'work*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $workDir } |
        ForEach-Object { try { Remove-TreeLong -Path $_.FullName } catch {} }
} else {
    Write-Info "已是最新，跳过补丁。"
}

# 写配置与版本
Write-InstallConfig -Config @{
    schemaVersion = 3
    mode          = $mode
    sourcePath    = $appDir
    installPath   = $targetApp
    version       = $version
    language      = $Language
    patchedAt     = (Get-Date).ToString('s')
}
Set-Content -LiteralPath $versionFile -Value $version -Encoding UTF8
Write-Log "安装完成 version=$version"

# 复制启动脚本到 localizeRoot（自包含）
foreach ($f in @('install.ps1', 'launch.ps1', 'asar-util.ps1', 'patch-rules.ps1', 'smo-banner.ps1')) {
    $srcF = Join-Path $scriptDir $f
    if (Test-Path -LiteralPath $srcF) {
        Copy-Item -LiteralPath $srcF -Destination (Join-Path $localizeRoot $f) -Force -ErrorAction SilentlyContinue
    }
}
$cmdContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launch.ps1`"`r`nif errorlevel 1 pause`r`n"
Set-Content -LiteralPath (Join-Path $localizeRoot 'launch.cmd') -Value $cmdContent -Encoding ASCII

# 桌面快捷方式（新建，不替换原有）
if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $exePath = Join-Path $targetApp 'ChatGPT.exe'
    $lnkPath = Join-Path $desktop 'Codex.lnk'
    if (-not (Test-Path -LiteralPath $exePath)) {
        $codexExe = Join-Path $targetApp 'resources\codex.exe'
        if (Test-Path -LiteralPath $codexExe) { $exePath = $codexExe }
    }
    if (Test-Path -LiteralPath $exePath) {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = Join-Path $localizeRoot 'launch.cmd'
        $sc.IconLocation = ($exePath + ',0')
        $sc.Description = '启动 Codex（中文本地化副本，原版保留，自动适配更新）'
        $sc.Save()
        Write-Ok "已创建桌面快捷方式：$lnkPath"
    }
}

Write-Ok "安装完成！以后请通过桌面『Codex』快捷方式启动（会自动适配更新）。"
Write-Ok "语言切换：启动后在 设置→General→Language 选择中文或 English 即可自由切换。"
if (-not $Silent) {
    $r = Read-Host "现在立即启动本地化版 Codex？[y/N]"
    if ($r -match '^[yY]') { & (Join-Path $localizeRoot 'launch.cmd') }
}
exit 0
