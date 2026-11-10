# LocalConfigTool - tests\AiTranslateTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\AiTranslateTest.ps1
#
# 守「大白话 → goal（Ollama 翻译）」这条链路：
#   TT-1 模拟 Ollama 正常返回 ⇒ mode=llm、goal 干净、中文不乱码
#   TT-2 端到端：翻译出来的 goal 能被 ai.plan 识别（含 driver.use）
#   TT-3 端点不可达 ⇒ ok=false，错误里明确「连不上」（不崩、不静默）
#   TT-4 -Fallback ⇒ 不可达时用原文当目标（mode=fallback）
#   TT-5 输出清洗：去「目标：」前缀 / 去引号 / 取第一行 / 截断 / 空串
#   TT-6 空 text ⇒ 拒绝
#
# 本机没装 Ollama 也能测：tests\FakeOllama.ps1 会起一个假的 /api/generate。
# 不联网（只连 127.0.0.1）、不执行任何系统动作。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fakeServer = Join-Path $root 'tests\FakeOllama.ps1'
$work = Join-Path $env:TEMP ('lct-aitr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
function Find-FreePort {
    foreach ($cand in 18450..18520) {
        $t = New-Object System.Net.Sockets.TcpClient
        try { $t.Connect('127.0.0.1', $cand); $t.Close() } catch { return $cand }
    }
    return 18521
}

# 清理上次可能残留的假服务器
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'FakeOllama\.ps1' } |
    ForEach-Object { & taskkill /PID $_.ProcessId /F 2>&1 | Out-Null }

$port = Find-FreePort
$proc = $null
try {
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "' + $fakeServer + '" -Port ' + $port + ' -LifeSeconds 120'
    $proc = Start-Process -FilePath $psExe -ArgumentList $argStr -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    Write-Host '== TT-1: 模拟 Ollama 正常返回 =='
    $tr = Eng 'ai.translate' @{ text = '帮我把 rtcore64 那个驱动挂上去读一下内核头'; endpoint = ('http://127.0.0.1:' + $port); model = 'fake'; timeoutSec = 20 }
    Check 'TT-1a ok=true 且 mode=llm' ($null -ne $tr -and $tr.ok -eq $true -and [string]$tr.data.mode -eq 'llm') ('mode=' + $(if ($null -ne $tr) { $tr.data.mode } else { '?' }))
    $goal = ''
    if ($null -ne $tr -and $null -ne $tr.data) { $goal = [string]$tr.data.goal }
    Check 'TT-1b goal 非空且中文正常（无乱码）' ($goal -ne '' -and $goal -match '[\u4e00-\u9fff]' -and $goal -notmatch 'å|ã|æ') ('goal=' + $goal)

    Write-Host ''
    Write-Host '== TT-2: 端到端（翻译结果 → ai.plan） =='
    $plan = $null
    if ($goal -ne '') { $plan = Eng 'ai.plan' @{ goal = $goal } }
    $steps = @()
    if ($null -ne $plan -and $null -ne $plan.data) { $steps = @($plan.data.steps) }
    $useCount = @($steps | Where-Object { [string]$_.verb -eq 'driver.use' }).Count
    Check 'TT-2 计划含 driver.use（翻译被正确识别）' ($useCount -ge 1) ('steps=' + @($steps).Count)

    Write-Host ''
    Write-Host '== TT-3: 端点不可达 ⇒ 明确报错 =='
    $bad = Eng 'ai.translate' @{ text = '随便说点什么'; endpoint = 'http://127.0.0.1:1'; model = 'fake'; timeoutSec = 3 }
    Check 'TT-3a ok=false' ($null -ne $bad -and $bad.ok -eq $false) ''
    Check 'TT-3b 错误明确说连不上' ((@($bad.errors) -join ' ') -match '连不上') ''

    Write-Host ''
    Write-Host '== TT-4: -Fallback（不可达时用原文） =='
    $probe = @()
    $probe += 'Import-Module ''' + (Join-Path $root 'core\Logging.psm1') + ''' -Force -Global'
    $probe += 'Import-Module ''' + (Join-Path $root 'core\Ai.psm1') + ''' -Force -Global -WarningAction SilentlyContinue 4>$null 6>$null'
    $probe += '$r = Invoke-LctAiTranslate -Text ''帮我提权到system'' -Endpoint ''http://127.0.0.1:1'' -TimeoutSec 3 -Fallback'
    $probe += 'Write-Host ("OK=" + $r.ok + " MODE=" + $r.data.mode + " GOAL=" + $r.data.goal)'
    $pf = Join-Path $work 'probe.ps1'
    [IO.File]::WriteAllText($pf, ($probe -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $ptext = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $pf 2>&1 | Out-String)
    Check 'TT-4a fallback 时 ok=true 且 mode=fallback' ($ptext -match 'OK=True' -and $ptext -match 'MODE=fallback') ''
    Check 'TT-4b goal 等于原文' ($ptext -match 'GOAL=帮我提权到system') ''

    Write-Host ''
    Write-Host '== TT-5: 输出清洗 =='
    $probe2 = @()
    $probe2 += 'Import-Module ''' + (Join-Path $root 'core\Logging.psm1') + ''' -Force -Global'
    $probe2 += 'Import-Module ''' + (Join-Path $root 'core\Ai.psm1') + ''' -Force -Global -WarningAction SilentlyContinue 4>$null 6>$null'
    $probe2 += '$bt = [string][char]96'
    $probe2 += '$q = [string][char]34'
    $probe2 += 'Write-Host ("A=[" + (ConvertTo-LctAiGoalText -Raw ("目标：加载 rtcore64 驱动")) + "]")'
    $probe2 += 'Write-Host ("B=[" + (ConvertTo-LctAiGoalText -Raw ($q + "加载内核" + $q)) + "]")'
    $probe2 += 'Write-Host ("C=[" + (ConvertTo-LctAiGoalText -Raw ("第一行目标" + [char]10 + "第二行解释")) + "]")'
    $probe2 += 'Write-Host ("D=" + (ConvertTo-LctAiGoalText -Raw (''x'' * 200)).Length)'
    $probe2 += 'Write-Host ("E=[" + (ConvertTo-LctAiGoalText -Raw "") + "]")'
    $pf2 = Join-Path $work 'probe2.ps1'
    [IO.File]::WriteAllText($pf2, ($probe2 -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $t2 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $pf2 2>&1 | Out-String)
    Check 'TT-5a 去「目标：」前缀' ($t2 -match 'A=\[加载 rtcore64 驱动\]') ''
    Check 'TT-5b 去引号' ($t2 -match 'B=\[加载内核\]') ''
    Check 'TT-5c 只取第一行' ($t2 -match 'C=\[第一行目标\]') ''
    Check 'TT-5d 超长截断到 80' ($t2 -match 'D=80') ''
    Check 'TT-5e 空输入返回空' ($t2 -match 'E=\[\]') ''

    Write-Host ''
    Write-Host '== TT-6: 空 text ⇒ 拒绝 =='
    $empty = Eng 'ai.translate' @{ text = '   '; endpoint = ('http://127.0.0.1:' + $port); model = 'fake' }
    Check 'TT-6 空 text 被拒' ($null -ne $empty -and $empty.ok -eq $false) ''
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) { & taskkill /PID $proc.Id /F 2>&1 | Out-Null }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'FakeOllama\.ps1' } |
        ForEach-Object { & taskkill /PID $_.ProcessId /F 2>&1 | Out-Null }
    if (Test-Path -LiteralPath $work) {
        try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
}

Write-Host ''
Write-Host ('AiTranslateTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
