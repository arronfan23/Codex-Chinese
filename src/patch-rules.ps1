#Requires -Version 5.1
<#
.SYNOPSIS
  Codex 本地化补丁规则库（多版本兼容 + 自动诊断）
.DESCRIPTION
  定义针对 Codex 桌面版 app.asar 内 JS 的补丁点规则。
  每条规则 = 在指定目录范围的 *.js 中做字符串替换。
  Critical 规则未命中 => 界面一定不会本地化，需提示用户并提供诊断片段。
  规则按"内容"搜索，不依赖带哈希的文件名，因此跨版本仍可用。
#>

function Get-CodexPatchRules {
    return @(
        @{
            Scope    = 'webview\assets'
            Pattern  = '.get(`enable_i18n`,!1)'
            Replace  = '.get(`enable_i18n`,!0)'
            Desc     = '开启官方多语言开关 enable_i18n（关键，否则界面永远英文；泛化匹配，兼容变量名混淆变化）'
            Critical = $true
        },
        @{
            Scope    = '.vite\build'
            Pattern  = 'getLocale():`en`'
            Replace  = 'getLocale():`zh-CN`'
            Desc     = 'getLocale 回退语言 en -> zh-CN（26.930.x 实测命中）'
            Critical = $false
        },
        @{
            Scope    = '.vite\build'
            Pattern  = 'xte=`en`'
            Replace  = 'xte=`zh-CN`'
            Desc     = '默认语言 en -> zh-CN（旧版本兼容）'
            Critical = $false
        }
    )
}

# 对单条规则执行补丁（Apply 为 $false 时只检测不写入）
function Invoke-CodexPatchRule {
    param(
        [string]$ExtractedDir,
        [hashtable]$Rule,
        [switch]$Apply
    )
    $scopeDir = Join-Path $ExtractedDir $Rule.Scope
    if (-not (Test-Path -LiteralPath $scopeDir)) { return @{ Hits = 0; Files = @() } }
    $hits = 0
    $patchedFiles = @()
    foreach ($js in (Get-ChildItem -LiteralPath $scopeDir -Filter '*.js' -File)) {
        $text = [System.IO.File]::ReadAllText($js.FullName)
        if (-not $text.Contains($Rule.Pattern)) { continue }
        $hits++
        if ($Apply) {
            $new = $text.Replace($Rule.Pattern, $Rule.Replace)
            if ($new -ne $text) {
                [System.IO.File]::WriteAllText($js.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
                $patchedFiles += $js.Name
            }
        } else {
            $patchedFiles += $js.Name
        }
    }
    return @{ Hits = $hits; Files = $patchedFiles }
}

# 对全部规则执行补丁，返回汇总结果
function Invoke-CodexAllPatches {
    param(
        [string]$ExtractedDir,
        [switch]$Apply
    )
    $rules = Get-CodexPatchRules
    $results = @()
    foreach ($r in $rules) {
        $res = Invoke-CodexPatchRule -ExtractedDir $ExtractedDir -Rule $r -Apply:$Apply
        $results += [pscustomobject]@{
            Scope    = $r.Scope
            Pattern  = $r.Pattern
            Desc     = $r.Desc
            Critical = $r.Critical
            Hits     = $res.Hits
            Files    = ($res.Files -join ', ')
        }
    }
    return $results
}

# 诊断：Critical 规则未命中时，在相关 JS 中提取语言相关上下文，便于维护者更新规则
function Find-LocaleContext {
    param([string]$ExtractedDir)
    $roots = @('webview\assets', '.vite\build')
    $keywords = @('enable_i18n', 'getLocale', 'locale_source', 'IntlProvider')
    $snippets = @()
    foreach ($r in $roots) {
        $dir = Join-Path $ExtractedDir $r
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($js in (Get-ChildItem -LiteralPath $dir -Filter '*.js' -File)) {
            $text = [System.IO.File]::ReadAllText($js.FullName)
            foreach ($kw in $keywords) {
                $i = $text.IndexOf($kw)
                if ($i -ge 0) {
                    $start = [Math]::Max(0, $i - 120)
                    $len = [Math]::Min(360, $text.Length - $start)
                    $snippet = $text.Substring($start, $len)
                    $snippets += "[$($r)\$($js.Name)] ... $snippet ..."
                    break
                }
            }
        }
    }
    return $snippets
}
