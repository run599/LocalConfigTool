# LocalConfigTool - tests\AiTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\AiTest.ps1
#
# 守「AI 接入层」的四件事：
#   1) 清单可读且完整（AI 靠它决定能不能做、按什么顺序做）
#   2) 计划是确定性的、有序的，并且只读（不执行任何动作）
#   3) 确认闸门：mutating 的 -Apply 没有/用错一次性短语必须被拒；短语用后即焚
#   4) MCP 服务器可用：initialize / tools/list / tools/call 全链路
#
#   AT-1  ai.manifest ok、verb 数与 engine.verbs 一致、每条含 name/summary/mutating/needsElevation/args
#   AT-2  预置流程含 elevate-then-drive，且 plugins.run 排在 driver.load 之前
#   AT-3  needsElevation 正确：driver.load=admin、plugins.run=non-elevated、driver.map=none
#   AT-4  ai.plan 生成的步骤有序、applied=false（只读）
#   AT-5  ai.plan 发出一次性确认短语，并在 var\ai\pending 落盘
#   AT-6  确认短语：错误的被拒；正确的通过且用后即焚（第二次被拒）
#   AT-7  ai.run 执行 mutating+apply 无 confirm ⇒ 被拒（confirmRequired）
#   AT-8  ai.run 执行只读 verb 不需要 confirm
#   AT-9  ai.run 不能递归调用 ai.*
#   AT-10 MCP：initialize + tools/list(4 个) + tools/call(lct_call driver.map) 成功
#   AT-11 审计日志存在
#
# 退出码 = 失败数。本测试不加载驱动、不发 IOCTL、不提权。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-ai-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}

Write-Host '== AT-1: ai.manifest 完整性 =='
$man = Eng 'ai.manifest' $null
$verbs = @()
if ($null -ne $man -and $null -ne $man.data) { $verbs = @($man.data.verbs) }
$eng = Eng 'engine.verbs' $null
$engCount = 0
if ($null -ne $eng) { $engCount = @($eng.data.verbs).Count }
Check 'AT-1a ai.manifest ok=true' ($null -ne $man -and $man.ok -eq $true) ''
Check 'AT-1b verb 数与 engine.verbs 一致' (@($verbs).Count -eq $engCount -and $engCount -gt 0) ('manifest=' + @($verbs).Count + ' engine=' + $engCount)
$badEntry = @($verbs | Where-Object { [string]$_.name -eq '' -or $null -eq $_.PSObject.Properties['mutating'] -or $null -eq $_.PSObject.Properties['needsElevation'] -or $null -eq $_.PSObject.Properties['args'] })
Check 'AT-1c 每条都含 name/mutating/needsElevation/args' (@($badEntry).Count -eq 0) ('bad=' + @($badEntry).Count)
Check 'AT-1d 含安全规则与确认前缀' ($null -ne $man.data.PSObject.Properties['rules'] -and [string]$man.data.safety.confirmPrefix -eq 'I-UNDERSTAND-') ''

Write-Host ''
Write-Host '== AT-2: 预置流程顺序 =='
$flow = $null
if ($null -ne $man.data) { $flow = @($man.data.flows) | Where-Object { [string]$_.id -eq 'elevate-then-drive' } | Select-Object -First 1 }
Check 'AT-2a 存在 elevate-then-drive 流程' ($null -ne $flow) ''
$elevIdx = -1; $drvIdx = -1
if ($null -ne $flow) {
    $steps = @($flow.steps)
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ([string]$steps[$i].verb -eq 'plugins.run' -and $elevIdx -lt 0) { $elevIdx = $i }
        if ([string]$steps[$i].verb -eq 'driver.load' -and $drvIdx -lt 0) { $drvIdx = $i }
    }
}
Check 'AT-2b 提权步骤排在加载驱动之前' ($elevIdx -ge 0 -and $drvIdx -ge 0 -and $elevIdx -lt $drvIdx) ('elev=' + $elevIdx + ' driver=' + $drvIdx)

Write-Host ''
Write-Host '== AT-3: needsElevation 判定 =='
function Get-Need([string]$v) {
    $x = @($verbs) | Where-Object { [string]$_.name -eq $v } | Select-Object -First 1
    if ($null -eq $x) { return '<missing>' }
    return [string]$x.needsElevation
}
Check 'AT-3a driver.load = admin' ((Get-Need 'driver.load') -eq 'admin') ('got=' + (Get-Need 'driver.load'))
Check 'AT-3b plugins.run = non-elevated（提权插件要求非提权上下文）' ((Get-Need 'plugins.run') -eq 'non-elevated') ('got=' + (Get-Need 'plugins.run'))
Check 'AT-3c driver.map = none（只读）' ((Get-Need 'driver.map') -eq 'none') ('got=' + (Get-Need 'driver.map'))

Write-Host ''
Write-Host '== AT-4/5: ai.plan 只读且有顺序 =='
$plan = Eng 'ai.plan' @{ goal = '先提权到 system 然后再加载驱动' }
$steps = @()
if ($null -ne $plan -and $null -ne $plan.data) { $steps = @($plan.data.steps) }
Check 'AT-4a ai.plan ok=true' ($null -ne $plan -and $plan.ok -eq $true) ''
Check 'AT-4b 计划是只读的（applied=false）' ($null -ne $plan -and $plan.applied -eq $false) ''
Check 'AT-4c 第一步是 capability.status（先看权限）' (@($steps).Count -gt 0 -and [string]$steps[0].verb -eq 'capability.status') ('first=' + $(if (@($steps).Count -gt 0) { $steps[0].verb } else { '' }))
$driveStepCount = @($steps | Where-Object { [string]$_.verb -in @('driver.load', 'driver.use') }).Count
Check 'AT-4d 含加载驱动步骤（driver.use 或 driver.load）' ($driveStepCount -ge 1) ''
Check 'AT-5a 为 mutating 步骤发了确认短语' ([string]$plan.data.confirmPhrase -like 'I-UNDERSTAND-????????') ('phrase=' + [string]$plan.data.confirmPhrase)
$pendingDir = Join-Path $root 'var\ai\pending'
$hex = ([string]$plan.data.confirmPhrase) -replace '^I-UNDERSTAND-', ''
Check 'AT-5b 短语已落盘（var\ai\pending）' (Test-Path -LiteralPath (Join-Path $pendingDir ($hex + '.json'))) ('file=' + $hex + '.json')

Write-Host ''
Write-Host '== AT-6/7/8/9: 确认闸门 =='
Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $root 'core\Capabilities.psm1') -Force -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $root 'core\Ai.psm1') -Force -Global -ErrorAction SilentlyContinue

$badConfirm = $null
try { $badConfirm = Test-LctAiConfirm -Phrase 'I-UNDERSTAND-00000000' -Verb 'driver.load' -Args $null } catch { }
Check 'AT-6a 伪造/无效短语被拒' ($null -ne $badConfirm -and $badConfirm.ok -eq $false) ('err=' + $(if ($null -ne $badConfirm) { $badConfirm.error } else { '?' }))

$plan2 = Eng 'ai.plan' @{ goal = '加载驱动' }
$phrase2 = ''
if ($null -ne $plan2 -and $null -ne $plan2.data) { $phrase2 = [string]$plan2.data.confirmPhrase }
$verb2 = ''
if ($null -ne $plan2 -and $null -ne $plan2.data -and $null -ne $plan2.data.confirmFor) { $verb2 = [string]$plan2.data.confirmFor.verb }
$good = $null
try { $good = Test-LctAiConfirm -Phrase $phrase2 -Verb $verb2 -Args $null } catch { }
Check 'AT-6b ai.plan 给的真实短语通过' ($null -ne $good -and $good.ok -eq $true) ('verb=' + $verb2 + ' err=' + $(if ($null -ne $good) { $good.error } else { '?' }))
$again = $null
try { $again = Test-LctAiConfirm -Phrase $phrase2 -Verb $verb2 -Args $null } catch { }
Check 'AT-6c 短语用后即焚（第二次被拒）' ($null -ne $again -and $again.ok -eq $false) ''

$noConfirm = Eng 'ai.run' @{ verb = 'driver.load'; args = @{ path = "$env:SystemRoot\System32\drivers\disk.sys"; name = 'lctainotest' }; apply = $true }
$nc = $false
if ($null -ne $noConfirm -and $null -ne $noConfirm.data -and $null -ne $noConfirm.data.PSObject.Properties['confirmRequired']) { $nc = [bool]$noConfirm.data.confirmRequired }
Check 'AT-7 ai.run mutating+apply 无 confirm ⇒ 被拒' ($null -ne $noConfirm -and $noConfirm.ok -eq $false -and $nc -eq $true) ('ok=' + $(if ($null -ne $noConfirm) { $noConfirm.ok } else { '?' }))
Check 'AT-7b 拒绝说明含"人未确认"' ((@($noConfirm.errors) -join ' ') -match '未确认') ''

$ro = Eng 'ai.run' @{ verb = 'driver.map'; args = @{} }
Check 'AT-8 只读 verb 不需要 confirm' ($null -ne $ro -and $ro.ok -eq $true -and $ro.applied -eq $false) ('ok=' + $(if ($null -ne $ro) { $ro.ok } else { '?' }))

$rec = Eng 'ai.run' @{ verb = 'ai.manifest' }
Check 'AT-9 不允许 ai.run 递归调 ai.*' ($null -ne $rec -and $rec.ok -eq $false) ''

Write-Host ''
Write-Host '== AT-10: MCP 服务器全链路 =='
$mcpOut = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\McpSmoke.ps1') -ToolRoot $root 2>&1
$mcpText = ($mcpOut | Out-String)
Check 'AT-10a MCP initialize 返回 serverInfo' ($mcpText -match 'local-config-tool') ''
Check 'AT-10b MCP tools/list 含 4 个工具' (($mcpText -match 'lct_manifest') -and ($mcpText -match 'lct_call') -and ($mcpText -match 'tools=4')) ''
Check 'AT-10c MCP tools/call 只读调用成功' ($mcpText -match 'call_ok=True') ''

Write-Host ''
Write-Host '== AT-11: 审计日志 =='
$logDir = Join-Path $root 'var\logs'
$logCount = 0
try { $logCount = @(Get-ChildItem $logDir -Filter 'ai-mcp-*.log' -ErrorAction SilentlyContinue).Count } catch { }
Check 'AT-11 MCP 审计日志存在' ($logCount -ge 1) ('files=' + $logCount)

if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
Write-Host ''
Write-Host ('AiTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail