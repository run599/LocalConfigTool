# LocalConfigTool - tests\AiCloudTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\AiCloudTest.ps1
#
# 守「云端 API 支持」：
#   CT-1 Ollama 协议（/api/generate）可用
#   CT-2 OpenAI 兼容协议（/v1/chat/completions）+ Authorization: Bearer 注入
#   CT-3 Anthropic 协议（/v1/messages）+ x-api-key / anthropic-version 注入
#   CT-4 provider 自动推断（给 /v1 风格地址不给 provider 也走 openai）
#   CT-5 密钥用 DPAPI 存：set 后 status 只显示长度/时间（不返明文）；调用时不传 apiKey 也能注入；clear 后不再注入
#   CT-6 ai.auto 一键：大白话 → 翻译 → 计划（translated=true，不执行）
#   CT-7 ai.auto -Apply 无 confirm ⇒ needConfirm（写操作仍要人确认）
#   CT-8 401 时错误里带「API Key 无效」的指引
#   CT-9 不可达时错误里说明连不上
#
# 用 tests\FakeOllama.ps1（已升级为三协议 + 记录请求头）。
# 不联网（只连 127.0.0.1）；会临时写 var\ai\credential.json，测试结束必须恢复原状。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fakeServer = Join-Path $root 'tests\FakeOllama.ps1'
$work = Join-Path $env:TEMP ('lct-cloud-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$headerLog = Join-Path $work 'headers.log'
$credFile = Join-Path $root 'var\ai\credential.json'
$credBackup = Join-Path $work 'credential.bak.json'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function Find-FreePort([int]$From) {
    foreach ($cand in $From..($From + 60)) {
        $t = New-Object System.Net.Sockets.TcpClient
        try { $t.Connect('127.0.0.1', $cand); $t.Close() } catch { return $cand }
    }
    return ($From + 61)
}
function ClearHeaders {
    if (-not (Test-Path -LiteralPath $headerLog)) { return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($headerLog, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}
function ReadHeaders { if (Test-Path -LiteralPath $headerLog) { return ((Get-Content -LiteralPath $headerLog -Raw -Encoding UTF8)) } return '' }

# 清理上次残留的假服务器
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'FakeOllama\.ps1' } |
    ForEach-Object { & taskkill /PID $_.ProcessId /F 2>&1 | Out-Null }

# 备份现有凭据（如果有）
$hadCred = Test-Path -LiteralPath $credFile
if ($hadCred) { Copy-Item -LiteralPath $credFile -Destination $credBackup -Force }

$pOk = Find-FreePort 18530
$p401 = Find-FreePort ($pOk + 1)
$procOk = $null
$proc401 = $null
try {
    $argsOk = '-NoProfile -ExecutionPolicy Bypass -File "' + $fakeServer + '" -Port ' + $pOk + ' -LifeSeconds 180 -HeaderLog "' + $headerLog + '"'
    $procOk = Start-Process -FilePath $psExe -ArgumentList $argsOk -PassThru -WindowStyle Hidden
    $args401 = '-NoProfile -ExecutionPolicy Bypass -File "' + $fakeServer + '" -Port ' + $p401 + ' -LifeSeconds 120 -ForceStatus 401'
    $proc401 = Start-Process -FilePath $psExe -ArgumentList $args401 -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    Write-Host '== CT-1: Ollama 协议 =='
    $o1 = Eng 'ai.translate' @{ text = '帮我把 rtcore64 挂上去读内核头'; endpoint = ('http://127.0.0.1:' + $pOk); model = 'fake'; provider = 'ollama'; timeoutSec = 20 }
    Check 'CT-1a ok=true 且 mode=llm' ($null -ne $o1 -and $o1.ok -eq $true -and [string]$o1.data.mode -eq 'llm') ('mode=' + $(if ($null -ne $o1) { $o1.data.mode } else { '?' }))
    Check 'CT-1b provider=ollama' ($null -ne $o1 -and [string]$o1.data.provider -eq 'ollama') ''
    Check 'CT-1c goal 有中文' ($null -ne $o1 -and [string]$o1.data.goal -match '[\u4e00-\u9fff]') ('goal=' + $(if ($null -ne $o1) { $o1.data.goal } else { '' }))

    Write-Host ''
    Write-Host '== CT-2: OpenAI 兼容协议 + Bearer 注入 =='
    ClearHeaders
    $o2 = Eng 'ai.translate' @{ text = '帮我把 rtcore64 挂上去读内核头'; endpoint = ('http://127.0.0.1:' + $pOk + '/v1'); model = 'gpt-x'; provider = 'openai'; apiKey = 'test-openai-key'; timeoutSec = 20 }
    Check 'CT-2a ok=true 且 provider=openai' ($null -ne $o2 -and $o2.ok -eq $true -and [string]$o2.data.provider -eq 'openai') ''
    Check 'CT-2b URL 命中 /v1/chat/completions' ($null -ne $o2 -and [string]$o2.data.endpoint -match '/v1/chat/completions') ('url=' + $(if ($null -ne $o2) { $o2.data.endpoint } else { '' }))
    $h2 = ReadHeaders
    Check 'CT-2c 请求里带 Authorization: Bearer' ($h2 -match 'Authorization: Bearer test-openai-key') ''

    Write-Host ''
    Write-Host '== CT-3: Anthropic 协议 + x-api-key =='
    ClearHeaders
    $o3 = Eng 'ai.translate' @{ text = '清理一下驱动'; endpoint = ('http://127.0.0.1:' + $pOk); model = 'claude-x'; provider = 'anthropic'; apiKey = 'test-claude-key'; timeoutSec = 20 }
    Check 'CT-3a ok=true 且 provider=anthropic' ($null -ne $o3 -and $o3.ok -eq $true -and [string]$o3.data.provider -eq 'anthropic') ''
    Check 'CT-3b URL 命中 /v1/messages' ($null -ne $o3 -and [string]$o3.data.endpoint -match '/v1/messages') ''
    $h3 = ReadHeaders
    Check 'CT-3c 请求里带 x-api-key' ($h3 -match 'x-api-key: test-claude-key') ''
    Check 'CT-3d 请求里带 anthropic-version' ($h3 -match 'anthropic-version') ''

    Write-Host ''
    Write-Host '== CT-4: provider 自动推断 =='
    $o4 = Eng 'ai.translate' @{ text = '看看权限'; endpoint = ('http://127.0.0.1:' + $pOk + '/v1'); model = 'gpt-x'; timeoutSec = 20 }
    Check 'CT-4 给 /v1 地址不给 provider ⇒ 推断为 openai' ($null -ne $o4 -and [string]$o4.data.provider -eq 'openai') ('provider=' + $(if ($null -ne $o4) { $o4.data.provider } else { '?' }))

    Write-Host ''
    Write-Host '== CT-5: DPAPI 密钥（set/status/自动注入/clear） =='
    $set = Eng 'ai.cred' @{ action = 'set'; provider = 'openai'; key = 'test-secret-key-placeholder' }
    Check 'CT-5a set ok' ($null -ne $set -and $set.ok -eq $true -and $set.data.saved -eq $true) ''
    $st = Eng 'ai.cred' @{ action = 'status' }
    $cfg = @()
    if ($null -ne $st -and $null -ne $st.data) { $cfg = @($st.data.configured) }
    $stText = ($st | ConvertTo-Json -Depth 5 -Compress)
    Check 'CT-5b status 显示已配置' (@($cfg | Where-Object { $_.provider -eq 'openai' }).Count -eq 1) ''
    Check 'CT-5c status 不泄露明文 key' ($stText -notmatch 'test-secret-key-placeholder' -and $stText -match 'keyLength') ''
    $fileText = ''
    if (Test-Path -LiteralPath $credFile) { $fileText = Get-Content -LiteralPath $credFile -Raw -Encoding UTF8 }
    Check 'CT-5d 磁盘上不是明文（DPAPI 密文）' ($fileText -ne '' -and $fileText -notmatch 'test-secret-key-placeholder') ''
    ClearHeaders
    $o5 = Eng 'ai.translate' @{ text = '看看权限'; endpoint = ('http://127.0.0.1:' + $pOk + '/v1'); model = 'gpt-x'; provider = 'openai'; timeoutSec = 20 }
    $h5 = ReadHeaders
    Check 'CT-5e 不传 apiKey 也能自动注入（DPAPI 解密）' ($h5 -match 'Authorization: Bearer test-secret-key-placeholder') ''
    $clr = Eng 'ai.cred' @{ action = 'clear'; provider = 'openai' }
    Check 'CT-5f clear 成功' ($null -ne $clr -and $clr.data.cleared -eq $true) ''
    ClearHeaders
    $o5b = Eng 'ai.translate' @{ text = '看看权限'; endpoint = ('http://127.0.0.1:' + $pOk + '/v1'); model = 'gpt-x'; provider = 'openai'; timeoutSec = 20 }
    $h5b = ReadHeaders
    Check 'CT-5g clear 后不再注入密钥' ($h5b -notmatch 'test-secret-key-placeholder') ''

    Write-Host ''
    Write-Host '== CT-6: ai.auto 一键（翻译 + 计划，不执行） =='
    $auto = Eng 'ai.auto' @{ text = '帮我把 rtcore64 挂上去读一下内核头'; endpoint = ('http://127.0.0.1:' + $pOk); model = 'fake'; provider = 'ollama'; timeoutSec = 20 }
    Check 'CT-6a ok=true 且 translated=true' ($null -ne $auto -and $auto.ok -eq $true -and $auto.data.translated -eq $true) ''
    $aplan = @()
    if ($null -ne $auto -and $null -ne $auto.data) { $aplan = @($auto.data.plan) }
    Check 'CT-6b 计划含 driver.use' (@($aplan | Where-Object { [string]$_.verb -eq 'driver.use' }).Count -ge 1) ('plan=' + @($aplan).Count)
    Check 'CT-6c 预览未执行（applied=false）' ($null -ne $auto -and $auto.data.applied -eq $false) ''

    Write-Host ''
    Write-Host '== CT-7: ai.auto -Apply 无 confirm ⇒ needConfirm =='
    $auto2 = Eng 'ai.auto' @{ text = '加载 rtcore64 读内核头'; endpoint = ('http://127.0.0.1:' + $pOk); model = 'fake'; provider = 'ollama'; timeoutSec = 20; apply = $true } -Apply
    $need = $false
    if ($null -ne $auto2 -and $null -ne $auto2.data) { $need = [bool]$auto2.data.needConfirm }
    Check 'CT-7 被拒（needConfirm=true）' ($null -ne $auto2 -and $auto2.ok -eq $false -and $need) ''

    Write-Host ''
    Write-Host '== CT-8: 401 ⇒ 提示配 API Key =='
    $o8 = Eng 'ai.translate' @{ text = '看看权限'; endpoint = ('http://127.0.0.1:' + $p401 + '/v1'); model = 'gpt-x'; provider = 'openai'; apiKey = 'bad'; timeoutSec = 10 }
    $e8 = (@($o8.errors) -join ' ')
    Check 'CT-8a ok=false 且提示 Key 无效' ($null -ne $o8 -and $o8.ok -eq $false -and $e8 -match 'API Key 无效|401') ($e8.Substring(0, [Math]::Min(90, $e8.Length)))

    Write-Host ''
    Write-Host '== CT-9: 不可达 ⇒ 说明连不上 =='
    $o9 = Eng 'ai.translate' @{ text = '看看权限'; endpoint = 'http://127.0.0.1:1/v1'; model = 'gpt-x'; provider = 'openai'; timeoutSec = 3 }
    Check 'CT-9 错误说明连不上' ($null -ne $o9 -and $o9.ok -eq $false -and ((@($o9.errors) -join ' ') -match '连不上')) ''
} finally {
    if ($null -ne $procOk -and -not $procOk.HasExited) { & taskkill /PID $procOk.Id /F 2>&1 | Out-Null }
    if ($null -ne $proc401 -and -not $proc401.HasExited) { & taskkill /PID $proc401.Id /F 2>&1 | Out-Null }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'FakeOllama\.ps1' } |
        ForEach-Object { & taskkill /PID $_.ProcessId /F 2>&1 | Out-Null }
    # 恢复凭据文件原状
    if (Test-Path -LiteralPath $credFile) {
        try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($credFile, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
    if ($hadCred -and (Test-Path -LiteralPath $credBackup)) {
        try { Copy-Item -LiteralPath $credBackup -Destination $credFile -Force } catch { }
    }
    if (Test-Path -LiteralPath $work) {
        try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
}

Write-Host ''
Write-Host ('AiCloudTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
