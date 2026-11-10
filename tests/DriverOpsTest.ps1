# LocalConfigTool - tests\DriverOpsTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\DriverOpsTest.ps1
#
# 守「操作级简化」：小白不该被要求"发明服务名 / 记住它 / 自己串三步"。
#   OP-1 driver.use 缺 path ⇒ 拒绝（并说明只要给路径）
#   OP-2 driver.use 预览 ⇒ applied=false、服务名自动推导且合法、**不创建服务键**
#   OP-3 driver.use -Apply（无效镜像）⇒ 服务键出现、系统拒绝启动（原文回传）、loaded=false
#   OP-4 driver.release -Path（不记名字）⇒ 按 ImagePath 反查并卸载，服务键消失
#   OP-5 driver.cleanup ⇒ 之后没有 lct* 服务
#   OP-6 driver.release 既无 name 也无 path ⇒ 拒绝
#   OP-7 服务名推导稳定：同一文件两次一致、不同文件不同名
#
# 安全：全程用**无效镜像**（文本文件冒充 .sys）。sc create 会成功，但 sc start 必被系统以 193 拒绝，
# 因此不会真的把任何内核代码加载进内核。测试结束（含失败路径）都会清理自己创建的服务。
#
# 退出码 = 失败数。不发 IOCTL、不提权。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-ops-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$pass = 0
$fail = 0
$svcName = ''
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function SvcKeyExists([string]$n) { return (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n)) }

# 造两个"无效镜像"：sc create 会成功，sc start 必得 193（不会真的加载内核代码）
$badA = Join-Path $work 'lctopsalpha.sys'
$badB = Join-Path $work 'lctopsbeta.sys'
[IO.File]::WriteAllText($badA, 'this is not a PE image (A)', (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($badB, 'this is not a PE image (B)', (New-Object System.Text.UTF8Encoding($false)))

try {
    Write-Host '== OP-1: driver.use 缺 path =='
    $op1 = Eng 'driver.use' @{} -Apply
    Check 'OP-1a 没有 path ⇒ 拒绝' ($null -ne $op1 -and $op1.ok -eq $false) ''
    Check 'OP-1b 提示只要给路径' ((@($op1.errors) -join ' ') -match 'Path') ''

    Write-Host ''
    Write-Host '== OP-2: 预览不落盘、名字自动推导 =='
    $op2 = Eng 'driver.use' @{ path = $badA }
    Check 'OP-2a 预览 ok=true 且 applied=false' ($null -ne $op2 -and $op2.ok -eq $true -and $op2.data.applied -eq $false) ''
    $derived = ''
    if ($null -ne $op2 -and $null -ne $op2.data) { $derived = [string]$op2.data.serviceName }
    Check 'OP-2b 服务名自动推导且合法' ($derived -match '^[A-Za-z0-9_.\-]{1,128}$') ('serviceName=' + $derived)
    Check 'OP-2c 预览没有创建服务键' (-not (SvcKeyExists $derived)) ''
    Check 'OP-2d 给了 nextSteps' (@($op2.data.nextSteps).Count -ge 1) ''

    Write-Host ''
    Write-Host '== OP-3: -Apply（无效镜像，系统必拒） =='
    $op3 = Eng 'driver.use' @{ path = $badA } -Apply
    if ($null -ne $op3 -and $null -ne $op3.data) { $svcName = [string]$op3.data.serviceName }
    Check 'OP-3a 服务键已创建' ($svcName -ne '' -and (SvcKeyExists $svcName)) ('service=' + $svcName)
    $exitCode = -1
    if ($null -ne $op3 -and $null -ne $op3.data -and $null -ne $op3.data.verdict) { $exitCode = [int]$op3.data.verdict.exitCode }
    Check 'OP-3b 系统拒绝了启动（exitCode≠0）' ($exitCode -ne 0) ('exitCode=' + $exitCode)
    Check 'OP-3c loaded=false 且给出 verify' ($null -ne $op3 -and $op3.data.loaded -eq $false -and $null -ne $op3.data.verify) ''

    Write-Host ''
    Write-Host '== OP-4: 按 path 卸载（不用记名字） =='
    $op4 = Eng 'driver.release' @{ path = $badA } -Apply
    Check 'OP-4a release ok=true' ($null -ne $op4 -and $op4.ok -eq $true) ''
    Check 'OP-4b 反查到并卸载了服务' (@($op4.data.released | Where-Object { $_.ok -eq $true }).Count -ge 1) ''
    Check 'OP-4c 服务键已消失' ($svcName -ne '' -and -not (SvcKeyExists $svcName)) ('service=' + $svcName)

    Write-Host ''
    Write-Host '== OP-5: cleanup 之后没有 lct* 服务 =='
    $op5 = Eng 'driver.cleanup' $null -Apply
    Check 'OP-5a cleanup ok=true' ($null -ne $op5 -and $op5.ok -eq $true) ''
    $left = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'lct*' })
    Check 'OP-5b 没有 lct* 服务残留' (@($left).Count -eq 0) ('left=' + @($left).Count)

    Write-Host ''
    Write-Host '== OP-6: release 既无 name 也无 path =='
    $op6 = Eng 'driver.release' @{} -Apply
    Check 'OP-6 拒绝并说明要给 name 或 path' (($null -ne $op6) -and ($op6.ok -eq $false) -and ((@($op6.errors) -join ' ') -match 'name|path|ImagePath')) ''
    Write-Host ''
Write-Host '== OP-7: 服务名推导稳定 =='
$p1 = Eng 'driver.use' @{ path = $badA }
$p2 = Eng 'driver.use' @{ path = $badA }
$p3 = Eng 'driver.use' @{ path = $badB }
$n1 = [string]$p1.data.serviceName
$n2 = [string]$p2.data.serviceName
$n3 = [string]$p3.data.serviceName
Check 'OP-7a 同一文件两次推导一致' ($n1 -eq $n2 -and $n1 -ne '') ('a=' + $n1)
Check 'OP-7b 不同文件推导不同名' ($n1 -ne $n3) ('a=' + $n1 + ' b=' + $n3)

    Write-Host '== OP-8: cleanup 也能清掉"指向样本库但名字不是 lct*"的服务 =='
    $storeDir = Join-Path $root 'var\samples'
    if (-not (Test-Path $storeDir)) { $null = New-Item -ItemType Directory -Path $storeDir -Force }
    $storeSys = Join-Path $storeDir 'lctopsstoretest.sys'
    [IO.File]::WriteAllText($storeSys, 'this is not a PE image (store)', (New-Object System.Text.UTF8Encoding($false)))
    $op8a = Eng 'driver.use' @{ path = $storeSys } -Apply
    $n8 = ''
    if ($null -ne $op8a -and $null -ne $op8a.data) { $n8 = [string]$op8a.data.serviceName }
    Check 'OP-8a 服务已注册（名字来自文件名，不带 lct 前缀）' ($n8 -ne '' -and (SvcKeyExists $n8)) ('service=' + $n8)
    $op8b = Eng 'driver.cleanup' $null -Apply
    Check 'OP-8b cleanup 认出了它（按 ImagePath 指向样本库）' (@($op8b.data.candidates) -contains $n8) ('candidates=' + ((@($op8b.data.candidates)) -join ','))
    Check 'OP-8c cleanup 卸载了它' ($n8 -ne '' -and -not (SvcKeyExists $n8)) ''
    if (Test-Path -LiteralPath $storeSys) { try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($storeSys, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }

} finally {
    # 无论如何都不留自己的服务
    try {
        foreach ($n in @('lctopsalpha', 'lctopsbeta', $svcName)) {
            if ($n -and (SvcKeyExists $n)) { $null = & $psExe -NoProfile -ExecutionPolicy Bypass -File $engine -Verb driver.release -Apply -Args ('{"name":"' + $n + '"}') 2>$null }
        }
    } catch { }
    if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
}

Write-Host ''

Write-Host ''
Write-Host ('DriverOpsTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail