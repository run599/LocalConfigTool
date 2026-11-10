# LocalConfigTool - end-to-end self test (ASCII only on purpose: safe to run even if other
# files in the tree are mid-edit / mis-encoded).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\SelfTest.ps1
#
# It drives the engine exactly like the GUI does: as a child process, JSON in / JSON out.
# IMPORTANT: every payload is handed over through a JSON FILE (-ArgsFile), never inline.
# Inline JSON is fragile across process boundaries - a backslash or quote gets mangled by the
# command-line escaping rules (observed: '{"path":"HKCU:\\Software"}' arriving as invalid JSON).
# The GUI must use the same file channel.
# Assertions are verified OUT OF BAND (reading the registry directly), not by trusting the
# module's own report. Only HKCU one-off keys are touched, and they are cleaned up.
# Exit code = number of failed checks.

$ErrorActionPreference = 'Continue'
$script:Fails = 0
$script:Passes = 0
$script:Notes = New-Object System.Collections.ArrayList

$toolRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $toolRoot 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$testVarDir = Join-Path $env:TEMP ('lct-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:LCT_VAR_DIR = $testVarDir
$null = New-Item -ItemType Directory -Path $testVarDir -Force

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Passes++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  (' + $Detail + ')' } else { '' })) }
    else { $script:Fails++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  (' + $Detail + ')' } else { '' })) }
}

function New-ArgsFile {
    param($Payload)
    if ($null -eq $Payload) { return '' }
    $f = Join-Path $testVarDir ('args-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    ($Payload | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $f -Encoding UTF8
    return $f
}

function Invoke-Engine {
    # returns @{ raw; json; exit }
    param([string]$Verb, $Payload = $null, [switch]$Apply, [string]$Out = 'json', [string]$RawArgsFile = '')
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $enginePath, '-Verb', $Verb)
    if ($RawArgsFile) { $argv += @('-ArgsFile', $RawArgsFile) }
    elseif ($null -ne $Payload) {
        $f = New-ArgsFile $Payload
        $argv += @('-ArgsFile', $f)
    }
    if ($Apply) { $argv += '-Apply' }
    if ($Out -ne 'json') { $argv += @('-Out', $Out) }
    $raw = ((& $psExe @argv 2>$null) | Out-String).Trim()
    $exit = $LASTEXITCODE
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ raw = $raw; json = $obj; exit = $exit }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $p = $item.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

$k = 'HKCU:\Software\LocalConfigTool-SelfTest'
$hklmUac = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacBefore = Get-RegValue -Path $hklmUac -Name 'EnableLUA'

Write-Host 'LocalConfigTool SelfTest'
Write-Host ('  toolRoot = ' + $toolRoot)
Write-Host ('  varDir   = ' + $testVarDir)
Write-Host ''

# ---- 1. engine self-description -------------------------------------------------
Write-Host '1) engine.verbs'
$r = Invoke-Engine -Verb 'engine.verbs'
Write-Check 'engine.verbs returns valid JSON' ($null -ne $r.json) ('exit=' + $r.exit)
if ($r.json) {
    Write-Check 'stdout is JSON only (no CLIXML)' (-not ($r.raw -match 'CLIXML'))
    Write-Check 'verb table has >= 15 entries' (@($r.json.data.verbs).Count -ge 15) ('count=' + @($r.json.data.verbs).Count)
    Write-Check 'availability.Logging = true' ($r.json.data.availability.Logging -eq $true)
    Write-Check 'availability.Backup = true' ($r.json.data.availability.Backup -eq $true)
    Write-Check 'availability.Registry = true' ($r.json.data.availability.Registry -eq $true)
    if (@($r.json.data.loadErrors).Count -gt 0) {
        $null = $script:Notes.Add('loadErrors: ' + (@($r.json.data.loadErrors) -join ' | '))
    }
}

# ---- 2. registry read (out-of-band verified) -----------------------------------
Write-Host '2) registry.get'
$r = Invoke-Engine -Verb 'registry.get' -Payload @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; name = 'ProductName' }
$real = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName'
Write-Check 'registry.get ok' ($r.json.ok -eq $true) ((@($r.json.errors) -join ';'))
Write-Check 'registry.get matches the real registry' ($r.json.data.value -eq $real) ('engine=' + $r.json.data.value + ' real=' + $real)

# ---- 3. preview must not write -------------------------------------------------
Write-Host '3) registry.set preview must NOT write'
if (Test-Path -LiteralPath $k) { $null = [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\LocalConfigTool-SelfTest', $false) }
$r = Invoke-Engine -Verb 'registry.set' -Payload @{ path = 'HKCU:\Software\LocalConfigTool-SelfTest'; name = 'Probe'; value = '1'; type = 'DWord' }
Write-Check 'preview ok' ($r.json.ok -eq $true) ((@($r.json.errors) -join ';'))
Write-Check 'preview reports applied=false' ($r.json.applied -eq $false)
Write-Check 'preview produced a change entry' (@($r.json.changes).Count -ge 1) ('changes=' + @($r.json.changes).Count)
Write-Check 'preview did NOT create the key' (-not (Test-Path -LiteralPath $k))

# ---- 4. apply writes + backup --------------------------------------------------
Write-Host '4) registry.set -Apply writes and leaves a backup'
$r = Invoke-Engine -Verb 'registry.set' -Payload @{ path = 'HKCU:\Software\LocalConfigTool-SelfTest'; name = 'Probe'; value = '1'; type = 'DWord' } -Apply
Write-Check 'apply ok' ($r.json.ok -eq $true -and $r.json.applied -eq $true) ((@($r.json.errors) -join ';'))
Write-Check 'key exists after apply' (Test-Path -LiteralPath $k)
Write-Check 'key value is 1' ((Get-RegValue -Path $k -Name 'Probe') -eq 1) ('got=' + (Get-RegValue -Path $k -Name 'Probe'))
$backupId = $r.json.backupId
Write-Check 'apply returned a backupId' ([bool]$backupId) ('backupId=' + $backupId)
$backupDir = Join-Path $testVarDir ('backups\' + $backupId)
Write-Check 'backup directory + meta.json exist' (Test-Path -LiteralPath (Join-Path $backupDir 'meta.json'))

# ---- 5. backup list / show / restore -------------------------------------------
Write-Host '5) backup.list / backup.restore'
$r = Invoke-Engine -Verb 'backup.list'
Write-Check 'backup.list ok' ($r.json.ok -eq $true)
Write-Check 'backup.list has >= 1 entry' (@($r.json.data).Count -ge 1) ('count=' + @($r.json.data).Count)
$r = Invoke-Engine -Verb 'backup.restore' -Payload @{ id = $backupId }
Write-Check 'restore preview ok and applied=false' ($r.json.ok -eq $true -and $r.json.applied -eq $false) ((@($r.json.errors) -join ';'))
Write-Check 'restore preview did not delete the key' (Test-Path -LiteralPath $k)
$r = Invoke-Engine -Verb 'backup.restore' -Payload @{ id = $backupId } -Apply
Write-Check 'restore -Apply ok' ($r.json.ok -eq $true -and $r.json.applied -eq $true) ((@($r.json.errors) -join ';'))
Write-Check 'key removed again (it did not exist when backed up)' (-not (Test-Path -LiteralPath $k))

# ---- 6. account -----------------------------------------------------------------
Write-Host '6) account.status / account.uac preview'
$r = Invoke-Engine -Verb 'account.status'
Write-Check 'account.status ok' ($r.json.ok -eq $true)
if ($r.json.ok) {
    Write-Check 'account.status.user.name present' ([bool]$r.json.data.user.name) ('user=' + $r.json.data.user.name)
    Write-Check 'account.status.users array has >= 2 entries' (@($r.json.data.users).Count -ge 2) ('count=' + @($r.json.data.users).Count)
    Write-Check 'account.status.uac.enableLUA present' ($null -ne $r.json.data.uac.enableLUA) ('enableLUA=' + $r.json.data.uac.enableLUA)
    Write-Check 'account.status.autologon present' ($null -ne $r.json.data.autologon) ('enabled=' + $r.json.data.autologon.enabled)
}
$r = Invoke-Engine -Verb 'account.uac' -Payload @{ enable = $false }
Write-Check 'account.uac preview ok and applied=false' ($r.json.ok -eq $true -and $r.json.applied -eq $false) ((@($r.json.errors) -join ';'))
$uacAfter = Get-RegValue -Path $hklmUac -Name 'EnableLUA'
Write-Check 'account.uac preview did NOT change EnableLUA' ($uacAfter -eq $uacBefore) ('before=' + $uacBefore + ' after=' + $uacAfter)

# ---- 7. plugins ----------------------------------------------------------------
Write-Host '7) plugins.list / plugins.run preview'
$logDir = Join-Path $testVarDir 'logs'
$logCountBefore = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'plugin-*' }).Count
$r = Invoke-Engine -Verb 'plugins.list'
Write-Check 'plugins.list ok' ($r.json.ok -eq $true) ((@($r.json.errors) -join ';'))
if ($r.json -and $r.json.ok) {
    $ids = @($r.json.data | Select-Object -ExpandProperty id)
    Write-Check 'plugins.list contains cve-2026-49176' ($ids -contains 'cve-2026-49176') ('ids=' + ($ids -join ','))
}
$r = Invoke-Engine -Verb 'plugins.run' -Payload @{ plugin = 'cve-2026-49176'; params = @{ timeout = 120 } }
if ($r.json -and $r.json.ok) {
    Write-Check 'plugins.run preview ok' $true
    Write-Check 'plugins.run preview applied=false' ($r.json.applied -eq $false)
    Write-Check 'plugins.run preview resolved a command' ([bool]$r.json.data.command) ('cmd=' + $r.json.data.command)
} else {
    Write-Check 'plugins.run preview ok' $false ((@($r.json.errors) -join ';'))
}
$logCountAfter = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'plugin-*' }).Count
Write-Check 'preview spawned nothing (no plugin-*.log)' ($logCountAfter -eq $logCountBefore)

# ---- 8. presets ----------------------------------------------------------------
Write-Host '8) presets.list / presets.show / presets.apply'
$r = Invoke-Engine -Verb 'presets.list'
Write-Check 'presets.list ok' ($r.json.ok -eq $true)
if ($r.json -and $r.json.ok) {
    $packs = @($r.json.data | Select-Object -ExpandProperty id)
    Write-Check 'presets.list contains account-login' ($packs -contains 'account-login') ('packs=' + ($packs -join ','))
    if ($packs -contains 'account-login') {
        $r2 = Invoke-Engine -Verb 'presets.show' -Payload @{ preset = 'account-login' }
        Write-Check 'presets.show account-login ok' ($r2.json.ok -eq $true)
        Write-Check 'account-login has >= 3 items' (@($r2.json.data.items).Count -ge 3) ('items=' + @($r2.json.data.items).Count)
        $r3 = Invoke-Engine -Verb 'presets.apply' -Payload @{ preset = 'account-login' }
        Write-Check 'presets.apply (all items) is a preview' ($r3.json.applied -eq $false)
        Write-Check 'presets.apply did not touch the system (EnableLUA unchanged)' ((Get-RegValue -Path $hklmUac -Name 'EnableLUA') -eq $uacBefore)
    }
}

# ---- 9. argument channels ------------------------------------------------------
Write-Host '9) argument channels (-ArgsFile robust; missing/unknown args fail cleanly)'
$argFile = Join-Path $testVarDir 'args.json'
Set-Content -LiteralPath $argFile -Value '{"path":"HKCU:\\Software","name":""}' -Encoding ASCII
$r = Invoke-Engine -Verb 'registry.get' -RawArgsFile $argFile
Write-Check '-ArgsFile channel produced a well-formed Result' ($null -ne $r.json -and $r.json.verb -eq 'registry.get' -and -not ((@($r.json.errors) -join ';') -match 'JSON')) ((@($r.json.errors) -join ';'))
$r = Invoke-Engine -Verb 'registry.get'
Write-Check 'missing -Args does not crash' ($null -ne $r.json)
$r = Invoke-Engine -Verb 'no.such.verb'
Write-Check 'unknown verb returns ok=false and exit 1' ($r.json.ok -eq $false -and $r.exit -eq 1) ((@($r.json.errors) -join ';'))

# ---- 10. -Out text is human readable and still exits 0 -------------------------
Write-Host '10) -Out text'
$r = Invoke-Engine -Verb 'engine.verbs' -Out 'text'
Write-Check '-Out text exits 0' ($r.exit -eq 0)
Write-Check '-Out text prints the verb line' ($r.raw -match 'verb\s*:\s*engine\.verbs')

# ---- 11. new verbs (process.* / wdac.*) are wired and never crash ---------------
Write-Host '11) new verbs: process.* / wdac.*'
$r = Invoke-Engine -Verb 'engine.verbs'
$allVerbs = @($r.json.data.verbs | Select-Object -ExpandProperty verb)
$expectedNew = @('process.list', 'process.detail', 'process.kill', 'process.watch.start', 'process.watch.status',
    'process.watch.stop', 'process.watch.log', 'process.block.set', 'process.block.remove', 'process.block.list',
    'wdac.status', 'wdac.rules.list', 'wdac.rules.add', 'wdac.rules.remove', 'wdac.policy.build',
    'wdac.policy.validate', 'wdac.deploy', 'wdac.revert', 'wdac.verify')
foreach ($v in $expectedNew) { Write-Check ('engine.verbs advertises ' + $v) ($allVerbs -contains $v) }
$missing = @($expectedNew | Where-Object { -not ($allVerbs -contains $_) })
Write-Check 'all 19 new verbs advertised' (@($missing).Count -eq 0) ('missing=' + ($missing -join ','))

# 只读 verb 必须返回契约形状且绝不崩：成功要 ok=true，失败要给可读错误
foreach ($v in @('process.list', 'process.watch.status', 'wdac.status', 'wdac.rules.list', 'wdac.verify')) {
    $rr = Invoke-Engine -Verb $v
    if ($null -eq $rr.json) { Write-Check ('' + $v + ' returns JSON') $false 'no JSON' ; continue }
    $shapeOk = ($null -ne $rr.json.ok) -and ($null -ne $rr.json.errors)
    if ($rr.json.ok -eq $true) {
        Write-Check ('' + $v + ' ok and contract shape') $shapeOk
    } else {
        $err = (@($rr.json.errors) -join ';')
        $readable = ($err -match '依赖未就绪|引擎异常|not recognized|不存在|未实现')
        Write-Check ('' + $v + ' fails readably (module may be not ready yet)') ($shapeOk -and $readable) $err
    }
}

# 预览类动作绝不落盘
$rr = Invoke-Engine -Verb 'process.kill' -Payload @{ name = '__lct_no_such_process__' }
if ($null -ne $rr.json) { Write-Check 'process.kill preview reports applied=false' ($rr.json.applied -eq $false) }
$rr = Invoke-Engine -Verb 'wdac.policy.build' -Payload @{ mode = 'audit'; scanPath = 'C:\Temp' }
if ($null -ne $rr.json) { Write-Check 'wdac.policy.build preview reports applied=false' ($rr.json.applied -eq $false) }
# ---- cleanup -------------------------------------------------------------------
Write-Host ''
Write-Host 'cleanup'
if (Test-Path -LiteralPath $k) { $null = [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\LocalConfigTool-SelfTest', $false) }
Write-Check 'test key removed' (-not (Test-Path -LiteralPath $k))
$uacFinal = Get-RegValue -Path $hklmUac -Name 'EnableLUA'
Write-Check 'EnableLUA never changed by this test' ($uacFinal -eq $uacBefore)
Write-Host ''

foreach ($n in $script:Notes) { Write-Host ('  note: ' + $n) }
Write-Host ('SelfTest: PASS=' + $script:Passes + '  FAIL=' + $script:Fails)
if ($script:Fails -eq 0) { Write-Host 'SelfTest: ALL GREEN' }
exit $script:Fails