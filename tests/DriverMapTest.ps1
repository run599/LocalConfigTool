# LocalConfigTool - tests\DriverMapTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\DriverMapTest.ps1
#
# Regression tests for `driver.map` (object-graph mapping: \Device device object <-> \Driver driver
# object <-> service name, plus the authoritative Win32_PnPEntity.Service cross-check).
#
# Everything here is read-only: no driver is loaded, no device is opened for I/O, no IOCTL is sent,
# no registry write happens. Exit code = number of failures.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-map-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function Remove-Work { if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } } }

Write-Host '== DM-1: verb is registered and declared read-only =='
$vb = Eng 'engine.verbs' $null
$entry = @()
if ($null -ne $vb) { $entry = @($vb.data.verbs) | Where-Object { [string]$_.verb -eq 'driver.map' } }
Check 'DM-1a driver.map appears in engine.verbs' (@($entry).Count -eq 1) ('hits=' + @($entry).Count + ' totalVerbs=' + $(if ($null -ne $vb) { @($vb.data.verbs).Count } else { -1 }))
Check 'DM-1b driver.map is mutating=false' ((@($entry).Count -eq 1) -and ($entry[0].mutating -eq $false)) ('mutating=' + $(if (@($entry).Count -ge 1) { $entry[0].mutating } else { '?' }))
Check 'DM-1c availability.DriverMap is true' ($null -ne $vb -and $vb.data.availability.DriverMap -eq $true) ('avail=' + $(if ($null -ne $vb) { $vb.data.availability.DriverMap } else { '?' }))

Write-Host ''
Write-Host '== DM-2: full map has real content =='
$full = Eng 'driver.map' $null
$st = $null
if ($null -ne $full -and $null -ne $full.data) { $st = $full.data.stats }
Check 'DM-2a ok=True and count>0' (($null -ne $full) -and ($full.ok -eq $true) -and ($full.data.count -gt 0)) ('count=' + $(if ($null -ne $full) { $full.data.count } else { -1 }))
Check 'DM-2b device objects enumerated' ($null -ne $st -and $st.deviceObjects -gt 50) ('deviceObjects=' + $(if ($null -ne $st) { $st.deviceObjects } else { -1 }))
Check 'DM-2c driver objects enumerated' ($null -ne $st -and $st.driverObjects -gt 20) ('driverObjects=' + $(if ($null -ne $st) { $st.driverObjects } else { -1 }))
Check 'DM-2d global symlinks resolved via NtQuerySymbolicLinkObject' ($null -ne $st -and $st.linksResolved -gt 0) ('linksResolved=' + $(if ($null -ne $st) { $st.linksResolved } else { -1 }) + ' failed=' + $(if ($null -ne $st) { $st.linksFailed } else { -1 }))
Check 'DM-2e applied=False (read-only verb)' ($null -ne $full -and $full.applied -eq $false) ('applied=' + $(if ($null -ne $full) { $full.applied } else { '?' }))

Write-Host ''
Write-Host '== DM-3: mapping quality and honesty =='
$items = @()
if ($null -ne $full -and $null -ne $full.data) { $items = @($full.data.items) }
$exact = @($items | Where-Object { [string]$_.confidence -eq 'exact' })
$unres = @($items | Where-Object { [string]$_.confidence -eq 'unresolved' })
Check 'DM-3a at least one exact name mapping exists' (@($exact).Count -gt 0) ('exact=' + @($exact).Count)
Check 'DM-3b exact mappings point at a real \Driver object name' ((@($exact).Count -eq 0) -or (@($exact | Where-Object { [string]$_.driverObject -like '\Driver\*' }).Count -gt 0)) ''
$verified = @($exact | Where-Object { $_.serviceVerified -eq $true })
Check 'DM-3c verified services have an existing registry service key' ((@($verified).Count -eq 0) -or (@($verified | Where-Object { Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $_.serviceName) }).Count -eq @($verified).Count)) ('verified=' + @($verified).Count)
Check 'DM-3d unresolved entries carry NO fake driver name' ((@($unres).Count -eq 0) -or (@($unres | Where-Object { [string]$_.driverName -ne '' }).Count -eq 0)) ('unresolved=' + @($unres).Count)
$withLinks = @($items | Where-Object { @($_.links).Count -gt 0 })
Check 'DM-3e links are attached with resolved \Device targets' ((@($withLinks).Count -eq 0) -or (@($withLinks | Where-Object { @($_.links | Where-Object { [string]$_.target -like '\Device\*' }).Count -gt 0 }).Count -gt 0)) ('itemsWithLinks=' + @($withLinks).Count)

Write-Host ''
Write-Host '== DM-4: -includeUnresolved switches the view =='
$mappedOnly = Eng 'driver.map' @{ includeUnresolved = $false }
$mo = @()
if ($null -ne $mappedOnly -and $null -ne $mappedOnly.data) { $mo = @($mappedOnly.data.items) }
Check 'DM-4a mapped-only view contains no unresolved items' ((@($mo).Count -eq 0) -or (@($mo | Where-Object { [string]$_.confidence -eq 'unresolved' }).Count -eq 0)) ('count=' + @($mo).Count)
Check 'DM-4b mapped-only view is smaller than the full view' (@($mo).Count -lt @($items).Count) ('mappedOnly=' + @($mo).Count + ' full=' + @($items).Count)

Write-Host ''
Write-Host '== DM-5: -Service filter (object-manager side) =='
$svc = ''
if (@($verified).Count -gt 0) { $svc = [string]$verified[0].serviceName }
if ($svc -eq '') { Check 'DM-5 service filter (SKIPPED: no verified service found)' $true 'skip' }
else {
    $one = Eng 'driver.map' @{ service = $svc }
    $oi = @()
    if ($null -ne $one -and $null -ne $one.data) { $oi = @($one.data.items) }
    $allMatch = $true
    foreach ($it in @($oi)) { if ([string]$it.serviceName -ne $svc -and [string]$it.serviceName -ne '') { $allMatch = $false } }
    Check ('DM-5a -Service ' + $svc + ' returns only that service') (($one.ok -eq $true) -and ($allMatch) -and (@($oi).Count -ge 1)) ('count=' + @($oi).Count)
}

Write-Host ''
Write-Host '== DM-6: PnP authoritative cross-check (Win32_PnPEntity.Service) =='
$pnpService = ''
try {
    $first = @(Get-CimInstance Win32_PnPEntity -Property Service -ErrorAction Stop | Where-Object { [string]$_.Service -ne '' } | Select-Object -First 1)
    if (@($first).Count -gt 0) { $pnpService = [string]$first[0].Service }
} catch { }
if ($pnpService -eq '') { Check 'DM-6 PnP cross-check (SKIPPED: no PnP entity with a Service)' $true 'skip' }
else {
    $pm = Eng 'driver.map' @{ service = $pnpService }
    $pd = @()
    if ($null -ne $pm -and $null -ne $pm.data) { $pd = @($pm.data.pnpDevices) }
    Check ('DM-6a -Service ' + $pnpService + ' yields PnP device instances') (@($pd).Count -ge 1) ('pnpDevices=' + @($pd).Count)
    Check 'DM-6b PnP instances are real device instance IDs' ((@($pd).Count -eq 0) -or (@($pd | Where-Object { [string]$_.deviceId -ne '' }).Count -eq @($pd).Count)) ''
}

Write-Host ''
Write-Host '== DM-7: nothing was loaded / written by this test =='
Check 'DM-7a no lct* kernel service was created' (@(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'lct*' }).Count -eq 0) ''
Check 'DM-7b no RTCore64 driver is loaded' (-not (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + 'RTCore64'))) ''

Remove-Work
Write-Host ''
Write-Host ('DriverMapTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
