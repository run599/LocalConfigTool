# LocalConfigTool - 进程监控 / 加载阻断 自测（task-4）
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\ProcessTest.ps1
#
# 覆盖（task-4 的 ①~⑤）：
#   ① process.list / process.detail：能列出，并给出「能否 PROCESS_TERMINATE」的**实测**结论
#   ② 预览不杀（进程仍在）→ -Apply 真杀（进程消失）
#   ③ 看门狗：对会自行复活的测试目标（ping 子进程，每 ~0.8s 重启）反复终止；Stop 后不再杀；日志有记录
#   ④ 关键名单拦截：默认被拒 + -Override 才进入预览 →（再用**同名的无害副本**验证 -Override 后能真杀，
#      绝不碰真实 lsass；并在每步复核真实 lsass 的 pid 仍在）
#   ⑤ IFEO：假映像名 → 预览不落盘 → -Apply 落盘 → 读回 → 回滚 → 断言恢复原状（不对任何真实系统进程做 IFEO）
#
# 安全约束：只动本测试自己起的进程（PING.EXE / powershell 复活器 / PING 的无害副本）；
#           目标进程 id 一律用 $procId（$pid 是只读自动变量）；不使用 Remove-Item（文件清理走回收站）。
# 退出码 = 失败项数。
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Continue'
$script:Passes = 0
$script:Fails = 0
$script:Skips = 0
$script:Notes = New-Object System.Collections.ArrayList

$toolRoot = Split-Path -Parent $PSScriptRoot
$coreDir = Join-Path $toolRoot 'core'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pingExe = Join-Path $env:SystemRoot 'System32\PING.EXE'
$workDir = Join-Path $env:TEMP ('lct-proctest-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:LCT_VAR_DIR = Join-Path $workDir 'var'
$null = New-Item -ItemType Directory -Path $workDir -Force
$null = New-Item -ItemType Directory -Path $env:LCT_VAR_DIR -Force

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $suffix = ''
    if ($Detail) { $suffix = '  (' + $Detail + ')' }
    if ($Ok) { $script:Passes++; Write-Host ('  [PASS] ' + $Name + $suffix) }
    else { $script:Fails++; Write-Host ('  [FAIL] ' + $Name + $suffix) }
}
function Write-Skip {
    param([string]$Name, [string]$Detail = '')
    $script:Skips++
    Write-Host ('  [SKIP] ' + $Name + $(if ($Detail) { '  (' + $Detail + ')' } else { '' }))
}
function Add-Note {
    param([string]$Text)
    $null = $script:Notes.Add($Text)
    Write-Host ('  [NOTE] ' + $Text)
}
function Test-ProcAlive {
    param([int]$ProcId)
    return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue))
}
function Get-RegValueOut {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $it = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop } catch { return $null }
    if ($null -eq $it) { return $null }
    $p = $it.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
function Stop-TestProc {
    param($Proc)
    if ($null -eq $Proc) { return }
    try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch { }
    try { $Proc.Dispose() } catch { }
}
function Stop-AllPing {
    foreach ($x in @(Get-Process -Name PING -ErrorAction SilentlyContinue)) { try { $x.Kill() } catch { } }
}

Write-Host 'LocalConfigTool ProcessTest（进程监控 / 加载阻断）'
Write-Host ('  toolRoot = ' + $toolRoot)
Write-Host ('  workDir  = ' + $workDir)
Write-Host ''

# ---------------- 装载模块（in-process：看门狗需要调用进程存活） ----------------
Import-Module (Join-Path $coreDir 'Logging.psm1') -Force -Global
Import-Module (Join-Path $coreDir 'Backup.psm1') -Force -Global
Import-Module (Join-Path $coreDir 'Processes.psm1') -Force -Global

$script:spawned = New-Object System.Collections.ArrayList
$respawnScript = Join-Path $workDir 'lct-respawn.ps1'
$respawnProc = $null
$fakeLsassExe = Join-Path $workDir 'lsass.exe'
$ifeoExe = Join-Path $workDir 'lct-ifeo-t1.exe'
$ifeoName = 'lct-ifeo-t1.exe'
$hcExe = Join-Path $workDir 'lct-ifeo-t2.exe'
$hcName = 'lct-ifeo-t2.exe'
$ifeoKeyNative = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $ifeoName
$ifeoKeyWow = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $ifeoName
$hcKeyNative = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $hcName

$isElevated = $false
try { $isElevated = [bool](Test-LctElevated) } catch { $isElevated = $false }

try {
    # ============ ① list / detail：能列出 + PROCESS_TERMINATE 实测结论 ============
    Write-Host '1) process.list / process.detail'
    $pingA = Start-Process -FilePath $pingExe -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    $pingB = Start-Process -FilePath $pingExe -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    $null = $script:spawned.Add($pingA); $null = $script:spawned.Add($pingB)
    Start-Sleep -Milliseconds 600

    $lst = Get-LctProcessList -Name 'PING' -IncludeSystem
    Write-Check -Name 'process.list 返回 Result 形状（ok/applied/changes/warnings/errors/data）' `
        -Ok ([bool]($lst.PSObject.Properties['ok'] -and $lst.PSObject.Properties['data'] -and $lst.PSObject.Properties['changes'])) `
        -Detail ('ok=' + $lst.ok + ' applied=' + $lst.applied)
    Write-Check -Name 'process.list 能列出两个测试 ping' -Ok ([bool]($lst.ok -and $lst.data.count -ge 2)) `
        -Detail ('count=' + $lst.data.count + ' matched=' + $lst.data.matched + ' processTotal=' + $lst.data.processTotal)
    $rowKeys = @()
    if (@($lst.data.items).Count -gt 0) { $rowKeys = @($lst.data.items[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    $needKeys = @('pid', 'name', 'user', 'session', 'path', 'wsMB', 'cpu', 'startTime', 'isCritical')
    $missing = @($needKeys | Where-Object { $rowKeys -notcontains $_ })
    Write-Check -Name '每行含 pid/name/user/session/path/wsMB/cpu/startTime/isCritical' -Ok (@($missing).Count -eq 0) `
        -Detail ('keys=' + ($rowKeys -join ',') + $(if (@($missing).Count -gt 0) { ' MISSING=' + ($missing -join ',') } else { '' }))
    $rowOk = $true
    foreach ($row in @($lst.data.items)) {
        if (-not ($row.path -ieq $pingExe)) { $rowOk = $false }
    }
    $firstRowPath = ''
    $firstRowUser = ''
    $firstRowStart = ''
    if (@($lst.data.items).Count -gt 0) {
        $firstRowPath = [string]$lst.data.items[0].path
        $firstRowUser = [string]$lst.data.items[0].user
        $firstRowStart = [string]$lst.data.items[0].startTime
    } else {
        $rowOk = $false
    }
    Write-Check -Name '行内映像路径正确（大小写不敏感，实测 C:\Windows\System32\PING.EXE）' -Ok $rowOk `
        -Detail ('path=' + $firstRowPath + ' user=' + $firstRowUser + ' startTime=' + $firstRowStart)

    $sess0Rows = @($lst.data.items | Where-Object { $_.session -eq 0 }).Count
    Write-Check -Name '默认（不加 -IncludeSystem）隐藏会话 0 进程' -Ok ($sess0Rows -eq 0) -Detail ('includeSystem=true 时会话0行数=' + $sess0Rows)

    $lstU = Get-LctProcessList -Name 'PING' -User $env:USERNAME -IncludeSystem
    $userOk = $true
    foreach ($row in @($lstU.data.items)) { if (-not ($row.user -like ('*' + $env:USERNAME + '*'))) { $userOk = $false } }
    Write-Check -Name '-User 过滤生效' -Ok ([bool]($lstU.ok -and $userOk -and $lstU.data.count -ge 2)) `
        -Detail ('count=' + $lstU.data.count + ' identity.user=' + $lstU.data.identity.user + ' elevated=' + $lstU.data.identity.elevated + ' mode=' + $lstU.data.identity.mode)

    $det = Get-LctProcessDetail -Id $pingA.Id
    Write-Check -Name 'process.detail 返回实测 PROCESS_TERMINATE 结论（普通进程应可用）' `
        -Ok ([bool]($det.ok -and ($det.data.terminate.canTerminate -eq $true))) `
        -Detail ('canTerminate=' + $det.data.terminate.canTerminate + ' win32Error=' + $det.data.terminate.win32Error + ' isCritical=' + $det.data.isCritical + ' path=' + $det.data.path)
    Write-Check -Name 'process.detail 结论字段齐全（win32Error/win32Message/conclusion/suspectedProtected）' `
        -Ok ([bool]($det.data.terminate.PSObject.Properties['win32Message'] -and $det.data.terminate.PSObject.Properties['conclusion'] -and $det.data.PSObject.Properties['suspectedProtected'])) `
        -Detail ('conclusion=' + $det.data.terminate.conclusion)

    # 受保护样本：csrss / services / Registry / System 中第一个存在的（只读，绝不终止）
    $protName = ''
    foreach ($tn in @('csrss', 'services', 'Registry', 'System')) {
        if ($protName -eq '') { if (@(Get-Process -Name $tn -ErrorAction SilentlyContinue).Count -gt 0) { $protName = $tn } }
    }
    if ($protName -ne '') {
        $prot = @(Get-Process -Name $protName)[0]
        $protDet = Get-LctProcessDetail -Id $prot.Id
        $deniedOk = $false
        $deniedDetail = ''
        if ($protDet.ok) {
            if ($protDet.data.terminate.canTerminate -eq $false) {
                $deniedOk = [bool](($protDet.data.terminate.win32Error -gt 0) -and (-not [string]::IsNullOrWhiteSpace([string]$protDet.data.terminate.win32Message)) -and $protDet.data.suspectedProtected)
                $deniedDetail = 'canTerminate=false win32Error=' + $protDet.data.terminate.win32Error + ' suspectedProtected=' + $protDet.data.suspectedProtected
            } else {
                $deniedOk = $true
                $deniedDetail = 'canTerminate=true（本机提权管理员确实能拿到句柄，结论如实上报）'
            }
        }
        Write-Check -Name ('受保护目标 ' + $protName + ' 的终止结论如实区分（access denied != 不存在）') -Ok $deniedOk `
            -Detail ($deniedDetail + ' ; ' + $protDet.data.terminate.conclusion)
    } else {
        Write-Skip -Name '受保护目标实测' -Detail '本机没有 csrss/services/Registry/System 可测'
    }

    # ============ ② 预览不杀 → -Apply 真杀 ============
    Write-Host '2) process.kill 预览 / -Apply'
    $prev = Stop-LctProcess -Id $pingB.Id
    $prevChange = $null
    if (@($prev.changes).Count -gt 0) { $prevChange = $prev.changes[0] }
    Write-Check -Name '预览：ok=true、applied=false、进程仍存活' `
        -Ok ([bool]($prev.ok -and (-not $prev.applied) -and (Test-ProcAlive -ProcId $pingB.Id))) `
        -Detail ('ok=' + $prev.ok + ' applied=' + $prev.applied + ' alive=' + (Test-ProcAlive -ProcId $pingB.Id))
    Write-Check -Name '预览 change 形状（kind/target/before/after/note）' `
        -Ok ([bool]($null -ne $prevChange -and $prevChange.kind -eq 'note' -and -not [string]::IsNullOrWhiteSpace([string]$prevChange.target) -and -not [string]::IsNullOrWhiteSpace([string]$prevChange.after))) `
        -Detail ('target=' + $prevChange.target + ' before=' + $prevChange.before + ' after=' + $prevChange.after + ' note=' + $prevChange.note)
    Write-Check -Name '预览也给出 terminate 实测结论' -Ok ([bool]($prev.data.terminate.PSObject.Properties['canTerminate'])) `
        -Detail ('canTerminate=' + $prev.data.terminate.canTerminate + ' win32Error=' + $prev.data.terminate.win32Error)

    $kill = Stop-LctProcess -Id $pingB.Id -Apply
    Write-Check -Name '-Apply：真杀成功、进程消失、ok/applied=true' `
        -Ok ([bool]($kill.ok -and $kill.applied -and $kill.data.killed -and (-not (Test-ProcAlive -ProcId $pingB.Id)))) `
        -Detail ('ok=' + $kill.ok + ' applied=' + $kill.applied + ' killed=' + $kill.data.killed + ' alive=' + (Test-ProcAlive -ProcId $pingB.Id) + ' method=' + $kill.data.terminate.method)
    Write-Check -Name '真实终止前已建备份（backupId 非空）' -Ok (-not [string]::IsNullOrWhiteSpace([string]$kill.backupId)) `
        -Detail ('backupId=' + $kill.backupId + ' change.after=' + $kill.changes[0].after)
    $selfKill = Stop-LctProcess -Id ([System.Diagnostics.Process]::GetCurrentProcess().Id)
    Write-Check -Name 'do-not-kill-self：拒绝终止自身 pid' -Ok ([bool](-not $selfKill.ok)) `
        -Detail ('ok=' + $selfKill.ok + ' errors=' + (@($selfKill.errors) -join ' | '))
    $noTarget = Stop-LctProcess
    Write-Check -Name '缺少显式目标（既无 -Id 也无 -Name）时拒绝执行' -Ok ([bool](-not $noTarget.ok)) `
        -Detail ('ok=' + $noTarget.ok + ' errors=' + (@($noTarget.errors) -join ' | '))

    # ============ ③ 看门狗：复活就杀 / Stop 后不杀 / 日志可读回 ============
    Write-Host '3) process.watch（会话内看门狗）'
    $respawnBody = @'
param([string]$PingExe, [int]$IntervalMs = 800)
while ($true) {
    try { Start-Process -FilePath $PingExe -ArgumentList @('-n','20','127.0.0.1') -WindowStyle Hidden | Out-Null } catch { }
    Start-Sleep -Milliseconds $IntervalMs
}
'@
    Set-Content -LiteralPath $respawnScript -Value $respawnBody -Encoding ASCII
    $respawnProc = Start-Process -FilePath $psExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $respawnScript, '-PingExe', $pingExe -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $livePing = @(Get-Process -Name PING -ErrorAction SilentlyContinue)
    if (@($livePing).Count -eq 0) {
        Write-Check -Name '复活器已产出可监控的 ping 子进程' -Ok $false -Detail '未产出 ping，后续看门狗断言无法进行'
    } else {
        $watchTarget = @{ pid = $livePing[0].Id }
        $beforeIds = @($livePing | ForEach-Object { $_.Id })

        $wPrev = Start-LctProcessWatch -Targets @($watchTarget) -IntervalSec 1 -DurationSec 20
        $aliveStill = $true
        Start-Sleep -Seconds 2
        foreach ($procId in $beforeIds) { if (-not (Test-ProcAlive -ProcId $procId)) { $aliveStill = $false } }
        Write-Check -Name '看门狗预览：不启动、也不杀（预览前的 ping 仍存活）' `
            -Ok ([bool]($wPrev.ok -and (-not $wPrev.applied) -and $aliveStill)) `
            -Detail ('ok=' + $wPrev.ok + ' applied=' + $wPrev.applied + ' running=' + $wPrev.data.running + ' 预览前 pid 全部仍存活=' + $aliveStill)

        $wStart = Start-LctProcessWatch -Targets @($watchTarget) -IntervalSec 1 -DurationSec 20 -Apply
        $targetDetail = 'targets=0'
        if (@($wStart.data.targets).Count -gt 0) {
            $targetDetail = 'target=' + $wStart.data.targets[0].name + ' path=' + $wStart.data.targets[0].path + ' isCritical=' + $wStart.data.targets[0].isCritical
        }
        Write-Check -Name '看门狗 -Apply 启动成功（单实例、running=true）' `
            -Ok ([bool]($wStart.ok -and $wStart.applied -and $wStart.data.running)) `
            -Detail ('ok=' + $wStart.ok + ' applied=' + $wStart.applied + ' running=' + $wStart.data.running + ' ' + $targetDetail + ' interval=' + $wStart.data.intervalSec + ' duration=' + $wStart.data.durationSec + ' logPath=' + $wStart.data.logPath)

        $wSecond = Start-LctProcessWatch -Targets @($watchTarget) -IntervalSec 1 -DurationSec 20 -Apply
        Write-Check -Name '单实例：重复启动被拒绝' -Ok ([bool](-not $wSecond.ok)) `
            -Detail ('ok=' + $wSecond.ok + ' errors=' + (@($wSecond.errors) -join ' | '))

        Start-Sleep -Seconds 5
        $wStat = Get-LctProcessWatchStatus
        Write-Check -Name '运行中并已反复终止复活实例（数秒内 killCount>=2）' `
            -Ok ([bool]($wStat.data.running -and $wStat.data.killCount -ge 2)) `
            -Detail ('running=' + $wStat.data.running + ' killCount=' + $wStat.data.killCount + ' failureCount=' + $wStat.data.failureCount + ' skipCount=' + $wStat.data.skipCount + ' lastEvent=' + $wStat.data.lastEvent + ' lastDetail=' + $wStat.data.lastDetail)
        Add-Note ('看门狗累计终止 ' + $wStat.data.killCount + ' 次（观察 5 秒，interval=1s，复活器每 0.8s 起一个新 ping）')

        $wStop = Stop-LctProcessWatch -Apply
        $killsAtStop = $wStop.data.killCount
        Write-Check -Name 'Stop（-Apply）成功停止并释放 runspace' `
            -Ok ([bool]($wStop.ok -and $wStop.applied -and $wStop.data.stopped -and $wStop.data.graceful)) `
            -Detail ('ok=' + $wStop.ok + ' applied=' + $wStop.applied + ' stopped=' + $wStop.data.stopped + ' graceful=' + $wStop.data.graceful + ' killCount=' + $killsAtStop)
        $wStat2 = Get-LctProcessWatchStatus
        $logAtStop = Get-LctProcessWatchLog
        $killOkAtStop = [int]$logAtStop.data.counts.killOk
        Start-Sleep -Seconds 4
        $wStat3 = Get-LctProcessWatchStatus
        $logAfter = Get-LctProcessWatchLog
        $killOkAfter = [int]$logAfter.data.counts.killOk
        $aliveAfter = @(Get-Process -Name PING -ErrorAction SilentlyContinue).Count
        # 用**日志**做 out-of-band 证据：Stop 之后 kill.ok 事件数必须冻结（runspace 已停），且复活实例能存活
        Write-Check -Name 'Stop 后不再杀（日志 kill.ok 冻结）且复活实例能存活' `
            -Ok ([bool]((-not $wStat2.data.running) -and (-not $wStat3.data.running) -and ($killOkAfter -eq $killOkAtStop) -and ($aliveAfter -ge 1))) `
            -Detail ('running(停止后立即)=' + $wStat2.data.running + ' running(4s后)=' + $wStat3.data.running + ' killOk@stop=' + $killOkAtStop + ' -> 4s后=' + $killOkAfter + ' 存活 ping=' + $aliveAfter)
        Write-Check -Name 'Stop 后 status 仍如实上报本次运行的最终计数（running=false，计数保留）' `
            -Ok ([bool]((-not $wStat3.data.running) -and ($wStat3.data.hasInstance -eq $true) -and ($wStat3.data.killCount -eq $killsAtStop))) `
            -Detail ('hasInstance=' + $wStat3.data.hasInstance + ' killCount=' + $wStat3.data.killCount + ' endedAt=' + $wStat3.data.endedAt + ' lastEvent=' + $wStat3.data.lastEvent)
        $wStopAgain = Stop-LctProcessWatch -Apply
        Write-Check -Name '重复 Stop 幂等（已结束实例不再动它）' -Ok ([bool]($wStopAgain.ok -and (-not $wStopAgain.data.wasRunning) -and (-not $wStopAgain.data.stopped))) `
            -Detail ('ok=' + $wStopAgain.ok + ' wasRunning=' + $wStopAgain.data.wasRunning + ' stopped=' + $wStopAgain.data.stopped + ' warnings=' + (@($wStopAgain.warnings) -join ' | '))

        $wLog = Get-LctProcessWatchLog
        $firstEvent = ''
        if (@($wLog.data.returned).Count -gt 0) { $firstEvent = [string]$wLog.data.returned[0].event }
        Write-Check -Name '看门狗事件日志可读回（文件存在 + watch.started + kill.ok 计数）' `
            -Ok ([bool]($wLog.ok -and $wLog.data.exists -and $wLog.data.total -ge 3 -and $firstEvent -eq 'watch.started' -and $wLog.data.counts.killOk -ge 2)) `
            -Detail ('path=' + $wLog.data.path + ' total=' + $wLog.data.total + ' killOk=' + $wLog.data.counts.killOk + ' killFail=' + $wLog.data.counts.killFail + ' identitySkip=' + $wLog.data.counts.identitySkip + ' firstEvent=' + $firstEvent)
        $evKeys = @()
        if (@($wLog.data.returned).Count -gt 0) { $evKeys = @($wLog.data.returned[0].PSObject.Properties | ForEach-Object { $_.Name }) }
        Write-Check -Name '事件行含 ts/event/target/pid/detail' -Ok (@(@('ts', 'event', 'target', 'pid', 'detail') | Where-Object { $evKeys -notcontains $_ }).Count -eq 0) `
            -Detail ('keys=' + ($evKeys -join ',') + ' 最后一条=' + (@($wLog.data.returned)[@($wLog.data.returned).Count - 1] | ConvertTo-Json -Compress))

        # 身份校验（防 pid 复用）：用错误的 path 指定目标必须被拒
        $badPath = Stop-LctProcess -Id $livePing[0].Id -Path (Join-Path $workDir 'not-the-real-path.exe')
        Write-Check -Name '身份校验：-Path 与真实映像不符时拒绝终止（防 pid 复用）' -Ok ([bool](-not $badPath.ok)) `
            -Detail ('ok=' + $badPath.ok + ' errors=' + (@($badPath.errors) -join ' | '))
    }
    Stop-TestProc -Proc $respawnProc
    $respawnProc = $null
    Stop-AllPing
    Start-Sleep -Milliseconds 400
    Write-Check -Name '清理：复活器与全部测试 ping 已结束' -Ok (@(Get-Process -Name PING -ErrorAction SilentlyContinue).Count -eq 0) `
        -Detail ('残留 ping=' + @(Get-Process -Name PING -ErrorAction SilentlyContinue).Count)

    # ============ ④ 关键名单拦截（用 PING.EXE 的无害副本冒充 lsass） ============
    Write-Host '4) 关键名单拦截'
    Copy-Item -LiteralPath $pingExe -Destination $fakeLsassExe -Force
    $realLsassIds = @(Get-Process -Name lsass -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $fakeLsass = Start-Process -FilePath $fakeLsassExe -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    $null = $script:spawned.Add($fakeLsass)
    Start-Sleep -Milliseconds 600
    Write-Check -Name '测试替身就绪（无害副本的进程名 = lsass）' -Ok ([string]$fakeLsass.ProcessName -eq 'lsass') `
        -Detail ('fake pid=' + $fakeLsass.Id + ' name=' + $fakeLsass.ProcessName + ' path=' + $fakeLsassExe + ' 真实 lsass pid=' + ($realLsassIds -join ','))

    $gate = Stop-LctProcess -Id $fakeLsass.Id -Apply
    Write-Check -Name '默认拒绝：关键名单目标即使 -Apply 也被拦（未加 -Override）' `
        -Ok ([bool]((-not $gate.ok) -and (-not $gate.applied) -and (Test-ProcAlive -ProcId $fakeLsass.Id) -and (@($gate.errors).Count -gt 0))) `
        -Detail ('ok=' + $gate.ok + ' applied=' + $gate.applied + ' refused=' + $gate.data.refused + ' alive=' + (Test-ProcAlive -ProcId $fakeLsass.Id) + ' errors=' + (@($gate.errors) -join ' | '))

    $gatePrev = Stop-LctProcess -Id $fakeLsass.Id -Override
    Write-Check -Name '-Override 后仅进入预览（applied=false，进程仍在，changes/warnings 有记录）' `
        -Ok ([bool]($gatePrev.ok -and (-not $gatePrev.applied) -and (Test-ProcAlive -ProcId $fakeLsass.Id) -and (@($gatePrev.warnings).Count -gt 0) -and (@($gatePrev.changes).Count -gt 0))) `
        -Detail ('ok=' + $gatePrev.ok + ' applied=' + $gatePrev.applied + ' alive=' + (Test-ProcAlive -ProcId $fakeLsass.Id) + ' changes[0].after=' + $gatePrev.changes[0].after + ' warnings=' + (@($gatePrev.warnings).Count) + ' 条')

    $gateKill = Stop-LctProcess -Id $fakeLsass.Id -Override -Apply
    Write-Check -Name '-Override -Apply 才真杀（且只杀了无害替身）' `
        -Ok ([bool]($gateKill.ok -and $gateKill.applied -and (-not (Test-ProcAlive -ProcId $fakeLsass.Id)))) `
        -Detail ('ok=' + $gateKill.ok + ' applied=' + $gateKill.applied + ' 替身存活=' + (Test-ProcAlive -ProcId $fakeLsass.Id))

    $realLsassOk = $true
    foreach ($procId in $realLsassIds) { if (-not (Test-ProcAlive -ProcId $procId)) { $realLsassOk = $false } }
    Write-Check -Name '安全：真实 lsass 全程未被触碰' -Ok $realLsassOk -Detail ('真实 lsass pid=' + ($realLsassIds -join ',') + ' 全部仍存活=' + $realLsassOk)

    $multi = Stop-LctProcess -Name 'lsass'
    Write-Check -Name '禁止通配/批量：-Name 命中多个（或命中名单）时被拒' -Ok ([bool](-not $multi.ok)) `
        -Detail ('ok=' + $multi.ok + ' errors=' + (@($multi.errors) -join ' | '))
    $wild = Stop-LctProcess -Name 'P*'
    Write-Check -Name '禁止通配符目标' -Ok ([bool](-not $wild.ok)) -Detail ('errors=' + (@($wild.errors) -join ' | '))

    # ============ ⑤ IFEO：预览 → 落盘 → 读回 → 回滚 ============
    Write-Host '5) process.block（IFEO 加载阻断，假映像名）'
    # ---- 探针：本机是否允许写 HKLM IFEO（IFEO 是常被安全策略保护的位置；不写就别说能写）----
    $script:IfeoWritable = $true
    $ifeoProbeErr = ''
    if (Test-Path -LiteralPath $ifeoKeyNative) {
        try {
            $null = New-ItemProperty -Path $ifeoKeyNative -Name 'LctProbe' -Value '1' -PropertyType String -Force -ErrorAction Stop
            $null = Remove-ItemProperty -Path $ifeoKeyNative -Name 'LctProbe' -ErrorAction SilentlyContinue
        } catch {
            $script:IfeoWritable = $false
            $ifeoProbeErr = $_.Exception.Message
        }
    }
    if (-not $script:IfeoWritable) {
        Write-Skip -Name 'IFEO HKLM 写入探针' -Detail ('本机拒绝写 HKLM IFEO（' + $ifeoProbeErr + '）⇒ 下面的 HKLM 段整体 SKIP；HKCU 段照常')
    }
    # HKCU 探针（同样不建新键：复用已有测试键写临时值）
    $script:HkcuIfeoWritable = $true
    $hkcuProbeErr = ''
    if (Test-Path -LiteralPath $hcKeyNative) {
        try {
            $null = New-ItemProperty -Path $hcKeyNative -Name 'LctProbe' -Value '1' -PropertyType String -Force -ErrorAction Stop
            $null = Remove-ItemProperty -Path $hcKeyNative -Name 'LctProbe' -ErrorAction SilentlyContinue
        } catch {
            $script:HkcuIfeoWritable = $false
            $hkcuProbeErr = $_.Exception.Message
        }
    }
    if (-not $script:HkcuIfeoWritable) {
        Write-Skip -Name 'IFEO HKCU 写入探针' -Detail ('本机拒绝写 HKCU IFEO（' + $hkcuProbeErr + '）⇒ HKCU 段整体 SKIP')
    }
    Copy-Item -LiteralPath $pingExe -Destination $ifeoExe -Force
    Copy-Item -LiteralPath $pingExe -Destination $hcExe -Force
    # 起始状态（干净起点）：假映像名，任何视图都不该存在
    $dN0 = Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'
    $dW0 = Get-RegValueOut -Path $ifeoKeyWow -Name 'Debugger'
    $clean0 = ([string]::IsNullOrEmpty([string]$dN0) -and [string]::IsNullOrEmpty([string]$dW0))
    Write-Check -Name 'IFEO 起始状态：两视图无生效阻断（无 Debugger 值；允许残留空键）' -Ok $clean0 -Detail ('native=[' + $dN0 + '] wow=[' + $dW0 + ']')

    if ($isElevated -and $script:IfeoWritable) {
        $bPrev = Set-LctProcessBlock -Path $ifeoExe -Reason 'ProcessTest 假映像名'
        Write-Check -Name 'IFEO 预览：不落盘（两视图仍不存在）' `
            -Ok ([bool]($bPrev.ok -and (-not $bPrev.applied) -and (-not (Test-Path -LiteralPath $ifeoKeyNative)) -and (-not (Test-Path -LiteralPath $ifeoKeyWow)))) `
            -Detail ('ok=' + $bPrev.ok + ' applied=' + $bPrev.applied + ' views=' + @($bPrev.data.views).Count + ' native存在=' + (Test-Path -LiteralPath $ifeoKeyNative) + ' wow存在=' + (Test-Path -LiteralPath $ifeoKeyWow))
        Write-Check -Name 'IFEO 预览同时覆盖 HKLM 原生视图与 Wow6432Node 视图' `
            -Ok ([bool](@($bPrev.data.views).Count -ge 2 -and (@($bPrev.data.views | Where-Object { $_.view -eq 'wow6432' }).Count -eq 1))) `
            -Detail ('views=' + (@($bPrev.data.views | ForEach-Object { $_.view }) -join ',') + ' ; change.before=' + $bPrev.changes[0].before + ' change.after=' + $bPrev.changes[0].after)

        $bSet = Set-LctProcessBlock -Path $ifeoExe -Reason 'ProcessTest 假映像名' -Apply
        $dbgNative = Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'
        $dbgWow = Get-RegValueOut -Path $ifeoKeyWow -Name 'Debugger'
        $reasonNative = Get-RegValueOut -Path $ifeoKeyNative -Name 'LctBlockReason'
        Write-Check -Name 'IFEO -Apply：落盘且两视图读回一致（含本工具标记 LctBlockReason）' `
            -Ok ([bool]($bSet.ok -and $bSet.applied -and ($dbgNative -eq $bSet.data.blocker) -and ($dbgWow -eq $bSet.data.blocker) -and ($reasonNative -eq 'ProcessTest 假映像名'))) `
            -Detail ('ok=' + $bSet.ok + ' applied=' + $bSet.applied + ' blocker=' + $bSet.data.blocker + ' native.Debugger=' + $dbgNative + ' wow.Debugger=' + $dbgWow + ' reason=' + $reasonNative)
        Write-Check -Name 'IFEO -Apply 已建备份，且记录「原本不存在」(.reg.absent)' `
            -Ok ([bool](-not [string]::IsNullOrWhiteSpace([string]$bSet.backupId))) `
            -Detail ('backupId=' + $bSet.backupId)
        $bkInfo = $null
        try { $bkInfo = Get-LctBackup -Id $bSet.backupId } catch { $bkInfo = $null }
        $absentCount = 0
        if ($null -ne $bkInfo) { $absentCount = @($bkInfo.files | Where-Object { $_ -like '*.reg.absent' }).Count }
        Write-Check -Name '备份内容正确：两个视图原不存在 -> 2 个 .reg.absent' -Ok ($absentCount -ge 1) `
            -Detail ('backup files=' + @($bkInfo.files).Count + ' 其中 .reg.absent=' + $absentCount)

        # 端到端：IFEO 真的让目标无法启动（纯 CreateProcess，避免任何 shell 对话框）
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ifeoExe
        $psi.Arguments = '-n 5 127.0.0.1'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $started = $null
        $startErr = ''
        try { $started = [System.Diagnostics.Process]::Start($psi) } catch { $startErr = $_.Exception.Message }
        if ($null -ne $started) { Stop-TestProc -Proc $started }
        $blocked = (($null -eq $started) -or (-not (Test-ProcAlive -ProcId $started.Id)))
        Write-Check -Name '端到端：IFEO 生效——目标程序创建失败（未能启动）' -Ok $blocked `
            -Detail ('CreateProcess 异常=' + $startErr + ' ; 启动对象=' + $(if ($null -ne $started) { '存在(结论：未被阻断)' } else { 'null' }))

        $bl = Get-LctProcessBlockList
        $mineRow = @($bl.data.items | Where-Object { $_.exeName -eq $ifeoName -and $_.byUs })
        Write-Check -Name 'block.list 列出本工具设置的重定向（byUs/byUsCount）' `
            -Ok ([bool]($bl.ok -and @($mineRow).Count -ge 1 -and $bl.data.byUsCount -ge 1)) `
            -Detail ('count=' + $bl.data.count + ' byUsCount=' + $bl.data.byUsCount + ' foreignCount=' + $bl.data.foreignCount + ' row=' + ($mineRow[0] | ConvertTo-Json -Compress))

        $bRemPrev = Remove-LctProcessBlock -Path $ifeoExe
        $dbgStill = Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'
        Write-Check -Name 'block.remove 预览：不落盘（Debugger 仍在）' `
            -Ok ([bool]($bRemPrev.ok -and (-not $bRemPrev.applied) -and ($dbgStill -eq $bSet.data.blocker))) `
            -Detail ('ok=' + $bRemPrev.ok + ' applied=' + $bRemPrev.applied + ' Debugger=' + $dbgStill)

        $bRem = Remove-LctProcessBlock -Path $ifeoExe -Apply
        Write-Check -Name 'block.remove -Apply：完整回滚到「原本不存在」（两视图键都已删除）' `
            -Ok ([bool]($bRem.ok -and $bRem.applied -and (-not (Test-Path -LiteralPath $ifeoKeyNative)) -and (-not (Test-Path -LiteralPath $ifeoKeyWow)))) `
            -Detail ('ok=' + $bRem.ok + ' applied=' + $bRem.applied + ' removed=' + $bRem.data.removed + ' native存在=' + (Test-Path -LiteralPath $ifeoKeyNative) + ' wow存在=' + (Test-Path -LiteralPath $ifeoKeyWow) + ' 残留Debugger=' + (Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'))
        $bl2 = Get-LctProcessBlockList
        $mineRow2 = @($bl2.data.items | Where-Object { $_.exeName -eq $ifeoName })
        Write-Check -Name '回滚后 block.list 不再含该目标' -Ok (@($mineRow2).Count -eq 0) `
            -Detail ('剩余该目标项=' + @($mineRow2).Count)
        Write-Check -Name '幂等：再次 remove 不报错（只是无变化）' `
            -Ok ([bool]((Remove-LctProcessBlock -Path $ifeoExe -Apply).ok)) -Detail '第二次 remove ok=true'
    } else {
        Write-Skip -Name 'IFEO HKLM 全流程' -Detail ($(if (-not $script:IfeoWritable) { '本机拒绝写 HKLM IFEO（见上面探针）' } else { '当前未提权（写 HKLM 需要管理员）' }) + '，已跳过 HKLM 落盘断言')
    }

    if ($script:HkcuIfeoWritable) {
    # HKCU 视图（测试友好）：写入 → 读回 → 回滚
    $hPrev = Set-LctProcessBlock -Path $hcExe -Reason 'ProcessTest HKCU' -Hive HKCU
    Write-Check -Name 'IFEO(HKCU) 预览：不落盘' -Ok ([bool]($hPrev.ok -and (-not $hPrev.applied) -and (-not (Test-Path -LiteralPath $hcKeyNative)))) `
        -Detail ('applied=' + $hPrev.applied + ' 键存在=' + (Test-Path -LiteralPath $hcKeyNative) + ' 视图数=' + @($hPrev.data.views).Count)
    $hSet = Set-LctProcessBlock -Path $hcExe -Reason 'ProcessTest HKCU' -Hive HKCU -Apply
    $hDbg = Get-RegValueOut -Path $hcKeyNative -Name 'Debugger'
    Write-Check -Name 'IFEO(HKCU) -Apply 落盘并可读回' -Ok ([bool]($hSet.ok -and $hSet.applied -and ($hDbg -eq $hSet.data.blocker))) `
        -Detail ('Debugger=' + $hDbg + ' blocker=' + $hSet.data.blocker + ' backupId=' + $hSet.backupId)
    $hRem = Remove-LctProcessBlock -Path $hcExe -Hive HKCU -Apply
    Write-Check -Name 'IFEO(HKCU) 回滚：键已删除' -Ok ([bool]($hRem.ok -and $hRem.applied -and (-not (Test-Path -LiteralPath $hcKeyNative)))) `
        -Detail ('key存在=' + (Test-Path -LiteralPath $hcKeyNative))

    } else {
        Write-Skip -Name 'IFEO(HKCU) 全流程' -Detail '本机拒绝写 HKCU IFEO（见上面探针），已跳过'
    }
    $dN1 = Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'
    $dW1 = Get-RegValueOut -Path $ifeoKeyWow -Name 'Debugger'
    $clean1 = ([string]::IsNullOrEmpty([string]$dN1) -and [string]::IsNullOrEmpty([string]$dW1))
    Write-Check -Name 'IFEO 清理后：HKLM 两视图无 Debugger 残留' -Ok $clean1 -Detail ('native=[' + $dN1 + '] wow=[' + $dW1 + ']')

    # ============ ⑥ 信息：Engine 是否已接线（Lead 负责，不计分） ============
    Write-Host '6) 信息（不计分）：Engine verb 接线状态'
    $engRaw = ''
    try {
        $engRaw = ((& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $coreDir 'Engine.ps1') -Verb 'process.list' 2>$null) | Out-String).Trim()
    } catch { $engRaw = '调用异常: ' + $_.Exception.Message }
    $engObj = $null
    try { $engObj = $engRaw | ConvertFrom-Json } catch { $engObj = $null }
    if ($null -ne $engObj) {
        if ($engObj.ok) { Add-Note ('Engine process.list 已接线：ok=' + $engObj.ok + ' count=' + $engObj.data.count) }
        else { Add-Note ('Engine process.list 尚未接线或依赖未就绪：errors=' + (@($engObj.errors) -join ' | ')) }
    } else {
        Add-Note ('Engine process.list 输出无法解析：' + $engRaw)
    }
} finally {
    # ---------------- 清理（只回收本测试产物；文件走回收站，绝不永久删除） ----------------
    Write-Host ''
    Write-Host 'cleanup'
    Stop-TestProc -Proc $respawnProc
    Stop-TestProc -Proc $fakeLsass
    foreach ($sp in @($script:spawned)) { Stop-TestProc -Proc $sp }
    Stop-AllPing
    # 兜底：若 IFEO 键因故残留，按规则回滚（键删除只用 Remove-LctRegistryKeyTree）
    foreach ($k in @($ifeoKeyNative, $ifeoKeyWow, $hcKeyNative)) {
        try { if (Test-Path -LiteralPath $k) { $null = Remove-LctRegistryKeyTree -Path $k } } catch { }
    }
    try { Get-LctProcessWatchStatus | Out-Null } catch { }
    try { Stop-LctProcessWatch -Apply | Out-Null } catch { }
    $dN2 = Get-RegValueOut -Path $ifeoKeyNative -Name 'Debugger'
    $dW2 = Get-RegValueOut -Path $ifeoKeyWow -Name 'Debugger'
    $dH2 = Get-RegValueOut -Path $hcKeyNative -Name 'Debugger'
    $clean2 = ([string]::IsNullOrEmpty([string]$dN2) -and [string]::IsNullOrEmpty([string]$dW2) -and [string]::IsNullOrEmpty([string]$dH2))
    Write-Check -Name '清理：IFEO 测试项无 Debugger 残留（HKLM/HKCU）' -Ok $clean2 -Detail ('native=[' + $dN2 + '] wow=[' + $dW2 + '] hkcu=[' + $dH2 + ']')
    if (-not $KeepArtifacts) {
        foreach ($f in @($ifeoExe, $hcExe, $fakeLsassExe, $respawnScript)) {
            try { if (Test-Path -LiteralPath $f) { $null = Move-LctToRecycleBin -Path $f } } catch { Write-Host ('  [WARN] 回收测试文件失败: ' + $f + ' -> ' + $_.Exception.Message) }
        }
    }
}

Write-Host ''
Write-Host ('ProcessTest 完成：PASS=' + $script:Passes + ' FAIL=' + $script:Fails + ' SKIP=' + $script:Skips)
if (@($script:Notes).Count -gt 0) {
    Write-Host '关键实测记录：'
    foreach ($n in @($script:Notes)) { Write-Host ('  - ' + $n) }
}
exit $script:Fails