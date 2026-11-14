# =====================================================================
# LocalConfigTool - DriverVm.psm1
#
# 职责：把「在 VMware 虚拟机里跑驱动」固化成引擎 verb。
#
# 为什么需要 VM 层：
#   静态分析只能猜"这个常量可能是 IOCTL"；真正的判定是把命令发过去看它执行不执行。
#   但内核驱动出问题的代价是整机蓝屏 —— 所以执行必须放在**一次性 VM** 里。
#
# 架构（主机编排 + guest 执行，全部经 vmrun，无需自研协议）：
#
#   主机 (本模块)                          VM (guest)
#   ┌────────────────────┐  vmrun 调用    ┌──────────────────────┐
#   │ driver.vm.status   │ ──────────────►│ guest-probe.ps1      │
#   │ driver.vm.push     │  copyFile      │  - sc create/start   │
#   │ driver.vm.probe    │  runProgram    │  - 取 ntoskrnl 基址  │
#   │ driver.vm.snapshot │ ◄────────────── │  - 发 IOCTL          │
#   └────────────────────┘  结果/超时     │  - 写 result.json    │
#                                          └──────────────────────┘
#
# 崩溃语义：
#   guest 蓝屏 → runProgramInGuest 超时 / tools 掉线 / result.json 不更新
#   → 主机判定 crash。**崩溃是结论，不是失败。**
#
# 安全边界：
#   * 密码只存 DPAPI 加密文件（var\vm\secret.dat），解出来只用于 -gp，**绝不写日志**
#   * push/probe 是写操作，默认只预览计划，-Apply 才真执行
#   * 不做自动回滚（回滚会丢弃 VM 当前状态，必须由人决定）
#
# 导出（6 个）：
#   driver.vm.config    查看/设置 vmrun 路径、vmx、guest 用户与密码（密码仅落 DPAPI）
#   driver.vm.status    VM 是否在跑 / Tools 状态 / 快照列表 / guest 环境
#   driver.vm.prepare   一次性准备 guest（建目录、Defender 排除）
#   driver.vm.push      把 .sys 与探测脚本送进 guest
#   driver.vm.probe     在 guest 里加载驱动并发 IOCTL，拉回结果
#   driver.vm.snapshot  打快照 / 回滚快照
# =====================================================================

$script:LctVmSelf = $MyInvocation.MyCommand.Path
$script:LctVmRoot = Split-Path -Parent (Split-Path -Parent $script:LctVmSelf)
$script:LctVmCore = Join-Path $script:LctVmRoot 'core'
$script:LctVmVar = Join-Path $script:LctVmRoot 'var\vm'

# 依赖：只需要 Logging（New-LctResult）。能解析就复用，不要 -Force（会重置模块状态）。
# 依赖：Logging（结果封装）、DriverProfiles（profile 读取 + buffer 编码）、DriverProbe（变异生成）。
# 能解析到就复用，不要 -Force（会重置已加载模块的状态）。
$script:LctVmDeps = New-Object System.Collections.ArrayList
$depProbeMap = @{
    'Logging' = 'New-LctResult'
    'DriverProfiles' = 'ConvertTo-LctPrfBuffer'
    'DriverProbe' = 'New-LctCtlPayloadVariants'
}
foreach ($dep in @('Logging', 'DriverProfiles', 'DriverProbe')) {
    $probeFn = $depProbeMap[$dep]
    if ($null -ne (Get-Command -Name $probeFn -ErrorAction SilentlyContinue)) {
        $null = $script:LctVmDeps.Add($dep + ':reuse')
        continue
    }
    $depPath = Join-Path $script:LctVmCore ($dep + '.psm1')
    if (-not (Test-Path -LiteralPath $depPath)) { $null = $script:LctVmDeps.Add($dep + ':missing'); continue }
    try { Import-Module $depPath -ErrorAction Stop; $null = $script:LctVmDeps.Add($dep + ':imported') }
    catch { $null = $script:LctVmDeps.Add($dep + ':FAIL ' + $_.Exception.Message) }
}
function Get-LctVmDeps { return @($script:LctVmDeps) }

# ---------------- 配置 ----------------

function Get-LctVmConfigPath { return (Join-Path $script:LctVmVar 'config.json') }
function Get-LctVmSecretPath { return (Join-Path $script:LctVmVar 'secret.dat') }

function Get-LctVmConfig {
    # 读配置；给合理默认（vmrun 路径会自动探测）
    $cfg = [ordered]@{ vmrun = ''; vmx = ''; guestUser = ''; guestDir = 'C:\lct'; timeoutSec = 120 }
    $p = Get-LctVmConfigPath
    if (Test-Path -LiteralPath $p) {
        try {
            $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('vmrun', 'vmx', 'guestUser', 'guestDir', 'timeoutSec')) {
                $v = $null
                try { $v = $raw.PSObject.Properties[$k].Value } catch { $v = $null }
                if ($null -ne $v -and [string]$v -ne '') { $cfg[$k] = $v }
            }
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.vmrun)) {
        foreach ($c in @('D:\vm\vmrun.exe', 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe', 'C:\Program Files\VMware\VMware Workstation\vmrun.exe')) {
            if (Test-Path -LiteralPath $c) { $cfg.vmrun = $c; break }
        }
    }
    return [pscustomobject]$cfg
}

function Save-LctVmConfig {
    param($Config)
    if (-not (Test-Path -LiteralPath $script:LctVmVar)) { $null = New-Item -ItemType Directory -Path $script:LctVmVar -Force }
    $json = $Config | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Get-LctVmConfigPath), $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-LctVmSecret {
    # 解出 guest 密码。DPAPI 绑定当前用户；解不出来返回空串。**调用方不得写日志**。
    $p = Get-LctVmSecretPath
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try {
        $enc = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
        if ($enc -eq '') { return '' }
        $sec = ConvertTo-SecureString -String $enc -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return '' }
}

function Set-LctVmSecret {
    param([string]$Plain)
    if (-not (Test-Path -LiteralPath $script:LctVmVar)) { $null = New-Item -ItemType Directory -Path $script:LctVmVar -Force }
    $sec = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    $enc = ConvertFrom-SecureString -SecureString $sec
    [IO.File]::WriteAllText((Get-LctVmSecretPath), $enc, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- vmrun 包装 ----------------

function Invoke-LctVmRun {
    # 执行一次 vmrun。返回 { exit, out, ok }。**不记录密码**。
    param([string[]]$Params, [string]$Pass, [string]$User, [int]$TimeoutSec = 60)
    $cfg = Get-LctVmConfig
    if (-not (Test-Path -LiteralPath $cfg.vmrun)) {
        return [pscustomobject][ordered]@{ ok = $false; exit = -1; out = ('vmrun 不存在: ' + $cfg.vmrun) }
    }
    $all = @('-T', 'ws')
    if (-not [string]::IsNullOrWhiteSpace($User) -and -not [string]::IsNullOrWhiteSpace($Pass)) {
        $all += @('-gu', $User, '-gp', $Pass)
    }
    $all += $Params

    # 必须用 Process + WaitForExit 做**真超时**：guest 里的 IOCTL 可能永久阻塞，
    # 同步调用 & vmrun 会一直挂着（实测 110 码扫描挂过 600 秒）。
    $argList = @()
    foreach ($a in $all) {
        $s = [string]$a
        if ($s -match '[\s"]') { $argList += ('"' + ($s -replace '"', '\"') + '"') } else { $argList += $s }
    }
    $outLines = @()
    $code = -1
    $timedOut = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cfg.vmrun
        $psi.Arguments = ($argList -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $ms = [Math]::Max(1000, ($TimeoutSec * 1000))
        if (-not $p.WaitForExit($ms)) {
            $timedOut = $true
            try { $p.Kill() } catch { }
            try { $null = $p.WaitForExit(5000) } catch { }
        }
        $so = ''
        $se = ''
        try { $so = [string]$outTask.Result } catch { $so = '' }
        try { $se = [string]$errTask.Result } catch { $se = '' }
        $outLines = @((($so + "`n" + $se) -split "`r?`n") | Where-Object { $_ -ne '' })
        try { $code = $p.ExitCode } catch { $code = -3 }
    } catch {
        $outLines = @('vmrun 调用异常: ' + $_.Exception.Message)
        $code = -2
    }
    if ($timedOut) { $outLines += ('[超时] vmrun 超过 ' + $TimeoutSec + ' 秒未返回（可能 guest 里 IOCTL 阻塞或 VM 蓝屏）') }
    $txt = (@($outLines) -join ' ').Trim()
    # vmrun 成功时通常无输出或 "The file exists." 之类；失败会带 Error:/non-zero
    $failed = $timedOut -or ($code -ne 0) -or ($txt -match '(?i)^error|non-zero exit code')
    return [pscustomobject][ordered]@{ ok = (-not $failed); exit = $code; out = $txt; lines = @($outLines); timedOut = $timedOut }
}

function Get-LctVmGuestAuth {
    # 返回 @{ user; pass }；密码为空时明确报错
    $cfg = Get-LctVmConfig
    $pwd = Get-LctVmSecret
    return [pscustomobject][ordered]@{ user = [string]$cfg.guestUser; pass = $pwd; configured = (($cfg.guestUser -ne '') -and ($pwd -ne '')) }
}

function Test-LctVmReady {
    # 检查 vmrun/vmx/密码是否就绪；返回 { ok; reasons[] }
    $cfg = Get-LctVmConfig
    $auth = Get-LctVmGuestAuth
    $reasons = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $cfg.vmrun)) { $null = $reasons.Add('vmrun 不存在（用 driver.vm.config 设置）: ' + $cfg.vmrun) }
    if ([string]::IsNullOrWhiteSpace([string]$cfg.vmx)) { $null = $reasons.Add('未配置 vmx（用 driver.vm.config -Vmx 设置）') }
    elseif (-not (Test-Path -LiteralPath $cfg.vmx)) { $null = $reasons.Add('vmx 文件不存在: ' + $cfg.vmx) }
    if (-not $auth.configured) { $null = $reasons.Add('未配置 guest 用户或密码（用 driver.vm.config -GuestUser -GuestPassword 设置）') }
    return [pscustomobject][ordered]@{ ok = (@($reasons).Count -eq 0); reasons = @($reasons); config = $cfg; auth = $auth }
}

# ---------------- verb: config ----------------

function Invoke-LctVmConfig {
    param([string]$Vmrun, [string]$Vmx, [string]$GuestUser, [string]$GuestPassword, [int]$TimeoutSec = 0, [switch]$ClearPassword, [switch]$Apply)
    $verb = 'driver.vm.config'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $cfg = Get-LctVmConfig
    $changed = @()

    if (-not [string]::IsNullOrWhiteSpace($Vmrun)) { $cfg.vmrun = $Vmrun; $changed += 'vmrun' }
    if (-not [string]::IsNullOrWhiteSpace($Vmx)) { $cfg.vmx = $Vmx; $changed += 'vmx' }
    if (-not [string]::IsNullOrWhiteSpace($GuestUser)) { $cfg.guestUser = $GuestUser; $changed += 'guestUser' }
    if ($TimeoutSec -gt 0) { $cfg.timeoutSec = $TimeoutSec; $changed += 'timeoutSec' }
    if ($ClearPassword) { $changed += 'clearPassword' }
    if (-not [string]::IsNullOrWhiteSpace($GuestPassword)) { $changed += 'guestPassword' }

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            wouldChange = @($changed)
            vmrun = $cfg.vmrun; vmx = $cfg.vmx; guestUser = $cfg.guestUser; guestDir = $cfg.guestDir; timeoutSec = $cfg.timeoutSec
            hasPassword = ((Get-LctVmSecret) -ne '')
            configPath = (Get-LctVmConfigPath)
            secretPath = (Get-LctVmSecretPath)
            note = '当前是预览。加 -Apply 才写入配置；密码只会以 DPAPI 加密形式落到 secret 文件，不写日志。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    Save-LctVmConfig -Config $cfg
    if ($ClearPassword) {
        $sp = Get-LctVmSecretPath
        if (Test-Path -LiteralPath $sp) {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
            try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($sp, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($GuestPassword)) { Set-LctVmSecret -Plain $GuestPassword }

    $ready = Test-LctVmReady
    $data = [pscustomobject][ordered]@{
        applied = $true
        changed = @($changed)
        vmrun = $cfg.vmrun; vmx = $cfg.vmx; guestUser = $cfg.guestUser; guestDir = $cfg.guestDir; timeoutSec = $cfg.timeoutSec
        hasPassword = ((Get-LctVmSecret) -ne '')
        ready = $ready.ok
        reasons = @($ready.reasons)
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: status ----------------

function Get-LctVmStatus {
    $verb = 'driver.vm.status'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady

    $live = @()
    $tools = ''
    $snaps = @()
    $guest = $null
    if ($ready.ok) {
        $r1 = Invoke-LctVmRun -Params @('list') -TimeoutSec 30
        if ($r1.ok) {
            # 输出形如 "Total running VMs: 1" 然后每行一个 vmx 路径 —— 按行取，不能按整串
            $live = @($r1.lines | Where-Object { $_ -match '\.vmx' } | ForEach-Object { $_.Trim() })
        }
        $r2 = Invoke-LctVmRun -Params @('checkToolsState', $ready.config.vmx) -TimeoutSec 30
        $tools = [string]$r2.out
        $r3 = Invoke-LctVmRun -Params @('listSnapshots', $ready.config.vmx) -TimeoutSec 30
        if ($r3.ok) {
            # 首行 "Total snapshots: N"，之后每行一个快照名
            $snaps = @($r3.lines | Where-Object { $_ -match '^\s*Snapshot' } | ForEach-Object { $_.Trim() })
        }
        # guest 环境（只在 tools running 时问）
        if ($tools -match '(?i)running') {
            $auth = $ready.auth
            $probePs = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
            if (Test-Path -LiteralPath $probePs) {
                $gd = [string]$ready.config.guestDir
                $envScript = Join-Path $gd 'env.ps1'
                $tmp = Join-Path $env:TEMP ('lct-vm-env-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
                $body = @'
$o = [ordered]@{
  admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  os = [System.Environment]::OSVersion.VersionString
  ps = $PSVersionTable.PSVersion.ToString()
  host = $env:COMPUTERNAME
  driverCount = 0
  testsigning = ''
}
try { $o.driverCount = @(Get-ChildItem 'C:\Windows\System32\drivers' -Filter '*.sys' -EA SilentlyContinue).Count } catch { }
try { $o.testsigning = ((bcdedit /enum '{current}' 2>$null) | Select-String 'testsigning') -join ';' } catch { }
$o | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath 'GUESTDIR\env.json' -Encoding UTF8
'@
                $body = $body.Replace('GUESTDIR', $gd)
                [IO.File]::WriteAllText($tmp, (($body -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
                $rc1 = Invoke-LctVmRun -Params @('createDirectoryInGuest', $ready.config.vmx, $gd) -User $auth.user -Pass $auth.pass -TimeoutSec 30
                $rc2 = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $ready.config.vmx, $tmp, $envScript) -User $auth.user -Pass $auth.pass -TimeoutSec 60
                if ($rc2.ok) {
                    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                    $rc3 = Invoke-LctVmRun -Params @('runProgramInGuest', $ready.config.vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('& ''' + $envScript + '''')) -User $auth.user -Pass $auth.pass -TimeoutSec 90
                    if ($rc3.ok) {
                        $outPath = Join-Path $env:TEMP ('lct-vm-env-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
                        $rc4 = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $ready.config.vmx, (Join-Path $gd 'env.json'), $outPath) -User $auth.user -Pass $auth.pass -TimeoutSec 60
                        if ($rc4.ok -and (Test-Path -LiteralPath $outPath)) {
                            try { $guest = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $guest = $null }
                        }
                    } else { $null = $warnings.Add('guest 环境查询失败：' + $rc3.out) }
                } else { $null = $warnings.Add('guest 环境脚本推送失败：' + $rc2.out) }
            }
        }
    }

    $data = [pscustomobject][ordered]@{
        ready = $ready.ok
        reasons = @($ready.reasons)
        vmrun = $ready.config.vmrun
        vmx = $ready.config.vmx
        guestUser = $ready.config.guestUser
        hasPassword = ((Get-LctVmSecret) -ne '')
        guestDir = $ready.config.guestDir
        runningVmx = @($live)
        toolsState = $tools
        snapshots = @($snaps)
        guest = $guest
        note = '只读检查。runningVmx 里出现目标 vmx 才说明虚拟机在跑；toolsState=running 才能做 guest 操作。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: prepare ----------------

function Initialize-LctVmGuest {
    <#
    .SYNOPSIS driver.vm.prepare：一次性准备 guest（建工作目录 + Defender 排除 + 报告 testsigning）
    #>
    param([switch]$Apply, [switch]$SkipDefender)
    $verb = 'driver.vm.prepare'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            guestDir = $gd
            wouldDo = @('createDirectoryInGuest ' + $gd, $(if (-not $SkipDefender) { 'Add-MpPreference -ExclusionPath ' + $gd } else { '（跳过 Defender 排除）' }), '读取 testsigning / SecureBoot 状态')
            note = '预览。加 -Apply 才真正在 guest 里执行。注意：Defender 排除是安全取舍，只应在一次性测试 VM 里做。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    $steps = New-Object System.Collections.ArrayList
    $rc1 = Invoke-LctVmRun -Params @('createDirectoryInGuest', $vmx, $gd) -User $auth.user -Pass $auth.pass -TimeoutSec 30
    $null = $steps.Add('createDirectory: ' + $(if ($rc1.ok) { 'ok' } else { $rc1.out }))

    $prep = Join-Path $env:TEMP ('lct-vm-prep-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
    $lines = @(
        '$o = [ordered]@{ steps = @() }',
        'try {',
        $(if (-not $SkipDefender) { "  Add-MpPreference -ExclusionPath '$gd' -ErrorAction Stop; `$o.steps += 'defender-exclusion: ok'" } else { "  `$o.steps += 'defender-exclusion: skipped'" }),
        '} catch { $o.steps += (''defender-exclusion: FAIL '' + $_.Exception.Message) }',
        'try { $o.steps += (''exclusionPath: '' + ((Get-MpPreference).ExclusionPath -join '','')) } catch { }',
        "try { `$o.testsigning = ((bcdedit /enum '{current}' 2>`$null) | Select-String 'testsigning') -join ';' } catch { }",
        'try { $o.secureBoot = (Confirm-SecureBootUEFI -ErrorAction Stop) } catch { $o.secureBoot = ''n/a'' }',
        'try { $o.admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }',
        "$o | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$gd\prepare.json' -Encoding UTF8",
        'Write-Output "PREPARE DONE"'
    )
    [IO.File]::WriteAllText($prep, (($lines -join "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
    $rc2 = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $prep, (Join-Path $gd 'prepare.ps1')) -User $auth.user -Pass $auth.pass -TimeoutSec 60
    $null = $steps.Add('push prepare.ps1: ' + $(if ($rc2.ok) { 'ok' } else { $rc2.out }))

    if ($rc2.ok) {
        $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $rc3 = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('& ''' + (Join-Path $gd 'prepare.ps1') + '''')) -User $auth.user -Pass $auth.pass -TimeoutSec 120
        $null = $steps.Add('run prepare: ' + $(if ($rc3.ok) { 'ok' } else { $rc3.out }))
        $outPath = Join-Path $env:TEMP ('lct-vm-prep-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        $rc4 = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, (Join-Path $gd 'prepare.json'), $outPath) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        $null = $steps.Add('pull prepare.json: ' + $(if ($rc4.ok) { 'ok' } else { $rc4.out }))
        $info = $null
        if ($rc4.ok -and (Test-Path -LiteralPath $outPath)) {
            try { $info = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        $data = [pscustomobject][ordered]@{
            applied = $true
            guestDir = $gd
            steps = @($steps)
            guest = $info
            note = 'guest 已准备。rtcore64 这类有正规厂商签名的驱动可直接加载；未签名驱动还需要 testsigning on + 重启。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    $data = [pscustomobject][ordered]@{ applied = $true; guestDir = $gd; steps = @($steps) }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('准备脚本推送失败') -Data $data
}

# ---------------- verb: push ----------------

function Push-LctVmDriver {
    <#
    .SYNOPSIS driver.vm.push：把 .sys 与探测脚本送进 guest
    #>
    param([string]$Path, [string]$Name = 'target.sys', [switch]$Apply)
    $verb = 'driver.vm.push'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path)) { return New-LctResult -Verb $verb -Errors @('缺少 -Path（要推送的 .sys）') }
    if (-not (Test-Path -LiteralPath $Path)) { return New-LctResult -Verb $verb -Errors @('文件不存在: ' + $Path) }
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    $probePs = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
    $guestSys = Join-Path $gd $Name
    $guestProbe = Join-Path $gd 'probe.ps1'

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            sys = (Resolve-Path -LiteralPath $Path).ProviderPath
            sysBytes = (Get-Item -LiteralPath $Path).Length
            guestSys = $guestSys
            guestProbe = $guestProbe
            wouldDo = @('createDirectoryInGuest ' + $gd, 'copyFileFromHostToGuest <sys> ' + $guestSys, 'copyFileFromHostToGuest <probe.ps1> ' + $guestProbe)
            note = '预览。加 -Apply 才真正复制。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    $steps = New-Object System.Collections.ArrayList
    $rc0 = Invoke-LctVmRun -Params @('createDirectoryInGuest', $vmx, $gd) -User $auth.user -Pass $auth.pass -TimeoutSec 30
    $null = $steps.Add('mkdir: ' + $(if ($rc0.ok) { 'ok' } else { 'exists/err' }))
    $rc1 = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, (Resolve-Path -LiteralPath $Path).ProviderPath, $guestSys) -User $auth.user -Pass $auth.pass -TimeoutSec 180
    $null = $steps.Add('push sys: ' + $(if ($rc1.ok) { 'ok' } else { $rc1.out }))
    if (-not $rc1.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('推送 .sys 失败: ' + $rc1.out) }
    $rc2 = Invoke-LctVmRun -Params @('fileExistsInGuest', $vmx, $guestSys) -User $auth.user -Pass $auth.pass -TimeoutSec 30
    $null = $steps.Add('verify sys: ' + $rc2.out)
    if (Test-Path -LiteralPath $probePs) {
        $rc3 = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $probePs, $guestProbe) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        $null = $steps.Add('push probe.ps1: ' + $(if ($rc3.ok) { 'ok' } else { $rc3.out }))
    } else { $null = $warnings.Add('找不到 tools\vm-agent\guest-probe.ps1，只推送了 .sys') }

    $data = [pscustomobject][ordered]@{
        applied = $true
        guestSys = $guestSys
        guestProbe = $guestProbe
        steps = @($steps)
        note = '已推送。下一步用 driver.vm.probe 在 guest 里执行。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: probe ----------------

function Invoke-LctVmProbe {
    <#
    .SYNOPSIS driver.vm.probe：在 guest 里加载驱动并发 IOCTL，拉回结果
    .DESCRIPTION
      crash 判定：runProgramInGuest 超时 / result.json 未更新 / tools 掉线。
      崩溃是结论，不是失败。
    #>
    param([string]$GuestSys = '', [string]$Ioctl = '', [int]$ReadSize = 0, [string]$Addr = '', [string]$Devices = '', [string]$Levels = '', [int]$TimeoutSec = 0, [switch]$Apply)
    $verb = 'driver.vm.probe'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    if ([string]::IsNullOrWhiteSpace($GuestSys)) { $GuestSys = Join-Path $gd 'target.sys' }
    if ($TimeoutSec -le 0) { $TimeoutSec = [int]$ready.config.timeoutSec }
    if ($TimeoutSec -le 0) { $TimeoutSec = 120 }
    $guestResult = Join-Path $gd 'result.json'
    $guestProbe = Join-Path $gd 'probe.ps1'
    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            guestSys = $GuestSys; guestProbe = $guestProbe; guestResult = $guestResult
            ioctl = $(if ($Ioctl -ne '') { $Ioctl } else { '0x80002048（默认）' })
            readSize = $(if ($ReadSize -gt 0) { $ReadSize } else { 4 })
            addr = $(if ($Addr -ne '') { $Addr } else { 'ntoskrnl 基址（guest 内自动取）' })
            timeoutSec = $TimeoutSec
            wouldDo = @(
                '在 guest 里跑: powershell -Command "& ''<guestProbe>''"'
                '传入环境变量: LCT_SYS / LCT_IOCTL / LCT_READSIZE / LCT_ADDR / LCT_DEVICES'
                '拉回 ' + $guestResult
                '判定: ok-data / error / no-device / crash（超时或 tools 掉线）'
            )
            note = '预览。加 -Apply 才真正在 guest 里加载驱动并发 IOCTL。畸形包可能蓝屏——确认 VM 有快照。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # 构造 -Command：设置环境变量 + 执行 probe（vmrun 的 -File 不可靠，必须 -Command）
    $envParts = New-Object System.Collections.ArrayList
    # ArrayList.Add 返回索引（0/1/…），漏进管道会污染函数返回值（实测 data 变成 [0,1,{...}]）
    $null = $envParts.Add("`$env:LCT_SYS='$GuestSys'")
    if ($Ioctl -ne '') { $null = $envParts.Add("`$env:LCT_IOCTL='$Ioctl'") }
    if ($ReadSize -gt 0) { $null = $envParts.Add("`$env:LCT_READSIZE='$ReadSize'") }
    if ($Addr -ne '') { $null = $envParts.Add("`$env:LCT_ADDR='$Addr'") }
    if ($Devices -ne '') { $null = $envParts.Add("`$env:LCT_DEVICES='$Devices'") }
    $cmdText = ($envParts -join '; ') + ('; & ''' + $guestProbe + '''')

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdText) -User $auth.user -Pass $auth.pass -TimeoutSec $TimeoutSec
    $sw.Stop()
    $elapsed = [int]$sw.ElapsedMilliseconds

    # 先看 tools 是否还活着（判断崩溃）
    $toolsAfter = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 30
    $crashed = $false
    $crashReason = ''
    if (-not $run.ok -and ($elapsed -ge ($TimeoutSec * 900))) { $crashed = $true; $crashReason = 'runProgramInGuest 超时（' + $elapsed + 'ms）' }
    if ($toolsAfter.out -notmatch '(?i)running') { $crashed = $true; $crashReason = 'VMware Tools 不在 running: ' + $toolsAfter.out }

    # 拉结果
    $outPath = Join-Path $env:TEMP ('lct-vm-result-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $pull = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, $guestResult, $outPath) -User $auth.user -Pass $auth.pass -TimeoutSec 60
    $result = $null
    if ($pull.ok -and (Test-Path -LiteralPath $outPath)) {
        try { $result = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $result = $null }
    }

    $verdict = 'unknown'
    if ($null -ne $result) { $verdict = [string]$result.verdict }
    if ($crashed) { $verdict = 'crash' }
    elseif ($null -eq $result -and -not $run.ok) { $verdict = 'run-failed' }

    $data = [pscustomobject][ordered]@{
        applied = $true
        guestSys = $GuestSys
        crashed = $crashed
        crashReason = $crashReason
        toolsState = $toolsAfter.out
        vmrunOut = $run.out
        elapsedMs = $elapsed
        timeoutSec = $TimeoutSec
        verdict = $verdict
        guestResult = $result
        note = 'verdict: ok-data=功能执行成功（返回数据）；error=驱动返回错误码（看 win32Error）；no-device=设备没打开；crash=VM 崩了/超时（校验缺失的强证据）。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: snapshot ----------------

function Invoke-LctVmAnchor {
    <#
    .SYNOPSIS driver.vm.anchor：用 kread 读内核对象，拿 DRIVER_OBJECT / MajorFunction[]
    .DESCRIPTION
      「动态定位 → 静态精读 → 动态验证」流水线的第一棒。

      借已知漏洞驱动（RTCore64 之类）的 kread 原语：
        handle -> FILE_OBJECT -> DEVICE_OBJECT -> DRIVER_OBJECT
        -> DriverName / DriverStart / DriverSize / MajorFunction[0..27]
      直接给出 IRP_MJ_DEVICE_CONTROL 的精确 RVA（反汇编起点），
      不需要暴力扫 IOCTL 码（driver.vm.discover），也不需要猜从哪开始反汇编。

      崩溃是结论，不是失败：VM 里代价是 30 秒回滚。
      预览模式（不加 -Apply）不发任何 IOCTL。
    #>
    param(
        [string]$SysPath = '',
        [string]$Name = 'target.sys',
        [string]$Device = '',
        [string]$Service = '',
        [string]$Ioctl = '',
        [switch]$NoLoad,
        [int]$TimeoutSec = 0,
        [switch]$Apply
    )
    $verb = 'driver.vm.anchor'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'target.sys' }
    if ([string]::IsNullOrWhiteSpace($Device)) { $Device = '\.\RTCore64' }
    if ([string]::IsNullOrWhiteSpace($Service)) { $Service = 'lctanchor' }
    if ($TimeoutSec -le 0) { $TimeoutSec = 180 }
    $guestAnchorPs = Join-Path $gd 'anchor.ps1'
    $guestAnchorJson = Join-Path $gd 'anchor.json'
    $guestSys = Join-Path $gd $Name
    $hostAnchorPs = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-anchor.ps1'
    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $hostAnchorPs)) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('找不到 tools\vm-agent\guest-anchor.ps1')
    }

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied    = $false
            guestSys   = $(if ([string]::IsNullOrWhiteSpace($SysPath)) { '（不加载，假定已加载）' } else { $guestSys })
            guestScript = $guestAnchorPs
            guestResult = $guestAnchorJson
            device     = $Device
            service    = $Service
            ioctl      = $(if ($Ioctl -ne '') { $Ioctl } else { '0x80002048（RTCore64 kread 默认）' })
            noLoad     = [bool]$NoLoad
            timeoutSec = $TimeoutSec
            wouldDo    = @(
                '推 guest-anchor.ps1 到 ' + $guestAnchorPs
                $(if (-not $NoLoad -and $SysPath -ne '') { '推 ' + $SysPath + ' 到 ' + $guestSys + '，并 sc create/start 加载' } else { '不加载驱动（-NoLoad 或未给 -SysPath）' })
                '在 guest 里跑: & ''' + $guestAnchorPs + '''（环境变量 LCT_SYS / LCT_DEVICES / LCT_SVC / LCT_IOCTL / LCT_NOLOAD）'
                '拉回 ' + $guestAnchorJson
                '输出: DriverName / DriverStart / DriverSize / MajorFunction[0..27] / 能力面 / IOCTL 分派 RVA'
            )
            note = '预览。加 -Apply 才真跑（会在 guest 里加载驱动并发 kread）。拿不到 DRIVER_OBJECT 时会如实报错，不会瞎猜。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # 推送脚本
    $pushSteps = New-Object System.Collections.ArrayList
    $rcDir = Invoke-LctVmRun -Params @('createDirectoryInGuest', $vmx, $gd) -User $auth.user -Pass $auth.pass -TimeoutSec 30
    $null = $pushSteps.Add('mkdir: ' + $(if ($rcDir.ok) { 'ok' } else { 'exists/err' }))
    $rcPs = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, (Resolve-Path -LiteralPath $hostAnchorPs).ProviderPath, $guestAnchorPs) -User $auth.user -Pass $auth.pass -TimeoutSec 90
    $null = $pushSteps.Add('push anchor.ps1: ' + $(if ($rcPs.ok) { 'ok' } else { $rcPs.out }))
    if (-not $rcPs.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('推送 guest-anchor.ps1 失败: ' + $rcPs.out) }
    $loadDriver = (-not $NoLoad) -and (-not [string]::IsNullOrWhiteSpace($SysPath))
    if ($loadDriver) {
        if (-not (Test-Path -LiteralPath $SysPath)) {
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('要加载的 .sys 不存在: ' + $SysPath)
        }
        $rcSys = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, (Resolve-Path -LiteralPath $SysPath).ProviderPath, $guestSys) -User $auth.user -Pass $auth.pass -TimeoutSec 180
        $null = $pushSteps.Add('push sys: ' + $(if ($rcSys.ok) { 'ok' } else { $rcSys.out }))
        if (-not $rcSys.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('推送 .sys 失败: ' + $rcSys.out) }
    }

    # 构造 -Command
    $envParts = New-Object System.Collections.ArrayList
    if ($loadDriver) { $null = $envParts.Add("`$env:LCT_SYS='" + $guestSys + "'") }
    $null = $envParts.Add("`$env:LCT_DEVICES='" + $Device + "'")
    $null = $envParts.Add("`$env:LCT_SVC='" + $Service + "'")
    if ($Ioctl -ne '') { $null = $envParts.Add("`$env:LCT_IOCTL='" + $Ioctl + "'") }
    if ($NoLoad) { $null = $envParts.Add("`$env:LCT_NOLOAD='1'") }
    $null = $envParts.Add("`$env:LCT_OUT='" + $guestAnchorJson + "'")
    $cmdText = ($envParts -join '; ') + ('; & ''' + $guestAnchorPs + '''')

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdText) -User $auth.user -Pass $auth.pass -TimeoutSec $TimeoutSec
    $sw.Stop()
    $elapsed = [int]$sw.ElapsedMilliseconds

    # 崩溃判定：先看 tools
    $toolsAfter = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 30
    $crashed = $false
    $crashReason = ''
    if ($toolsAfter.out -notmatch '(?i)running') { $crashed = $true; $crashReason = 'VMware Tools 不在 running: ' + $toolsAfter.out }
    elseif (-not $run.ok) { $crashReason = 'runProgramInGuest 失败: ' + $run.out }

    # 拉结果
    $outPath = Join-Path $env:TEMP ('lct-vm-anchor-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $pull = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, $guestAnchorJson, $outPath) -User $auth.user -Pass $auth.pass -TimeoutSec 60
    $result = $null
    if ($pull.ok -and (Test-Path -LiteralPath $outPath)) {
        try { $result = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $result = $null }
    }
    try { if (Test-Path -LiteralPath $outPath) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($outPath, 'OnlyErrorDialogs', 'SendToRecycleBin') } } catch { }

    if ($crashed) {
        $data = [pscustomobject][ordered]@{
            applied = $true
            verdict = 'crash'
            crashReason = $crashReason
            guestSys = $(if ($loadDriver) { $guestSys } else { '' })
            elapsedMs = $elapsed
            note = 'VM 崩了。这是结论（说明读到了不该读的地址或驱动自身崩了）。回滚快照后可重试。'
        }
        $null = $warnings.Add('VM 崩溃: ' + $crashReason)
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }
    if ($null -eq $result) {
        $data = [pscustomobject][ordered]@{ applied = $true; verdict = 'no-result'; runOutput = $run.out; elapsedMs = $elapsed }
        $null = $errors.Add('guest 没有产出 anchor.json（脚本可能早退）')
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    $verdict = $(if ($result.ok) { 'anchored' } else { 'failed' })
    $cap = $result.capability
    $data = [pscustomobject][ordered]@{
        applied        = $true
        verdict        = $verdict
        driverName     = [string]$result.driverName
        driverObject   = [string]$result.driverObject
        deviceObject   = [string]$result.deviceObject
        fileObject     = [string]$result.fileObject
        driverStart    = [string]$result.driverStart
        driverSize     = [string]$result.driverSize
        device         = [string]$result.device
        ioctlDispatchRva = $(if ($null -ne $cap) { [string]$cap.ioctlDispatchRva } else { '' })
        hasDeviceControl = $(if ($null -ne $cap) { [bool]$cap.hasDeviceControl } else { $false })
        capability     = $cap
        majorFunctions = @($result.majorFunctions)
        selfCheck      = $result.selfCheck
        kreadCalls     = [int]$result.kreadCalls
        elapsedMs      = $elapsed
        pushSteps      = @($pushSteps)
    }
    if ($result.error) { $null = $errors.Add([string]$result.error) }
    if ($verdict -eq 'anchored' -and $null -ne $cap) {
        if (-not $cap.hasDeviceControl) {
            $null = $warnings.Add('这个设备的 MajorFunction[14] 不在驱动内（指向 ntoskrnl 的默认处理）⇒ 它不处理 IRP_MJ_DEVICE_CONTROL，发 IOCTL 没有意义。')
        } else {
            $null = $warnings.Add('IOCTL 分派函数 RVA = ' + [string]$cap.ioctlDispatchRva + '（下一步：只反汇编这一段，不要全扫 .text）')
        }
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}
function Set-LctVmSnapshot {
    <#
    .SYNOPSIS driver.vm.snapshot：打快照 / 回滚快照 / 列快照
    .NOTES 回滚会丢弃 VM 当前全部状态，必须 -Apply 且明确给 -RevertTo。
    #>
    param([string]$Create = '', [string]$RevertTo = '', [switch]$List, [switch]$Apply)
    $verb = 'driver.vm.snapshot'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $vmx = $ready.config.vmx

    if ($List -or ($Create -eq '' -and $RevertTo -eq '')) {
        $r = Invoke-LctVmRun -Params @('listSnapshots', $vmx) -TimeoutSec 30
        $snaps = @($r.lines | Where-Object { $_ -match '^\s*Snapshot' } | ForEach-Object { $_.Trim() })
        $data = [pscustomobject][ordered]@{ action = 'list'; snapshots = @($snaps); raw = $r.out }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    if ($Create -ne '') {
        if (-not $Apply) {
            $data = [pscustomobject][ordered]@{ applied = $false; action = 'create'; name = $Create; note = '预览。加 -Apply 才真的打快照。' }
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
        }
        $r = Invoke-LctVmRun -Params @('snapshot', $vmx, $Create) -TimeoutSec 300
        $data = [pscustomobject][ordered]@{ applied = $true; action = 'create'; name = $Create; ok = $r.ok; out = $r.out }
        if (-not $r.ok) { $null = $errors.Add('打快照失败: ' + $r.out) }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    if ($RevertTo -ne '') {
        if (-not $Apply) {
            $data = [pscustomobject][ordered]@{ applied = $false; action = 'revert'; name = $RevertTo; note = '⚠ 回滚会丢弃 VM 当前全部状态。加 -Apply 才执行。' }
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
        }
        $r = Invoke-LctVmRun -Params @('revertToSnapshot', $vmx, $RevertTo) -TimeoutSec 600
        $data = [pscustomobject][ordered]@{ applied = $true; action = 'revert'; name = $RevertTo; ok = $r.ok; out = $r.out }
        if (-not $r.ok) { $null = $errors.Add('回滚失败: ' + $r.out) }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    return New-LctResult -Verb $verb -Errors @('参数不足')
}

# ---------------- verb: matrix（完整变异矩阵） ----------------

function Invoke-LctVmMatrix {
    <#
    .SYNOPSIS driver.vm.matrix：把 ctl.variants 生成的变异逐个送进 VM，一条命令跑完整个矩阵
    .DESCRIPTION
      对每个变异：
        1. 按 profile 的 in 布局把变异值编码成字节（@ntoskrnl 留 0 占位并记 patch 位置）
        2. 在 guest 里用该 buffer 发 IOCTL（LCT_INHEX + LCT_PATCH）
        3. 如实记录 verdict / 返回码 / 返回字节 / 是否崩
      按 baseline → boundary → address → cross-page 顺序升级；一旦判定 crash 就停（后续没意义）。
      每条独立超时（默认 60 秒），防止某个畸形包把驱动卡死。
    #>
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Action,
        [string]$Levels = 'baseline,boundary,address,cross-page',
        [int]$MaxVariants = 40,
        [int]$PerVariantTimeoutSec = 60,
        [string]$GuestSys = '',
        [string]$Codes = '',
        [int]$MaxCodes = 64,
        [switch]$Apply
    )
    $verb = 'driver.vm.matrix'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    if ([string]::IsNullOrWhiteSpace($GuestSys)) { $GuestSys = Join-Path $gd 'target.sys' }
    $guestResult = Join-Path $gd 'result.json'
    $guestProbe = Join-Path $gd 'probe.ps1'
    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($PerVariantTimeoutSec -le 0) { $PerVariantTimeoutSec = 60 }

    # ---- 生成变异 ----
    $varRes = $null
    try { $varRes = New-LctCtlPayloadVariants -Profile $Profile -Action $Action -MaxVariants $MaxVariants } catch { $varRes = $null }
    if ($null -eq $varRes -or -not $varRes.ok) {
        $e = '生成变异失败'
        if ($null -ne $varRes) { $e = (@($varRes.errors) -join ';') }
        return New-LctResult -Verb $verb -Errors @($e)
    }
    $variants = @($varRes.data.variants)

    # ---- 读 profile（拿 inFields / layout / ioctl）----
    $show = $null
    try { $show = Get-LctDriverProfileShow -Id $Profile } catch { $show = $null }
    if ($null -eq $show) { return New-LctResult -Verb $verb -Errors @('读不到 profile: ' + $Profile) }
    $shell = $show
    $prof = Get-LctVmProp $shell 'profile' $null
    if ($null -eq $prof) { $prof = $shell }
    $actions = Get-LctVmProp $prof 'actions' $null
    $act = $null
    if ($null -ne $actions) { $act = Get-LctVmProp $actions $Action $null }
    if ($null -eq $act) { return New-LctResult -Verb $verb -Errors @('profile 里没有 action: ' + $Action) }
    $inFields = @(Get-LctVmProp $act 'in' @())
    $layout = Get-LctVmProp $prof 'layout' $null
    $ioctlText = [string](Get-LctVmProp $act 'ioctl' '')
    if ([string]::IsNullOrWhiteSpace($ioctlText)) { return New-LctResult -Verb $verb -Errors @('action 没有 ioctl 码') }


    # ---- 码表模式：dispatchmap 给出的精确码 -> 每个码一条任务 ----
    # 「反哺动态」：不再盲扫/猜码，只测静态表证明有效的那些。
    # 注意：New-LctVmPack 读的是 variant.values（不是 payload），所以这里填 profile 的 presets，
    # 否则字段全 0 -> readSize=0 -> 驱动空转 -> 每个码都"成功"，结论全假。
    $codesList = @()
    if (-not [string]::IsNullOrWhiteSpace($Codes)) {
        $codesList = @(([string]$Codes) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if (@($codesList).Count -eq 0) { return New-LctResult -Verb $verb -Errors @('-Codes 解析后为空') }
        if (@($codesList).Count -gt $MaxCodes) {
            $null = $warnings.Add('码表 ' + @($codesList).Count + ' 个超过 -MaxCodes ' + $MaxCodes + '，只测前 ' + $MaxCodes + ' 个')
            $codesList = @($codesList | Select-Object -First $MaxCodes)
        }
        $presetsObj = $null
        try { $presetsObj = Get-LctVmProp $act 'presets' $null } catch { $presetsObj = $null }
        if ($null -eq $presetsObj) {
            $null = $warnings.Add('profile 的 action 没有 presets：每个码都会用全 0 payload 发送，驱动可能空转（readSize=0），结论不可信。建议先给 action 补 presets。')
        }
        # 把 presets 展开成字典，并自动给"地址类字段"填 @ntoskrnl。
        # 不填的话 addr=0 -> 驱动做 NULL 检查 -> 每个码都返回 87，看起来"全无效"，其实是空转。
        $baseVals = @{}
        if ($presetsObj -is [System.Collections.IDictionary]) {
            foreach ($pk in @($presetsObj.Keys)) { $baseVals[[string]$pk] = $presetsObj[$pk] }
        } elseif ($null -ne $presetsObj) {
            foreach ($pp in @($presetsObj.PSObject.Properties)) { $baseVals[[string]$pp.Name] = $pp.Value }
        }
        $addrFields = @()
        foreach ($fld in @($inFields)) {
            $fn = [string](Get-LctVmProp $fld 'name' '')
            if ($fn -match '(?i)^(addr|address|base|ptr|pointer|target)$' -and -not $baseVals.ContainsKey($fn)) {
                $baseVals[$fn] = '@ntoskrnl'
                $addrFields += $fn
            }
        }
        if (@($addrFields).Count -gt 0) { $null = $warnings.Add('码表模式：地址类字段 ' + (@($addrFields) -join ',') + ' 自动用 @ntoskrnl（guest 侧填真实内核基址）') }
        $variants = @($codesList | ForEach-Object {
                [pscustomobject][ordered]@{
                    mutation = ('code-' + $_)
                    values   = $baseVals
                    risk     = ''
                    ioctl    = [string]$_
                    level    = 'code'
                }
            })
        $null = $warnings.Add('码表模式：按 dispatchmap 给的 ' + @($codesList).Count + ' 个码逐个实测（不用 ctl.variants 的变异）')
    }
    $wantLevels = @(([string]$Levels) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if (@($codesList).Count -gt 0) { $wantLevels += 'code' }

    if (-not $Apply) {
        $plan = New-Object System.Collections.ArrayList
        foreach ($v in $variants) {
            $mut = [string]$v.mutation
            $lvl = Get-LctVmLevel -Mutation $mut
            if ($wantLevels -notcontains $lvl) { continue }
            $oneIoctl = $ioctlText
            if ($null -ne $v.PSObject.Properties['ioctl'] -and -not [string]::IsNullOrWhiteSpace([string]$v.ioctl)) { $oneIoctl = [string]$v.ioctl }
            $pack = New-LctVmPack -InFields $inFields -Layout $layout -Variant $v
            $null = $plan.Add([pscustomobject][ordered]@{
                    mutation = $mut; level = $lvl; payload = [string]$v.payload; ioctl = $oneIoctl
                    inSize = $(if ($null -ne $pack) { $pack.size } else { 0 })
                    inHex = $(if ($null -ne $pack) { $pack.hex } else { '' })
                    patch = $(if ($null -ne $pack) { $pack.patch } else { '' })
                    risk = [string]$v.risk
                })
        }
        $data = [pscustomobject][ordered]@{
            applied = $false
            profile = $Profile; action = $Action; ioctl = $ioctlText
            guestSys = $GuestSys; perVariantTimeoutSec = $PerVariantTimeoutSec
            planned = @($plan).Count
            plan = @($plan)
            note = '预览：把每个变异编码成 in-buffer 并显示 hex/patch。加 -Apply 才真的逐个在 guest 里执行。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # ---- 真跑 ----
    # 先把 guest 侧的 probe.ps1 刷成最新：实测踩过坑——主机脚本改了但 guest 还是旧版，
    # 旧版会静默忽略新参数（LCT_INHEX），表现为所有变异结果一模一样。
    $probeLocal = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
    if (Test-Path -LiteralPath $probeLocal) {
        $rcPush = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $probeLocal, $guestProbe) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        if (-not $rcPush.ok) { $null = $warnings.Add('推送最新 probe.ps1 失败（guest 里可能是旧版）：' + $rcPush.out) }
    } else { $null = $warnings.Add('找不到 tools\vm-agent\guest-probe.ps1，无法刷新 guest 脚本') }

    $results = New-Object System.Collections.ArrayList
    $stopped = ''
    $idx = 0
    foreach ($v in $variants) {
        $mut = [string]$v.mutation
        $lvl = Get-LctVmLevel -Mutation $mut
        if ($wantLevels -notcontains $lvl) { continue }
        $idx++
        $pack = New-LctVmPack -InFields $inFields -Layout $layout -Variant $v
        if ($null -eq $pack -or -not $pack.ok) {
            $null = $results.Add([pscustomobject][ordered]@{
                    mutation = $mut; level = $lvl; verdict = 'encode-failed'
                    detail = $(if ($null -ne $pack) { $pack.error } else { '编码失败' })
                    win32Error = 0; bytesReturned = 0; outHex = ''; elapsedMs = 0
                })
            continue
        }

        # 组装 -Command（vmrun 的 -File 不可靠，必须 -Command）
        $parts = New-Object System.Collections.ArrayList
        $null = $parts.Add("`$env:LCT_SYS='$GuestSys'")
        # 码表模式下每个任务自带 ioctl；否则用 profile 的 action.ioctl
        $oneIoctl = $ioctlText
        if ($null -ne $v.PSObject.Properties['ioctl'] -and -not [string]::IsNullOrWhiteSpace([string]$v.ioctl)) { $oneIoctl = [string]$v.ioctl }
        $null = $parts.Add("`$env:LCT_IOCTL='" + $oneIoctl + "'")
        $null = $parts.Add("`$env:LCT_INHEX='$($pack.hex)'")
        if ($pack.patch -ne '') { $null = $parts.Add("`$env:LCT_PATCH='$($pack.patch)'") }
        $cmdText = ($parts -join '; ') + ('; & ''' + $guestProbe + '''')

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdText) -User $auth.user -Pass $auth.pass -TimeoutSec $PerVariantTimeoutSec
        $sw.Stop()
        $elapsed = [int]$sw.ElapsedMilliseconds

        $toolsAfter = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 30
        # 关键是区分两种"没正常返回"：
        #   crash   = VM 真崩了（tools 掉线），驱动把系统打死了
        #   timeout = IOCTL 挂起但 VM 还活着（实测 addr-low 读地址 0x1 会卡 45 秒，之后 VM 正常）
        # 两者都是校验缺失的证据，但严重程度不同，不能混为一谈。
        $vmDead = ($toolsAfter.out -notmatch '(?i)running')
        $crashed = $vmDead
        $hung = ($run.timedOut -and -not $vmDead)

        $one = [ordered]@{
            mutation = $mut; level = $lvl; payload = [string]$v.payload; ioctl = $oneIoctl
            inSize = $pack.size; inHex = $pack.hex; patch = $pack.patch
            verdict = ''; detail = ''; win32Error = 0; bytesReturned = 0; outHex = ''; elapsedMs = $elapsed
            crashed = $crashed; timedOut = [bool]$run.timedOut
        }
        if ($crashed -or $hung) {
            $one.verdict = $(if ($crashed) { 'crash' } else { 'timeout' })
            $one.detail = $(if ($crashed) { 'VMware Tools 掉线（VM 崩了）: ' + $toolsAfter.out } else { 'IOCTL 挂起 ' + $PerVariantTimeoutSec + 's（VM 还活着）' })
            $null = $results.Add([pscustomobject]$one)
            $stopped = $one.verdict + ' at ' + $mut
            break
        }
        # 拉结果
        $outPath = Join-Path $env:TEMP ('lct-mx-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        $pull = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, $guestResult, $outPath) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        if ($pull.ok -and (Test-Path -LiteralPath $outPath)) {
            try {
                $gr = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $one.verdict = [string]$gr.verdict
                $one.win32Error = [int]$gr.win32Error
                $one.bytesReturned = [int]$gr.bytesReturned
                $one.outHex = [string]$gr.outHex
                if ($one.outHex.Length -gt 128) { $one.outHex = $one.outHex.Substring(0, 128) }
                $one.detail = ('inSize={0} dev={1}' -f $gr.payload, $gr.device)
            } catch { $one.verdict = 'parse-failed'; $one.detail = $_.Exception.Message }
        } else {
            $one.verdict = 'pull-failed'
            $one.detail = $pull.out
        }
        $null = $results.Add([pscustomobject]$one)
    }

    # ---- 汇总 ----
    $all = @($results)
    $sum = [ordered]@{
        total = @($all).Count
        okData = @($all | Where-Object { $_.verdict -eq 'ok-data' }).Count
        error = @($all | Where-Object { $_.verdict -eq 'error' }).Count
        noDevice = @($all | Where-Object { $_.verdict -eq 'no-device' }).Count
        crash = @($all | Where-Object { $_.verdict -eq 'crash' }).Count
        timeout = @($all | Where-Object { $_.verdict -eq 'timeout' }).Count
        other = @($all | Where-Object { $_.verdict -notin @('ok-data', 'error', 'no-device', 'crash', 'timeout') }).Count
        stoppedEarly = $stopped
        totalMs = (@($all | Measure-Object -Property elapsedMs -Sum).Sum)
    }

    # ---- 动态结论落盘：供 driver.batch.scan 反哺 riskScore ----
    # 动态验证比静态猜测强一个数量级，所以结论必须能被静态分诊看到。
    $targetSha = ''
    try {
        $tobj = Get-LctVmProp $prof 'target' $null
        if ($null -ne $tobj) { $targetSha = [string](Get-LctVmProp $tobj 'sha256' '') }
    } catch { }
    $dynPath = ''
    if ($targetSha -match '^[0-9A-Fa-f]{64}$') {
        $dynDir = Join-Path $script:LctVmVar 'driver-dynamic'
        if (-not (Test-Path -LiteralPath $dynDir)) { $null = New-Item -ItemType Directory -Path $dynDir -Force }
        $dynPath = Join-Path $dynDir (($targetSha.ToUpperInvariant()) + '.json')
        # worst：取最严重的结论
        $rank = @{ 'crash' = 5; 'timeout' = 4; 'error' = 3; 'ok-data' = 2; 'no-device' = 1 }
        $worst = ''
        $worstRank = -1
        foreach ($r in @($all)) {
            $v = [string]$r.verdict
            $rk = 0
            if ($rank.ContainsKey($v)) { $rk = $rank[$v] }
            if ($rk -gt $worstRank) { $worstRank = $rk; $worst = $v }
        }
        $dyn = [ordered]@{
            sha256 = $targetSha.ToUpperInvariant()
            profile = $Profile
            action = $Action
            ioctl = $ioctlText
            testedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            worst = $worst
            verdicts = [pscustomobject][ordered]@{
                okData = $sum.okData; error = $sum.error; timeout = $sum.timeout; crash = $sum.crash; noDevice = $sum.noDevice; other = $sum.other
            }
            results = @($all | ForEach-Object {
                    [pscustomobject][ordered]@{
                        mutation = [string]$_.mutation; level = [string]$_.level; verdict = [string]$_.verdict
                        win32Error = [int]$_.win32Error; bytesReturned = [int]$_.bytesReturned; elapsedMs = [int]$_.elapsedMs
                    }
                })
        }
        try {
            [IO.File]::WriteAllText($dynPath, ($dyn | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        } catch { $null = $warnings.Add('动态结论落盘失败: ' + $_.Exception.Message) }
    } else {
        $null = $warnings.Add('profile 没有合法的 target.sha256，动态结论不落盘 —— batch.scan 无法反哺（补上 profile.target.sha256 后重跑）')
    }

    $data = [pscustomobject][ordered]@{
        applied = $true
        profile = $Profile; action = $Action; ioctl = $ioctlText
        guestSys = $GuestSys; perVariantTimeoutSec = $PerVariantTimeoutSec
        summary = [pscustomobject]$sum
        results = $all
        dynamicRecord = $dynPath
        note = 'ok-data=功能执行成功；error=驱动返回错误码（看 win32Error）；no-device=设备没打开；crash=VM 崩了（tools 掉线）；timeout=单条超时但 VM 存活（IOCTL 挂起）。后两者都是校验缺失的强证据，已停止后续。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

function Get-LctVmProp {
    param($Bag, [string]$Name, $Default = $null)
    if ($null -eq $Bag) { return $Default }
    try {
        if ($Bag -is [System.Collections.IDictionary]) {
            if ($Bag.Contains($Name)) { return $Bag[$Name] }
            return $Default
        }
        $p = $Bag.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    } catch { }
    return $Default
}

function Get-LctVmLevel {
    param([string]$Mutation)
    # 码表模式（driver.vm.matrix -Codes）：每个码一条，级别是 code
    if ($Mutation -like 'code-*') { return 'code' }
    # 先判组合变异（addr-max-size-zero 同时含 addr 前缀，放后面会被误判成 address）
    if ($Mutation -eq 'addr-max-size-zero' -or $Mutation -like 'cross-page-*') { return 'cross-page' }
    if ($Mutation -like 'size-*') { return 'boundary' }
    if ($Mutation -like 'addr-*') { return 'address' }
    return 'baseline'
}

function New-LctVmPack {
    <#
      把变异的 values 编码成 in-buffer。
      @ntoskrnl 用 0 占位，并把该字段的字节偏移记进 patch（guest 侧填真实内核基址）。
    #>
    param($InFields, $Layout, $Variant)
    $vals = @{}
    try {
        $raw = Get-LctVmProp $Variant 'values' $null
        if ($null -ne $raw) {
            # 坑：presets 从 profile 读出来是 OrderedDictionary（不是 PSCustomObject）。
            # 直接遍历 PSObject.Properties 会拿到字典自己的 Count/Keys/Values，键值对全丢，
            # 结果是 payload 全 0 -> readSize=0 -> 驱动空转 -> 每个码都"成功"。
            if ($raw -is [System.Collections.IDictionary]) {
                foreach ($k in @($raw.Keys)) { $vals[[string]$k] = $raw[$k] }
            } else {
                foreach ($p in @($raw.PSObject.Properties)) {
                    $vals[[string]$p.Name] = $p.Value
                }
            }
        }
    } catch { }
    # 找出所有 @ntoskrnl 的字段，先换成 0
    $kernelFields = @()
    foreach ($k in @($vals.Keys)) {
        if ([string]$vals[$k] -match '(?i)^@ntoskrnl$') { $kernelFields += $k; $vals[$k] = '0' }
    }
    $pack = ConvertTo-LctPrfBuffer -Fields $InFields -Layout $Layout -Values $vals
    if ($null -eq $pack -or -not $pack.ok) {
        return [pscustomobject][ordered]@{ ok = $false; error = $(if ($null -ne $pack) { $pack.error } else { '编码失败' }); hex = ''; size = 0; patch = '' }
    }
    $bytes = @($pack.bytes)
    # 算每个内核字段的偏移：按 inFields 顺序累加字节数（与 ConvertTo-LctPrfBuffer 的对齐规则一致）
    $patch = @()
    if (@($kernelFields).Count -gt 0) {
        $offset = 0
        $plan = @()
        if ($null -ne $pack.PSObject.Properties['plan']) { $plan = @($pack.plan) }
        foreach ($p in $plan) {
            $nm = ''
            try { $nm = [string]$p.name } catch { $nm = '' }
            $sz = 0
            try { $sz = [int]$p.size } catch { $sz = 0 }
            if ($kernelFields -contains $nm -and $sz -gt 0) { $patch += ($offset.ToString() + ':' + $sz.ToString()) }
            $offset += $sz
        }
    }
    $hex = ''
    if (@($bytes).Count -gt 0) { $hex = (([BitConverter]::ToString([byte[]]$bytes)) -replace '-', '') }
    return [pscustomobject][ordered]@{ ok = $true; error = ''; hex = $hex; size = @($bytes).Count; patch = (@($patch) -join ';') }
}

# ---------------- verb: fields（差分探测推字段布局） ----------------

function Invoke-LctVmFields {
    <#
    .SYNOPSIS driver.vm.fields：差分探测——逐块改 payload，看哪块影响行为，从而推出 in 字段布局
    .DESCRIPTION
      原理（已在 rtcore64 上实测验证）：
        1. 先建立一个**能成功**的 baseline（例如 addr 用 guest 内核基址、readSize=4）
        2. 逐块把 payload 的某个 4 字节块改成 0xFF，重新发送
        3. 比较结果：
             verdict/返回值变了  → 强有效字段（影响控制流或返回长度）
             outHex 变了          → 可能有效（也可能是驱动把输入回填到输出）
             完全没变             → padding
      实测 rtcore64（48 字节 payload）：改 offset 0/40 无影响（padding），
      改 offset 20/24 输出变化（有效字段 offset/readSize），改 addr 会 87（有效字段）。

      这是**动态逆向**：不需要反汇编，只需要能重复发 IOCTL。
      推得出「哪些偏移是字段、多宽」，推不出「语义」（是 addr 还是 size）——那个还得人命名。
    .NOTES 需要 VM 在跑 + 驱动已 push（driver.vm.push）。默认只预览，-Apply 才真发。
    #>
    param(
        [string]$GuestSys = '',
        [Parameter(Mandatory)][string]$Ioctl,
        [int]$InSize = 48,
        [int]$BlockSize = 4,
        [string]$Patch = '',
        [int]$ReadSize = 0,
        [int]$TimeoutSec = 0,
        [switch]$SafeMode,
        [switch]$Aggressive,
        [switch]$Apply
    )
    $verb = 'driver.vm.fields'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    if ([string]::IsNullOrWhiteSpace($GuestSys)) { $GuestSys = Join-Path $gd 'target.sys' }
    $guestResult = Join-Path $gd 'result.json'
    $guestProbe = Join-Path $gd 'probe.ps1'
    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($TimeoutSec -le 0) { $TimeoutSec = 45 }
    if ($InSize -lt 4 -or $InSize -gt 4096) { return New-LctResult -Verb $verb -Errors @('InSize 超出范围 4..4096') }
    if ($BlockSize -lt 1 -or $BlockSize -gt 64) { return New-LctResult -Verb $verb -Errors @('BlockSize 超出范围 1..64') }

    # baseline：全 0 + readSize + patch
    # baseline：全 0；如果给了 ReadSize 就按 kread 的约定放在 offset 24（可被 Patch 之外的语义覆盖）
    $base = New-Object byte[] $InSize
    if ($ReadSize -gt 0) {
        if ($InSize -lt 28) { return New-LctResult -Verb $verb -Errors @('InSize < 28，无法按约定把 readSize 放在 offset 24；请改用 -Patch 或加大 InSize') }
        [BitConverter]::GetBytes([UInt32]$ReadSize).CopyTo($base, 24)
    }
    $baseHex = (($base | ForEach-Object { '{0:X2}' -f $_ }) -join '')

    # SafeMode 只探前 16 字节（通常是 padding / 设备无关区，相对不容易越界）。
    # 完整探测会改到 offset/size 这类字段 —— 它们没有边界检查，改成极值会直接 BSOD。
    $probeEnd = if ($SafeMode) { [Math]::Min(16, $InSize) } else { $InSize }
    $blocks = New-Object System.Collections.ArrayList
    for ($off = 0; $off -lt $probeEnd; $off += $BlockSize) { $null = $blocks.Add($off) }

    if (-not $Apply) {
        $plan = @($blocks | ForEach-Object { [pscustomobject][ordered]@{ offset = $_; size = [Math]::Min($BlockSize, $InSize - $_) } })
        $data = [pscustomobject][ordered]@{
            applied = $false
            guestSys = $GuestSys; ioctl = $Ioctl; inSize = $InSize; blockSize = $BlockSize; safeMode = [bool]$SafeMode; aggressive = [bool]$Aggressive
            patch = $Patch; baseHex = $baseHex
            probes = @($plan).Count
            plan = $plan
            estimatedSec = [Math]::Round((@($plan).Count * 2.5), 0)
            note = ('预览：每条探测 = 一次完整 IOCTL（约 2.5 秒）。扰动=' + $(if ($Aggressive) { '0xFF 极值（会 BSOD）' } else { '+1 温和（不崩）' }) + '。加 -Apply 才真发。需要 VM 在跑且驱动已 push。')
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # 先确保 guest 脚本是最新的
    $probeLocal = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
    if (Test-Path -LiteralPath $probeLocal) {
        $null = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $probeLocal, $guestProbe) -User $auth.user -Pass $auth.pass -TimeoutSec 60
    }

    $sendProbe = {
        param([string]$Hex)
        $parts = New-Object System.Collections.ArrayList
        $null = $parts.Add("`$env:LCT_SYS='$GuestSys'")
        $null = $parts.Add("`$env:LCT_IOCTL='$Ioctl'")
        $null = $parts.Add("`$env:LCT_INHEX='$Hex'")
        if (-not [string]::IsNullOrWhiteSpace($Patch)) { $null = $parts.Add("`$env:LCT_PATCH='$Patch'") }
        $cmdText = ($parts -join '; ') + ('; & ''' + $guestProbe + '''')
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdText) -User $auth.user -Pass $auth.pass -TimeoutSec $TimeoutSec
        $sw2.Stop()
        # 崩溃判定必须可靠：BSOD 之后 Windows 会重启，checkToolsState 可能**短暂仍报 running**。
        # 实测教训：把 `offset` 字段改成 0xFF... 会让驱动越界 BSOD，但当时 tools 仍报 running，
        # 于是我们以为"只是挂起"并继续探测，结果连撞两次、VM 进了恢复界面。
        # 所以：超时或 tools 异常时，多等 6 秒复查 + 用 list 确认 VM 是否真的消失。
        $toolsAfter = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 30
        $crashed = ($run.timedOut) -or ($toolsAfter.out -notmatch '(?i)running')
        if ($crashed) {
            Start-Sleep -Seconds 6
            $tools2 = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 30
            $list2 = Invoke-LctVmRun -Params @('list') -TimeoutSec 30
            $vmGone = -not ([string]$list2.out -match [regex]::Escape((Split-Path $vmx -Leaf)))
            $stillDead = $vmGone -or ([string]$tools2.out -notmatch '(?i)running')
            if ($stillDead) { $crashed = $true } else { $crashed = $true }  # 复查后仍异常 → 判定崩溃
        }
        $res = [ordered]@{ verdict = ''; ret = 0; err = 0; outHex = ''; crashed = $crashed; ms = [int]$sw2.ElapsedMilliseconds }
        if ($crashed) { $res.verdict = 'crash'; return [pscustomobject]$res }
        $tmp = Join-Path $env:TEMP ('lct-fld-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        $pull = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, $guestResult, $tmp) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        if ($pull.ok -and (Test-Path -LiteralPath $tmp)) {
            try {
                $gr = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
                $res.verdict = [string]$gr.verdict
                $res.ret = [int]$gr.bytesReturned
                $res.err = [int]$gr.win32Error
                $res.outHex = [string]$gr.outHex
            } catch { $res.verdict = 'parse-failed' }
        } else { $res.verdict = 'pull-failed' }
        return [pscustomobject]$res
    }

    # 1) baseline
    $bl = & $sendProbe $baseHex
    if ($bl.crashed) {
        return New-LctResult -Verb $verb -Errors @('baseline 就让 VM 崩了/超时——先确认 ioctl 码与 payload 是否合理，不要继续探测')
    }
    if ([string]$bl.verdict -ne 'ok-data') {
        $null = $warnings.Add('baseline 不是 ok-data（verdict=' + $bl.verdict + ', err=' + $bl.err + '）：差分结果可能不可靠。建议先手动找到一个能成功的 baseline（例如补 -Patch 或 -ReadSize）。')
    }

    # 2) 逐块探测
    $fields = New-Object System.Collections.ArrayList
    $stopReason = ''
    $vmMayBeDead = $false
    foreach ($off in $blocks) {
        $sz = [Math]::Min($BlockSize, $InSize - $off)
        $buf = New-Object byte[] $InSize
        [Array]::Copy($base, $buf, $InSize)
        # 扰动策略（关键）：
        #   默认「温和」= 该块 +1（逐字节进位）。为什么不用 0xFF？
        #     实测：把 offset 字段改成 0xFFFFFFFF → 驱动按 4GB 偏移访问 → **直接 BSOD**。
        #     而 +1 只是轻微偏移，通常能成功返回但结果不同 —— 足以识别"这块是有效字段"且不崩。
        #   -Aggressive 才用 0xFF（能探出"无边界检查"这类最严重的问题，但会 BSOD）。
        if ($Aggressive) {
            for ($i = 0; $i -lt $sz; $i++) { $buf[$off + $i] = 0xFF }
        } else {
            $carry = 1
            for ($i = 0; $i -lt $sz; $i++) {
                if ($carry -eq 0) { break }
                $v = [int]$buf[$off + $i] + 1
                if ($v -gt 255) { $buf[$off + $i] = 0; $carry = 1 } else { $buf[$off + $i] = [byte]$v; $carry = 0 }
            }
            if ($carry -eq 1) { $buf[$off] = 0x7F }   # 全 0xFF 再加 1 回绕 → 用个明显值
        }
        $hex = (($buf | ForEach-Object { '{0:X2}' -f $_ }) -join '')
        $r = & $sendProbe $hex
        if ($r.crashed) {
            # 崩溃就**停**。不尝试"恢复后继续"——实测这个假设是错的：
            # `offset` 字段(20) 改成 0xFF... 直接 BSOD，而当时 tools 还报 running。
            # 继续探下去只会连撞多次，把 VM 打进恢复界面（真发生过一次）。
            $null = $fields.Add([pscustomobject][ordered]@{
                    offset = $off; size = $sz; kind = 'crash'
                    evidence = '这一改直接让 VM 崩了/驱动越界（最强的信号：该字段没有边界检查）'
                    verdict = [string]$r.verdict; ret = [int]$r.ret; err = [int]$r.err
                })
            $stopReason = ('offset ' + $off + ' 导致崩溃，已停止探测。VM 可能需要重启/回滚快照。')
            $vmMayBeDead = $true
            break
        }
        $verdictChanged = ([string]$r.verdict -ne [string]$bl.verdict)
        $retChanged = ([int]$r.ret -ne [int]$bl.ret)

        # ---- 判断该块是否落在 patch 遮罩区（patch 会在 guest 侧覆盖它，探测不到真实值）----
        $masked = $false
        if (-not [string]::IsNullOrWhiteSpace($Patch)) {
            foreach ($pp in @($Patch -split ';')) {
                if ($pp.Trim() -eq '') { continue }
                $bits = $pp.Split(':')
                if ($bits.Count -lt 2) { continue }
                $po = [int]$bits[0]; $pz = [int]$bits[1]
                if ($off -lt ($po + $pz) -and ($off + $sz) -gt $po) { $masked = $true; break }
            }
        }

        # ---- 输出比较：排除「自身回填区」----
        # 很多 buffered IOCTL 会把整个输入结构回填到输出（rtcore64 的 out 和 in 布局完全一样）。
        # 那样改任何字节都会改 outHex —— 但不代表它影响行为。所以只比较该块**之外**的字节。
        $outDiffOutside = $false
        $outDiffInside = $false
        try {
            $hb = ([string]$bl.outHex -replace '[^0-9A-Fa-f]', '')
            $hp = ([string]$r.outHex -replace '[^0-9A-Fa-f]', '')
            if ($hb.Length -eq $hp.Length -and $hb.Length -gt 0) {
                for ($bi = 0; $bi -lt [int]($hb.Length / 2); $bi++) {
                    if ($hb.Substring($bi * 2, 2) -ne $hp.Substring($bi * 2, 2)) {
                        if ($bi -ge $off -and $bi -lt ($off + $sz)) { $outDiffInside = $true } else { $outDiffOutside = $true }
                    }
                }
            } elseif ([string]$r.outHex -ne [string]$bl.outHex) { $outDiffOutside = $true }
        } catch { }

        $kind = 'padding'
        $ev = '无变化（改这块不影响任何输出）'
        if ($masked) {
            $kind = 'masked'
            $ev = '被 patch 遮罩（guest 侧会覆盖这块，探测不到真实值；要测它请去掉 -Patch 或改区间）'
        } elseif ($verdictChanged -or $retChanged) {
            $kind = 'active-strong'
            $ev = 'verdict/返回值变了：' + $bl.verdict + '/' + $bl.ret + ' → ' + $r.verdict + '/' + $r.ret + '（影响控制流或返回长度）'
        } elseif ($outDiffOutside) {
            $kind = 'active-strong'
            $ev = '该块之外的输出变了（说明它影响实际读写的**内容**，不只是回填）'
        } elseif ($outDiffInside) {
            $kind = 'active-weak'
            $ev = '只有该块自身对应的输出变了（典型回填效应，未必影响行为）'
        }
        $null = $fields.Add([pscustomobject][ordered]@{
                offset = $off; size = $sz; kind = $kind; evidence = $ev
                verdict = [string]$r.verdict; ret = [int]$r.ret; err = [int]$r.err
            })
    }

    $all = @($fields)
    $sum = [ordered]@{
        total = @($all).Count
        padding = @($all | Where-Object { $_.kind -eq 'padding' }).Count
        activeStrong = @($all | Where-Object { $_.kind -eq 'active-strong' }).Count
        activeWeak = @($all | Where-Object { $_.kind -eq 'active-weak' }).Count
        masked = @($all | Where-Object { $_.kind -eq 'masked' }).Count
        crash = @($all | Where-Object { $_.kind -eq 'crash' }).Count
        stoppedEarly = $stopReason
        vmMayBeDead = $vmMayBeDead
        safeMode = [bool]$SafeMode
    }

    # 3) 给一个「建议的 in 字段布局」（人还要命名语义）
    # 只把 active-strong 当有效字段：active-weak 大概率是回填噪音（见上面注释）
    # active-strong（影响实际内容）+ crash（能崩溃/挂起）都算有效字段；active-weak 是回填噪音，不算。
    $active = @($all | Where-Object { $_.kind -in @('active-strong', 'crash') })
    $suggested = New-Object System.Collections.ArrayList
    $cursor = 0
    foreach ($b in @($active | Sort-Object offset)) {
        if ([int]$b.offset -gt $cursor) {
            $null = $suggested.Add([pscustomobject][ordered]@{ name = ('pad_' + $cursor); type = 'bytes'; len = ([int]$b.offset - $cursor); note = '推测为 padding' })
        }
        $null = $suggested.Add([pscustomobject][ordered]@{ name = ('field_' + $b.offset); type = $(if ([int]$b.size -ge 8) { 'u64?' } else { 'u32?' }); len = [int]$b.size; note = ('有效字段（' + $b.kind + '）—— 语义需人工命名') })
        $cursor = [int]$b.offset + [int]$b.size
    }
    if ($cursor -lt $InSize) {
        $null = $suggested.Add([pscustomobject][ordered]@{ name = ('pad_' + $cursor); type = 'bytes'; len = ($InSize - $cursor); note = '推测为 padding' })
    }

    $data = [pscustomobject][ordered]@{
        applied = $true
        guestSys = $GuestSys; ioctl = $Ioctl; inSize = $InSize; blockSize = $BlockSize; safeMode = [bool]$SafeMode
        patch = $Patch; baseHex = $baseHex
        baseline = [pscustomobject][ordered]@{ verdict = $bl.verdict; ret = $bl.ret; err = $bl.err; outHex = $(if ([string]$bl.outHex.Length -gt 200) { ([string]$bl.outHex).Substring(0, 200) } else { [string]$bl.outHex }) }
        summary = [pscustomobject]$sum
        fields = $all
        suggestedLayout = @($suggested)
        note = '这是动态逆向的产出：能确定「哪些偏移是字段、多宽」，但确定不了语义（addr/size/offset）。suggestedLayout 直接喂给 profile.actions[].in 之前必须人工命名 + 确认。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: batch（批量 matrix + 崩溃恢复） ----------------

function Get-LctVmBatchTasks {
    <#
      收集「能测」的任务：有 profile 的驱动才算（profile 是执行的必要条件）。
      输入可以是 -Dir（扫目录按 sha256 匹配 profile）或 -Profiles（直接给 id）。
    #>
    param([string]$Dir = '', [string]$Profiles = '')
    $tasks = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $profDir = Join-Path $script:LctVmRoot 'var\driver-profiles'
    $allProf = @()
    if (Test-Path -LiteralPath $profDir) {
        $allProf = @(Get-ChildItem $profDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    }
    $wanted = @()
    if (-not [string]::IsNullOrWhiteSpace($Profiles)) {
        $wanted = @(([string]$Profiles) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    if (-not [string]::IsNullOrWhiteSpace($Dir)) {
        if (-not (Test-Path -LiteralPath $Dir)) {
            $null = $notes.Add('目录不存在: ' + $Dir)
            return [pscustomobject]@{ tasks = @(); notes = @($notes) }
        }
        # 目录里的 .sys → sha256 → 匹配 profile
        $shaToProf = @{}
        foreach ($pf in $allProf) {
            try {
                $j = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $sha = ''
                if ($null -ne $j.target) { $sha = [string]$j.target.sha256 }
                if ($sha -match '^[0-9A-Fa-f]{64}$') { $shaToProf[$sha.ToUpperInvariant()] = $pf.FullName }
            } catch { }
        }
        $sysFiles = @(Get-ChildItem -LiteralPath $Dir -Filter '*.sys' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $sysFiles) {
            $sha = ''
            try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpperInvariant() } catch { continue }
            if ($shaToProf.ContainsKey($sha)) {
                $null = $tasks.Add([pscustomobject][ordered]@{
                        profilePath = $shaToProf[$sha]
                        sysPath = $f.FullName
                        sha256 = $sha
                        file = $f.Name
                    })
            }
        }
        $null = $notes.Add('目录扫描：' + @($sysFiles).Count + ' 个 .sys，其中 ' + @($tasks).Count + ' 个有 profile（可测）')
        $noProf = @($sysFiles).Count - @($tasks).Count
        if ($noProf -gt 0) { $null = $notes.Add(($noProf).ToString() + ' 个驱动没有 profile，跳过（先用 driver.profile.draft 生成并审定）') }
    } else {
        # 直接按 profile id 收集
        foreach ($id in $wanted) {
            $pf = @($allProf | Where-Object { $_.BaseName -eq $id }) | Select-Object -First 1
            if ($null -eq $pf) { $null = $notes.Add('找不到 profile: ' + $id); continue }
            $j = $null
            try { $j = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
            $sha = ''
            $fname = ''
            if ($null -ne $j -and $null -ne $j.target) {
                $sha = [string]$j.target.sha256
                $fname = [string]$j.target.fileName
            }
            # 找实际 .sys：优先 samples 目录
            $sysPath = ''
            $cand1 = Join-Path $script:LctVmRoot ('var\samples\' + $id + '.sys')
            $cand2 = Join-Path $script:LctVmRoot ('var\samples\' + $fname)
            if (Test-Path -LiteralPath $cand1) { $sysPath = $cand1 }
            elseif (Test-Path -LiteralPath $cand2) { $sysPath = $cand2 }
            if ($sysPath -eq '') { $null = $notes.Add('找不到驱动文件（试过 var\samples\' + $id + '.sys 和 ' + $fname + '）: ' + $id); continue }
            $null = $tasks.Add([pscustomobject][ordered]@{
                    profilePath = $pf.FullName; sysPath = $sysPath; sha256 = $sha; file = (Split-Path $sysPath -Leaf)
                })
        }
    }
    return [pscustomobject]@{ tasks = @($tasks); notes = @($notes) }
}

function Get-LctVmProfileMeta {
    # 读 profile 的关键元信息：id / 第一个 action / 该 action 的 ioctl
    param([string]$ProfilePath)
    $meta = [ordered]@{ id = ''; action = ''; ioctl = ''; ok = $false; error = '' }
    if (-not (Test-Path -LiteralPath $ProfilePath)) { $meta.error = 'profile 不存在'; return [pscustomobject]$meta }
    $j = $null
    try { $j = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        $meta.error = '解析失败: ' + $_.Exception.Message; return [pscustomobject]$meta
    }
    $meta.id = [IO.Path]::GetFileNameWithoutExtension($ProfilePath)
    $acts = $null
    try { $acts = $j.actions } catch { $acts = $null }
    if ($null -eq $acts) { $meta.error = 'profile 没有 actions'; return [pscustomobject]$meta }
    $names = @()
    try { $names = @($acts.PSObject.Properties.Name) } catch { $names = @() }
    if ($names.Count -eq 0) { $meta.error = 'actions 为空（draft 不能直接执行）'; return [pscustomobject]$meta }
    $meta.action = [string]$names[0]
    try { $meta.ioctl = [string]$acts.($names[0]).ioctl } catch { $meta.ioctl = '' }
    $meta.ok = $true
    return [pscustomobject]$meta
}

function Invoke-LctVmBatch {
    <#
    .SYNOPSIS driver.vm.batch：批量跑多个驱动的变异矩阵，崩溃后自动回滚快照重建环境继续
    .DESCRIPTION
      为什么需要它：单个 vm.matrix 一次只能测一个驱动；要"扫一个目录 → 自动测完"，
      必须解决两件事：
        ① 批量调度（跳过没有 profile 的驱动）
        ② 崩溃恢复（崩溃后回滚快照 → 重建 guest 环境 → 继续下一个）
      崩溃是正常现象（畸形输入就是奔着让它崩去的），所以 -Snapshot 是本命令的关键参数：
      给了就能自动恢复；不给则崩溃即停（因为无法把 VM 恢复到干净状态）。
    .NOTES 默认只预览任务清单，-Apply 才真跑。真跑会往 VM 里 push 驱动并发送 IOCTL。
    #>
    param(
        [string]$Dir = '',
        [string]$Profiles = '',
        [string]$Snapshot = '',
        [string]$Levels = 'baseline,boundary,address,cross-page',
        [int]$MaxVariants = 40,
        [int]$TimeoutSec = 45,
        [int]$MaxDrivers = 10,
        [int]$MaxMinutes = 30,
        [switch]$Apply
    )
    $verb = 'driver.vm.batch'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }

    $collected = Get-LctVmBatchTasks -Dir $Dir -Profiles $Profiles
    $tasks = @($collected.tasks)
    if (@($tasks).Count -eq 0) {
        $e = @($collected.notes)
        if (@($e).Count -eq 0) { $e = @('没有可测任务（需要 .sys + 对应的 profile）') }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors $e
    }
    if (@($tasks).Count -gt $MaxDrivers) {
        $null = $warnings.Add('任务数 ' + @($tasks).Count + ' 超过 MaxDrivers=' + $MaxDrivers + '，只跑前 ' + $MaxDrivers + ' 个')
        $tasks = @($tasks | Select-Object -First $MaxDrivers)
    }
    # 给每个任务补元信息（id / action / ioctl）
    $plan = New-Object System.Collections.ArrayList
    foreach ($tk in $tasks) {
        $meta = Get-LctVmProfileMeta -ProfilePath $tk.profilePath
        if (-not $meta.ok) { $null = $warnings.Add('跳过 ' + $tk.file + '：' + $meta.error); continue }
        $null = $plan.Add([pscustomobject][ordered]@{
                file = $tk.file; sysPath = $tk.sysPath; sha256 = $tk.sha256
                profileId = $meta.id; action = $meta.action; ioctl = $meta.ioctl
            })
    }
    if (@($plan).Count -eq 0) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('所有任务的 profile 都不可执行（actions 为空或解析失败）') }

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            tasks = @($plan)
            taskCount = @($plan).Count
            snapshot = $Snapshot
            levels = $Levels; maxVariants = $MaxVariants; perVariantTimeoutSec = $TimeoutSec
            estimatedMin = [Math]::Round((@($plan).Count * ($MaxVariants * 2.5 + 20) / 60), 1)
            notes = @($collected.notes)
            note = '预览：每个驱动会 push + 跑变异矩阵（每条 ~2.5 秒）。' + $(if ($Snapshot -ne '') { '崩溃后回滚快照 "' + $Snapshot + '" 重建环境继续。' } else { '未给 -Snapshot：崩溃后会直接停止（无法恢复 VM）。' }) + ' 加 -Apply 才真跑。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # ---- 真跑 ----
    $vmrun = $ready.config.vmrun
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    $auth = $ready.auth
    $probeLocal = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
    $swAll = [Diagnostics.Stopwatch]::StartNew()
    # 注意：[ordered]@{ probes = @() } 是**固定大小数组**，对它 .Add() 会抛
    # `Collection was of a fixed size`（项目老坑），所以用独立 ArrayList 收集。
    $probesList = New-Object System.Collections.ArrayList
    $results = New-Object System.Collections.ArrayList
    $stopReason = ''
    $recoverCount = 0

    $ensureEnv = {
        # 重建 guest 环境（回滚快照后会丢）：建目录 + Defender 排除 + push probe
        $null = Invoke-LctVmRun -Params @('createDirectoryInGuest', $vmx, $gd) -User $auth.user -Pass $auth.pass -TimeoutSec 30
        $prepCmd = "try { Add-MpPreference -ExclusionPath '$gd' -ErrorAction Stop } catch { }"
        $null = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', '-NoProfile', '-Command', $prepCmd) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        if (Test-Path -LiteralPath $probeLocal) {
            $null = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $probeLocal, (Join-Path $gd 'probe.ps1')) -User $auth.user -Pass $auth.pass -TimeoutSec 60
        }
    }

    $idx = 0
    foreach ($tk in @($plan)) {
        $idx++
        if ($swAll.Elapsed.TotalMinutes -ge $MaxMinutes) { $stopReason = '超过 MaxMinutes=' + $MaxMinutes + '，提前结束'; break }
        Write-LctVmBatchLine -Text ('[' + $idx + '/' + @($plan).Count + '] ' + $tk.file + '  (profile=' + $tk.profileId + ', action=' + $tk.action + ')')
        $one = [ordered]@{
            file = $tk.file; profileId = $tk.profileId; action = $tk.action; ioctl = $tk.ioctl
            pushed = $false; verdictSummary = ''; crashed = $false; recovered = $false; ms = 0; error = ''
        }
        $swOne = [Diagnostics.Stopwatch]::StartNew()
        try {
            # 1) push 驱动
            $pushRes = Push-LctVmDriver -Path $tk.sysPath -Name 'target.sys' -Apply
            if ($null -eq $pushRes -or -not $pushRes.ok) {
                $one.error = 'push 失败: ' + $(if ($null -ne $pushRes) { (@($pushRes.errors) -join ';') } else { 'null' })
                $null = $results.Add([pscustomobject]$one)
                continue
            }
            $one.pushed = $true
            # 2) 跑矩阵
            $mx = Invoke-LctVmMatrix -Profile $tk.profileId -Action $tk.action -Levels $Levels -MaxVariants $MaxVariants -PerVariantTimeoutSec $TimeoutSec -Apply
            if ($null -ne $mx -and $null -ne $mx.data) {
                $sum = $mx.data.summary
                $one.verdictSummary = ('okData=' + $sum.okData + ' error=' + $sum.error + ' timeout=' + $sum.timeout + ' crash=' + $sum.crash)
                $one.crashed = ([int]$sum.crash -gt 0) -or ([int]$sum.timeout -gt 0)
            } else {
                $one.error = 'matrix 返回空'
            }
        } catch {
            $one.error = '异常: ' + $_.Exception.Message
        }
        $swOne.Stop()
        $one.ms = [int]$swOne.ElapsedMilliseconds

        # 3) 崩溃恢复
        if ($one.crashed) {
            if ($Snapshot -ne '') {
                Write-LctVmBatchLine -Text ('    崩溃 → 回滚快照 "' + $Snapshot + '" 并重建环境')
                $rv = Invoke-LctVmRun -Params @('revertToSnapshot', $vmx, $Snapshot) -TimeoutSec 600
                if ($rv.ok) {
                    Start-Sleep -Seconds 5
                    # 关键：revertToSnapshot 会把 VM 关机再恢复，但**不会自动启动**（实测踩过：
                    # 回滚后 VM 状态变成 installed、list 里 0 台运行，后续全失败）。
                    $lst = Invoke-LctVmRun -Params @('list') -TimeoutSec 30
                    $vmRunning = [string]$lst.out -match [regex]::Escape((Split-Path $vmx -Leaf))
                    if (-not $vmRunning) {
                        Write-LctVmBatchLine -Text '    VM 未运行，启动中（nogui）'
                        $null = Invoke-LctVmRun -Params @('start', $vmx, 'nogui') -TimeoutSec 180
                        Start-Sleep -Seconds 5
                    }
                    # 等 tools 恢复（开机 + 登录需要时间，给足 3 分钟）
                    $ok = $false
                    for ($try = 1; $try -le 36; $try++) {
                        $ts = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 20
                        if ($ts.out -match '(?i)^\s*running\s*$') { $ok = $true; break }
                        Start-Sleep -Seconds 5
                    }
                    if ($ok) { & $ensureEnv; $one.recovered = $true; $recoverCount++ }
                    else { $null = $warnings.Add('回滚后 VMware Tools 未恢复（' + $tk.file + ' 之后的任务可能失败）') }
                } else {
                    $null = $warnings.Add('回滚快照失败: ' + $rv.out)
                    $stopReason = '回滚失败，停止'
                    $null = $results.Add([pscustomobject]$one)
                    break
                }
            } else {
                $stopReason = '崩溃且未提供 -Snapshot，无法恢复 VM，停止（已测完的部分见 results）'
                $null = $results.Add([pscustomobject]$one)
                break
            }
        }
        $null = $results.Add([pscustomobject]$one)
    }
    $swAll.Stop()

    $all = @($results)
    $sum2 = [ordered]@{
        tasks = @($plan).Count
        done = @($all).Count
        crashedDrivers = @($all | Where-Object { $_.crashed }).Count
        recovered = $recoverCount
        failed = @($all | Where-Object { $_.error -ne '' }).Count
        stoppedEarly = $stopReason
        totalMin = [Math]::Round($swAll.Elapsed.TotalMinutes, 1)
    }
    $data = [pscustomobject][ordered]@{
        applied = $true
        summary = [pscustomobject]$sum2
        results = $all
        snapshot = $Snapshot
        notes = @($collected.notes)
        note = '每个驱动的 verdict 汇总在 verdictSummary；crashed=true 表示该驱动有变异导致崩溃/挂起。recovered=true 表示已回滚快照并重建环境。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

function Write-LctVmBatchLine {
    # 模块里不能用 Write-Host（引擎 stdout 只允许最终 JSON），所以这里只写日志
    param([string]$Text)
    try { $null = Write-LctLog -Verb 'driver.vm.batch' -Level 'info' -Message $Text } catch { }
}

# ---------------- verb: discover（暴力扫 IOCTL 码） ----------------

function Invoke-LctVmDiscover {
    <#
    .SYNOPSIS driver.vm.discover：不知道 profile 时，靠暴力扫找到能用的 IOCTL 码
    .DESCRIPTION
      解决「没有 profile 就没法测」的死结：
        即使完全不知道驱动支持哪些 IOCTL，也能通过遍历码范围 + 观察响应来发现入口。

      判别依据（实测 rtcore64）：
        ok-data            → 功能执行成功，**确定是这个码**（最强）
        ERROR_INVALID_FUNCTION(1)  → 驱动不认这个码（确定无效）
        ERROR_INVALID_PARAMETER(87)→ 可能认了但参数不对，也可能不认（**不确定**）
        其他错误码（如 1450）    → 处理了但失败，说明**码是有效的**（强信号）
        崩溃/超时            → 该码会越界或死锁（危险但也是有效证据）

      为什么用 step=4：IOCTL 码低 2 位是 Method，同一功能通常只在一个 Method 上实现，
      所以步长 4 能覆盖所有"功能号"而不浪费。要全扫可以 -Step 1。
    .NOTES 默认只预览。真扫会连续发送几十个 IOCTL，**可能让驱动崩溃/挂起**（有 -Snapshot 时可配合 batch 恢复）。
    #>
    param(
        [string]$GuestSys = '',
        [string]$Devices = '',
        [string]$Base = '0x80002000',
        [int]$Count = 64,
        [int]$Step = 4,
        [int]$InSize = 48,
        [int]$TimeoutSec = 8,
        [switch]$Apply
    )
    $verb = 'driver.vm.discover'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $auth = $ready.auth
    $vmx = $ready.config.vmx
    $gd = [string]$ready.config.guestDir
    if ([string]::IsNullOrWhiteSpace($GuestSys)) { $GuestSys = Join-Path $gd 'target.sys' }
    $guestResult = Join-Path $gd 'result.json'
    $guestProbe = Join-Path $gd 'probe.ps1'
    $psG = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($Count -lt 1 -or $Count -gt 1024) { return New-LctResult -Verb $verb -Errors @('Count 超出范围 1..1024') }
    if ($Step -lt 1 -or $Step -gt 16) { return New-LctResult -Verb $verb -Errors @('Step 超出范围 1..16') }
    if ($InSize -lt 4 -or $InSize -gt 4096) { return New-LctResult -Verb $verb -Errors @('InSize 超出范围 4..4096') }

    $baseVal = [Convert]::ToUInt32(($Base -replace '^0x', ''), 16)
    $codes = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Count; $i++) {
        $c = [uint64]$baseVal + [uint64]($i * $Step)
        # 注意：0xFFFFFFFF 在 PowerShell 里是 int32 = -1（转 uint64 还会抛异常），
        # 所以用 2^32 = 0x100000000（正整数）做上界判断。
        if ($c -ge 4294967296) { break }
        $null = $codes.Add([uint32]$c)
    }
    $inHex = (('00' * $InSize))

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            guestSys = $GuestSys; devices = $Devices
            base = $Base; count = @($codes).Count; step = $Step; inSize = $InSize; perCodeTimeoutSec = $TimeoutSec
            firstCodes = @($codes | Select-Object -First 5 | ForEach-Object { '0x{0:X8}' -f $_ })
            lastCode = ('0x{0:X8}' -f $codes[@($codes).Count - 1])
            estimatedMin = [Math]::Round((@($codes).Count * ($TimeoutSec * 0.4 + 1) / 60), 1)
            note = '预览：逐个发送 IOCTL（每条超时 ' + $TimeoutSec + 's）。判别：ok-data=确定有效；err=1 确定无效；err=87 不确定；其他错误码/崩溃=有效但危险。加 -Apply 才真扫。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # 确保 guest 脚本最新
    $probeLocal = Join-Path $script:LctVmRoot 'tools\vm-agent\guest-probe.ps1'
    if (Test-Path -LiteralPath $probeLocal) {
        $null = Invoke-LctVmRun -Params @('copyFileFromHostToGuest', $vmx, $probeLocal, $guestProbe) -User $auth.user -Pass $auth.pass -TimeoutSec 60
    }

    $results = New-Object System.Collections.ArrayList
    $stopReason = ''
    $vmMayBeDead = $false
    $swAll = [Diagnostics.Stopwatch]::StartNew()
    # 注意：[ordered]@{ probes = @() } 是**固定大小数组**，对它 .Add() 会抛
    # `Collection was of a fixed size`（项目老坑），所以用独立 ArrayList 收集。
    $probesList = New-Object System.Collections.ArrayList
    # 多 payload 对比（破解 87 的不可区分性）：
    #   实测 rtcore64：真码 0x80002048 在全 0 payload 下返回 87（被 NULL 检查拦），
    #   和「不认这个码」长得一模一样 → 单一 payload 根本分不出来。
    #   解法：再发一次「全 0x01」。如果两次响应不同（verdict/错误码发生变化），
    #   说明这个码**确实在处理参数**，只是参数值不对 → 判定 param-sensitive（强信号）。
    $payloadSet = @(
        @{ tag = 'zeros'; hex = ('00' * $InSize) }
        @{ tag = 'ones'; hex = ('01' * $InSize) }
    )
    foreach ($c in @($codes)) {
        $codeHex = ('0x{0:X8}' -f $c)
        $resps = New-Object System.Collections.ArrayList
        $codeCrashed = $false
        $codeTimeout = $false
        foreach ($pl in $payloadSet) {
            $parts = New-Object System.Collections.ArrayList
            $null = $parts.Add("`$env:LCT_SYS='$GuestSys'")
            $null = $parts.Add("`$env:LCT_IOCTL='$codeHex'")
            $null = $parts.Add("`$env:LCT_INHEX='$($pl.hex)'")
            if (-not [string]::IsNullOrWhiteSpace($Devices)) { $null = $parts.Add("`$env:LCT_DEVICES='$Devices'") }
            $cmdText = ($parts -join '; ') + ('; & ''' + $guestProbe + '''')
            $sw1 = [Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-LctVmRun -Params @('runProgramInGuest', $vmx, $psG, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdText) -User $auth.user -Pass $auth.pass -TimeoutSec $TimeoutSec
            $sw1.Stop()
            if ($run.timedOut) {
                Start-Sleep -Seconds 3
                $ts = Invoke-LctVmRun -Params @('checkToolsState', $vmx) -TimeoutSec 20
                if ([string]$ts.out -notmatch '(?i)^\s*running\s*$') {
                    $codeCrashed = $true
                    $null = $resps.Add([pscustomobject]@{ payload = $pl.tag; verdict = 'crash'; win32Error = 0; bytesReturned = 0; ms = [int]$sw1.ElapsedMilliseconds })
                    break
                }
                $codeTimeout = $true
                $null = $resps.Add([pscustomobject]@{ payload = $pl.tag; verdict = 'timeout'; win32Error = 0; bytesReturned = 0; ms = [int]$sw1.ElapsedMilliseconds })
                break   # 该码已证明危险，不再试其它 payload
            }
            $tmp = Join-Path $env:TEMP ('lct-dsc-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $pull = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmx, $guestResult, $tmp) -User $auth.user -Pass $auth.pass -TimeoutSec 30
            $rr = [pscustomobject]@{ payload = $pl.tag; verdict = 'pull-failed'; win32Error = 0; bytesReturned = 0; ms = [int]$sw1.ElapsedMilliseconds }
            if ($pull.ok -and (Test-Path -LiteralPath $tmp)) {
                try {
                    $gr = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
                    $rr = [pscustomobject]@{ payload = $pl.tag; verdict = [string]$gr.verdict; win32Error = [int]$gr.win32Error; bytesReturned = [int]$gr.bytesReturned; ms = [int]$sw1.ElapsedMilliseconds }
                } catch { }
            }
            $null = $resps.Add($rr)
        }

        # ---- 判定 ----
        $one = [ordered]@{ code = $codeHex; kind = 'unknown'; verdict = ''; win32Error = 0; bytesReturned = 0; ms = 0; note = ''; payloads = @($resps | ForEach-Object { $_.payload + ':' + $_.verdict + '/' + $_.win32Error }) }
        $one.ms = [int](@($resps | Measure-Object -Property ms -Sum).Sum)
        if ($codeCrashed) {
            $one.kind = 'crash'; $one.verdict = 'crash'
            $one.note = 'IOCTL 让 VM 崩了（最强信号：这个码确实在处理，且不检查参数）'
            $null = $results.Add([pscustomobject]$one)
            $vmMayBeDead = $true
            $stopReason = ('码 ' + $codeHex + ' 导致 VM 崩溃，停止扫描')
            break
        }
        if ($codeTimeout) {
            $one.kind = 'timeout'; $one.verdict = 'timeout'
            $one.note = 'IOCTL 挂起但 VM 还活着（强信号：码有效且不检查地址/长度）'
            $null = $results.Add([pscustomobject]$one)
            continue
        }
        $vs = @($resps | ForEach-Object { [string]$_.verdict })
        $es = @($resps | ForEach-Object { [int]$_.win32Error })
        $hasOk = @($vs | Where-Object { $_ -eq 'ok-data' }).Count -gt 0
        $hasOther = @($es | Where-Object { $_ -ne 0 -and $_ -ne 87 -and $_ -ne 1 }).Count -gt 0
        $allInvalid = (@($es | Where-Object { $_ -eq 87 }).Count -eq @($es).Count)
        $differ = ((@($vs | Select-Object -Unique)).Count -gt 1) -or ((@($es | Select-Object -Unique)).Count -gt 1)
        $one.verdict = $vs[0]; $one.win32Error = $es[0]
        $one.bytesReturned = [int](@($resps | ForEach-Object { $_.bytesReturned }) | Measure-Object -Maximum).Maximum
        if ($hasOk) { $one.kind = 'accepted'; $one.note = '功能执行成功（返回 ' + $one.bytesReturned + ' 字节）' }
        elseif ($allInvalid) {
            if ($differ) {
                $one.kind = 'param-sensitive'
                $one.note = ('不同 payload 响应不同（' + ((@($vs | Select-Object -Unique)) -join '/') + ' / err ' + ((@($es | Select-Object -Unique)) -join '/') + '）→ 码有效，只是参数不对')
            } else { $one.kind = 'invalid-param'; $one.note = '所有 payload 都 87 → 无法区分"认了但参数不对"和"不认"' }
        }
        elseif ($hasOther) { $one.kind = 'other-error'; $one.note = ('错误码 ' + ((@($es | Where-Object { $_ -ne 0 -and $_ -ne 87 -and $_ -ne 1 })) -join '/') + '：码有效但调用失败') }
        elseif ($differ) { $one.kind = 'param-sensitive'; $one.note = '不同 payload 响应不同 → 码在处理参数' }
        else { $one.kind = 'no-data'; $one.note = '调用成功但没数据' }
        $null = $results.Add([pscustomobject]$one)
    }
    $swAll.Stop()

    $all = @($results)
    $sum = [ordered]@{
        scanned = @($all).Count
        accepted = @($all | Where-Object { $_.kind -eq 'accepted' }).Count
        otherError = @($all | Where-Object { $_.kind -eq 'other-error' }).Count
        paramSensitive = @($all | Where-Object { $_.kind -eq 'param-sensitive' }).Count
        invalidParam = @($all | Where-Object { $_.kind -eq 'invalid-param' }).Count
        notImplemented = @($all | Where-Object { $_.kind -eq 'not-implemented' }).Count
        timeout = @($all | Where-Object { $_.kind -eq 'timeout' }).Count
        crash = @($all | Where-Object { $_.kind -eq 'crash' }).Count
        other = @($all | Where-Object { $_.kind -notin @('accepted', 'other-error', 'invalid-param', 'not-implemented', 'timeout', 'crash') }).Count
        stoppedEarly = $stopReason
        vmMayBeDead = $vmMayBeDead
        totalMin = [Math]::Round($swAll.Elapsed.TotalMinutes, 1)
    }
    # 候选码分两档（实测教训：全 0 payload 会被 NULL 检查掩盖 —— rtcore64 的 kread(0x80002048)
    # 在 addr=0 时返回 87，看起来和"不认这个码"一样。而 patch 的偏移是驱动特定的，不能通用假设。）
    #   强候选：accepted（功能确认）/ other-error（真被处理了，如 1450）/ timeout（挂起）
    #   弱候选：invalid-param(87) —— **无法区分"认了但参数不对"和"根本不认"**，只能交给 vm.fields 进一步验证
    $rank = @{ 'accepted' = 0; 'param-sensitive' = 1; 'other-error' = 2; 'timeout' = 3; 'crash' = 4; 'invalid-param' = 5 }
    # param-sensitive 是多 payload 对比的新产物：不同 payload 响应不同 → 码在处理参数（强信号）
    $strong = @($all | Where-Object { $_.kind -in @('accepted', 'param-sensitive', 'other-error', 'timeout', 'crash') } | Sort-Object { $rank[$_.kind] }, code)
    $weak = @($all | Where-Object { $_.kind -eq 'invalid-param' } | Sort-Object code)
    $data = [pscustomobject][ordered]@{
        applied = $true
        guestSys = $GuestSys; base = $Base; count = @($codes).Count; step = $Step; inSize = $InSize
        summary = [pscustomobject]$sum
        strongCandidates = @($strong | ForEach-Object { $_.code })
        weakCandidates = @($weak | ForEach-Object { $_.code })
        candidates = @($strong | ForEach-Object { $_.code })
        results = $all
        note = ('强候选 ' + @($strong).Count + ' 个（accepted/other-error/timeout）；弱候选 ' + @($weak).Count + ' 个（invalid-param=87，无法区分"认了但参数不对"和"不认"）。先用 strongCandidates 喂 driver.vm.fields；weakCandidates 作为兜底（可能包含被 NULL 检查掩盖的真码，如 rtcore64 的 kread）。')
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: fromprobe（探测结果 → 可审定 profile） ----------------

function Invoke-LctVmFromProbe {
    <#
    .SYNOPSIS driver.profile.fromprobe：把 dispatch + 差分探测的结果合成一份 draft profile
    .DESCRIPTION
      解决「profile 要人手写 107 行」的问题。自动填的部分：
        target.sha256 / fileName        ← 算
        locate.candidates（设备名）      ← 静态扫
        actions.<name>.ioctl            ← 参数 / dispatch 范围 / 用户指定
        actions.<name>.in               ← 差分探测的有效字段偏移
        actions.<name>.out              ← **默认与 in 同构**（实测 rtcore64 完全一致，可省去手写）
        layout.method                   ← **ioctl & 3**（纯算术：0=buffered 1=in-direct 2=out-direct 3=neither）
        actions.<name>.presets          ← 探测用的 baseline
        risk.level                      ← method=3 或 探测到崩溃 → bsod

      字段语义名用 field_N 占位 —— **不影响执行**（执行器按位置/类型的字节布局读写，不认名字）。
      **产物可直接执行**：VM 里崩了回滚快照即可，不需要先人工审定。只有「把结论用到实体机」那一步才需要人复核。
    .NOTES 默认预览。真跑会 push 驱动并发送 IOCTL（约 1-2 分钟）。
    #>
    param(
        [Parameter(Mandatory)][string]$SysPath,
        [string]$Ioctl = '',
        [int]$InSize = 48,
        [int]$BlockSize = 4,
        [string]$ActionName = 'auto',
        [int]$TimeoutSec = 30,
        [string]$Patch = '',
        [string]$Snapshot = '',
        [switch]$Apply
    )
    $verb = 'driver.profile.fromprobe'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $SysPath)) { return New-LctResult -Verb $verb -Errors @('找不到驱动: ' + $SysPath) }
    if ($InSize -lt 4 -or $InSize -gt 4096) { return New-LctResult -Verb $verb -Errors @('InSize 超出范围 4..4096') }

    $sha = (Get-FileHash -LiteralPath $SysPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $fname = Split-Path $SysPath -Leaf
    $profId = [IO.Path]::GetFileNameWithoutExtension($SysPath)

    # 1) 静态：设备名候选 + 跳转表范围
    $devNames = @()
    try {
        $draft = New-LctDriverProfileDraft -Path $SysPath
        if ($null -ne $draft -and $draft.ok) {
            $ev = $draft.data.draft.draft.evidence
            # deviceNameCandidates 是 PSCustomObject（{text,width,fileOffset,rva,xrefs}），
            # 直接 [string] 转换会得到空串 —— 必须取 .text
            $devNames = @($ev.deviceNameCandidates | ForEach-Object { [string]$_.text } | Where-Object { $_ -ne "" })
        }
    } catch { $null = $warnings.Add('静态草案失败: ' + $_.Exception.Message) }
    $jt = $null
    try { $jt = Get-LctPrfJumpTable -Path $SysPath } catch { }

    # 2) 定 ioctl
    $code = ''
    $codeSource = ''
    if (-not [string]::IsNullOrWhiteSpace($Ioctl)) { $code = $Ioctl; $codeSource = '参数指定' }
    elseif ($null -ne $jt -and $jt.hit -and $jt.base -ne '?' -and $jt.base -ne '') { $code = $jt.base; $codeSource = 'dispatch 范围起点（需验证！范围起点的码不一定是有效功能）' }
    if ($code -eq '') {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('没有 ioctl 码：dispatch 也没识别出跳转表。请用 -Ioctl 指定，或先跑 driver.vm.discover 找候选码。')
    }
    $codeVal = [Convert]::ToUInt32(($code -replace '^0x', ''), 16)
    $methodVal = $codeVal -band 3
    $methodNames = @('buffered', 'in-direct', 'out-direct', 'neither')

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            sysPath = $SysPath; sha256 = $sha; profileId = $profId
            ioctl = $code; ioctlSource = $codeSource
            layoutMethod = $methodNames[$methodVal]
        patchUsed = $patchToUse
        patchSource = $patchSource
            deviceCandidates = $devNames
            dispatchRange = $(if ($null -ne $jt -and $jt.hit) { $jt.ioctlRange } else { '' })
            inSize = $InSize; blockSize = $BlockSize
            probes = [Math]::Ceiling($InSize / $BlockSize)
            estimatedMin = [Math]::Round(($InSize / $BlockSize * 2.5 / 60 + 0.5), 1)
            note = '预览：会 push 驱动 + 跑 ' + [Math]::Ceiling($InSize / $BlockSize) + ' 次差分探测（两轮），然后合成 profile。产物可直接在 VM 里执行（崩了回滚快照）。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    # 3) 真跑：push + 差分探测
    # 注意：后面 presets 扫描要用 $ready.config / $ready.auth，必须先取一次。
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }
    $push = Push-LctVmDriver -Path $SysPath -Name 'target.sys' -Apply
    if ($null -eq $push -or -not $push.ok) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('push 失败: ' + $(if ($null -ne $push) { (@($push.errors) -join ';') } else { 'null' }))
    }
    # 注意：不用 patch（patch 的偏移是驱动特定的，通用场景下不知道 addr 在哪）。
    # 代价：addr 字段可能被 NULL 检查拦成 87，探测会漏掉它 —— 这一点必须在 profile 里标注。
    # 两轮探测（实测必需）：
    #   轮 1 无 patch：payload 全 0 → 能探到「addr 这类被 NULL 检查掩盖的字段」
    #                （rtcore64 实测：addr=0 得 87，addr=1 行为变 → off 8/12 判 active-strong）
    #   轮 2 有 patch：把 addr 槽位换成 guest 内核基址 → baseline 能成功 → 能探到 offset/readSize
    #                （rtcore64 实测：off 20/24 判 active-strong，但 addr 区被 patch 遮罩）
    # 两轮结果取并集才能拼出完整布局。patch 偏移是驱动特定的，所以要么用户给 -Patch，要么只能跑一轮。
    $fd = Invoke-LctVmFields -Ioctl $code -InSize $InSize -BlockSize $BlockSize -TimeoutSec $TimeoutSec -Apply
    if ($null -eq $fd -or -not $fd.ok -or $null -eq $fd.data) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('差分探测失败: ' + $(if ($null -ne $fd) { (@($fd.errors) -join ';') } else { 'null' }))
    }
    $rounds = @(@{ tag = 'no-patch'; data = $fd.data })

    # ---- 合并相邻确认块（先把轮 1 的块合并，才能正确推导 patch 宽度）----
    # 关键：探测粒度是 BlockSize(4)，一个 u64 字段会表现成两块相邻 active-strong。
    # 不合并 → addr(u64@8) 变 field_8+field_12，且自动推导的 patch 只有 4 字节 → baseline 必失败（实测踩过）。
    $mergeAdjacent = {
        param($items)
        $out = New-Object System.Collections.ArrayList
        $sorted = @($items | Sort-Object offset)
        $cur = $null
        foreach ($f in $sorted) {
            if ($null -eq $cur) {
                $cur = [pscustomobject]@{ offset = [int]$f.offset; size = [int]$f.size; kind = [string]$f.kind; rounds = @($f.round) }
                continue
            }
            if ([int]$f.offset -eq ([int]$cur.offset + [int]$cur.size)) {
                $cur.size = [int]$cur.size + [int]$f.size
                if ($f.kind -eq 'crash') { $cur.kind = 'crash' }
                $cur.rounds = @($cur.rounds) + @($f.round)
            } else {
                $null = $out.Add($cur)
                $cur = [pscustomobject]@{ offset = [int]$f.offset; size = [int]$f.size; kind = [string]$f.kind; rounds = @($f.round) }
            }
        }
        if ($null -ne $cur) { $null = $out.Add($cur) }
        return , $out
    }

    $r1raw = @($fd.data.fields | Where-Object { $_.kind -in @('active-strong', 'crash') } | ForEach-Object {
            [pscustomobject]@{ offset = [int]$_.offset; size = [int]$_.size; kind = [string]$_.kind; round = 'no-patch' }
        })
    $r1merged = & $mergeAdjacent $r1raw

    # ---- 自动推导第二轮 patch ----
    # 逻辑：轮 1 里第一个合并后的字段，很可能是「把 0 变成非 0 就改变行为」的那个
    # （rtcore64 实测 = addr(u64@8)：addr=0 被 NULL 检查拒成 87，addr=1 就走另一条路）。
    # 用它做 patch（换成 guest 内核基址），第二轮 baseline 才能成功，从而探到 offset/readSize。
    $patchToUse = $Patch
    $patchSource = 'user'
    if ([string]::IsNullOrWhiteSpace($patchToUse) -and @($r1merged).Count -gt 0) {
        $patchToUse = ('{0}:{1}' -f [int]$r1merged[0].offset, [int]$r1merged[0].size)
        $patchSource = 'auto(round-1 merged first field)'
    }
    if (-not [string]::IsNullOrWhiteSpace($patchToUse)) {
        $fd2 = Invoke-LctVmFields -Ioctl $code -InSize $InSize -BlockSize $BlockSize -Patch $patchToUse -TimeoutSec $TimeoutSec -Apply
        if ($null -ne $fd2 -and $fd2.ok -and $null -ne $fd2.data) {
            $bl2 = [string]$fd2.data.baseline.verdict
            $rounds += @{ tag = ('with-patch(' + $patchToUse + ')'); data = $fd2.data }
            if ($bl2 -ne 'ok-data') {
                $null = $warnings.Add(('第二轮 baseline 不是 ok-data（' + $bl2 + '），patch ' + $patchToUse + ' 可能猜错偏移。可用 -Patch 手动指定。'))
            }
        } else {
            $null = $warnings.Add('第二轮（带 patch ' + $patchToUse + '）探测失败，只用了第一轮结果')
        }
    } else {
        $null = $warnings.Add('第一轮没探到任何确认字段，无法推导 patch —— 结果可能不完整。')
    }

    # ---- 合并两轮 ----
    $allRaw = New-Object System.Collections.ArrayList
    foreach ($rd in $rounds) {
        foreach ($f in @($rd.data.fields)) {
            if ($f.kind -notin @('active-strong', 'crash')) { continue }
            $null = $allRaw.Add([pscustomobject]@{ offset = [int]$f.offset; size = [int]$f.size; kind = [string]$f.kind; round = [string]$rd.tag })
        }
    }
    # 去重（同 offset 同 size 只留一次）
    $dedup = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($f in @($allRaw | Sort-Object offset, size)) {
        $k = ([string]$f.offset + '/' + [string]$f.size)
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $null = $dedup.Add($f) }
    }
    $fdAllFields = & $mergeAdjacent $dedup
    $fdAllFields = @($fdAllFields)
    if ($null -ne $fd.data.summary -and [bool]$fd.data.summary.vmMayBeDead) {
        $null = $warnings.Add('探测过程中 VM 可能崩溃了（vmMayBeDead=true）。产物可能不完整。' + $(if ($Snapshot -ne '') { ' 可用 -Snapshot 配合 driver.vm.batch 恢复。' } else { '' }))
    }

    # 4) 从探测结果重建 in 布局
    #    active-strong / crash 算"确认字段"；active-weak 可能是回填噪音（不算）；padding 明确写出
    $fields = $fdAllFields
    # 确认字段列表（差分探测合并后的结果）
    $fields = $fdAllFields
    $confirmed = @($fields | Sort-Object offset)

    # 布局生成：每个确认字段要**落在它探测到的偏移上**，中间用 padding 填。
    # 关键陷阱（实测踩过）：padding 用「大块 bytes」会被对齐规则推走。
    #   ConvertTo-LctPrfBuffer 每字段按 min(size, align=8) 对齐，
    #   所以 20 字节的 tail padding 在偏移 28 上（28%8=4）会被推到 32 → 总长从 48 变 52。
    # 解法：padding 一律拆成「8 字节块 + 1 字节块」——8 字节块(step=8)只在 8 倍数处落位，
    #       1 字节块(step=1)任何位置都对，两种都不会触发额外填充。
    $layout = New-Object System.Collections.ArrayList
    $cursor = 0
    $alignWarn = New-Object System.Collections.ArrayList
    foreach ($f in $confirmed) {
        $off = [int]$f.offset; $sz = [int]$f.size
        # 补齐到目标偏移
        # 注意：8 字节块只在 cursor 是 8 的倍数时才用 —— 否则它自己会被编码器的
        # 对齐规则推走（实测：在偏移 28 放 8 字节块 → 28%8=4 → 填充到 32 → 总长失控）。
        while ($cursor -lt $off) {
            $gap = $off - $cursor
            if (($cursor % 8) -eq 0 -and $gap -ge 8) {
                $null = $layout.Add([ordered]@{ name = ('pad8_' + $cursor); type = 'bytes'; len = 8 })
                $cursor += 8
            } else {
                $null = $layout.Add([ordered]@{ name = ('padb_' + $cursor); type = 'bytes'; len = 1 })
                $cursor += 1
            }
        }
        # 字段自身的对齐要求（step = min(size,8)）；不满足就会被编码器填充 → 长度失控
        $t2 = if ($sz -ge 8) { 'u64' } else { 'u32' }
        $step = if ($sz -ge 8) { 8 } else { 4 }
        if (($cursor % $step) -ne 0) {
            $null = $alignWarn.Add(('field_' + $off + '(' + $t2 + ') 落在偏移 ' + $cursor + '，不是 ' + $step + ' 的倍数 → 编码器会插入填充'))
        }
        $null = $layout.Add([ordered]@{ name = ('field_' + $off); type = $t2 })
        $cursor += $sz
    }
    # 尾部补齐到 InSize（同样：8 字节块只在 8 的倍数处用）
    while ($cursor -lt $InSize) {
        $gap = $InSize - $cursor
        if (($cursor % 8) -eq 0 -and $gap -ge 8) {
            $null = $layout.Add([ordered]@{ name = ('pad8_' + $cursor); type = 'bytes'; len = 8 })
            $cursor += 8
        } else {
            $null = $layout.Add([ordered]@{ name = ('padb_' + $cursor); type = 'bytes'; len = 1 })
            $cursor += 1
        }
    }
    if (@($alignWarn).Count -gt 0) { foreach ($aw in @($alignWarn)) { $null = $warnings.Add($aw) } }
    # ---- 补齐到 InSize（对齐会改变总长度，实测踩过）----
    # ConvertTo-LctPrfBuffer 每个字段按 min(字段大小, align=8) 对齐。
    # 探测产物常漏掉 4 字节字段（如 offset/value），导致最后一个 padding 落在
    # 非 8 倍数偏移上 → 被填充 → 总长从 48 变 52（实测），驱动收到的尺寸不对。
    # 这里先算出"按对齐规则的真实总长"，再用 1 字节 padding 补到 InSize。
    # （用 1 字节是因为 step=min(1,8)=1，任何偏移都对齐，绝不会再触发填充。）
    $calcTotal = 0
    foreach ($e in @($layout)) {
        $esz = 0
        if ([string]$e.type -eq 'bytes') { $esz = [int]$e.len }
        elseif ([string]$e.type -eq 'u64') { $esz = 8 }
        elseif ([string]$e.type -eq 'u32') { $esz = 4 }
        elseif ([string]$e.type -eq 'u16') { $esz = 2 }
        elseif ([string]$e.type -eq 'u8') { $esz = 1 }
        else { $esz = 8 }
        $estep = [Math]::Min($esz, 8)
        if ($estep -lt 1) { $estep = 1 }
        while (($calcTotal % $estep) -ne 0) { $calcTotal++ }
        $calcTotal += $esz
    }
    $padGuard = 0
    while ($calcTotal -lt $InSize -and $padGuard -lt 64) {
        $null = $layout.Add([ordered]@{ name = ('padx' + $calcTotal); type = 'bytes'; len = 1 })
        $calcTotal += 1
        $padGuard++
    }
    if ($calcTotal -gt $InSize) {
        $null = $warnings.Add(('按布局编码后的总长 ' + $calcTotal + ' 超过 InSize=' + $InSize + '（说明探测漏了字段或粒度不对）。驱动会收到超长 buffer，结论需复核。'))
    } elseif ($calcTotal -eq $InSize -and $padGuard -gt 0) {
        $null = $warnings.Add(('已用 ' + $padGuard + ' 个 1 字节 padding 把编码总长补到 InSize=' + $InSize + '（原为 ' + ($InSize - $padGuard) + '）'))
    }

    # ---- presets 扫描（关键：不给有意义的 size，驱动会全程 no-op，结论全是假的）----
    # 实测踩过：探测产物的 presets 为空 → readSize=0 → 驱动什么都不读就直接成功返回，
    # 于是 matrix 里一堆变异显示 ok-data，看起来"无害"，其实根本没干活。
    # 做法：对每个确认字段试 1/4/8/16，找"能让返回数据非全 0"的值当 preset。
    # 跳过被 patch 覆盖的字段（它的值会被 guest 侧改写成内核基址，设了也没用）。
    $foundPresets = [ordered]@{}
    $presetNotes = New-Object System.Collections.ArrayList
    $patchOff = -1; $patchLen = 0
    if ($patchToUse -match '^(\d+):(\d+)$') { $patchOff = [int]$matches[1]; $patchLen = [int]$matches[2] }
    if (@($confirmed).Count -gt 0) {
        $vmxP = $ready.config.vmx
        $gdP = [string]$ready.config.guestDir
        $guestResultP = Join-Path $gdP 'result.json'
        $guestProbeP = Join-Path $gdP 'probe.ps1'
        $psGP = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $authP = $ready.auth
        $guestSysP = Join-Path $gdP 'target.sys'

        $sendPb = {
            param([byte[]]$Buf)
            $hexP = (($Buf | ForEach-Object { '{0:X2}' -f $_ }) -join '')
            $partsP = New-Object System.Collections.ArrayList
            $null = $partsP.Add("`$env:LCT_SYS='$guestSysP'")
            $null = $partsP.Add("`$env:LCT_IOCTL='$code'")
            $null = $partsP.Add("`$env:LCT_INHEX='$hexP'")
            if ($patchToUse -ne '') { $null = $partsP.Add("`$env:LCT_PATCH='$patchToUse'") }
            $cmdP = ($partsP -join '; ') + ('; & ''' + $guestProbeP + '''')
            $null = Invoke-LctVmRun -Params @('runProgramInGuest', $vmxP, $psGP, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdP) -User $authP.user -Pass $authP.pass -TimeoutSec $TimeoutSec
            $tmpP = Join-Path $env:TEMP ('lct-ps-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
            $pullP = Invoke-LctVmRun -Params @('copyFileFromGuestToHost', $vmxP, $guestResultP, $tmpP) -User $authP.user -Pass $authP.pass -TimeoutSec 30
            if ($pullP.ok -and (Test-Path -LiteralPath $tmpP)) {
                try {
                    $rp = Get-Content -LiteralPath $tmpP -Raw -Encoding UTF8 | ConvertFrom-Json
                    return [pscustomobject]@{ verdict = [string]$rp.verdict; ret = [int]$rp.bytesReturned; err = [int]$rp.win32Error; outHex = [string]$rp.outHex }
                } catch { }
            }
            return [pscustomobject]@{ verdict = 'pull-failed'; ret = 0; err = 0; outHex = '' }
        }

        foreach ($cf in @($confirmed)) {
            $cOff = [int]$cf.offset; $cSz = [int]$cf.size
            # 被 patch 覆盖的字段跳过（设了也会被 guest 改成内核基址）
            if ($patchOff -ge 0 -and $cOff -lt ($patchOff + $patchLen) -and ($cOff + $cSz) -gt $patchOff) {
                $null = $presetNotes.Add(('field_' + $cOff + ' 被 patch 覆盖，跳过'))
                continue
            }
            foreach ($val in @(1, 4, 8, 16)) {
                $bufP = New-Object byte[] $InSize
                try {
                    if ($cSz -ge 8) { [BitConverter]::GetBytes([UInt64]$val).CopyTo($bufP, $cOff) }
                    else { [BitConverter]::GetBytes([UInt32]$val).CopyTo($bufP, $cOff) }
                } catch { continue }
                $rp = & $sendPb $bufP
                if ([string]$rp.verdict -in @('timeout', 'crash')) {
                    $null = $presetNotes.Add(('field_' + $cOff + '=' + $val + ' → ' + $rp.verdict + '（危险值）'))
                    break
                }
                if ([string]$rp.verdict -eq 'ok-data' -and (([string]$rp.outHex -replace '[0][0]', '') -replace ' ', '') -ne '') {
                    $foundPresets['field_' + $cOff] = $val
                    $null = $presetNotes.Add(('field_' + $cOff + '=' + $val + ' 让返回数据非全 0 ✓'))
                    break
                }
            }
        }
    }

    # 5) 合成 profile（探测产物，可直接在 VM 里执行）
    $presets = [ordered]@{}
    foreach ($pk in $foundPresets.Keys) { $presets[$pk] = $foundPresets[$pk] }
    if ($foundPresets.Count -eq 0 -and @($confirmed).Count -gt 0) {
        $null = $warnings.Add('presets 扫描没找到"能让驱动真干活"的值 —— 所有变异都可能只是 no-op，结论不可信。')
    }

    $action = [ordered]@{
        ioctl = $code
        in = @($layout)
        # out 默认与 in 同构（实测 rtcore64 完全一致）—— 不写，由执行器按 in 推导
        presets = $presets
    }
    $riskLevel = 'bsod'
    $riskNotes = '探测生成：字段语义未确认，未经验证直接使用可能蓝屏。'
    if ($methodVal -eq 3) { $riskNotes = 'METHOD_NEITHER：驱动直接操作用户态指针，未验证前不要执行。' }
    if (@($fdAllFields | Where-Object { $_.kind -eq 'crash' }).Count -gt 0) {
        $riskNotes += ' 探测中已出现崩溃（某些偏移会越界），风险更高。'
    }
    $prof = [ordered]@{
        id = $profId
        kind = 'driver-profile'
        engineApi = 1
        target = [ordered]@{ sha256 = $sha; fileName = $fname }
        locate = [ordered]@{ candidates = @($devNames) }
        actions = [ordered]@{ ($ActionName) = $action }
        layout = [ordered]@{ method = $methodNames[$methodVal]; align = 8 }
        risk = [ordered]@{ level = $riskLevel; notes = $riskNotes }
        requires = [ordered]@{ restart = $false; admin = $true; elevation = 'admin' }
        source = [ordered]@{
            generatedBy = 'driver.profile.fromprobe'
            probeGenerated = $true
            verifiedInVm = $true
            ioctlSource = $codeSource
            dispatchRange = $(if ($null -ne $jt -and $jt.hit) { $jt.ioctlRange } else { '' })
        }
        note = '字段偏移来自差分探测（实测），语义名用 field_N 占位 —— 但**不影响执行**（执行器是按位置和类型的字节布局读写）。可直接 driver.vm.matrix 跑变异矩阵。要更好读可以自己改名。'
    }
    $json = ($prof | ConvertTo-Json -Depth 12)


    # 6) 落盘
    $profDir = Join-Path $script:LctVmRoot 'var\driver-profiles'
    if (-not (Test-Path -LiteralPath $profDir)) { $null = New-Item -ItemType Directory -Path $profDir -Force }
    $outPath = Join-Path $profDir ($profId + '.json')
    $existing = Test-Path -LiteralPath $outPath
    [IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    if ($existing) { $null = $warnings.Add('覆盖了已存在的 profile: ' + $outPath) }

    $data = [pscustomobject][ordered]@{
        applied = $true
        profilePath = $outPath
        profileId = $profId
        ioctl = $code
        layoutMethod = $methodNames[$methodVal]
        confirmedFields = @($confirmed | ForEach-Object { [ordered]@{ offset = $_.offset; size = $_.size; kind = $_.kind } })
        layout = @($layout)
        readyForVm = $true
        presets = $presets
        presetNotes = @($presetNotes)
        probeRounds = @($rounds | ForEach-Object { [ordered]@{ round = $_.tag; summary = $_.data.summary } })
        nextSteps = @(
            '（可选）把 field_N 改成语义名，纯粹为了可读性，不影响执行',
            '（可选）driver.vm.matrix -Profile <id> -Action auto 直接跑变异矩阵',
            '（可选）如果漏了 addr 这类被 NULL 检查掩盖的字段，用 -Ioctl + 正确的 baseline 重跑 driver.vm.fields'
        )
        note = '产物已写入 var\driver-profiles\，**可直接执行**（Vm 里崩了回滚快照即可）。要应用到实体机时才需要人工复核。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

# ---------------- verb: explore（全自动探索：一个 .sys 进去，能力报告出来） ----------------

function Invoke-LctVmExplore {
    <#
    .SYNOPSIS driver.vm.explore：给一个 .sys，全自动探出「它实际能做什么」
    .DESCRIPTION
      **不需要 profile，不需要人审定**。VM 里崩了回滚快照即可 —— 这正是用 VM 的意义。

      流水线（全部复用已有零件）：
        1. push 驱动
        2. discover 暴力扫 IOCTL 码（找候选）
        3. 对每个候选码跑 fromprobe（两轮差分探测 → 字段布局 + profile）
        4. 对生成的 profile 跑 matrix（字段边界变异 → 找崩溃/越界）
        5. 汇总成能力结论

      崩溃处理：任一步崩了就停，报告已得结论（可用 -Snapshot 配合 batch 恢复后重跑）。
    .NOTES
      默认只预览。真跑会 push 驱动 + 发几十个 IOCTL + 可能让 VM 崩，
      但**崩了不心疼**——回滚快照 30 秒就回来了。
    #>
    param(
        [Parameter(Mandatory)][string]$SysPath,
        [string]$Base = '0x80002000',
        [int]$Count = 32,
        [int]$Step = 4,
        [int]$InSize = 48,
        [int]$BlockSize = 4,
        [int]$MaxCodes = 3,
        [int]$TimeoutSec = 20,
        [switch]$SkipMatrix,
        [switch]$Apply
    )
    $verb = 'driver.vm.explore'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $SysPath)) { return New-LctResult -Verb $verb -Errors @('找不到驱动: ' + $SysPath) }
    $ready = Test-LctVmReady
    if (-not $ready.ok) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($ready.reasons) }

    $sha = (Get-FileHash -LiteralPath $SysPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $fname = Split-Path $SysPath -Leaf
    $profId = [IO.Path]::GetFileNameWithoutExtension($SysPath)

    if (-not $Apply) {
        $data = [pscustomobject][ordered]@{
            applied = $false
            sysPath = $SysPath; sha256 = $sha; profileId = $profId
            phases = @(
                [ordered]@{ phase = 'push'; what = '把驱动推到 guest 并准备环境'; estSec = 10 }
                [ordered]@{ phase = 'discover'; what = ('暴力扫 ' + $Count + ' 个码（step=' + $Step + '）'); estSec = [Math]::Round($Count * 3) }
                [ordered]@{ phase = 'fromprobe'; what = ('对前 ' + $MaxCodes + ' 个候选码做两轮差分探测'); estSec = $MaxCodes * 120 }
                [ordered]@{ phase = 'matrix'; what = '对生成的 profile 跑字段边界变异'; estSec = $MaxCodes * 40 }
            )
            estimatedMin = [Math]::Round(((10 + $Count * 3 + $MaxCodes * 120 + $MaxCodes * 40) / 60), 1)
            note = '预览：不需要 profile，也不需要人审定。VM 里崩了回滚快照即可（-Snapshot 配合 driver.vm.batch 可自动恢复）。加 -Apply 才真跑。'
        }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
    }

    $swAll = [Diagnostics.Stopwatch]::StartNew()
    # 注意：[ordered]@{ probes = @() } 是**固定大小数组**，对它 .Add() 会抛
    # `Collection was of a fixed size`（项目老坑），所以用独立 ArrayList 收集。
    $probesList = New-Object System.Collections.ArrayList
    $report = [ordered]@{
        sysPath = $SysPath; sha256 = $sha; profileId = $profId
        deviceCandidates = @()
        dispatchRange = ''
        discover = $null
        probes = @()   # 占位，真值在最后从 $probesList 赋值
        theCode = ''
        profilePath = ''
        matrix = $null
        capabilities = @()
        stoppedAt = ''
    }

    # ---- 阶段 1：静态 + push ----
    try {
        $draft = New-LctDriverProfileDraft -Path $SysPath
        if ($null -ne $draft -and $draft.ok) {
            $report.deviceCandidates = @($draft.data.draft.draft.evidence.deviceNameCandidates | ForEach-Object { [string]$_.text } | Where-Object { $_ -ne '' })
        }
    } catch { }
    try {
        $jt = Get-LctPrfJumpTable -Path $SysPath
        if ($null -ne $jt -and $jt.hit) { $report.dispatchRange = $jt.ioctlRange }
    } catch { }

    $push = Push-LctVmDriver -Path $SysPath -Name 'target.sys' -Apply
    if ($null -eq $push -or -not $push.ok) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @(('push 失败: ' + $(if ($null -ne $push) { (@($push.errors) -join ';') } else { 'null' })))
    }

    # ---- 阶段 2：discover ----
    $disc = Invoke-LctVmDiscover -Base $Base -Count $Count -Step $Step -InSize $InSize -TimeoutSec 8 -Apply
    if ($null -ne $disc -and $disc.ok -and $null -ne $disc.data) {
        $report.discover = $disc.data.summary
        if ([bool]$disc.data.summary.vmMayBeDead) {
            $report.stoppedAt = 'discover 阶段 VM 崩了'
            $null = $warnings.Add('discover 阶段崩溃，后续阶段跳过')
        }
    } else {
        $null = $warnings.Add('discover 失败: ' + $(if ($null -ne $disc) { (@($disc.errors) -join ';') } else { 'null' }))
    }

    if ($report.stoppedAt -eq '' -and $null -ne $disc -and $null -ne $disc.data) {
        # 候选：强候选优先，其次弱候选
        $cands = New-Object System.Collections.ArrayList
        foreach ($c in @($disc.data.strongCandidates)) { $null = $cands.Add([string]$c) }
        foreach ($c in @($disc.data.weakCandidates)) { if (-not $cands.Contains([string]$c)) { $null = $cands.Add([string]$c) } }
        # 如果 dispatch 有范围，把范围内的码也优先
        if ($report.dispatchRange -ne '') {
            $null = $warnings.Add('dispatch 已识别范围 ' + $report.dispatchRange + '，可优先试这个范围')
        }
        $tryCodes = @($cands | Select-Object -First $MaxCodes)

        foreach ($code in $tryCodes) {
            $one = [ordered]@{ ioctl = $code; fields = 0; confirmed = @(); layoutMethod = ''; crashed = $false; error = '' }
            $fp = $null
            try {
                $fp = Invoke-LctVmFromProbe -SysPath $SysPath -Ioctl $code -InSize $InSize -BlockSize $BlockSize -ActionName 'auto' -TimeoutSec $TimeoutSec -Apply
            } catch { $one.error = $_.Exception.Message }
            if ($null -ne $fp -and $fp.ok -and $null -ne $fp.data) {
                $one.confirmed = @($fp.data.confirmedFields)
                $one.fields = @($one.confirmed).Count
                $one.layoutMethod = [string]$fp.data.layoutMethod
                if (@($one.confirmed).Count -gt 0) {
                    # 探到字段就定案、**立刻停**：fromprobe 每次写同一个 profile 文件，
                    # 继续试后面的码会用「探不到字段的空产物」覆盖掉这个好的（实测踩过）。
                    $report.theCode = $code
                    $report.profilePath = [string]$fp.data.profilePath
                    $null = $warnings.Add(('码 ' + $code + ' 探出 ' + @($one.confirmed).Count + ' 个字段，已定案并停止后续探测'))
                    $null = $report.probes.Add([pscustomobject]$one)
                    break
                }
                $sm = $null
                try { $sm = $fp.data.probeRounds[0].summary } catch { }
                if ($null -ne $sm -and [bool]$sm.vmMayBeDead) {
                    $one.crashed = $true
                    $report.stoppedAt = ('fromprobe(' + $code + ') 让 VM 崩了')
                    $null = $probesList.Add([pscustomobject]$one)
                    break
                }
            } else {
                $one.error = $(if ($null -ne $fp) { (@($fp.errors) -join ';') } else { 'null' })
            }
            $null = $probesList.Add([pscustomobject]$one)
            if ($report.stoppedAt -ne '') { break }
        }

        # ---- 阶段 4：matrix ----
        if ($report.stoppedAt -eq '' -and -not $SkipMatrix -and $report.theCode -ne '') {
            $mx = Invoke-LctVmMatrix -Profile $report.profileId -Action 'auto' -Levels 'baseline,boundary' -MaxVariants 20 -PerVariantTimeoutSec $TimeoutSec -Apply
            if ($null -ne $mx -and $mx.ok -and $null -ne $mx.data) {
                $report.matrix = $mx.data.summary
                $crashV = @($mx.data.results | Where-Object { $_.verdict -in @('crash', 'timeout') })
                if (@($crashV).Count -gt 0) {
                    $null = $warnings.Add(('matrix 里有 ' + @($crashV).Count + ' 条变异导致崩溃/挂起：' + ((@($crashV) | ForEach-Object { $_.mutation }) -join ', ')))
                    $report.stoppedAt = 'matrix 阶段有崩溃/挂起'
                }
            }
        }
    }
    $swAll.Stop()

    # ---- 能力推断 ----
    $caps = New-Object System.Collections.ArrayList
    if ($null -ne $report.discover) {
        $n = [int]$report.discover.accepted
        if ($n -gt 0) { $null = $caps.Add([ordered]@{ what = ('发现 ' + $n + ' 个功能可用的 IOCTL 码'); evidence = 'discover accepted' }) }
        if ([int]$report.discover.otherError -gt 0) { $null = $caps.Add([ordered]@{ what = ('另有 ' + $report.discover.otherError + ' 个码被处理但调用失败（说明码有效）'); evidence = 'discover other-error' }) }
        if ([int]$report.discover.crash -gt 0 -or [int]$report.discover.timeout -gt 0) { $null = $caps.Add([ordered]@{ what = '存在会让驱动挂起/崩溃的 IOCTL 码'; evidence = 'discover crash/timeout' }) }
    }
    if ($report.theCode -ne '') {
        $null = $caps.Add([ordered]@{ what = ('确定可用码 ' + $report.theCode + '，布局已探出 ' + @($probesList | Where-Object { $_.ioctl -eq $report.theCode } | ForEach-Object { @($_.confirmed).Count }) + ' 个字段'); evidence = 'fromprobe' })
    }
    if ($null -ne $report.matrix) {
        if ([int]$report.matrix.crash -gt 0 -or [int]$report.matrix.timeout -gt 0) {
            $null = $caps.Add([ordered]@{ what = '字段边界变异导致崩溃/挂起 → 参数校验不完整'; evidence = 'matrix' })
        }
        if ([int]$report.matrix.okData -gt 0) {
            $null = $caps.Add([ordered]@{ what = ('有 ' + $report.matrix.okData + ' 条畸形输入仍被接受 → 可能是任意读写能力'); evidence = 'matrix' })
        }
    }
    $report.capabilities = @($caps)

    $data = [pscustomobject][ordered]@{
        applied = $true
        sysPath = $SysPath; sha256 = $sha; profileId = $profId
        deviceCandidates = @($report.deviceCandidates)
        dispatchRange = $report.dispatchRange
        discover = $report.discover
        probes = @($probesList)
        theCode = $report.theCode
        profilePath = $report.profilePath
        matrix = $report.matrix
        capabilities = @($report.capabilities)
        stoppedAt = $report.stoppedAt
        totalMin = [Math]::Round($swAll.Elapsed.TotalMinutes, 1)
        note = '这是「实测结论」不是草案：每一步都在 VM 里真跑过。崩了回滚快照即可。要应用到实体机时才需要人工复核。'
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data
}

Export-ModuleMember -Function Invoke-LctVmConfig, Get-LctVmStatus, Initialize-LctVmGuest, Push-LctVmDriver, Invoke-LctVmProbe, Invoke-LctVmAnchor, Set-LctVmSnapshot, Invoke-LctVmMatrix, Invoke-LctVmFields, Invoke-LctVmBatch, Invoke-LctVmDiscover, Invoke-LctVmFromProbe, Invoke-LctVmExplore, Get-LctVmBatchTasks, Get-LctVmDeps