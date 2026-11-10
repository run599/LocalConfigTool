# LocalConfigTool - tests\AiFlowTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\AiFlowTest.ps1
#
# 守「AI 一句话跑流水线」的能力（ai.plan 样本识别 + ai.do 一键执行）：
#   FT-1 plan 认得样本库条目：目标含 rtcore64 ⇒ 步骤里有 driver.use，且 path 是**真实路径**（不是占位符）
#   FT-2 plan 认得"清理" ⇒ 最后一步是 driver.cleanup
#   FT-3 ai.do 预览：applied=false、给步骤与确认短语、**不创建任何服务**
#   FT-4 ai.do -Apply 无 confirm ⇒ 拒绝（needConfirm），**不创建任何服务**
#   FT-5 ai.do 只读目标 -Apply ⇒ 直接跑通（capability.status）
#   FT-6 ai.do 错误 confirm ⇒ 拒绝
#   FT-7 ai.manifest 收录 ai.do
#   FT-8 全程无 lct*/rtcore 服务残留
#
# 安全：本测试**不真加载驱动、不发 IOCTL**（预览路径），也不提权。
# 退出码 = 失败数。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-aiflow-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function LctServices { return @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^lct|rtcore' } | ForEach-Object { [string]$_.PSChildName }) }

# ---- 前提准备：plan 的「读内核」步骤依赖 var\driver-profiles\<样本>.json 存在 ----
# 公开版是全新目录，这里自己造出前提，保证测试自给自足（不依赖本机历史运行状态）。
$sampleIdForPlan = 'rtcore64-01aa278b'
$profDirForPlan = Join-Path $root 'var\driver-profiles'
$profPathForPlan = Join-Path $profDirForPlan ($sampleIdForPlan + '.json')
$createdProfile = $false
if (-not (Test-Path -LiteralPath $profPathForPlan)) {
    try {
        if (-not (Test-Path -LiteralPath $profDirForPlan)) { $null = New-Item -ItemType Directory -Path $profDirForPlan -Force }
        $catPathForPlan = Join-Path $root 'samples\catalog.json'
        if (Test-Path -LiteralPath $catPathForPlan) {
            $catObjForPlan = Get-Content -LiteralPath $catPathForPlan -Raw -Encoding UTF8 | ConvertFrom-Json
            $entryForPlan = @($catObjForPlan.entries) | Where-Object { [string]$_.id -eq $sampleIdForPlan } | Select-Object -First 1
            if ($null -ne $entryForPlan -and $null -ne $entryForPlan.PSObject.Properties['profile'] -and $null -ne $entryForPlan.profile) {
                [IO.File]::WriteAllText($profPathForPlan, ($entryForPlan.profile | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
                $createdProfile = $true
            }
        }
    } catch { }
}

$before = @(LctServices).Count

Write-Host '== FT-1: plan 认得样本库（真实路径而非占位符） =='
$plan = Eng 'ai.plan' @{ goal = '加载 rtcore64 读一下内核头' }
$steps = @()
if ($null -ne $plan -and $null -ne $plan.data) { $steps = @($plan.data.steps) }
$useStep = @($steps) | Where-Object { [string]$_.verb -eq 'driver.use' } | Select-Object -First 1
Check 'FT-1a 计划含 driver.use' ($null -ne $useStep) ('steps=' + @($steps).Count)
$usePath = ''
if ($null -ne $useStep -and $null -ne $useStep.args -and $null -ne $useStep.args.PSObject.Properties['path']) { $usePath = [string]$useStep.args.path }
Check 'FT-1b path 是真实样本路径（不是占位符）' ($usePath -match 'var\\samples\\rtcore64-01aa278b\.sys$' -and $usePath -notmatch '^<') ('path=' + $usePath)
$ioctlCount = @($steps | Where-Object { [string]$_.verb -eq 'driver.ctl.send' }).Count
$hasIoctlStep = ($ioctlCount -ge 1)
Check 'FT-1c 计划含 driver.ctl.send（读内核头）' $hasIoctlStep ''

Write-Host ''
Write-Host '== FT-2: plan 认得"清理" =='
$plan2 = Eng 'ai.plan' @{ goal = '清理一下驱动' }
$steps2 = @()
if ($null -ne $plan2 -and $null -ne $plan2.data) { $steps2 = @($plan2.data.steps) }
$lastVerb = ''
if (@($steps2).Count -gt 0) { $lastVerb = [string]$steps2[@($steps2).Count - 1].verb }
Check 'FT-2 最后一步是 driver.cleanup' ($lastVerb -eq 'driver.cleanup') ('last=' + $lastVerb)

Write-Host ''
Write-Host '== FT-3: ai.do 预览（不执行、不建服务） =='
$pre = Eng 'ai.do' @{ goal = '加载 rtcore64 读内核头' }
Check 'FT-3a 预览 ok=true 且 applied=false' ($null -ne $pre -and $pre.ok -eq $true -and $pre.data.applied -eq $false) ''
Check 'FT-3b 给出了步骤与写操作计数' ($null -ne $pre -and [int]$pre.data.stepCount -gt 0 -and [int]$pre.data.mutatingCount -gt 0) ('steps=' + $pre.data.stepCount + ' mut=' + $pre.data.mutatingCount)
Check 'FT-3c 给了确认短语' ([string]$pre.data.confirmPhrase -like 'I-UNDERSTAND-????????') ('phrase=' + [string]$pre.data.confirmPhrase)
Check 'FT-3d 预览没有创建服务' (@(LctServices).Count -eq $before) ('before=' + $before + ' now=' + @(LctServices).Count)

Write-Host ''
Write-Host '== FT-4: ai.do -Apply 无 confirm ⇒ 拒绝且不建服务 =='
$noC = Eng 'ai.do' @{ goal = '加载 rtcore64 读内核头' } -Apply
$needC = $false
if ($null -ne $noC -and $null -ne $noC.data) { $needC = [bool]$noC.data.needConfirm }
Check 'FT-4a 被拒（needConfirm=true）' ($null -ne $noC -and $noC.ok -eq $false -and $needC) ('ok=' + $(if ($null -ne $noC) { $noC.ok } else { '?' }))
Check 'FT-4b 拒绝理由说明"人未确认"' ((@($noC.errors) -join ' ') -match '未确认') ''
Check 'FT-4c 拒绝时没有创建服务' (@(LctServices).Count -eq $before) ('now=' + @(LctServices).Count)

Write-Host ''
Write-Host '== FT-5: 只读目标直接跑通 =='
$ro = Eng 'ai.do' @{ goal = '看看我现在是什么权限' } -Apply
Check 'FT-5a ok=true 且已执行' ($null -ne $ro -and $ro.ok -eq $true -and $ro.data.applied -eq $true) ''
$roOk = 0
if ($null -ne $ro -and $null -ne $ro.data) { $roOk = [int]$ro.data.okCount }
Check 'FT-5b 步骤全部成功' ($roOk -ge 1 -and $roOk -eq [int]$ro.data.stepCount) ('ok=' + $roOk + '/' + $ro.data.stepCount)

Write-Host ''
Write-Host '== FT-6: 错误 confirm ⇒ 拒绝 =='
$badC = Eng 'ai.do' @{ goal = '加载 rtcore64 读内核头'; apply = $true; confirm = 'I-UNDERSTAND-00000000' } -Apply
Check 'FT-6 伪造短语被拒' ($null -ne $badC -and $badC.ok -eq $false) ''

Write-Host ''
Write-Host '== FT-7: ai.manifest 收录 ai.do =='
$man = Eng 'ai.manifest' $null
$names = @()
if ($null -ne $man -and $null -ne $man.data) { $names = @($man.data.verbs | ForEach-Object { [string]$_.name }) }
Check 'FT-7 manifest 里有 ai.do' ($names -contains 'ai.do') ('count=' + @($names).Count)

Write-Host ''
Write-Host '== FT-8: 无服务残留 =='
Check 'FT-8 测试没有留下 lct*/rtcore 服务' (@(LctServices).Count -eq $before) ('now=' + @(LctServices).Count)

if (Test-Path -LiteralPath $work) { try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
Write-Host ''
if ($createdProfile -and (Test-Path -LiteralPath $profPathForPlan)) {
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($profPathForPlan, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}
Write-Host ('AiFlowTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail