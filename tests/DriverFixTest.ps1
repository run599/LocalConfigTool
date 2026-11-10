# LocalConfigTool - regression tests for the three driver-profile fixes (2026-10-28).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\DriverFixTest.ps1
#
# What it guards (each was a real defect found by a live run against a real vulnerable driver):
#   F1  signature classification: a PROPER VENDOR cert (e.g. MICRO-STAR / GlobalSign chain) must be
#       'valid-vendor' with likelyTestSigned=False. Only SELF-SIGNED certs are test-signing.
#       (Before the fix: every non-Microsoft signer was mislabelled valid-non-microsoft + likelyTestSigned=True.)
#   F2  .sys resolution must NOT depend on locate.strategy: a profile with strategy=symlink plus a
#       serviceNameHint must still try the service's registry ImagePath (and strip the '\??\' prefix).
#       (Before: the registry candidate was only added when strategy=serviceImagePath.)
#   F3  payload packing: fields the payload omits must default to zero (padding!) and be reported in
#       warnings, instead of hard-failing with "payload 缺少字段". A typo in a field name still shows up
#       in that warning list.
#
# Exit code = number of failures. Nothing here loads a driver or sends an IOCTL.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
$work = Join-Path $env:TEMP ('lct-drvfix-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 12 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function Remove-TempDir([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
}

Write-Host '== F1: signature classification (vendor vs self-signed) =='
$msDriver = Join-Path $env:SystemRoot 'System32\drivers\disk.sys'
if (Test-Path -LiteralPath $msDriver) {
    $r = Eng 'driver.info' @{ path = $msDriver }
    Check 'F1-a Microsoft-signed driver -> microsoft-signed, not test-signed' `
        ($r.ok -and ([string]$r.data.signatureClass -eq 'microsoft-signed') -and ($r.data.likelyTestSigned -eq $false) -and ($r.data.isSelfSigned -eq $false)) `
        ('class=' + [string]$r.data.signatureClass + ' testSigned=' + $r.data.likelyTestSigned)
}
# self-signed branch: sign a throw-away ps1 with a fresh self-signed code-signing cert
$fake = Join-Path $work 'signed.ps1'
'sample' | Set-Content -LiteralPath $fake -Encoding ASCII
$thumb = ''
try {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=LctFixTestOnly' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable -ErrorAction Stop
    $thumb = [string]$cert.Thumbprint
    $null = Set-AuthenticodeSignature -FilePath $fake -Certificate $cert -ErrorAction Stop
    $r2 = Eng 'driver.info' @{ path = $fake }
    Check 'F1-b self-signed file -> likelyTestSigned=True (test-signing still detected)' `
        ($r2.ok -and ($r2.data.likelyTestSigned -eq $true) -and ($r2.data.isSelfSigned -eq $true)) `
        ('class=' + [string]$r2.data.signatureClass + ' isSelfSigned=' + $r2.data.isSelfSigned)
} catch {
    Check 'F1-b self-signed branch (SKIPPED: cannot create a test certificate here)' $true ('skip: ' + $_.Exception.Message)
} finally {
    if ($thumb -ne '') {
        try {
            $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
            $st.Open('ReadWrite')
            foreach ($c in @($st.Certificates)) { if ($c.Thumbprint -eq $thumb) { $st.Remove($c) } }
            $st.Close()
        } catch { }
    }
}

Write-Host ''
Write-Host '== F3: payload packing defaults omitted fields to zero =='
$modPath = Join-Path $root 'core\DriverProfiles.psm1'
# field descriptors must be dictionaries (that is what the module builds from JSON), not PSCustomObjects
$fields = @(
    @{ name = 'pad0'; type = 'bytes'; len = 8 },
    @{ name = 'addr'; type = 'u64' },
    @{ name = 'readSize'; type = 'u32' },
    @{ name = 'pad3'; type = 'bytes'; len = 16 }
)
$layout = @{ method = 'buffered'; align = 8; endian = 'little' }
$values = @{ addr = '0x1122334455667788'; readSize = 4 }
$pack = $null
try {
    Import-Module $modPath -Force -Global -ErrorAction Stop
    $pack = & (Get-Module DriverProfiles) { param($f, $l, $v) ConvertTo-LctPrfBuffer -Fields $f -Layout $l -Values $v } $fields $layout $values
} catch { $pack = $null }
if ($null -eq $pack) {
    Check 'F3-a pack works via module scope' $false 'cannot invoke ConvertTo-LctPrfBuffer'
} else {
    Check 'F3-a omitted fields are defaulted (not an error)' ([bool]$pack.ok) ('ok=' + $pack.ok + ' err=' + [string]$pack.error)
    Check 'F3-b defaulted list names pad0 and pad3' ((@($pack.defaulted) -contains 'pad0') -and (@($pack.defaulted) -contains 'pad3')) ('defaulted=' + (@($pack.defaulted) -join ','))
    $lenOk = ($null -ne $pack.bytes -and @($pack.bytes).Length -eq 40)
    Check 'F3-c buffer is 40 bytes (8 pad + 8 addr + 4 size + 4 align + 16 pad)' $lenOk ('len=' + $(if ($null -ne $pack.bytes) { @($pack.bytes).Length } else { -1 }))
    if ($lenOk) {
        $addrOk = ([BitConverter]::ToUInt64([byte[]]$pack.bytes, 8) -eq [uint64]0x1122334455667788)
        $sizeOk = ([BitConverter]::ToUInt32([byte[]]$pack.bytes, 16) -eq [uint32]4)
        Check 'F3-d defaulted padding does not shift addr/readSize offsets' ($addrOk -and $sizeOk) ('addrOk=' + $addrOk + ' sizeOk=' + $sizeOk)
    }
}

Write-Host ''
Write-Host '== F2: .sys resolution must work with strategy=symlink (registry ImagePath + \??\ prefix) =='
$svcName = 'lctfixcheck'
$diskSha = ''
if (Test-Path -LiteralPath $msDriver) { $diskSha = (Get-FileHash -LiteralPath $msDriver -Algorithm SHA256).Hash.ToLower() }
$created = $false
try {
    $null = & sc.exe delete $svcName 2>$null
    $scOut = & sc.exe create $svcName type= kernel binPath= ('\??\' + $msDriver) start= demand 2>&1
    $created = (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svcName))
} catch { $created = $false }
if (-not $created) {
    Check 'F2 .sys resolution with strategy=symlink (SKIPPED: cannot create a temp service here)' $true 'skip'
} else {
    try {
        $prof = [ordered]@{
            id = 'lctfixsymlink'; kind = 'driver-profile'; engineApi = 2
            target = [ordered]@{ sha256 = $diskSha; fileName = 'disk.sys' }
            locate = [ordered]@{ strategy = 'symlink'; candidates = @('\??\LctNoSuchDev'); serviceNameHint = $svcName; notes = 'regression test' }
            actions = [ordered]@{ probe = [ordered]@{ ioctl = '0x00222000'
                        'in' = @([pscustomobject]@{ name = 'a'; type = 'u32' })
                        out = @([pscustomobject]@{ name = 'code'; type = 'u32' }) } }
            layout = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
            risk = [ordered]@{ level = 'medium'; notes = 'regression test only' }
            requires = [ordered]@{ restart = $false; admin = $true; elevation = 'admin' }
        }
        $sv = Eng 'driver.profile.save' @{ id = 'lctfixsymlink'; json = ($prof | ConvertTo-Json -Depth 12 -Compress); override = $true } -Apply
        Check 'F2-a temp profile saved' ([bool]$sv.ok) ('ok=' + $sv.ok)
        $pv = Eng 'driver.ctl.send' @{ profile = 'lctfixsymlink'; action = 'probe'; payload = '{"a":1}' }
        $res = ''
        if ($null -ne $pv -and $null -ne $pv.data.sysFile) { $res = [string]$pv.data.sysFile.resolution }
        Check 'F2-b resolution is registryImagePath (not skipped for strategy=symlink)' ($res -eq 'registryImagePath') ('resolution=' + $res)
        Check 'F2-c preview only: no IOCTL sent' (($null -ne $pv) -and ($pv.applied -eq $false) -and ($pv.data.ioctlSent -eq $false)) ('applied=' + $pv.applied + ' ioctlSent=' + $pv.data.ioctlSent)
    } finally {
        $null = & sc.exe delete $svcName 2>$null
        $pf = Join-Path $root 'var\driver-profiles\lctfixsymlink.json'
        if (Test-Path -LiteralPath $pf) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($pf, 'OnlyErrorDialogs', 'SendToRecycleBin') }
        Check 'F2-d temp service removed' (-not (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svcName))) ''
    }
}

Remove-TempDir $work
Write-Host ''
Write-Host ('DriverFixTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
