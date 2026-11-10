# LocalConfigTool - 引擎命令行入口（前端与人都通过它访问引擎；stdout 只输出最终 JSON）
# 维护者：Lead。契约见 docs\CONTRACT.md §5。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 -Verb <v> [-Args <json|@文件|文件>] [-Apply] [-Out json|text]
#
# 设计要点：
#   1) 前端拿 stdout 当 JSON 解析，所以这里必须压制一切 host 输出（Write-Host/Write-Warning/进度条），
#      只允许最后一行是 JSON；所有留痕走 var\logs 里的日志文件。
#   2) Windows PowerShell 5.1 的 ConvertTo-Json 会把中文转义成 \uXXXX，因此 stdout 是纯 ASCII，
#      不会被控制台代码页破坏（这正是本项目反复踩坑的地方）。
param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(Position = 1)][Alias('Args')][string]$ArgsJson,
    # 推荐通道：含引号/反斜杠的 JSON 请走文件（-ArgsFile 或 -Args @文件）；内联形式在跨进程命令行层会被转义规则破坏
    [string]$ArgsFile = '',
    [switch]$Apply,
    [ValidateSet('json', 'text')][string]$Out = 'json',
    [string]$VarDir = '',
    [string]$PluginRoot = ''
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if ($VarDir) { $env:LCT_VAR_DIR = $VarDir }
if ($PluginRoot) { $env:LCT_PLUGIN_ROOT = $PluginRoot }
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'Engine.psm1') -Force

# -Args 解析：@文件 | 存在的文件路径 | 内联 JSON 字符串
$parsed = $null
$argError = ''
if ($ArgsFile) {
    if (Test-Path -LiteralPath $ArgsFile) { $ArgsJson = "@" + $ArgsFile }
    else { $argError = "参数文件不存在: $ArgsFile" }
}
if (-not $argError -and $ArgsJson) {
    $text = $null
    if ($ArgsJson.StartsWith('@')) {
        $p = $ArgsJson.Substring(1)
        if (Test-Path -LiteralPath $p) { $text = Get-Content -LiteralPath $p -Raw -Encoding UTF8 }
        else { $argError = "参数文件不存在: $p" }
    } elseif (Test-Path -LiteralPath $ArgsJson -PathType Leaf) {
        $text = Get-Content -LiteralPath $ArgsJson -Raw -Encoding UTF8
    } else {
        $text = $ArgsJson
    }
    if (-not $argError -and $text) {
        try { $parsed = $text | ConvertFrom-Json }
        catch { $argError = "参数 JSON 解析失败: " + $_.Exception.Message }
    }
}

if (-not $Verb) {
    $result = New-LctResult -Verb 'engine' -Errors @('缺少 -Verb。可用能力见: engine.verbs')
} elseif ($argError) {
    $result = New-LctResult -Verb $Verb -Errors @($argError)
} else {
    $result = Invoke-LctEngine -Verb $Verb -Args $parsed -Apply:$Apply
}

if ($Out -eq 'json') {
    $json = $result | ConvertTo-Json -Depth 12
    [Console]::Out.WriteLine($json)
} else {
    Write-Host ("verb    : " + $result.verb)
    Write-Host ("ok      : " + $result.ok + "     applied: " + $result.applied + $(if ($Apply) { '' } else { '   (未加 -Apply，仅预览)' }))
    foreach ($c in @($result.changes)) {
        Write-Host ("  [" + $c.kind + "] " + $c.target + " / " + $c.name + " : " + $c.before + " -> " + $c.after + $(if ($c.note) { '   ' + $c.note } else { '' }))
    }
    foreach ($w in @($result.warnings)) { Write-Host ("  ! " + $w) }
    foreach ($e in @($result.errors)) { Write-Host ("  x " + $e) }
    if ($result.backupId) { Write-Host ("  backupId: " + $result.backupId) }
    if ($null -ne $result.data) { Write-Host ("data    : " + ($result.data | ConvertTo-Json -Depth 8 -Compress)) }
    Write-Host ("log     : " + $result.log)
}

if ($result.ok) { exit 0 } else { exit 1 }