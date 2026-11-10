# LocalConfigTool - 插件清单 lint（tests\Lint-Plugin.ps1）
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-Plugin.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-Plugin.ps1 -PluginRoot tests\fixtures\PluginSdk\good
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Lint-Plugin.ps1 -Quiet
#
# 作用：递归扫描 <root>\**\plugin.json（root 缺省 = 环境变量 LCT_PLUGIN_ROOT，否则 <工具根>\plugins），
#       逐个交给 core\PluginSdk.psm1 的 Test-LctPluginManifestV2 校验，覆盖
#       schema（id / entry / manifest 版本 / 字段形状）、能力名、入口种类名、路径越界（..）、sha256 实际相符。
#
# 退出码 = 问题数（0 = CLEAN）。**问题 == SDK 判定 ok=false 的清单**，保持两者严格一致：
#   * warnings（例如「按 v1 规则运行」的降级提示）与 engineApiOk=false 只打印为「提示」，不计数 ——
#     因为契约 §12.2 第 4/5 条明确要求 v1 老插件 ok=true、engineApi 不满足不得变成 ok=false。
#   * 因此 samples\plugins\cve-2026-49176（v1 清单）必须 0 问题，这正是 v1 兼容的硬证据。
#
# 只读：本脚本不修改任何插件文件、不启动任何插件进程；本文件自身也保持 ASCII 无关（含中文，UTF-8 带 BOM）。
param([string]$PluginRoot = '', [switch]$Quiet)

$toolRoot = Split-Path -Parent $PSScriptRoot
if (-not $toolRoot) { $toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$sdkPath = Join-Path $toolRoot 'core\PluginSdk.psm1'

$problems = New-Object System.Collections.ArrayList
$warns = New-Object System.Collections.ArrayList
$manifestCount = 0
$degradedCount = 0

function Add-LintProblem([string]$Message) {
    $null = $problems.Add($Message)
    Write-Host ('  [问题] ' + $Message)
}

function Add-LintWarn([string]$Message) {
    $null = $warns.Add($Message)
    if (-not $Quiet) { Write-Host ('  [提示] ' + $Message) }
}

# ---- 装载 SDK（缺模块属于环境问题，直接失败；不属于"清单问题"，固定 exit 1）----
if (-not (Test-Path -LiteralPath $sdkPath -PathType Leaf)) {
    Write-Host ('Lint-Plugin: 找不到 SDK 模块: ' + $sdkPath)
    exit 1
}
$sdkLoadError = ''
try {
    $null = Import-Module -Name $sdkPath -Force -ErrorAction Stop
} catch {
    $sdkLoadError = $_.Exception.Message
}
if ($sdkLoadError) {
    Write-Host ('Lint-Plugin: 装载 SDK 模块失败: ' + $sdkLoadError)
    exit 1
}

# ---- 解析扫描根目录 ----
$scanRoot = $PluginRoot
if ([string]::IsNullOrWhiteSpace($scanRoot)) {
    if ($env:LCT_PLUGIN_ROOT) { $scanRoot = $env:LCT_PLUGIN_ROOT } else { $scanRoot = Join-Path $toolRoot 'plugins' }
}
$rootPath = ''
try { $rootPath = (Resolve-Path -LiteralPath $scanRoot -ErrorAction Stop).Path } catch { $rootPath = '' }
if ([string]::IsNullOrWhiteSpace($rootPath)) {
    Write-Host ('Lint-Plugin: 插件根目录不存在: ' + $scanRoot)
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter 'plugin.json' -ErrorAction SilentlyContinue | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Host ('Lint-Plugin: 未找到任何 plugin.json（root=' + $rootPath + '）')
}

foreach ($file in @($files)) {
    $manifestCount++
    $rel = [string]$file.FullName
    if ($rel.StartsWith($rootPath)) { $rel = $rel.Substring($rootPath.Length).TrimStart('\', '/') }
    $dir = [string]$file.Directory.FullName
    $dirName = [string]$file.Directory.Name

    $text = $null
    $readError = ''
    try {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        $readError = '读取失败: ' + $_.Exception.Message
    }
    if ($readError) {
        Add-LintProblem ($rel + '  ' + $readError)
        continue
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Add-LintProblem ($rel + '  清单内容为空')
        continue
    }

    $obj = $null
    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        Add-LintProblem ($rel + '  不是合法 JSON: ' + $_.Exception.Message)
        continue
    }
    if ($null -eq $obj) {
        Add-LintProblem ($rel + '  不是合法 JSON 对象')
        continue
    }

    $result = $null
    try {
        $result = Test-LctPluginManifestV2 -Obj $obj -Dir $dir -Id $dirName
    } catch {
        # SDK 契约要求「任何函数都不得 throw」；这里兜底报成问题，绝不让 lint 自己崩掉
        Add-LintProblem ($rel + '  SDK 校验内部异常（违反「不得 throw」约定）: ' + $_.Exception.Message)
        continue
    }
    if ($null -eq $result) {
        Add-LintProblem ($rel + '  SDK 未返回校验结果')
        continue
    }

    foreach ($e in @($result.errors)) { Add-LintProblem ($rel + '  ' + [string]$e) }
    foreach ($w in @($result.warnings)) { Add-LintWarn ($rel + '  ' + [string]$w) }
    # engineApiOk=false 这一事实已由上面 SDK 的 warnings 说明（含 reason 与当前引擎版本），此处不再重复一条。

    if ([bool]$result.degraded) { $degradedCount++ }
    if (-not $Quiet) {
        $capText = '(无)'
        if (@($result.capabilities).Count -gt 0) { $capText = (@($result.capabilities) -join ',') }
        $kindText = '(无)'
        if (@($result.kinds).Count -gt 0) { $kindText = (@($result.kinds) -join ',') }
        $verdict = '通过'
        if (-not [bool]$result.ok) { $verdict = '不通过' }
        Write-Host ('  [清单] ' + $rel + '  manifest=v' + [string]$result.manifestVersion + '  种类=' + $kindText + '  能力=' + $capText + '  ' + $verdict)
    }
}

Write-Host ('Lint-Plugin: 清单={0} 问题={1} 提示={2} v1降级={3} root={4}' -f $manifestCount, @($problems).Count, @($warns).Count, $degradedCount, $rootPath)
if (@($problems).Count -eq 0) { Write-Host 'Lint-Plugin: CLEAN' }
exit @($problems).Count