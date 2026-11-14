# =====================================================================
# LocalConfigTool - DriverAudit.psm1
#
# 职责：**驱动的静态批量鉴定**（L1，零加载、零 IOCTL、零蓝屏风险）。
#
# 为什么需要它：
#   单点能力（driver.info / driver.profile.draft）只能一次看一个驱动。
#   真实场景是「我手上有一批 .sys，想知道哪些值得深挖」——几百个文件人工点太慢。
#   本模块把静态分析批量化，产出分级报告，把"值得动态验证的"从几百个筛到几个。
#
# 分级（**静态分析的极限**，不等于"有漏洞"）：
#   L0 invalid          不是可解析的 PE，或文件不存在
#   L1 no-signal        有效 PE，但没有设备名候选、也没有 IOCTL 候选
#   L2 device-only      有设备名候选，但无 IOCTL 候选
#   L3 ioctl-candidate  有 IOCTL 候选（**启发式**，来自 CMP reg,imm32 筛选，可能误报）
#
# 明确不做的事（诚实边界）：
#   * 不加载驱动、不发 IOCTL、不碰注册表 —— 所以它**不能**证明"能利用"
#   * L3 只是"候选"，真正确认必须走 driver.use + driver.ctl.send（L2/L3 动态验证）
#   * 不做反编译；draft 是启发式，不是分析器
#
# 导出（1 个）：
#   Invoke-LctDriverBatchScan -Dir -Pattern -MaxFiles -Recurse -SkipDraft
#
# 契约：docs\CONTRACT.md §3 Result / §7 铁律；模块间调用必须 -Global 导入
# =====================================================================

$script:LctAuditSelf = $MyInvocation.MyCommand.Path
$script:LctAuditRoot = Split-Path -Parent (Split-Path -Parent $script:LctAuditSelf)
$script:LctAuditCore = Join-Path $script:LctAuditRoot 'core'

# 关键：本模块要调用其它模块的函数，必须在**本模块作用域**导入它们。
# 依赖 Engine 的 -Global 导入是不够的 —— 模块有自己的 SessionState，
# 调用 -Global 导入的函数时命令解析会失败（实测：Get-LctDriverFileInfo 返回 $null、
# New-LctDriverProfileDraft 抛 CommandNotFound，表现为"文件不存在"/"不是可解析的 PE"）。
# 关键：本模块要调用其它模块的函数。**不要 -Force 重载**——那会把 Drivers/DriverProfiles/Logging
# 的模块状态整体重置，进而破坏 Engine 已建立的会话（实测导致 DriverOpsTest/CtlSimplifyTest 崩）。
# 正确做法：已能解析到就复用；解析不到才导入（且不带 -Force）。
$script:LctAuditDeps = New-Object System.Collections.ArrayList
$probeMap = @{ 'Logging' = 'New-LctResult'; 'Drivers' = 'Get-LctDriverFileInfo'; 'DriverProfiles' = 'New-LctDriverProfileDraft' }
foreach ($dep in @('Logging', 'Drivers', 'DriverProfiles')) {
    $probeName = $probeMap[$dep]
    if ($null -ne (Get-Command -Name $probeName -ErrorAction SilentlyContinue)) {
        $null = $script:LctAuditDeps.Add($dep + ':reuse')
        continue
    }
    $depPath = Join-Path $script:LctAuditCore ($dep + '.psm1')
    if (-not (Test-Path -LiteralPath $depPath)) { $null = $script:LctAuditDeps.Add($dep + ':missing'); continue }
    try {
        Import-Module $depPath -ErrorAction Stop
        $null = $script:LctAuditDeps.Add($dep + ':imported')
    } catch {
        $null = $script:LctAuditDeps.Add($dep + ':FAIL ' + $_.Exception.Message)
    }
}
function Get-LctAuditDeps { return @($script:LctAuditDeps) }

function Get-LctAuditProp {
    # 安全取属性（对象可能是 PSObject / Hashtable / $null）
    param($Bag, [string]$Name, $Default = $null)
    if ($null -eq $Bag) { return $Default }
    try {
        if ($Bag -is [hashtable]) { if ($Bag.ContainsKey($Name)) { return $Bag[$Name] } return $Default }
        $p = $Bag.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    } catch { }
    return $Default
}

function Get-LctAuditKnownHashes {
    # 读样本库里的已知哈希（用于"这个驱动是不是已知样本"标记）
    $map = @{}
    try {
        $catalog = Join-Path $script:LctAuditRoot 'samples\catalog.json'
        if (Test-Path -LiteralPath $catalog) {
            $obj = Get-Content -LiteralPath $catalog -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($obj.entries)) {
                $sha = [string](Get-LctAuditProp $e 'sha256')
                if ($sha.Length -ge 32) { $map[$sha.ToUpperInvariant()] = [string](Get-LctAuditProp $e 'id') }
            }
        }
    } catch { }
    return $map
}

function Get-LctAuditItem {
    # 单个驱动的静态鉴定（不加载）
    param([Parameter(Mandatory)][string]$Path, [bool]$DoDraft = $true, [hashtable]$KnownHashes = @{})

    $item = [ordered]@{
        file             = [IO.Path]::GetFileName($Path)
        path             = $Path
        exists           = $false
        lengthBytes      = 0
        sha256           = ''
        signatureStatus  = ''
        signatureClass   = ''
        isMicrosoftSigner = $false
        likelyTestSigned = $false
        deviceCandidates = 0
        ioctlCandidates  = 0
        confidence       = 0.0
        deviceList       = @()
        criticalDevice   = $false
        isSystemDriver   = $false
        knownSample      = ''
        confidenceReason = ''
        likelyIoctl      = 0
        riskScore        = 0.0
        importCount      = 0
        ioctlReliability = 'low'
        importSignal     = ''
        finalRisk        = 0.0
        dynamic          = $null
        dynamicReason    = ''
        triage           = 'benign'
        grade            = 'L0-invalid'
        verdict          = ''
    }

    # 系统自带驱动（路径在 %SystemRoot%\System32\drivers）：不算外来风险，单独标记
    try {
        $sysDir = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\drivers'))
        $item.isSystemDriver = [IO.Path]::GetFullPath($Path).StartsWith($sysDir, [StringComparison]::OrdinalIgnoreCase)
    } catch { }

    $info = $null
    try { $info = Get-LctDriverFileInfo -Path $Path } catch { $info = $null }
    # 注意：Get-LctDriverFileInfo 返回的是**裸 info 对象**（不经 Result 包装）；
    # 其它模块函数可能返回 Result（有 .data）。这里兼容两种形态，否则 exists 永远读到 $null。
    $d = $null
    if ($null -ne $info) {
        if (($null -ne $info.PSObject.Properties['data']) -and ($null -ne $info.data)) { $d = $info.data } else { $d = $info }
    }
    if ($null -ne $d) {
        $item.exists = [bool](Get-LctAuditProp $d 'exists' $false)
        $item.lengthBytes = [int](Get-LctAuditProp $d 'lengthBytes' 0)
        $item.sha256 = [string](Get-LctAuditProp $d 'sha256' '')
        $item.signatureStatus = [string](Get-LctAuditProp $d 'signatureStatus' '')
        $item.signatureClass = [string](Get-LctAuditProp $d 'signatureClass' '')
        $item.isMicrosoftSigner = [bool](Get-LctAuditProp $d 'isMicrosoftSigner' $false)
        $item.likelyTestSigned = [bool](Get-LctAuditProp $d 'likelyTestSigned' $false)
    }
    if (-not $item.exists) {
        $item.verdict = '文件不存在'
        return [pscustomobject]$item
    }
    if ($item.sha256 -ne '' -and $KnownHashes.ContainsKey($item.sha256.ToUpperInvariant())) {
        $item.knownSample = [string]$KnownHashes[$item.sha256.ToUpperInvariant()]
    }

    if (-not $DoDraft) {
        $item.grade = 'L1-no-signal'
        $item.verdict = '有效文件（未做 draft 分析）'
        return [pscustomobject]$item
    }

    $draft = $null
    $draftException = ''
    try {
        # 显式取命令对象再调用：模块内 SessionState 对 -Global 导入函数的解析不稳定
        $draftCmd = Get-Command -Name 'New-LctDriverProfileDraft' -ErrorAction SilentlyContinue
        if ($null -eq $draftCmd) { throw 'New-LctDriverProfileDraft 不可用（DriverProfiles.psm1 未加载）' }
        $draft = & $draftCmd -Path $Path
    } catch {
        $draft = $null
        $draftException = $_.Exception.Message
    }
    if ($null -eq $draft -or -not $draft.ok) {
        $err = ''
        if ($null -ne $draft) { $err = (@($draft.errors) -join ';') }
        if ($draftException -ne '') { $err = '调用异常: ' + $draftException }
        $item.grade = 'L0-invalid'
        $item.verdict = '不是可解析的 PE 映像' + $(if ($err -ne '') { '（' + $err + '）' } else { '' })
        return [pscustomobject]$item
    }

    $dd = $draft.data
    $item.deviceCandidates = [int](Get-LctAuditProp $dd 'candidatesFound' 0)
    $item.ioctlCandidates = [int](Get-LctAuditProp $dd 'ioctlCandidateCount' 0)
    $item.confidence = [double](Get-LctAuditProp $dd 'confidence' 0)

    # 设备名危险度：暴露物理内存类设备是 BYOVD 的经典特征（比 IOCTL 数量更能区分）
    # 逐层显式取：data.draft（profile）.locate.candidates。用 PSObject.Properties 避免链式访问静默返回空。
    $devCands = @()
    try {
        $prof = $null
        if ($null -ne $dd) { $prof = $dd.draft }
        if ($null -eq $prof) { } else {
            $loc = $prof.locate
            if ($null -eq $loc) { } else {
                $cc = $loc.candidates
                if ($null -ne $cc) { $devCands = @($cc) }
            }
        }
    } catch { }
    $item.deviceList = @($devCands | ForEach-Object { [string]$_ })
    foreach ($c in $devCands) {
        if ([string]$c -match '(?i)PhysicalMemory|\\Device\\Mem\b|PhyMem|\\Device\\Physical') { $item.criticalDevice = $true; break }
    }

    # 把引擎已经算好的加分明细带出来（本来就有，只是之前没暴露）
    try {
        $innerDraft = $null
        $profObj = $dd.draft
        if ($null -ne $profObj) { $innerDraft = $profObj.draft }
        if ($null -ne $innerDraft) { $item.confidenceReason = [string]$innerDraft.confidenceReason }
    } catch { }

    # likely IOCTL 数量（分层修复后才有区分度）
    try {
        $evObj = $null
        $profObj2 = $dd.draft
        if ($null -ne $profObj2) {
            $in2 = $profObj2.draft
            if ($null -ne $in2) { $evObj = $in2.evidence }
        }
        if ($null -ne $evObj) {
            $allC = @($evObj.ioctlCandidates)
            $item.likelyIoctl = @($allC | Where-Object { [string]$_.tier -eq 'likely' }).Count

            # ---- 导入表组合特征 ----
            # 注意：不是"数危险 API 个数"。实测 tcpip.sys 有 3 个"危险"API（KeStackAttachProcess /
            # MmProbeAndLockPages / ZwOpenProcess）却完全正常；而 rtcore64 只有 1 个（MmMapIoSpace）。
            # 有区分度的是「直接映射物理内存的 API」+「导入表极简」这个组合：
            #   rtcore64 : MmMapIoSpace(非 Ex) + 导入 2 个   ← 漏洞驱动
            #   acpi     : 只有 MmMapIoSpaceEx   + 导入 5 个  ← 正常
            #   ntfs     : 没有映射 API          + 导入 8 个  ← 正常
            #   tcpip    : 没有映射 API          + 导入 9 个  ← 正常
            # 这是启发式，不是分析；有信号时会在 importSignal 里说明依据。
            $interest = @($evObj.importsOfInterest | ForEach-Object { [string]$_ })
            $item.importCount = @($evObj.imports).Count
            $item.importSignal = ''
            # 三个条件同时满足才算强信号（这是逻辑推理，不是过拟合）：
            #   ① 导入 MmMapIoSpace（非 Ex 变体）—— 有能力映射物理内存
            #   ② 有设备名候选                  —— 暴露设备给用户态（没有设备 = 用户态够不着 = 不可能 BYOVD）
            #   ③ 导入总数 < 4                  —— 实现极简（有大功能面的驱动不会这么少）
            # 实测验证：
            #   rtcore64 : ①✓ ②✓(RTCore64/PhysicalMemory) ③2个 → 命中
            #   amdgpio2 : ①✓ ②✗（无设备名）             ③2个 → 不命中
            #   amdsbs   : ①✓ ②✗（无设备名）             ③2个 → 不命中
            #   amdpsp   : ①✓ ②✓(\Device\amdpsp)         ③2个 → 命中（确实值得测）
            #   acpi/ntfs/tcpip : ①✗（只有 Ex 变体或没有）        → 不命中
            $hasMapIo = (@($interest | Where-Object { $_ -eq 'MmMapIoSpace' }).Count -gt 0)
            $hasDevice = (@($item.deviceList).Count -gt 0)
            if ($hasMapIo -and $hasDevice -and $item.importCount -gt 0 -and $item.importCount -lt 4) {
                $item.importSignal = ('MmMapIoSpace(非 Ex) + 暴露设备 + 导入仅 ' + $item.importCount + ' 个：可实现任意物理内存读写')
            }
        }
    } catch { }

    # riskScore：**危险度**，和 confidence（分析完整度）分开算
    #   confidence 度量"我把这个文件看懂了多少"，正常的功能驱动天然分高（结构完整）
    #   riskScore 只由危险信号构成，系统自带驱动降权
    $risk = 0.0
    if ($item.criticalDevice) { $risk += 0.60 }
    # IOCTL 候选**不参与打分**：实测 rtcore64 用跳转表分派，正则扫出的候选 100% 是噪音；
    # 而跳转表是编译器对 switch 的默认生成方式，所以这个信号在真实驱动上基本没有信息量。
    # 字段保留（供人参考 + 动态验证时挑码），但不再贡献危险度。
    if ($item.knownSample -ne '') { $risk += 0.10 }
    if ($item.importSignal -ne '') { $risk += 0.40 }
    if ($item.isSystemDriver) { $risk -= 0.20 }
    if ($risk -lt 0) { $risk = 0.0 }
    if ($risk -gt 1) { $risk = 1.0 }
    $item.riskScore = [Math]::Round($risk, 2)

    # ---- 动态结论反哺 ----
    # 动态验证比静态猜测强一个数量级：跑过 driver.vm.matrix 的驱动，用实测结论修正静态分。
    # finalRisk 才是"证据级别"的危险度；riskScore 保留为静态猜测，便于对比。
    $item.finalRisk = $item.riskScore
    $item.dynamic = $null
    $item.dynamicReason = ''
    try {
        $sha = [string]$item.sha256
        if ($sha -match '^[0-9A-Fa-f]{64}$') {
            $dynFile = Join-Path (Join-Path $script:LctAuditRoot 'var\vm\driver-dynamic') ($sha.ToUpperInvariant() + '.json')
            if (Test-Path -LiteralPath $dynFile) {
                $dyn = Get-Content -LiteralPath $dynFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $w = [string]$dyn.worst
                $item.dynamic = [pscustomobject][ordered]@{
                    testedAt = [string]$dyn.testedAt
                    profile = [string]$dyn.profile
                    action = [string]$dyn.action
                    worst = $w
                    verdicts = $dyn.verdicts
                }
                if ($w -eq 'crash' -or $w -eq 'timeout') {
                    # 动态确认缺陷：静态分不再重要，直接顶到最高
                    $item.finalRisk = 1.0
                    $item.dynamicReason = '动态确认：' + $w + '（' + $dyn.profile + '/' + $dyn.action + '）'
                } elseif ($w -eq 'error') {
                    # 驱动对畸形输入返回错误码 = 有校验，静态猜测降权
                    $item.finalRisk = [Math]::Round([double]$item.riskScore * 0.5, 2)
                    $item.dynamicReason = '动态验证：畸形包被拒（有校验），静态分降权'
                } elseif ($w -eq 'ok-data') {
                    $v = $dyn.verdicts
                    $allOk = ([int]$v.error -eq 0 -and [int]$v.timeout -eq 0 -and [int]$v.crash -eq 0)
                    if ($allOk) {
                        $item.finalRisk = [Math]::Min(1.0, [Math]::Round([double]$item.riskScore + 0.35, 2))
                        $item.dynamicReason = '动态验证：畸形包也全部成功（无校验），静态分上调'
                    } else {
                        $item.finalRisk = $item.riskScore
                        $item.dynamicReason = '动态验证：部分变异被拒（有部分校验）'
                    }
                } else {
                    $item.dynamicReason = '动态验证：no-device，结论不适用（设备没打开）'
                }
            }
        }
    } catch { }

    if ($item.criticalDevice) {
        $item.grade = 'L4-critical-device'
        $item.verdict = '暴露物理内存类设备（强 BYOVD 特征）' + $(if ($item.isSystemDriver) { '；但属系统自带驱动' } else { '' })
    } elseif ($item.ioctlCandidates -gt 0) {
        $item.grade = 'L3-ioctl-candidate'
        $item.verdict = ('有 ' + $item.ioctlCandidates + ' 个 IOCTL 候选（启发式，需动态验证才算数）')
    } elseif ($item.deviceCandidates -gt 0) {
        $item.grade = 'L2-device-only'
        $item.verdict = ('有 ' + $item.deviceCandidates + ' 个设备名候选，无 IOCTL 候选')
    } else {
        $item.grade = 'L1-no-signal'
        $item.verdict = '有效 PE，无设备名/IOCTL 候选'
    }

    # 分诊：静态分析的价值在于"把值得深挖的挑出来"，而不是给所有东西打个分
    #   investigate = 值得做动态验证（外来驱动、或暴露物理内存、或命中已知样本）
    #   weak        = 有信号但大概率正常（系统自带驱动有 IOCTL 是正常的）
    #   benign      = 没有可利用信号
    # 分诊用 riskScore（危险度），不用 confidence（分析完整度）
    # 分诊优先级：confirmed（动态实测确认）> investigate（静态可疑）> weak > benign
    if ($item.grade -eq 'L0-invalid') { $item.triage = 'benign' }
    elseif ($null -ne $item.dynamic -and @('crash', 'timeout') -contains [string]$item.dynamic.worst) { $item.triage = 'confirmed' }
    elseif ([double]$item.finalRisk -ge 0.25) { $item.triage = 'investigate' }
    elseif ([double]$item.finalRisk -ge 0.15) { $item.triage = 'weak' }
    else { $item.triage = 'benign' }
    return [pscustomobject]$item
}

function Invoke-LctDriverBatchScan {
    <#
    .SYNOPSIS driver.batch.scan：对一个目录里的 .sys 做静态批量鉴定（不加载、不发 IOCTL）。
    .DESCRIPTION
      产出一份分级报告（L0 无效 / L1 无信号 / L2 有设备 / L3 有 IOCTL 候选）。
      L3 只是"候选"，**不等于漏洞**；确认必须走动态验证（driver.use + driver.ctl.send）。
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$Pattern = '*.sys',
        [int]$MaxFiles = 200,
        [switch]$Recurse,
        [switch]$SkipDraft
    )
    $verb = 'driver.batch.scan'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if ([string]::IsNullOrWhiteSpace($Dir)) {
        return New-LctResult -Verb $verb -Errors @('缺少 dir（要扫描的目录）')
    }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return New-LctResult -Verb $verb -Errors @('目录不存在: ' + $Dir)
    }
    if ($MaxFiles -lt 1) { $MaxFiles = 1 }
    if ($MaxFiles -gt 2000) {
        $MaxFiles = 2000
        $null = $warnings.Add('MaxFiles 超过上限，已收敛为 2000')
    }

    $gciArgs = @{ LiteralPath = $Dir; File = $true; Filter = $Pattern; ErrorAction = 'SilentlyContinue' }
    if ($Recurse) { $gciArgs['Recurse'] = $true }
    $all = @(Get-ChildItem @gciArgs)
    $truncated = $false
    if (@($all).Count -gt $MaxFiles) {
        $all = @($all | Select-Object -First $MaxFiles)
        $truncated = $true
        $null = $warnings.Add(('目录里匹配的文件超过 MaxFiles=' + $MaxFiles + '，只处理前 ' + $MaxFiles + ' 个'))
    }
    if (@($all).Count -eq 0) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                dir = $Dir; pattern = $Pattern; total = 0; truncated = $false; items = @()
                summary = [pscustomobject][ordered]@{ invalid = 0; noSignal = 0; deviceOnly = 0; ioctlCandidate = 0; criticalDevice = 0; systemDrivers = 0; investigate = 0
                    signedValid = 0; unsigned = 0; knownSamples = 0; ms = 0 }
                note = '目录里没有匹配的文件'
            })
    }

    $known = Get-LctAuditKnownHashes
    $items = New-Object System.Collections.ArrayList
    $invalid = 0; $noSignal = 0; $deviceOnly = 0; $ioctlCand = 0; $criticalDev = 0; $sysDrv = 0; $investigate = 0
    $signedValid = 0; $unsigned = 0; $knownCount = 0; $confirmed = 0

    foreach ($f in $all) {
        $it = $null
        try { $it = Get-LctAuditItem -Path $f.FullName -DoDraft:(-not $SkipDraft) -KnownHashes $known } catch {
            # 兜底对象必须和正常路径同构，否则消费方（测试/UI）按字段取值会拿到 null
            $it = [pscustomobject][ordered]@{
                file = $f.Name; path = $f.FullName; exists = $true; lengthBytes = $f.Length
                sha256 = ''; signatureStatus = ''; signatureClass = ''; isMicrosoftSigner = $false
                likelyTestSigned = $false; deviceCandidates = 0; ioctlCandidates = 0; confidence = 0.0
                deviceList = @(); likelyIoctl = 0; riskScore = 0.0
                criticalDevice = $false; isSystemDriver = $false
                knownSample = ''; confidenceReason = ''; triage = 'benign'
                importCount = 0; importSignal = ''; ioctlReliability = 'low';
                finalRisk = 0.0; dynamic = $null; dynamicReason = ''
                grade = 'L0-invalid'; verdict = ('分析异常: ' + $_.Exception.Message)
            }
        }
        $null = $items.Add($it)
        switch ([string]$it.grade) {
            'L0-invalid' { $invalid++ }
            'L1-no-signal' { $noSignal++ }
            'L2-device-only' { $deviceOnly++ }
            'L3-ioctl-candidate' { $ioctlCand++ }
            'L4-critical-device' { $criticalDev++ }
        }
        if ([string]$it.signatureStatus -eq 'Valid') { $signedValid++ } else { $unsigned++ }
        if ([string]$it.knownSample -ne '') { $knownCount++ }
        if ([bool]$it.isSystemDriver) { $sysDrv++ }
        if ([string]$it.triage -eq 'investigate') { $investigate++ }
        if ([string]$it.triage -eq 'confirmed') { $confirmed++ }
    }

    $sw.Stop()
    $data = [pscustomobject][ordered]@{
        dir         = $Dir
        pattern     = $Pattern
        total       = @($items).Count
        truncated   = $truncated
        summary     = [pscustomobject][ordered]@{
            invalid         = $invalid
            noSignal        = $noSignal
            deviceOnly      = $deviceOnly
            ioctlCandidate  = $ioctlCand
            criticalDevice  = $criticalDev
            systemDrivers   = $sysDrv
            investigate     = $investigate
            confirmed       = $confirmed
            signedValid     = $signedValid
            unsigned        = $unsigned
            knownSamples    = $knownCount
            ms              = $sw.ElapsedMilliseconds
        }
        items       = @($items)
        note        = 'triage=investigate 的条目才值得做动态验证（driver.use + driver.ctl.send）；L3 只是有 IOCTL 候选（启发式），系统自带驱动命中 L3 是正常的（triage=weak）。本扫描全程不加载驱动、不发 IOCTL。'
    }
    $triageRank = @{ 'investigate' = 0; 'weak' = 1; 'benign' = 2 }
    $rank = [ordered]@{ 'L4-critical-device' = 0; 'L3-ioctl-candidate' = 1; 'L2-device-only' = 2; 'L1-no-signal' = 3; 'L0-invalid' = 4 }
    $sorted = @($items | Sort-Object @{ Expression = { $triageRank[[string]$_.triage] } }, @{ Expression = { $rank[[string]$_.grade] } }, @{ Expression = { $_.file } })
    $data.items = $sorted

    $log = $null
    if (Get-Command -Name 'Write-LctQuiet' -ErrorAction SilentlyContinue) {
        $log = Write-LctQuiet -Verb $verb -Level info -Message 'driver.batch.scan 完成' -Data @{
            dir = $Dir; total = @($items).Count; ioctlCandidate = $ioctlCand; ms = $sw.ElapsedMilliseconds
        }
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

Export-ModuleMember -Function Invoke-LctDriverBatchScan, Get-LctAuditDeps