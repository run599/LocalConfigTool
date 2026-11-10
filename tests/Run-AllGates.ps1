# LocalConfigTool - run EVERY acceptance gate, capturing stderr so failures are never hidden.
# (Lesson: an earlier gate run used `2>$null` and silently swallowed a real parse error.)
# ASCII only on purpose. Exit code = number of failing gates.
$root = Split-Path -Parent $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$gates = @(
    @{ name = 'Fix-Encoding'; file = 'tests\Fix-Encoding.ps1'; extra = @() },
    @{ name = 'Lint'; file = 'tests\Lint-PowerShell.ps1'; extra = @() },
    @{ name = 'SelfTest'; file = 'tests\SelfTest.ps1'; extra = @() },
    @{ name = 'ProcessTest'; file = 'tests\ProcessTest.ps1'; extra = @() },
    @{ name = 'WdacTest'; file = 'tests\WdacTest.ps1'; extra = @() },
    @{ name = 'DriverTest'; file = 'tests\DriverTest.ps1'; extra = @() },
    @{ name = 'DriverProfileTest'; file = 'tests\DriverProfileTest.ps1'; extra = @() },
    @{ name = 'DriverFixTest'; file = 'tests\DriverFixTest.ps1'; extra = @() },
    @{ name = 'DriverMapTest'; file = 'tests\DriverMapTest.ps1'; extra = @() },
    @{ name = 'JavaUiTest'; file = 'tests\JavaUiTest.ps1'; extra = @() },
    @{ name = 'CapabilityTest'; file = 'tests\CapabilityTest.ps1'; extra = @() },
    @{ name = 'AiTest'; file = 'tests\AiTest.ps1'; extra = @() },
    @{ name = 'AiFlowTest'; file = 'tests\AiFlowTest.ps1'; extra = @() },
    @{ name = 'AiTranslateTest'; file = 'tests\AiTranslateTest.ps1'; extra = @() },
    @{ name = 'AiCloudTest'; file = 'tests\AiCloudTest.ps1'; extra = @() },
    @{ name = 'SamplesTest'; file = 'tests\SamplesTest.ps1'; extra = @() },
    @{ name = 'DriverOpsTest'; file = 'tests\DriverOpsTest.ps1'; extra = @() },
    @{ name = 'CtlSimplifyTest'; file = 'tests\CtlSimplifyTest.ps1'; extra = @() },
    @{ name = 'Lint-Plugin'; file = 'tests\Lint-Plugin.ps1'; extra = @() },
    @{ name = 'PluginSdkTest'; file = 'tests\PluginSdkTest.ps1'; extra = @() },
    @{ name = 'Fix-Encoding (pre-SelfCheck)'; file = 'tests\Fix-Encoding.ps1'; extra = @() }
)
$fails = 0
$pass = 0
foreach ($g in $gates) {
    $script = Join-Path $root $g.file
    if (-not (Test-Path -LiteralPath $script)) { Write-Host ('  [SKIP] ' + $g.name + '  (not present yet)'); continue }
    $errFile = Join-Path $env:TEMP ('lct-gate-' + $g.name + '.err')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + @($g.extra)
    $out = & $psExe @a 2> $errFile
    $code = $LASTEXITCODE
    $last = ''
    $hit = @($out | Where-Object { $_ -match 'Fix-Encoding:|Lint-PowerShell:|SelfTest:|UiPageSmoke:|ProcessTest|WdacTest|Lint-Plugin|PluginSdkTest|^OK' })
    if (@($hit).Count -gt 0) { $last = $hit[-1] }
    $tag = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
    if ($code -eq 0) { $pass++ } else { $fails++ }
    Write-Host ('  [{0}] {1,-14} exit={2,-4} {3}' -f $tag, $g.name, $code, $last)
    if ($code -ne 0) {
        $txt = ''
        if (Test-Path -LiteralPath $errFile) { $txt = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) }
        if ($txt) {
            $errs = @([regex]::Matches($txt, '<S S="Error">(.*?)</S>') | ForEach-Object { ($_.Groups[1].Value -replace '_x000D__x000A_', '') })
            if (@($errs).Count -eq 0) { $errs = @(($txt -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 8) }
            @($errs) | Select-Object -First 6 | ForEach-Object { Write-Host ('        err| ' + $_) }
        }
    }
}
Write-Host ('Run-AllGates: PASS=' + $pass + ' FAIL=' + $fails + '  (exit=FAIL count)')
exit $fails