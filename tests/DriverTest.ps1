# =====================================================================
# LocalConfigTool - tests\DriverTest.ps1
# 职责：task-1（自定义驱动加载模块）自测
#
# 铁律（本文件的核心约束）：
#   * **绝不允许加载任何真实内核代码**：全程只用「无效镜像」（把一段文本存成 .sys），
#     断言拿到的是操作系统自己的拒绝原文（实测 error 193 / 577 等），
#     并断言服务项与系统状态**零残留**。
#   * 需要动系统的只有注册 → 启动 → 卸载这一条链路，跑完必须把服务项删干净
#     （末尾还有一道兜底卸载）。
#   * **不真的改 testsigning**（会牵动启动配置）：只断言预览 applied=false 与
#     「Secure Boot=True 会拒绝开启」的纯判定函数。
#   * 不改任何 .sys 文件；卸载后断言原始的 .sys 仍在（本工具绝不删驱动文件）。
#
# 运行：powershell -NoProfile -ExecutionPolicy Bypass -File tests\DriverTest.ps1
# 退出码 = 失败断言数（0 = 全绿）
# =====================================================================
param([switch]$Quiet)

$script:Pass = 0
$script:Fail = 0
$script:Lines = New-Object System.Collections.ArrayList

function Section([string]$Title) {
    if (-not $Quiet) { Write-Host ''; Write-Host ('== ' + $Title) }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = '[FAIL] '
    if ($Ok) { $tag = '[PASS] '; $script:Pass++ } else { $script:Fail++ }
    $line = $tag + $Name
    if (-not [string]::IsNullOrEmpty($Detail)) { $line = $line + '  -> ' + $Detail }
    if (-not $Quiet) { Write-Host $line }
    $null = $script:Lines.Add($line)
}
function Skip([string]$Name, [string]$Why) {
    $line = '[SKIP] ' + $Name + '  -> ' + $Why
    if (-not $Quiet) { Write-Host $line }
    $null = $script:Lines.Add($line)
}
function Short([string]$Text, [int]$Max = 160) {
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '...' }
    return $t
}
function Joined($Items) { return (Short ((@($Items | ForEach-Object { [string]$_ }) -join ' / '))) }

$root = Split-Path -Parent $PSScriptRoot
$ErrorActionPreference = 'Continue'

# ---------- 隔离环境（先设 LCT_VAR_DIR 再碰任何模块函数）----------
$testId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$varDir = Join-Path $env:TEMP ('lct-driver-test-' + $testId)
$workDir = Join-Path $varDir 'work'
foreach ($d in @($varDir, $workDir)) { if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force } }
$env:LCT_VAR_DIR = $varDir

# 无效镜像：一段文本，**不是有效 PE**，永远不可能被内核接受
$badSys = Join-Path $workDir 'lctdrv-bad.sys'
[IO.File]::WriteAllText($badSys, ("LocalConfigTool invalid driver image - never a valid PE`r`n" + ('X' * 64) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$badSize = (Get-Item -LiteralPath $badSys).Length
$diskSys = Join-Path $env:SystemRoot 'System32\drivers\disk.sys'
$svcName = 'lctdrv-bad'
$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $svcName

function Get-RegValueSafe {
    param([string]$Key, [string]$ValueName)
    try { return (Get-ItemProperty -LiteralPath $Key -Name $ValueName -ErrorAction Stop).$ValueName } catch { return $null }
}
function Get-DriverSnapshot {
    $cim = -1
    try { $cim = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop).Count } catch { $cim = -1 }
    $keys = New-Object System.Collections.ArrayList
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
            $nm = [string]$k.PSChildName
            if ($nm -like 'lctdrv*' -or $nm -like 'lctprobe*') { $null = $keys.Add($nm) }
        }
    } catch { }
    return [pscustomobject]@{ cimDriverCount = $cim; probeKeys = @($keys) }
}

# ---------- 装载模块 ----------
$loadError = ''
try {
    Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $root 'core\Backup.psm1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $root 'core\Drivers.psm1') -Force -Global -ErrorAction Stop
} catch { $loadError = $_.Exception.Message }
if ($loadError -ne '') {
    Write-Host ('FATAL: 模块装载失败: ' + $loadError)
    exit 99
}

$elevated = $false
try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
Write-Host ('DriverTest: varDir=' + $varDir)
Write-Host ('DriverTest: 无效镜像=' + $badSys + ' (' + $badSize + ' 字节)  elevated=' + $elevated)

# ---------- 跑测前的兜底清理（清掉此前遗留的 lctdrv*/lctprobe*，保证"零残留"断言公平）----------
$leftovers = @(Get-DriverSnapshot).probeKeys
if (@($leftovers).Count -gt 0) {
    Write-Host ('DriverTest: 发现遗留服务项，先清理：' + (@($leftovers) -join ', '))
    foreach ($nm in @($leftovers)) {
        try { Remove-LctDriverService -Name $nm -Apply | Out-Null } catch { Write-Host ('  cleanup failed: ' + $nm + ' ' + $_.Exception.Message) }
    }
}
$before = Get-DriverSnapshot
Write-Host ('DriverTest: 基线 Win32_SystemDriver 数量=' + $before.cimDriverCount + '；遗留 probe 键=' + (@($before.probeKeys).Count))

# =====================================================================
Section '⓪ 导出签名与 Engine 接线口径（参数名逐字一致）'

$exported = @(Get-Command -Module Drivers | Select-Object -ExpandProperty Name | Sort-Object)
$expectExports = @('Get-LctDriverFileInfo', 'Get-LctDriverList', 'Get-LctDriverStatus', 'Get-LctDriverVerification',
    'Load-LctDriver', 'Remove-LctDriverService', 'Set-LctDriverTestSigning', 'Start-LctDriver', 'Stop-LctDriver',
      'Invoke-LctDriverUse', 'Invoke-LctDriverRelease', 'Invoke-LctDriverCleanup')
Check '⓪ 导出函数 = 契约 §12.3 的 9 个 + 操作级简化 3 个（共 12）' (@($exported).Count -eq @($expectExports).Count -and (@($expectExports | Where-Object { $exported -notcontains $_ }).Count -eq 0)) (@($exported) -join ', ')

$sigChecks = @(
    @{ fn = 'Get-LctDriverStatus'; ps = @() },
    @{ fn = 'Get-LctDriverList'; ps = @('Name') },
    @{ fn = 'Get-LctDriverFileInfo'; ps = @('Path') },
    @{ fn = 'Load-LctDriver'; ps = @('Path', 'Name', 'StartType', 'Stage', 'Override', 'Apply') },
    @{ fn = 'Start-LctDriver'; ps = @('Name', 'Apply') },
    @{ fn = 'Stop-LctDriver'; ps = @('Name', 'Apply') },
    @{ fn = 'Remove-LctDriverService'; ps = @('Name', 'Apply') },
    @{ fn = 'Set-LctDriverTestSigning'; ps = @('Enable', 'Disable', 'Apply') },
    @{ fn = 'Get-LctDriverVerification'; ps = @('Name') }
)
foreach ($sc in $sigChecks) {
    $cmd = Get-Command $sc.fn -ErrorAction SilentlyContinue
    $missing = @()
    foreach ($p in @($sc.ps)) { if (@($cmd.Parameters.Keys) -notcontains $p) { $missing += $p } }
    $extra = @()
    if ($cmd) { foreach ($p in @($cmd.Parameters.Keys)) { if (@($sc.ps) -notcontains $p) { $extra += $p } } }
    Check ('⓪ ' + $sc.fn + ' 参数名/个数逐字一致') (($null -ne $cmd) -and (@($missing).Count -eq 0) -and (@($extra).Count -eq 0)) ('missing=' + (@($missing) -join ',') + ' extra=' + (@($extra) -join ',') + ' have=' + (@($cmd.Parameters.Keys) -join ','))
}

# =====================================================================
Section '① 只读 getter（status / list / fileInfo；不做签名门槛）'

$st = Get-LctDriverStatus
$sbProbe = $null
try { $sbProbe = [bool](Confirm-SecureBootUEFI) } catch { $sbProbe = $null }
Check '① status.secureBoot 与独立探测一致' (($null -eq $sbProbe) -or ([bool]$st.secureBoot -eq $sbProbe)) ('status=' + $st.secureBoot + ' probe=' + $sbProbe + ' source=' + $st.secureBootSource)
$bcdText = ''
try { $bcdText = ((& (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /enum '{current}' 2>&1) | Out-String) } catch { }
$tsMatch = ([regex]::Match($bcdText, '(?im)^\s*testsigning\s+(\S+)')).Groups[1].Value
Check '① status.testSigning 与 bcdedit 原文一致' ([string]$st.testSigning -eq [string]$tsMatch) ('status=' + $st.testSigning + ' bcdedit=' + $tsMatch + ' source=' + $st.testSigningSource)
Check '① status 带 testsigning 原文行' (@($st.testSigningBcdLines) -join ' ' -match 'testsigning') (Joined $st.testSigningBcdLines)
Check '① status.noIntegrityChecks 已读取' ([string]$st.noIntegrityChecks -ne '') ('value=' + $st.noIntegrityChecks + ' source=' + $st.noIntegrityChecksSource)
$cimCount = @(Get-CimInstance Win32_SystemDriver).Count
Check '① status.driverTotal = Win32_SystemDriver 实际条数' ([int]$st.driverTotal -eq $cimCount) ('status=' + $st.driverTotal + ' cim=' + $cimCount)
Check '① status.driverRunning 在 0..total 之间' ([int]$st.driverRunning -ge 0 -and [int]$st.driverRunning -le [int]$st.driverTotal) ('running=' + $st.driverRunning)
Check '① status.vbs.status / hvciRunning 已读取' (($null -ne $st.vbs.status) -and ($null -ne $st.vbs.hvciRunning)) ('vbs=' + $st.vbs.statusText + ' hvciRunning=' + $st.vbs.hvciRunning)
Check '① status.driversDirectory 指向 System32\drivers' ([string]$st.driversDirectory -ieq (Join-Path $env:SystemRoot 'System32\drivers')) ('dir=' + $st.driversDirectory)
Check '① status.selfManagedCount=0（实测无 lctdrv* 占用）' ([int]$st.selfManagedCount -eq 0) ('count=' + $st.selfManagedCount + ' keys=' + (@($before.probeKeys) -join ','))

$li0 = Get-LctDriverList -Name 'lctdrv-bad'
Check '① list(-Name 不存在) 返回包装对象 {items,count,total}' (($null -ne $li0.items) -and ($null -ne $li0.count) -and ($null -ne $li0.total) -and ($null -ne $li0.infoPolicy)) ('count=' + $li0.count + ' total=' + $li0.total)
Check '① list(-Name 不存在) count=0 且 error 为空' ([int]$li0.count -eq 0 -and [string]$li0.error -eq '') ('count=' + $li0.count + ' err=' + (Short ([string]$li0.error) 80))

$liAll = Get-LctDriverList
Check '① list(全量) 是包装对象且 items 条数 = count' (@($liAll.items).Count -eq [int]$liAll.count -and [int]$liAll.count -gt 300) ('count=' + $liAll.count + ' total=' + $liAll.total + ' items=' + @($liAll.items).Count)
Check '① list(全量) 条目含 name/state/startMode/path' (($null -ne $liAll.items[0].name) -and ($null -ne $liAll.items[0].state) -and ($null -ne $liAll.items[0].startMode) -and ($null -ne $liAll.items[0].path)) ('sample=' + $liAll.items[0].name + '/' + $liAll.items[0].state + '/' + $liAll.items[0].startMode)
Check '① list(全量) 跳过全量签名核验（>60 条时）并说明策略' ([int]$liAll.infoChecked -eq 0 -and [string]$liAll.infoPolicy -match '不作为加载门槛') ('infoChecked=' + $liAll.infoChecked + ' skipped=' + $liAll.infoSkipped)

$fiBad = Get-LctDriverFileInfo -Path $badSys
Check '① fileInfo(无效镜像) 不崩、exists=true' ($fiBad.exists -and [string]$fiBad.error -eq '') ('exists=' + $fiBad.exists + ' err=' + (Short ([string]$fiBad.error) 80))
Check '① fileInfo(无效镜像) 给出 SHA256（64 hex）' ([string]$fiBad.sha256 -match '^[0-9A-Fa-f]{64}$') ('sha256=' + (Short ([string]$fiBad.sha256) 20) + '...')
Check '① fileInfo(无效镜像) 签名摘要明确「不是 Valid」（且不作为门槛）' ([string]$fiBad.signatureStatus -ne 'Valid' -and [string]$fiBad.signatureClass -ne 'unknown') ('status=' + $fiBad.signatureStatus + ' class=' + $fiBad.signatureClass + ' note=' + (Short ([string]$fiBad.note) 60))
Check '① fileInfo(无效镜像) 识别扩展名 .sys' ($fiBad.isSysExtension) ('ext=' + $fiBad.extension)

$fiDisk = Get-LctDriverFileInfo -Path $diskSys
Check '① fileInfo(disk.sys) signatureStatus=Valid' ([string]$fiDisk.signatureStatus -eq 'Valid') ('status=' + $fiDisk.signatureStatus + ' msg=' + (Short ([string]$fiDisk.signatureStatusMessage) 60))
Check '① fileInfo(disk.sys) 签名者是 Microsoft' ([bool]$fiDisk.isMicrosoftSigner -and [string]$fiDisk.signerSubject -match 'Microsoft') ('signer=' + (Short ([string]$fiDisk.signerSubject) 90))
Check '① fileInfo(disk.sys) SHA256 与 Get-FileHash 一致' ([string]$fiDisk.sha256 -eq [string](Get-FileHash -LiteralPath $diskSys -Algorithm SHA256).Hash) ('len=' + $fiDisk.lengthBytes)

$fiMissing = Get-LctDriverFileInfo -Path (Join-Path $workDir 'nope.sys')
Check '① fileInfo(不存在) 不崩、exists=false、error 非空' ((-not $fiMissing.exists) -and [string]$fiMissing.error -ne '') ('err=' + (Short ([string]$fiMissing.error) 80))
$fiDir = Get-LctDriverFileInfo -Path $workDir
Check '① fileInfo(目录) 不崩、isFile=false' ($fiDir.exists -and (-not $fiDir.isFile)) ('isFile=' + $fiDir.isFile)

# =====================================================================
Section '② 预览路径：applied=false 且零写盘'

$previews = New-Object System.Collections.ArrayList
$p1 = Load-LctDriver -Path $badSys -Name $svcName
$null = $previews.Add($p1)
Check '② load 预览 ok=true / applied=false' ($p1.ok -and (-not $p1.applied)) ('ok=' + $p1.ok + ' applied=' + $p1.applied)
Check '② load 预览未创建服务键' (-not (Test-Path -LiteralPath $svcKey)) ('key=' + $svcKey)
Check '② load 预览 plan 含 type= kernel 与 binPath' ((@($p1.data.plan) -join ' ') -match 'type= kernel' -and (@($p1.data.plan) -join ' ') -match 'binPath=' -and (@($p1.data.plan) -join ' ') -match 'sc\.exe start') (Joined $p1.data.plan)
Check '② load 预览 verdict=null（未执行任何 sc 动作）' ($null -eq $p1.data.verdict) ('verdict=' + $p1.data.verdict)

$pSys = Load-LctDriver -Path $badSys -Name $svcName -StartType 'system'
$null = $previews.Add($pSys)
Check '② StartType=system 不带 -Override 被拒' ((-not $pSys.ok) -and ((@($pSys.errors) -join ' ') -match 'Override')) (Joined $pSys.errors)
Check '② StartType=system 被拒时未创建服务键' (-not (Test-Path -LiteralPath $svcKey))

$pBoot = Load-LctDriver -Path $badSys -Name $svcName -StartType 'boot'
$null = $previews.Add($pBoot)
Check '② StartType=boot 不带 -Override 被拒' ((-not $pBoot.ok) -and ((@($pBoot.errors) -join ' ') -match 'Override')) (Joined $pBoot.errors)

$pSysOv = Load-LctDriver -Path $badSys -Name $svcName -StartType 'system' -Override
$null = $previews.Add($pSysOv)
Check '② StartType=system + -Override 预览通过（applied=false）' ($pSysOv.ok -and (-not $pSysOv.applied)) (Joined $pSysOv.errors)
Check '② 高危启动类型命中时 warnings 标注后果' ((@($pSysOv.warnings) -join ' ') -match '高危' -and (@($pSysOv.warnings) -join ' ') -match '蓝屏') (Joined $pSysOv.warnings)

$pAuto = Load-LctDriver -Path $badSys -Name $svcName -StartType 'auto'
$null = $previews.Add($pAuto)
Check '② StartType=auto 无需 -Override 即预览通过' ($pAuto.ok -and (-not $pAuto.applied)) (Joined $pAuto.errors)

$pBadSt = Load-LctDriver -Path $badSys -Name $svcName -StartType 'bogus'
$null = $previews.Add($pBadSt)
Check '② 非法 StartType 被拒' ((-not $pBadSt.ok) -and ((@($pBadSt.errors) -join ' ') -match 'StartType')) (Joined $pBadSt.errors)
$pBadName = Load-LctDriver -Path $badSys -Name 'bad name!'
$null = $previews.Add($pBadName)
Check '② 非法服务名被拒' ((-not $pBadName.ok) -and ((@($pBadName.errors) -join ' ') -match '服务名')) (Joined $pBadName.errors)
$pNoFile = Load-LctDriver -Path (Join-Path $workDir 'missing.sys') -Name $svcName
$null = $previews.Add($pNoFile)
Check '② 文件不存在被拒' ((-not $pNoFile.ok) -and ((@($pNoFile.errors) -join ' ') -match '不存在')) (Joined $pNoFile.errors)

$pStage = Load-LctDriver -Path $badSys -Name $svcName -Stage
$null = $previews.Add($pStage)
Check '② -Stage 预览给出暂存计划（System32\drivers）' ($pStage.ok -and ([string]$pStage.data.stagedPath -ieq (Join-Path $env:SystemRoot ('System32\drivers\' + 'lctdrv-bad.sys')))) ('stagedPath=' + $pStage.data.stagedPath)
Check '② -Stage 预览未把文件复制进 System32\drivers' (-not (Test-Path -LiteralPath $pStage.data.stagedPath)) ('exists=' + (Test-Path -LiteralPath $pStage.data.stagedPath))
Check '② -Stage 预览未创建服务键' (-not (Test-Path -LiteralPath $svcKey))

$ps1 = Start-LctDriver -Name $svcName
$null = $previews.Add($ps1)
Check '② start 预览（服务不存在）ok=false / applied=false' ((-not $ps1.ok) -and (-not $ps1.applied) -and ((@($ps1.errors) -join ' ') -match '不存在')) (Joined $ps1.errors)
$pu1 = Stop-LctDriver -Name $svcName
$null = $previews.Add($pu1)
Check '② stop 预览（服务不存在）ok=false / applied=false' ((-not $pu1.ok) -and (-not $pu1.applied)) (Joined $pu1.errors)
$pr0 = Remove-LctDriverService -Name $svcName
$null = $previews.Add($pr0)
Check '② unload 预览（服务不存在）ok=false / applied=false' ((-not $pr0.ok) -and (-not $pr0.applied)) (Joined $pr0.errors)

Check '② 所有预览路径 applied 全为 false' (@($previews | Where-Object { $_.applied }).Count -eq 0) ('previews=' + @($previews).Count)
Check '② 预览阶段结束后服务键仍不存在（零写盘）' (-not (Test-Path -LiteralPath $svcKey))

# =====================================================================
Section '③ 全链路：注册 → 系统真实拒绝 → 冲突 → 停止 → 卸载 → revert 产物'

if (-not $elevated) {
    Skip '③ 全链路（注册/启动/卸载）' '当前进程未提权，无法创建内核驱动服务（预览与只读断言已在上方完成）'
} else {
    $a1 = Load-LctDriver -Path $badSys -Name $svcName -Apply
    Check '③ load -Apply 后 ok=true / applied=true' ($a1.ok -and $a1.applied) ('ok=' + $a1.ok + ' applied=' + $a1.applied + ' err=' + (Joined $a1.errors))
    Check '③ 服务注册表键已创建' (Test-Path -LiteralPath $svcKey) ('key=' + $svcKey)
    Check '③ 注册项 Type=1（kernel）' ([int](Get-RegValueSafe -Key $svcKey -ValueName 'Type') -eq 1) ('Type=' + (Get-RegValueSafe -Key $svcKey -ValueName 'Type'))
    Check '③ 注册项 Start=3（demand，默认值）' ([int](Get-RegValueSafe -Key $svcKey -ValueName 'Start') -eq 3) ('Start=' + (Get-RegValueSafe -Key $svcKey -ValueName 'Start'))
    $img = [string](Get-RegValueSafe -Key $svcKey -ValueName 'ImagePath')
    Check '③ ImagePath 指向我们给的无效镜像且带 \??\ 规范化前缀' ($img -match [regex]::Escape($badSys) -and $img -match '^\\\?\?\\') ('ImagePath=' + $img)
    Check '③ sc create 成功（createVerdict.exitCode=0）' ([int]$a1.data.createVerdict.exitCode -eq 0) ('create=' + $a1.data.createVerdict.exitCode + ' msg=' + (Short ([string]$a1.data.createVerdict.message) 60))
    Check '③ sc start 拿到 OS 真实拒绝（exitCode<>0 且 message 非空）' (([int]$a1.data.verdict.exitCode -ne 0) -and ([string]$a1.data.verdict.message).Trim().Length -gt 0) ('exit=' + $a1.data.verdict.exitCode + ' msg=' + (Short ([string]$a1.data.verdict.message) 120))
    Check '③ verdict 原文含 sc.exe 的 FAILED 字样（原样回传，未美化）' ([string]$a1.data.verdict.message -match 'FAILED') ('msg=' + (Short ([string]$a1.data.verdict.message) 120))
    Check '③ verdict.osBlocked=true / systemAccepted=false' ([bool]$a1.data.verdict.osBlocked -and (-not [bool]$a1.data.verdict.systemAccepted)) ('osBlocked=' + $a1.data.verdict.osBlocked + ' accepted=' + $a1.data.verdict.systemAccepted)
    Check '③ 保留了 stdout/stderr 分离原文' (([string]$a1.data.verdict.stdout).Length -gt 0 -or ([string]$a1.data.verdict.stderr).Length -gt 0) ('stdout=' + (Short ([string]$a1.data.verdict.stdout) 60) + ' stderr=' + (Short ([string]$a1.data.verdict.stderr) 40))
    Check '③ 系统拒绝没有被我方当成 errors（口径：照抄不回退）' (@($a1.errors).Count -eq 0 -and (@($a1.warnings) -join ' ') -match '系统拒绝') (Joined $a1.warnings)
    Check '③ 系统拒绝时仍标 applied=true（我们确实执行了动作）' ($a1.applied -eq $true)

    $liA = Get-LctDriverList -Name $svcName
    Check '③ list(-Name) 命中 1 条（注册表权威来源）' ([int]$liA.count -eq 1 -and @($liA.items)[0].name -eq $svcName) ('count=' + $liA.count + ' state=' + @($liA.items)[0].state)
    Check '③ list(-Name) 条目不处于 Running（无效镜像不可能加载成功）' ([string]@($liA.items)[0].state -ine 'Running') ('state=' + @($liA.items)[0].state)
    Check '③ list(-Name) 给出 sha256 + 签名摘要（<=60 条时核验）' ([int]$liA.infoChecked -eq 1 -and [string]@($liA.items)[0].sha256 -match '^[0-9A-Fa-f]{64}$' -and [string]@($liA.items)[0].signatureClass -ne '') ('sha256=' + (Short ([string]@($liA.items)[0].sha256) 16) + '... class=' + @($liA.items)[0].signatureClass)

    $stA = Get-LctDriverStatus
    Check '③ status 自管清单里出现刚注册的服务' ([int]$stA.selfManagedCount -eq 1 -and @($stA.selfManagedServices)[0].name -eq $svcName) ('count=' + $stA.selfManagedCount + ' name=' + @($stA.selfManagedServices)[0].name)

    $v1 = Get-LctDriverVerification -Name $svcName
    Check '③ verify 结论不是「真的在运行」' ([string]$v1.conclusion -ne 'running') ('conclusion=' + $v1.conclusion + ' text=' + $v1.conclusionText + ' state=' + $v1.state)
    Check '③ verify 结论属于三档之一' (@('running', 'os-rejected', 'unknown') -contains [string]$v1.conclusion) ('conclusion=' + $v1.conclusion)
    Check '③ verify 带 CIM 状态 / 注册信息 / 事件原文键' (($null -ne $v1.registered) -and ($null -ne $v1.state) -and ($null -ne $v1.events) -and ($null -ne $v1.eventsRead) -and ($v1.PSObject.Properties.Name -contains 'conclusionText')) ('registered=' + $v1.registered + ' eventsRead=' + $v1.eventsRead + ' matched=' + $v1.eventCount)
    if ($v1.conclusion -eq 'os-rejected') {
        Check '③ verify 被系统拒绝时给出事件原文' (@($v1.events).Count -gt 0 -and [string]@($v1.events)[0].message -ne '') ('ev=' + @($v1.events)[0].id + ' ' + (Short ([string]@($v1.events)[0].message) 90))
    } else {
        Skip '③ verify 事件原文断言' ('本次未匹配到指向该服务的事件（结论=' + $v1.conclusion + '），不算失败')
    }

    # ---- 同名冲突默认被拒 ----
    $conflict = Load-LctDriver -Path $badSys -Name $svcName -Apply
    Check '③ 同名服务冲突默认被拒（ok=false + errors 说明）' ((-not $conflict.ok) -and ((@($conflict.errors) -join ' ') -match '已存在')) ('applied=' + $conflict.applied + ' err=' + (Joined $conflict.errors))
    Check '③ 冲突被拒后原服务键与 ImagePath 未被改动' ((Test-Path -LiteralPath $svcKey) -and ([string](Get-RegValueSafe -Key $svcKey -ValueName 'ImagePath') -eq $img)) ('ImagePath=' + (Get-RegValueSafe -Key $svcKey -ValueName 'ImagePath'))
    $ovPrev = Load-LctDriver -Path $badSys -Name $svcName -Override
    Check '③ -Override 预览通过 + 标注覆盖与备份（applied=false）' ($ovPrev.ok -and (-not $ovPrev.applied) -and ((@($ovPrev.warnings) -join ' ') -match '覆盖')) (Joined $ovPrev.warnings)

    # ---- 启动 / 停止（OS 判定原文）----
    $s1 = Start-LctDriver -Name $svcName -Apply
    Check '③ start -Apply 回传 OS 拒绝（exitCode<>0 + message 非空）' ([int]$s1.data.verdict.exitCode -ne 0 -and ([string]$s1.data.verdict.message).Trim().Length -gt 0) ('exit=' + $s1.data.verdict.exitCode + ' msg=' + (Short ([string]$s1.data.verdict.message) 100))
    Check '③ start -Apply 后服务键仍在（只启动不删服务）' (Test-Path -LiteralPath $svcKey)

    $s2 = Stop-LctDriver -Name $svcName -Apply
    Check '③ stop -Apply 记录了 sc 退出码与原文' (($null -ne $s2.data.verdict) -and ([string]$s2.data.verdict.message).Trim().Length -gt 0) ('exit=' + $s2.data.verdict.exitCode + ' msg=' + (Short ([string]$s2.data.verdict.message) 100) + ' goalMet=' + $s2.data.verdict.goalMet)
    Check '③ stop 后服务键仍在（不删服务项）' (Test-Path -LiteralPath $svcKey)
    Check '③ stop 返回 1062（未启动）时不算失败并标注目标已达成' (([int]$s2.data.verdict.exitCode -ne 1062) -or ((@($s2.warnings) -join ' ') -match '1062')) ('warnings=' + (Joined $s2.warnings))

    # ---- 卸载 ----
    $r0 = Remove-LctDriverService -Name $svcName
    Check '③ unload 预览 applied=false 且服务键仍在' ((-not $r0.applied) -and (Test-Path -LiteralPath $svcKey)) ('applied=' + $r0.applied + ' plan=' + (Joined $r0.data.plan))
    Check '③ unload 预览声明保留 .sys 文件' ([bool]$r0.data.fileKept -and (@($r0.data.plan) -join ' ') -match '不删除') (Joined $r0.data.plan)

    $r1 = Remove-LctDriverService -Name $svcName -Apply
    Check '③ unload -Apply ok=true / applied=true / deleted=true' ($r1.ok -and $r1.applied -and $r1.data.deleted) ('ok=' + $r1.ok + ' applied=' + $r1.applied + ' deleted=' + $r1.data.deleted + ' err=' + (Joined $r1.errors))
    Check '③ unload 后服务注册表键消失' (-not (Test-Path -LiteralPath $svcKey)) ('key=' + $svcKey)
    Check '③ unload 生成了 revert.cmd' ([string]$r1.data.revertCmdPath -ne '' -and (Test-Path -LiteralPath $r1.data.revertCmdPath)) ('revert.cmd=' + $r1.data.revertCmdPath)
    Check '③ revert.ps1 / revert.json 也生成（精确值）' ((Test-Path -LiteralPath $r1.data.revertPs1Path) -and (Test-Path -LiteralPath $r1.data.revertJsonPath)) ('ps1=' + $r1.data.revertPs1Path)
    if (Test-Path -LiteralPath $r1.data.revertCmdPath) {
        $cmdBytes = [IO.File]::ReadAllBytes($r1.data.revertCmdPath)
        $cmdNonAscii = @($cmdBytes | Where-Object { $_ -gt 127 }).Count
        $cmdText = [IO.File]::ReadAllText($r1.data.revertCmdPath, [System.Text.Encoding]::ASCII)
        Check '③ revert.cmd 纯 ASCII（cmd.exe 按 OEM 读）' ($cmdNonAscii -eq 0) ('nonAscii=' + $cmdNonAscii)
        Check '③ revert.cmd 含重建命令与原始参数' ($cmdText -match 'sc\.exe create' -and $cmdText -match [regex]::Escape($svcName) -and $cmdText -match 'type= kernel' -and $cmdText -match 'start= demand' -and $cmdText -match [regex]::Escape([IO.Path]::GetFileName($badSys))) (Short $cmdText 240)
        Check '③ revert.cmd 为 CRLF 且声明不加载/不删文件' ($cmdText -match "`r`n" -and $cmdText -match 'does not load' -and $cmdText -match 'does not touch') (Short $cmdText 200)
    } else {
        Check '③ revert.cmd 纯 ASCII' $false 'revert.cmd 不存在'
    }
    Check '③ 卸载绝不删 .sys：原始无效镜像仍在' ((Test-Path -LiteralPath $badSys) -and [bool]$r1.data.fileKept) ('fileKept=' + $r1.data.fileKept + ' exists=' + (Test-Path -LiteralPath $badSys))
    Check '③ 备份已生成且含该服务的注册表导出' ([string]$r1.data.backupId -ne '' -and (Test-Path -LiteralPath (Join-Path (Join-Path $varDir 'backups') $r1.data.backupId))) ('backupId=' + $r1.data.backupId)
    if ([string]$r1.data.backupId -ne '') {
        $bkFiles = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $varDir 'backups') $r1.data.backupId) -Recurse -File | ForEach-Object { $_.FullName })
        $regFile = @($bkFiles | Where-Object { $_ -like '*.reg' })
        Check '③ 备份目录含 .reg 导出' (@($regFile).Count -ge 1) ('files=' + (@($bkFiles).Count))
        if (@($regFile).Count -ge 1) {
            $regText = Get-Content -LiteralPath @($regFile)[0] -Raw
            Check '③ .reg 导出内容含该服务路径（可用于手工还原）' ([string]$regText -match [regex]::Escape($svcName)) ('reg=' + [IO.Path]::GetFileName(@($regFile)[0]))
        }
    }
    $v2 = Get-LctDriverVerification -Name $svcName
    Check '③ 卸载后 verify 不再是「真的在运行」且 registered=false' ((-not [bool]$v2.running) -and (-not [bool]$v2.registered)) ('conclusion=' + $v2.conclusion + ' registered=' + $v2.registered + ' reason=' + (Short ([string]$v2.verdictReason) 90))
}

# =====================================================================
Section '④ 系统零残留'

# 兜底：万一上面的断言路径没跑到卸载，这里强制清一次（服务项由本测试创建，必须收回）
if (Test-Path -LiteralPath $svcKey) {
    Write-Host ('DriverTest: 兜底卸载 ' + $svcName)
    try { Remove-LctDriverService -Name $svcName -Apply | Out-Null } catch { Write-Host ('  fallback uninstall failed: ' + $_.Exception.Message) }
}
$after = Get-DriverSnapshot
Check '④ 前后 Win32_SystemDriver 数量一致' ([int]$after.cimDriverCount -eq [int]$before.cimDriverCount) ('before=' + $before.cimDriverCount + ' after=' + $after.cimDriverCount)
Check '④ 系统里无 lctdrv* / lctprobe* 服务键' (@($after.probeKeys).Count -eq 0) ('keys=' + (@($after.probeKeys) -join ', '))
Check '④ 服务键已彻底移除' (-not (Test-Path -LiteralPath $svcKey))
$liEnd = Get-LctDriverList -Name 'lctdrv*'
Check '④ driver.list(lctdrv*) 现在为 0 条' ([int]$liEnd.count -eq 0) ('count=' + $liEnd.count)
Check '④ 无效镜像文件仍在（工具从不删 .sys）' (Test-Path -LiteralPath $badSys) ('file=' + $badSys)
Check '④ 测试产物全部落在隔离 varDir 内' ((Test-Path -LiteralPath $varDir) -and $varDir -like ($env:TEMP + '*')) ('varDir=' + $varDir)

# =====================================================================
Section '⑤ testsigning 只预览 + 模块源码卫生'

$stNow = Get-LctDriverStatus
$tsBefore = [string]$stNow.testSigning
$ts1 = Set-LctDriverTestSigning -Enable
Check '⑤ testsigning 开启预览 ok=true / applied=false' ($ts1.ok -and (-not $ts1.applied)) ('ok=' + $ts1.ok + ' applied=' + $ts1.applied + ' err=' + (Joined $ts1.errors))
Check '⑤ testsigning 预览记录原值 + needsRestart=true + 计划命令' (([string]$ts1.data.before -ne '') -and [bool]$ts1.data.needsRestart -and (@($ts1.data.plan) -join ' ') -match 'bcdedit') ('before=' + $ts1.data.before + ' after=' + $ts1.data.after + ' needsRestart=' + $ts1.data.needsRestart + ' cmd=' + $ts1.data.bcdeditCommand)
$stNow2 = Get-LctDriverStatus
Check '⑤ testsigning 预览未落盘（值未变）' ([string]$stNow2.testSigning -eq $tsBefore) ('now=' + $stNow2.testSigning + ' before=' + $tsBefore)
$ts2 = Set-LctDriverTestSigning -Enable -Disable
Check '⑤ -Enable 与 -Disable 同时给被拒' (-not $ts2.ok) (Joined $ts2.errors)
$ts3 = Set-LctDriverTestSigning
Check '⑤ 两个都不给被拒' (-not $ts3.ok) (Joined $ts3.errors)
$ts4 = Set-LctDriverTestSigning -Disable
$stNow3 = Get-LctDriverStatus
Check '⑤ testsigning 关闭预览 applied=false 且不落盘' ((-not $ts4.applied) -and ([string]$stNow3.testSigning -eq $tsBefore)) ('ok=' + $ts4.ok + ' applied=' + $ts4.applied)

$gateTrue = & (Get-Module -Name Drivers) { param($sb) Test-LctDrvTestSigningGate -Action 'enable' -SecureBoot $sb } $true
$gateFalse = & (Get-Module -Name Drivers) { param($sb) Test-LctDrvTestSigningGate -Action 'enable' -SecureBoot $sb } $false
Check '⑤ Secure Boot=True 时开启 testsigning 被判定拒绝' ((-not [bool]$gateTrue.allowed) -and ([string]$gateTrue.reason -match 'Secure Boot')) ('allowed=' + $gateTrue.allowed + ' reason=' + (Short ([string]$gateTrue.reason) 90))
Check '⑤ Secure Boot=False 时允许开启（本机实测 False）' ([bool]$gateFalse.allowed) ('allowed=' + $gateFalse.allowed)
$stFinal = Get-LctDriverStatus
Check '⑤ 本机 Secure Boot 实测为 False' ((-not [bool]$stFinal.secureBoot)) ('secureBoot=' + $stFinal.secureBoot + ' source=' + $stFinal.secureBootSource)

$modulePath = Join-Path $root 'core\Drivers.psm1'
$moduleCodeLines = @(Get-Content -LiteralPath $modulePath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*#' })
$moduleCodeText = ($moduleCodeLines -join "`n")
Check '⑤ 模块源码（非注释行）不含永久删除命令 Remove-Item' (-not ($moduleCodeText -match 'Remove-Item')) ''
Check '⑤ 模块源码（非注释行）不含 Write-Host' (-not ($moduleCodeText -match 'Write-Host')) ''
Check '⑤ 模块源码不含 Set-StrictMode' (-not ($moduleCodeText -match 'Set-StrictMode')) ''
Check '⑤ 模块源码未对只读自动变量赋值' (-not ($moduleCodeText -match '\$(pid|host|home|ExecutionContext|PSVersionTable|PSCulture|PSUICulture|PSHome|ShellId|ConsoleFileName)\s*=')) ''
Check '⑤ 模块源码不含 New-Service（内核驱动必须 sc type= kernel）' (-not ($moduleCodeText -match 'New-Service')) ''
Check '⑤ 模块源码显式导出 9 个函数' (@([regex]::Matches($moduleCodeText, 'Export-ModuleMember')).Count -eq 1) ''

# =====================================================================
Section '⑥ 参数真实生效（防简单函数漏 param 被 $args 静默吞参；只断言 ok=true 是假绿）'

# driver.info：-Path 必须真的生效
$e1 = Get-LctDriverFileInfo -Path $diskSys
Check '⑥ fileInfo -Path 生效（disk.sys → exists=true + 路径回显）' ($e1.exists -and [string]$e1.fullPath -ieq $diskSys) ('fullPath=' + $e1.fullPath)
$e2 = Get-LctDriverFileInfo -Path $badSys
Check '⑥ fileInfo -Path 生效（无效镜像 → 路径/大小回显）' ($e2.exists -and [string]$e2.path -eq $badSys -and [int]$e2.lengthBytes -gt 0) ('path=' + (Short ([string]$e2.path) 70) + ' len=' + $e2.lengthBytes)

# driver.list：-Name 过滤必须真的生效
$n1 = Get-LctDriverList -Name 'disk'
Check '⑥ list -Name 生效（disk → 恰好 1 条）' ([int]$n1.count -eq 1 -and [string]@($n1.items)[0].name -ieq 'disk') ('count=' + $n1.count + ' name=' + @($n1.items)[0].name + ' filter=' + $n1.filter)
$n2 = Get-LctDriverList -Name 'lctdrv*'
Check '⑥ list -Name 通配也生效（lctdrv* → 0 条，total 不受过滤影响）' ([int]$n2.count -eq 0 -and [int]$n2.total -gt 300) ('count=' + $n2.count + ' total=' + $n2.total)

# driver.verify：-Name 必须真的生效（不存在 / 非法）
$vv1 = Get-LctDriverVerification -Name 'lctdrv-does-not-exist'
Check '⑥ verify -Name 生效（不存在的服务 → nameValid=true / registered=false）' ([bool]$vv1.nameValid -and (-not [bool]$vv1.registered) -and [string]$vv1.name -eq 'lctdrv-does-not-exist') ('name=' + $vv1.name + ' registered=' + $vv1.registered + ' conclusion=' + $vv1.conclusion)
$vv2 = Get-LctDriverVerification -Name 'bad name!'
Check '⑥ verify -Name 非法输入被识别（nameValid=false + error）' ((-not [bool]$vv2.nameValid) -and [string]$vv2.error -ne '') ('nameValid=' + $vv2.nameValid + ' err=' + (Short ([string]$vv2.error) 70))

# driver.load：6 个形参必须全部回显（预览路径，零写盘）
$lp = Load-LctDriver -Path $badSys -Name $svcName -StartType 'auto' -Stage -Override
Check '⑥ load 形参回显（path/name/startType/stage/override）' (([string]$lp.data.path -eq $badSys) -and ([string]$lp.data.name -eq $svcName) -and ([string]$lp.data.startType -eq 'auto') -and [bool]$lp.data.staged -and [bool]$lp.data.override) ('path=' + (Short ([string]$lp.data.path) 55) + ' name=' + $lp.data.name + ' startType=' + $lp.data.startType + ' staged=' + $lp.data.staged + ' override=' + $lp.data.override)
Check '⑥ load -Stage 让 binPath 指向 System32\drivers 的暂存副本' ([string]$lp.data.binPath -ieq [string]$lp.data.stagedPath) ('binPath=' + $lp.data.binPath)
Check '⑥ load -Apply 缺省即预览（applied=false 且 verdict=null）' ((-not $lp.applied) -and ($null -eq $lp.data.verdict)) ('applied=' + $lp.applied)
Check '⑥ load 预览未把暂存文件写进 System32\drivers' (-not (Test-Path -LiteralPath $lp.data.stagedPath)) ('exists=' + (Test-Path -LiteralPath $lp.data.stagedPath))

# driver.start / stop / unload：-Name 必须回显
$sp = Start-LctDriver -Name 'lctdrv-does-not-exist'
Check '⑥ start -Name 回显（不存在 → name 一致 / ok=false / applied=false）' ((-not $sp.ok) -and (-not $sp.applied) -and [string]$sp.data.name -eq 'lctdrv-does-not-exist') ('name=' + $sp.data.name + ' err=' + (Joined $sp.errors))
$tp = Stop-LctDriver -Name 'lctdrv-does-not-exist'
Check '⑥ stop -Name 回显（不存在 → name 一致 / ok=false）' ((-not $tp.ok) -and [string]$tp.data.name -eq 'lctdrv-does-not-exist') ('name=' + $tp.data.name)
$up = Remove-LctDriverService -Name 'lctdrv-does-not-exist'
Check '⑥ unload -Name 回显（不存在 → name 一致 / ok=false）' ((-not $up.ok) -and [string]$up.data.name -eq 'lctdrv-does-not-exist') ('name=' + $up.data.name)

# driver.testsigning：-Enable / -Disable 两个开关必须可区分
$te = Set-LctDriverTestSigning -Enable
$td = Set-LctDriverTestSigning -Disable
Check '⑥ testsigning -Enable 生效（action=enable / enable=true / after=Yes）' ([string]$te.data.action -eq 'enable' -and [bool]$te.data.enable -and (-not [bool]$te.data.disable) -and [string]$te.data.after -eq 'Yes') ('action=' + $te.data.action + ' after=' + $te.data.after)
Check '⑥ testsigning -Disable 生效（action=disable / disable=true / after=No）' ([string]$td.data.action -eq 'disable' -and [bool]$td.data.disable -and (-not [bool]$td.data.enable) -and [string]$td.data.after -eq 'No') ('action=' + $td.data.action + ' after=' + $td.data.after)
$stEnd2 = Get-LctDriverStatus
Check '⑥ ⑥ 段所有预览调用都没有真的改 testsigning' ([string]$stEnd2.testSigning -eq $tsBefore) ('now=' + $stEnd2.testSigning + ' before=' + $tsBefore)

# =====================================================================
Write-Host ''
Write-Host ('DriverTest 结果: PASS=' + $script:Pass + ' FAIL=' + $script:Fail)
Write-Host ('测试产物（保留以便复查）：' + $varDir)
if ($script:Fail -gt 0) {
    Write-Host '--- 失败项 ---'
    foreach ($l in @($script:Lines)) { if ($l -like '`[FAIL`]*') { Write-Host $l } }
}
exit $script:Fail