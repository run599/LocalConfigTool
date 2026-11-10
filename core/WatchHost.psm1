# LocalConfigTool - 看门狗宿主（维护者：Lead）
#
# 背景（backend-processes 实测发现的致命限制）：他们的看门狗是在**调用进程内的 runspace** 里跑的，
# 而引擎 CLI 每调用一次都是新的 powershell 进程 ⇒ 进程一退出看门狗就消失了，
# 于是 watch.status 在新进程里永远 running=false，这个能力等于用不了。
#
# 本模块给看门狗一个有界的「寿命容器」：
#   · start 时起一个**独立的宿主进程**（powershell.exe，最小化窗口、任务管理器可见），
#     由它 Import Processes.psm1 并调用 Start-LctProcessWatch -Apply，宿主负责活到监控结束；
#   · 宿主寿命 = DurationSec（5..3600 秒，**到点自行结束**，不会无限期驻留）；
#   · state 文件记录 hostPid/targets/起止时间，status/log/stop 跨进程可读；
#   · stop = 写停止文件 → 等宿主自行收尾 → 超时再兜底结束该宿主进程。
# 明确不做（与用户约定一致）：不装服务、不注册计划任务、不写任何 Run/自启动项、不做任何隐藏。
# 杀进程的全部逻辑仍在 backend-processes 的模块里，本模块只管寿命与状态。

function Get-LctWatchStateDir {
    $d = Join-Path (Get-LctVarDir) 'watch'
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    return $d
}

function Write-LctWatchState {
    param([Parameter(Mandatory)][string]$StateFile, $State)
    (ConvertTo-LctJson -Object $State -Depth 8) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Read-LctWatchState {
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-LctWatchStateNewest {
    $dir = Get-LctWatchStateDir
    $f = @(Get-ChildItem -LiteralPath $dir -File -Filter 'watch-*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.stop' } | Sort-Object LastWriteTime -Descending)
    if (@($f).Count -eq 0) { return $null }
    return $f[0]
}

function Get-LctWatchLogFile {
    # backend-processes 的看门狗事件日志：var\logs\process-watch-<日期>.log（按约定 glob 最新）
    $dir = Join-Path (Get-LctVarDir) 'logs'
    $f = @(Get-ChildItem -LiteralPath $dir -File -Filter 'process-watch-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if (@($f).Count -eq 0) { return $null }
    return $f[0].FullName
}

# ---------------------------------------------------------------------------
# 子进程入口：在本进程内启用看门狗，并活到监控结束（或收到停止文件）
# ---------------------------------------------------------------------------
function Invoke-LctWatchHostLoop {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string[]]$Targets,
        [int]$IntervalSec = 2,
        [int]$DurationSec = 300
    )
    $ErrorActionPreference = 'Continue'
    $core = $PSScriptRoot
    if (-not $core) { $core = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $procModule = Join-Path $core 'Processes.psm1'
    $stopFile = $StateFile + '.stop'
    $base = [ordered]@{
        hostPid    = $PID
        startedAt  = (Get-Date).ToString('s')
        targets    = @($Targets)
        intervalSec = $IntervalSec
        durationSec = $DurationSec
        status     = 'starting'
        note       = '宿主进程承载进程内看门狗；到点自行结束，不装服务/任务/自启动'
    }
    $watchResult = $null
    try {
        Import-Module $procModule -Force -Global
        $watchResult = Start-LctProcessWatch -Targets $Targets -IntervalSec $IntervalSec -DurationSec $DurationSec -Apply
        $base.status = 'running'
        if ($watchResult -and $watchResult.data) { $base.watch = $watchResult.data }
        if ($watchResult -and $watchResult.errors) { $base.watchErrors = @($watchResult.errors) }
    } catch {
        $base.status = 'failed'
        $base.error = $_.Exception.Message
    }
    Write-LctWatchState -StateFile $StateFile -State ([pscustomobject]$base)

    if ($base.status -eq 'running') {
        $deadline = (Get-Date).AddSeconds($DurationSec + 30)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $stopFile) { break }
            Start-Sleep -Seconds 1
        }
        try { $null = Stop-LctProcessWatch -Apply } catch { }
    }
    $base.status = 'stopped'
    $base.endedAt = (Get-Date).ToString('s')
    Write-LctWatchState -StateFile $StateFile -State ([pscustomobject]$base)
    return 0
}

# ---------------------------------------------------------------------------
# 父进程侧：起宿主 / 查状态 / 读日志 / 停宿主（都返回契约 Result）
# ---------------------------------------------------------------------------
function Start-LctWatchHost {
    param([Parameter(Mandatory)][string[]]$Targets, [int]$IntervalSec = 2, [int]$DurationSec = 300)
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $clean = @(@($Targets) | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() })
    if (@($clean).Count -eq 0) { $null = $errors.Add('必须显式指定至少一个目标（name 或 path），不支持通配与"全部"') }
    if ($IntervalSec -lt 1) { $IntervalSec = 1 }
    if ($DurationSec -lt 5) { $DurationSec = 5 }
    if ($DurationSec -gt 3600) { $DurationSec = 3600; $null = $warnings.Add('DurationSec 超过上限，已收敛为 3600 秒（1 小时）') }
    foreach ($t in $clean) { if ($t -match '[\*\?]') { $null = $errors.Add("目标不允许通配: $t") } }
    if (@($errors).Count -gt 0) { return New-LctResult -Verb 'process.watch.start' -Errors @($errors) -Warnings @($warnings) }

    # 单实例：已有存活宿主则拒绝
    $existing = Get-LctWatchHostStatus
    if ($existing.ok -and $existing.data -and $existing.data.hostAlive -eq $true) {
        return New-LctResult -Verb 'process.watch.start' -Errors @("已有存活的看门狗宿主（hostPid=$($existing.data.hostPid)），请先 process.watch.stop") -Warnings @($warnings)
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $stateFile = Join-Path (Get-LctWatchStateDir) ("watch-$stamp.json")
    $stopFile = $stateFile + '.stop'
    if (Test-Path -LiteralPath $stopFile) { $null = Move-LctToRecycleBin -Path $stopFile }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $modulePath = Join-Path $PSScriptRoot 'WatchHost.psm1'
    $q = @($clean | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $inner = "Import-Module '" + ($modulePath -replace "'", "''") + "' -Force; " +
    "Invoke-LctWatchHostLoop -StateFile '" + ($stateFile -replace "'", "''") + "' -Targets @(" + $q + ") -IntervalSec $IntervalSec -DurationSec $DurationSec"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $host_proc = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64) -WindowStyle Minimized -PassThru
    Start-Sleep -Seconds 2
    $state = Read-LctWatchState -StateFile $stateFile
    $alive = $false
    if ($state -and $state.hostPid) { $alive = [bool](Get-Process -Id $state.hostPid -ErrorAction SilentlyContinue) }
    if (-not $alive -and $host_proc) { $alive = [bool](Get-Process -Id $host_proc.Id -ErrorAction SilentlyContinue) }
    if ($state -and $state.status -eq 'failed') { $null = $errors.Add('宿主内看门狗启动失败: ' + [string]$state.error) }

    $null = $warnings.Add('看门狗运行在独立宿主进程内（任务管理器可见、最小化窗口）：寿命上限 ' + $DurationSec + ' 秒，到点自行结束；本工具不装服务、不注册任务、不写任何自启动。')
    if (-not $alive) { $null = $warnings.Add('宿主进程未确认存活，请用 process.watch.status 复核') }

    return New-LctResult -Verb 'process.watch.start' -Applied -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]@{
            hostPid     = $(if ($state) { $state.hostPid } else { $(if ($host_proc) { $host_proc.Id } else { 0 }) })
            stateFile   = $stateFile
            stopFile    = $stopFile
            targets     = @($clean)
            intervalSec = $IntervalSec
            durationSec = $DurationSec
            hostAlive   = $alive
            status      = $(if ($state) { $state.status } else { 'unknown' })
            logFile     = (Get-LctWatchLogFile)
        })
}

function Get-LctWatchHostStatus {
    $f = Get-LctWatchStateNewest
    if ($null -eq $f) {
        return New-LctResult -Verb 'process.watch.status' -Data ([pscustomobject]@{ running = $false; hostAlive = $false; note = '没有看门狗会话记录' })
    }
    $state = Read-LctWatchState -StateFile $f.FullName
    $alive = $false
    if ($state -and $state.hostPid) { $alive = [bool](Get-Process -Id $state.hostPid -ErrorAction SilentlyContinue) }
    return New-LctResult -Verb 'process.watch.status' -Data ([pscustomobject]@{
            running       = ($alive -and $state.status -eq 'running')
            hostAlive     = $alive
            hostPid       = $(if ($state) { $state.hostPid } else { 0 })
            status        = $(if ($state) { $state.status } else { 'unknown' })
            targets       = $(if ($state) { @($state.targets) } else { @() })
            intervalSec   = $(if ($state) { $state.intervalSec } else { 0 })
            durationSec   = $(if ($state) { $state.durationSec } else { 0 })
            startedAt     = $(if ($state) { $state.startedAt } else { '' })
            endedAt       = $(if ($state) { $state.endedAt } else { '' })
            stateFile     = $f.FullName
            logFile       = (Get-LctWatchLogFile)
            watchSummary  = $(if ($state -and $state.watch) { $state.watch } else { $null })
        })
}

function Stop-LctWatchHost {
    $warnings = New-Object System.Collections.ArrayList
    $f = Get-LctWatchStateNewest
    if ($null -eq $f) { return New-LctResult -Verb 'process.watch.stop' -Data ([pscustomobject]@{ stopped = $false; note = '没有看门狗会话可停' }) }
    $state = Read-LctWatchState -StateFile $f.FullName
    $hostPid = 0
    if ($state -and $state.hostPid) { $hostPid = [int]$state.hostPid }
    $alive = ($hostPid -gt 0) -and [bool](Get-Process -Id $hostPid -ErrorAction SilentlyContinue)
    if (-not $alive) {
        return New-LctResult -Verb 'process.watch.stop' -Data ([pscustomobject]@{ stopped = $true; hostPid = $hostPid; note = '宿主已不在运行（可能已到点自行结束）' })
    }
    $stopFile = $f.FullName + '.stop'
    Set-Content -LiteralPath $stopFile -Value (Get-Date).ToString('s') -Encoding UTF8
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $hostPid -ErrorAction SilentlyContinue)) { break }
    }
    if (Get-Process -Id $hostPid -ErrorAction SilentlyContinue) {
        $null = $warnings.Add('宿主未在 5 秒内自行收尾，已兜底结束该宿主进程（仅结束本工具自己起的那个 pid）')
        Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue
    }
    $final = Read-LctWatchState -StateFile $f.FullName
    return New-LctResult -Verb 'process.watch.stop' -Applied -Warnings @($warnings) -Data ([pscustomobject]@{
            stopped  = (-not [bool](Get-Process -Id $hostPid -ErrorAction SilentlyContinue))
            hostPid  = $hostPid
            status   = $(if ($final) { $final.status } else { 'unknown' })
            endedAt  = $(if ($final) { $final.endedAt } else { '' })
        })
}

function Get-LctWatchHostLog {
    param([int]$Tail = 30)
    $logFile = Get-LctWatchLogFile
    $lines = @()
    if ($logFile) { $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last $Tail) }
    return New-LctResult -Verb 'process.watch.log' -Data ([pscustomobject]@{
            logFile = $logFile
            count   = @($lines).Count
            lines   = $lines
        })
}

Export-ModuleMember -Function Start-LctWatchHost, Get-LctWatchHostStatus, Stop-LctWatchHost, Get-LctWatchHostLog, Invoke-LctWatchHostLoop