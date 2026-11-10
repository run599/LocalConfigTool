# LocalConfigTool - core\Ai.psm1
#
# AI 接入层（让 AI 能安全地编排本工具，而不是让 AI 直接裸调引擎）。
#
# 设计原则（重要）：
#   1) 本模块**不调用任何 LLM**。AI 是调用方（MCP / HTTP / 命令行都行），这里只提供：
#      机器可读清单（能做什么）、确定性计划（该按什么顺序做）、确认闸门（执行前必须拿到人给的短语）。
#   2) 能力顺序是硬的：普通用户 → （提权路线）→ 管理员/SYSTEM → （driver.load）→ 内核原语。
#      计划生成器会按这个顺序装配步骤，并且把「当前是否已提权」算进去。
#   3) 护栏是"人在回路"：mutating 的 verb 真正执行（-Apply）前，必须出示 ai.plan 发出的
#      **一次性确认短语**（I-UNDERSTAND-<8hex>，10 分钟有效、用后即焚、绑定 verb+args）。
#      诚实说明：有执行权的 AI 理论上可以自己回填该短语 —— 真正的护栏是界面每次都弹确认框 +
#      审计日志。本模块能做到的是"要求显式确认 + 全量留痕"，不假装能拦死自主 AI。
#   4) 只读操作（清单/计划/预览）永远不产生副作用。
#
# 对应 verb：ai.manifest / ai.plan / ai.run

$script:LctAiConfirmPrefix = 'I-UNDERSTAND-'
$script:LctAiConfirmTtlSeconds = 600

function Get-LctAiVarDir {
    param()
    $d = ''
    try { $d = [string](Get-LctVarDir) } catch { $d = '' }
    if ([string]::IsNullOrWhiteSpace($d)) { $d = Join-Path (Split-Path -Parent $PSScriptRoot) 'var' }
    return $d
}

function Get-LctAiPendingDir {
    param()
    $d = Join-Path (Get-LctAiVarDir) 'ai\pending'
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    return $d
}

function Remove-LctAiPendingFile {
    # 一次性确认短语文件：只允许走回收站（项目铁律），且必须先加载 Microsoft.VisualBasic 程序集——
    # 否则 [Microsoft.VisualBasic.FileIO.FileSystem] 不可用、异常被吞，文件还在 ⇒ 短语可被重复使用。
    # 若回收站删除不可用，就把它标记成 used（调用方负责写标记），绝不永久删除。
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        return (-not (Test-Path -LiteralPath $Path))
    } catch { return $false }
}

function Get-LctAiArgsHash {
    param($ArgBag = $null)
    if ($null -eq $ArgBag) { return '' }
    try {
        $json = ($ArgBag | ConvertTo-Json -Depth 10 -Compress)
        $sha = [Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } catch { return '' }
}

function Get-LctAiElevationForVerb {
    # 返回 'admin' | 'non-elevated' | 'none'
    param([AllowEmptyString()][string]$Verb = '', [bool]$Mutating = $false)
    $v = [string]$Verb
    if ($v -in @('driver.load', 'driver.start', 'driver.stop', 'driver.unload', 'driver.testsigning', 'driver.ctl.send')) { return 'admin' }
    if ($v -eq 'plugins.run') { return 'non-elevated' }   # 提权插件必须在非提权上下文跑
    if ($v -eq 'samples.get') { return 'none' }
    if ($v -eq 'ai.do') { return 'none' }             # 编排层：具体步骤各自判定，别把它标成需要管理员          # 下载/校验样本只写 var\samples，不需要管理员
    if ($Mutating -and ($v -like 'wdac.*' -or $v -like 'accounts.*' -or $v -like 'registry.*')) { return 'admin' }
    if ($Mutating -and $v -like 'process.*') { return 'admin' }
    if ($Mutating) { return 'admin' }
    return 'none'
}

function Get-LctAiFlows {
    # 预置的高层流程（AI 直接照抄即可，不用自己发明顺序）
    param()
    return @(
        [pscustomobject][ordered]@{
            id    = 'elevate-then-drive'
            title = '先提权到 SYSTEM，再加载驱动'
            why   = '本工具默认普通权限；sc create/sc start 需要管理员，所以顺序不能反'
            steps = @(
                [pscustomobject][ordered]@{ n = 1; verb = 'capability.status'; args = $null; why = '看当前权限（isAdmin / integrityLevel / canLoadDriver）'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 2; verb = 'plugins.run'; args = [ordered]@{ plugin = 'cve-2026-49176'; params = [ordered]@{}; timeout = 300 }; why = '普通用户 → 管理员/SYSTEM（提权路线）'; needsElevation = 'non-elevated'; mutating = $true }
                [pscustomobject][ordered]@{ n = 3; verb = 'capability.status'; args = $null; why = '确认 isAdmin=true 再继续'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 4; verb = 'driver.load'; args = [ordered]@{ path = '<你的 .sys 绝对路径>'; name = '<服务名>'; startType = 'demand' }; why = '加载驱动（需要管理员）'; needsElevation = 'admin'; mutating = $true }
                [pscustomobject][ordered]@{ n = 5; verb = 'driver.verify'; args = [ordered]@{ name = '<服务名>' }; why = '确认驱动真的在运行（以系统返回为准）'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 6; verb = 'driver.unload'; args = [ordered]@{ name = '<服务名>' }; why = '用完立即卸载（不删 .sys，生成 revert）'; needsElevation = 'admin'; mutating = $true }
            )
        },
        [pscustomobject][ordered]@{
            id    = 'draft-then-send'
            title = '静态草案 → 人工审定 → 预览 → 才发送 IOCTL'
            why   = '未知 IOCTL 直接发会蓝屏；草案只是候选，语义必须人确认'
            steps = @(
                [pscustomobject][ordered]@{ n = 1; verb = 'driver.profile.draft'; args = [ordered]@{ path = '<.sys 绝对路径>' }; why = '静态分析：设备名候选 + IOCTL 候选（只读）'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 2; verb = 'driver.profile.save'; args = [ordered]@{ id = '<id>'; json = '<审定后的 profile JSON>'; override = $false }; why = '落盘审定过的 profile（走校验）'; needsElevation = 'admin'; mutating = $true }
                [pscustomobject][ordered]@{ n = 3; verb = 'driver.profile.validate'; args = [ordered]@{ id = '<id>'; path = '<.sys>' }; why = '指纹门：sha256 必须与实际文件一致'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 4; verb = 'driver.ctl.send'; args = [ordered]@{ profile = '<id>'; action = '<action 名>'; payload = '<JSON>' }; why = '预览：只给 IOCTL 与缓冲区十六进制，不发出去'; needsElevation = 'none'; mutating = $false }
                [pscustomobject][ordered]@{ n = 5; verb = 'driver.ctl.send'; args = [ordered]@{ profile = '<id>'; action = '<action 名>'; payload = '<JSON>' }; why = '人已核对预览字节后才 -Apply 真发'; needsElevation = 'admin'; mutating = $true }
            )
        }
    )
}

function Get-LctAiManifest {
    # 机器可读清单：一个 AI 看完就知道"能做什么、要不要提权、按什么顺序"。
    param()
    $verb = 'ai.manifest'
    $warnings = New-Object System.Collections.ArrayList
    $table = @()
    try { $table = @(Get-LctVerbTable) } catch { $null = $warnings.Add('取 verb 表失败：' + $_.Exception.Message) }
    $isAdmin = $false
    try { $isAdmin = [bool](Test-LctElevated) } catch { }
    $items = New-Object System.Collections.ArrayList
    foreach ($v in $table) {
        $name = [string]$v.verb
        $mut = [bool]$v.mutating
        $need = Get-LctAiElevationForVerb -Verb $name -Mutating $mut
        $blocked = ''
        if ($need -eq 'admin' -and (-not $isAdmin)) { $blocked = '未提权：需要先走 elevate 路线（plugins.run cve-2026-49176）' }
        if ($need -eq 'non-elevated' -and $isAdmin) { $blocked = '当前已提权：该插件要求非提权上下文，请以普通用户身份运行' }
        $null = $items.Add([pscustomobject][ordered]@{
                name          = $name
                summary       = [string]$v.summary
                mutating      = $mut
                needsElevation = $need
                blockedNow    = $blocked
                args          = @($v.args)
            })
    }
    $data = [pscustomobject][ordered]@{
        tool        = 'LocalConfigTool'
        apiVersion  = 1
        generatedAt = (Get-Date).ToString('s')
        cli         = 'powershell -NoProfile -ExecutionPolicy Bypass -File core\Engine.ps1 -Verb <verb> -ArgsFile <json文件> [-Apply]'
        mcp         = 'powershell -NoProfile -ExecutionPolicy Bypass -File tools\McpServer.ps1  （JSON-RPC 2.0 over stdio）'
        context     = [pscustomobject][ordered]@{
            isAdmin        = $isAdmin
            verbCount      = @($items).Count
            mutatingCount  = @($items | Where-Object { $_.mutating }).Count
        }
        rules       = @(
            'mutating=true 的 verb 默认只预览；真正执行要加 -Apply，且 AI 必须先拿到人出示的确认短语（ai.plan 发出、一次性、10 分钟有效）。',
            'driver.load/start/stop/unload/testsigning 与 driver.ctl.send 需要管理员/SYSTEM；未提权时引擎会拦住并返回顺序提示，不要重试，先去提权。',
            '提权用 plugins.run（插件 cve-2026-49176），它要求**非提权**上下文；提权后必须用 capability.status 确认 isAdmin=true 再加载驱动。',
            '不要对未知驱动盲发 IOCTL（可能蓝屏）：先 driver.profile.draft → 人审定 → profile.validate 过指纹 → ctl.send 预览核对字节 → 才 -Apply。',
            '本工具不做隐藏/规避安全产品；所有动作写审计日志（var\logs）。',
            '能力清单里的 blockedNow 字段直接告诉你"现在这一步能不能做"，不要猜。'
        )
        flows       = @(Get-LctAiFlows)
        safety      = [pscustomobject][ordered]@{
            confirmPrefix          = $script:LctAiConfirmPrefix
            confirmTtlSeconds      = $script:LctAiConfirmTtlSeconds
            mutatingRequiresConfirm = $true
            noAutoRetry            = $true
            humanInTheLoop         = '确认短语由 ai.plan 生成并显示给人；人点了确认才把短语交给 AI 执行。有执行权的 AI 理论上能自己回填——真正的护栏是界面确认框 + 审计日志。'
            forbidden              = @('对未知 IOCTL 盲扫', '隐藏自身/规避杀软', '把提权后的 SYSTEM 会话留在机器上不清理')
        }
        verbs       = @($items)
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Data $data
}

function Invoke-LctAiPlan {
    <#
    .SYNOPSIS
        把一句自然语言目标，转成**确定性的、有序的**执行计划（只读，不执行任何动作）。
    #>
    param([AllowEmptyString()][string]$Goal = '')
    $verb = 'ai.plan'
    $warnings = New-Object System.Collections.ArrayList
    $g = ([string]$Goal).Trim()
    if ($g -eq '') {
        return New-LctResult -Verb $verb -Errors @('缺少 goal（一句话目标，例如「提权到system然后加载我的驱动」）') -Data ([pscustomobject]@{ goal = ''; steps = @() })
    }
    $isAdmin = $false
    try { $isAdmin = [bool](Test-LctElevated) } catch { }
    $integ = 'Unknown'
    try { $integ = [string](Get-LctCapIntegrityLevel).name } catch { }

    $steps = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $low = $g.ToLowerInvariant()

    $wantElevate = ($low -match '提权|system|管理员|admin|elevat|root')
    # "加载"要区分动作与描述：「挂上去/装上/加载 xxx 驱动」是动作；「已加载的驱动/装了哪些」是描述（只想列表）
    $wantLoadVerb = (($low -match '挂上|挂上去|装上|装载|挂载|运行|注入') -or (($low -match '加载') -and ($low -notmatch '已加载|加载的|加载了哪些|装了哪些')))
    $wantList = ($low -match '列出|哪些驱动|已加载的驱动|驱动列表|查看.*驱动|看看.*驱动|driver\.list|装了哪些|设备列表')
    $wantUnload = ($low -match '卸载|卸了|卸掉|移除|清理|cleanup|unload')
    $wantLoad = ($wantLoadVerb -or ($null -ne $sampleHit -and ($low -match '加载|挂|装|读内核')))
    $wantDriver = ($wantLoad -or $wantList -or $wantUnload -or $low -match '驱动|driver|\.sys')   # 兼容旧语义
    $wantKernel = ($low -match '内核|读写|kread|kwrite|原语|primitive')
    $wantMap = ($low -match '设备|对象图|map|device')
    $wantProc = ($low -match '进程|process')
    $wantInfo = ($low -match '权限|能做什么|capabilit|status|现状')
    # 「问能力」= 直接给清单，不要叠加驱动/进程等动作（否则翻译里带的词会被误判成要执行）
    $wantManifest = ($low -match '能力清单|你能做|能干什么|有哪些功能|功能列表|怎么用|ai\.manifest')
    if ($wantManifest) {
        $wantElevate = $false; $wantLoad = $false; $wantList = $false; $wantUnload = $false
        $wantKernel = $false; $wantMap = $false; $wantProc = $false; $wantInfo = $false
        $wantDriver = $false; $sampleHit = $null; $samplePath = ''
    }

    $n = 0
    $add = {
        param($verbName, $argsObj, $why, $mut)
        $script:__n = $script:__n + 1
        $need = Get-LctAiElevationForVerb -Verb $verbName -Mutating ([bool]$mut)
        $blocked = ''
        if ($need -eq 'admin' -and (-not $isAdmin)) { $blocked = '未提权：必须先完成上面的提权步骤' }
        if ($need -eq 'non-elevated' -and $isAdmin) { $blocked = '当前已提权：该步骤要求非提权上下文' }
        $null = $steps.Add([pscustomobject][ordered]@{
                n = $script:__n; verb = $verbName; args = $argsObj; why = $why
                mutating = [bool]$mut; needsElevation = $need; blockedNow = $blocked
            })
    }
    $script:__n = 0

    # ---- 样本库识别：让"说一句话"能落到真实文件与真实 profile ----
    $sampleHit = $null
    try {
        $cat = Get-LctSampleCatalog
        $items = @()
        if ($null -ne $cat -and $null -ne $cat.data) { $items = @($cat.data.items) }
        foreach ($it in $items) {
            if (-not [bool]$it.usable) { continue }
            $sid = [string]$it.id
            $snm = [string]$it.name
            $hit = $false
            if ($low -match [regex]::Escape($sid.ToLowerInvariant())) { $hit = $true }
            $short = ($sid -split '-')[0]
            if (-not $hit -and $short.Length -ge 4 -and $low -match [regex]::Escape($short)) { $hit = $true }
            if (-not $hit -and $snm -ne '') {
                $brand = (($snm -split '（')[0]).Trim()
                if ($brand.Length -ge 5 -and $low -match [regex]::Escape($brand.ToLowerInvariant())) { $hit = $true }
            }
            if ($hit) { $sampleHit = $it; break }
        }
    } catch { }
    $sampleId = ''
    $samplePath = ''
    $sampleProfileReady = $false
    if ($null -ne $sampleHit) {
        $sampleId = [string]$sampleHit.id
        $samplePath = [string]$sampleHit.path
        if (-not (Test-Path -LiteralPath $samplePath)) { $samplePath = '' }
        $profFile = Join-Path (Join-Path (Get-LctAiVarDir) 'driver-profiles') ($sampleId + '.json')
        $sampleProfileReady = (Test-Path -LiteralPath $profFile)
    }

    $wantCleanup = ($wantUnload -or ($low -match '清理|cleanup'))

    if ($wantManifest) {
        & $add 'ai.manifest' $null '能力清单：全部 verb + 预置流程 + 安全规则（只读）' $false
    }
    if ($wantInfo -or ($wantElevate -and ($wantDriver -or $null -ne $sampleHit))) {
        & $add 'capability.status' $null '先看当前权限画像（isAdmin / integrityLevel / canLoadDriver）' $false
    }
    if ($wantElevate) {
        if ($isAdmin) {
            $null = $notes.Add('当前进程已是管理员（' + $integ + '），不需要再跑提权插件')
        } else {
            & $add 'plugins.run' ([ordered]@{ plugin = 'cve-2026-49176'; params = [ordered]@{}; timeout = 300 }) '提权路线：普通用户 → SYSTEM（该插件要求非提权上下文，恰好符合）' $true
            & $add 'capability.status' $null '提权后确认 isAdmin=true，再继续' $false
        }
    }
    # 样本：还没下载就先取（哈希门），取完路径就定了
    if ($null -ne $sampleHit -and $samplePath -eq '') {
        & $add 'samples.get' ([ordered]@{ id = $sampleId }) ('样本库取 ' + $sampleId + '：下载 + 强制 SHA256 校验，不符即丢弃') $true
        $samplePath = Join-Path (Join-Path (Get-LctAiVarDir) 'samples') ($sampleId + '.sys')
    }
    if ($wantList -and -not $wantLoad) {
        & $add 'driver.list' $null '列出已注册的驱动服务（只读；不加载任何东西）' $false
    }
    if ($wantLoad -or $null -ne $sampleHit) {
        if (-not $isAdmin) { $null = $notes.Add('加载驱动需要管理员：计划里已把提权排在前面；若提权失败，后面的驱动步骤会一直是 blockedNow') }
        $usePath = $(if ($samplePath -ne '') { $samplePath } else { '<你的 .sys 绝对路径>' })
        & $add 'driver.use' ([ordered]@{ path = $usePath }) '一条命令加载并确认在跑（服务名自动推导，启动类型 demand）' $true
        & $add 'driver.verify' ([ordered]@{ name = '<自动推导的服务名>' }) '确认驱动真的在运行（名字会自动用上一步的 serviceName）' $false
    }
    if ($wantKernel -or ($null -ne $sampleHit -and $sampleProfileReady)) {
        if (@($steps | Where-Object { $_.verb -eq 'driver.use' }).Count -eq 0) {
            & $add 'driver.use' ([ordered]@{ path = $(if ($samplePath -ne '') { $samplePath } else { '<你的 .sys 绝对路径>' }) }) '内核原语需要先把驱动加载起来' $true
        }
        if ($sampleProfileReady) {
            & $add 'driver.ctl.send' ([ordered]@{ profile = $sampleId; action = 'kread'; payload = 'addr=@ntoskrnl' }) '读内核基址的 PE 头：payload 用简写 + @ntoskrnl 自动取基址（只预览）' $false
            $null = $notes.Add('真正发送要在核对预览字节后加 -Apply（ai.do 带 confirm 才会执行），本计划默认只预览')
        } else {
            & $add 'driver.profile.draft' ([ordered]@{ path = $(if ($samplePath -ne '') { $samplePath } else { '<.sys 绝对路径>' }) }) '还没有 profile：先静态起草（只读，actions 为空）' $false
        }
    }
    if ($wantMap) {
        & $add 'driver.map' $null '对象图映射：\Device ↔ \Driver ↔ 服务名（只读，附 PnP 权威旁证）' $false
    }
    if ($wantProc) {
        & $add 'process.list' $null '进程清单（只读）' $false
    }
    if ($wantUnload -or $wantLoad -or $wantKernel -or $null -ne $sampleHit) {
        & $add 'driver.cleanup' $null '用完清理：卸掉本工具加载过的驱动（lct* 或指向样本库的），不碰系统驱动' $true
        $null = $notes.Add('清理排在最后：测完让它跑掉，别把漏洞驱动留在机器上')
    }
    if (@($steps).Count -eq 0) {
        $null = $notes.Add('没能从目标里识别出具体动作。可选的下一步：ai.manifest 看全部 55 个 verb，或把目标说得更具体（例：提权到system / 加载驱动 / 看看有哪些设备）')
        & $add 'ai.manifest' $null '先看能力清单再决定' $false
    }

    # 为第一个未阻塞的 mutating 步骤发一次性确认短语（人才看得到；AI 执行时必须回填）
    $phrase = ''
    $phraseFor = $null
    $firstMut = @($steps | Where-Object { $_.mutating -and $_.blockedNow -eq '' }) | Select-Object -First 1
    if ($null -ne $firstMut) {
        $hex = -join (1..8 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
        $phrase = $script:LctAiConfirmPrefix + $hex
        $phraseFor = [pscustomobject][ordered]@{ verb = $firstMut.verb; args = $firstMut.args }
        try {
            $pending = [ordered]@{
                phrase    = $phrase
                verb      = [string]$firstMut.verb
                argsHash  = (Get-LctAiArgsHash -Args $firstMut.args)
                createdAt = (Get-Date).ToString('s')
                expiresAt = (Get-Date).AddSeconds($script:LctAiConfirmTtlSeconds).ToString('s')
                goal      = $g
            }
            $file = Join-Path (Get-LctAiPendingDir) ($hex + '.json')
            [IO.File]::WriteAllText($file, ($pending | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        } catch { $null = $warnings.Add('写确认短语失败（执行时会被要求重新 plan）：' + $_.Exception.Message) }
    }

    $data = [pscustomobject][ordered]@{
        goal           = $g
        isAdmin        = $isAdmin
        integrityLevel = $integ
        steps          = @($steps)
        stepCount      = @($steps).Count
        nextAction     = ($(if ($null -ne $firstMut) { '先执行第 1 步；遇到 mutating 步骤时，把 confirmPhrase 回填给 ai.run' } else { '按顺序执行只读步骤即可' }))
        confirmPhrase  = $phrase
        confirmFor     = $phraseFor
        confirmTtlSec  = $script:LctAiConfirmTtlSeconds
        notes          = @($notes)
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Data $data
}

function Invoke-LctAiDo {
    <#
    .SYNOPSIS
        AI 一键流水线：一句话 → 完整计划（参数已解析）→ 逐步执行。
        写步骤必须先拿到 ai.plan 的一次性确认短语（-Confirm），否则拒绝执行。
        步骤之间会自动传参：samples.get 的 targetPath 传给 driver.use；driver.use 的 serviceName 传给 driver.verify。
    #>
    param(
        [AllowEmptyString()][string]$Goal = '',
        [switch]$Apply,
        [AllowEmptyString()][string]$Confirm = ''
    )
    $verb = 'ai.do'
    $plan = Invoke-LctAiPlan -Goal $Goal
    if ($null -eq $plan) { return New-LctResult -Verb $verb -Errors @('计划生成失败') }
    $steps = @()
    if ($null -ne $plan.data) { $steps = @($plan.data.steps) }
    $phrase = ''
    if ($null -ne $plan.data -and $null -ne $plan.data.PSObject.Properties['confirmPhrase']) { $phrase = [string]$plan.data.confirmPhrase }
    $isAdmin = $false
    if ($null -ne $plan.data) { $isAdmin = [bool]$plan.data.isAdmin }
    $mutSteps = @($steps | Where-Object { $_.mutating })

    if (-not $Apply) {
        return New-LctResult -Verb $verb -Warnings @($plan.warnings) -Data ([pscustomobject][ordered]@{
                goal = $Goal; isAdmin = $isAdmin; steps = @($steps); stepCount = @($steps).Count
                mutatingCount = @($mutSteps).Count; confirmPhrase = $phrase; applied = $false
                note = '预览：没有执行任何动作。要执行请带 -Apply 和上面这个 confirmPhrase'
            })
    }
    if (@($mutSteps).Count -gt 0) {
        $chk = Test-LctAiConfirm -Phrase $Confirm -Verb ([string]$mutSteps[0].verb) -ArgBag $mutSteps[0].args
        if (-not $chk.ok) {
            return New-LctResult -Verb $verb -Errors @('执行被拒（人未确认）：' + [string]$chk.error) -Data ([pscustomobject][ordered]@{
                    apply = $true; applied = $false; needConfirm = $true; confirmPhrase = $phrase; steps = @($steps)
                })
        }
    }

    $ctx = @{}
    $results = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if ($null -ne $plan) { foreach ($w in @($plan.warnings)) { $null = $warnings.Add($w) } }

    foreach ($st in @($steps)) {
        $vn = [string]$st.verb
        if ($vn -in @('ai.do', 'ai.plan', 'ai.manifest')) { continue }
        $blocked = [string]$st.blockedNow
        if ($blocked -ne '' -and [int]$st.n -gt 1) {
            $null = $results.Add([pscustomobject][ordered]@{ n = [int]$st.n; verb = $vn; ok = $false; skipped = $true; reason = $blocked })
            continue
        }
        # 参数注入：把前一步的产物填进后一步
        $sa = $st.args
        if ($null -ne $sa -and $sa -is [System.Collections.IDictionary]) {
            $sa2 = @{}
            foreach ($k in @($sa.Keys)) { $sa2[$k] = $sa[$k] }
            if ($sa2.ContainsKey('path')) {
                $pv = [string]$sa2['path']
                if (($pv -eq '' -or $pv -match '^<') -and $ctx.ContainsKey('samplePath')) { $sa2['path'] = [string]$ctx['samplePath'] }
            }
            if ($sa2.ContainsKey('name')) {
                $nv = [string]$sa2['name']
                if ($nv -match '^<' -and $ctx.ContainsKey('serviceName')) { $sa2['name'] = [string]$ctx['serviceName'] }
            }
            if ($sa2.ContainsKey('profile')) {
                if ([string]$sa2['profile'] -match '^<' -and $ctx.ContainsKey('sampleId')) { $sa2['profile'] = [string]$ctx['sampleId'] }
            }
            $sa = $sa2
        }
        $mut = [bool]$st.mutating
        try {
            $r = Invoke-LctEngine -Verb $vn -Args $sa -Apply:$mut
            $okFlag = [bool]$r.ok
            $null = $results.Add([pscustomobject][ordered]@{
                    n = [int]$st.n; verb = $vn; ok = $okFlag; applied = [bool]$r.applied
                    errors = @($r.errors)
                })
            if (-not $okFlag) { foreach ($e in @($r.errors)) { $null = $errors.Add($vn + ': ' + [string]$e) } }
            # 产物入上下文，供后续步骤注入
            if ($null -ne $r.data) {
                if ($vn -eq 'samples.get' -and $null -ne $r.data.PSObject.Properties['targetPath']) { $ctx['samplePath'] = [string]$r.data.targetPath }
                if ($vn -eq 'samples.get' -and $null -ne $r.data.PSObject.Properties['id']) { $ctx['sampleId'] = [string]$r.data.id }
                if (($vn -eq 'driver.use' -or $vn -eq 'driver.load') -and $null -ne $r.data.PSObject.Properties['serviceName']) {
                    $ctx['serviceName'] = [string]$r.data.serviceName
                }
                if ($vn -eq 'driver.use' -and $null -ne $r.data.PSObject.Properties['path'] -and -not $ctx.ContainsKey('samplePath')) { $ctx['samplePath'] = [string]$r.data.path }
            }
        } catch {
            $null = $results.Add([pscustomobject][ordered]@{ n = [int]$st.n; verb = $vn; ok = $false; errors = @($_.Exception.Message) })
            $null = $errors.Add($vn + ': ' + $_.Exception.Message)
        }
    }
    try { Write-LctLog -Level 'change' -Message ('[ai.do] ' + $Goal) -Data @{ steps = @($results | ForEach-Object { $_.verb }); ok = @($results | Where-Object { $_.ok }).Count } | Out-Null } catch { }
    return New-LctResult -Verb $verb -Applied -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            goal = $Goal; applied = $true; stepCount = @($steps).Count; steps = @($steps); results = @($results)
            okCount = @($results | Where-Object { $_.ok }).Count
            failCount = @($results | Where-Object { $_.ok -eq $false }).Count
            context = [pscustomobject][ordered]@{ sampleId = $(if ($ctx.ContainsKey('sampleId')) { $ctx['sampleId'] } else { '' }); samplePath = $(if ($ctx.ContainsKey('samplePath')) { $ctx['samplePath'] } else { '' }); serviceName = $(if ($ctx.ContainsKey('serviceName')) { $ctx['serviceName'] } else { '' }) }
        })
}

function ConvertTo-LctAiGoalText {
    # 把 LLM 的输出清洗成"一行目标"：去代码块、去引号、取第一行、去掉"目标："前缀、限长。
    # 单独抽出来是为了能不联网就测。
    param([AllowEmptyString()][string]$Raw = '', [int]$MaxLen = 80)
    $t = [string]$Raw
    if ($t -eq '') { return '' }
    $t = $t -replace '(?s)```.*?```', ' '
    $t = $t -replace '(?s)```', ' '
    $rows = @($t -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if (@($rows).Count -eq 0) { return '' }
    $one = [string]$rows[0]
    $one = $one -replace '^\s*(目标|Goal|goal)\s*[:：]\s*', ''
    $one = $one.Trim('"', "'", '`', ' ', [char]0x201C, [char]0x201D, [char]0x300C, [char]0x300D)
    $one = ($one -replace '\s+', ' ').Trim()
    if ($one.Length -gt $MaxLen) { $one = $one.Substring(0, $MaxLen) }
    return $one
}

# =====================================================================
# AI 供应商 & 凭据（云端 API 支持）
#   协议三种：ollama（/api/generate）/ openai 兼容（/v1/chat/completions）/ anthropic（/v1/messages）
#   密钥：DPAPI（当前用户）加密存 var\ai\credential.json，明文不落盘、不进日志
# =====================================================================
function Resolve-LctAiProvider {
    # provider 可显式给，也可从 endpoint 推断
    param([AllowEmptyString()][string]$Provider = '', [AllowEmptyString()][string]$Endpoint = '')
    $p = ([string]$Provider).Trim().ToLowerInvariant()
    if ($p -ne '' -and $p -ne 'auto') { return $p }
    $e = ([string]$Endpoint).ToLowerInvariant()
    if ($e -match 'anthropic|claude') { return 'anthropic' }
    if ($e -match 'openai|deepseek|moonshot|bigmodel|dashscope|siliconflow|groq|together|openrouter|/v1|/chat/completions') { return 'openai' }
    return 'ollama'
}

function Get-LctAiCredPath {
    $d = Join-Path (Get-LctAiVarDir) 'ai'
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    return (Join-Path $d 'credential.json')
}

function Read-LctAiCredStore {
    $p = Get-LctAiCredPath
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = @{}
        foreach ($k in @($raw.PSObject.Properties.Name)) { $h[$k] = $raw.$k }
        return $h
    } catch { return @{} }
}

function Save-LctAiCredential {
    # DPAPI（CurrentUser）加密；只存密文
    param([string]$Provider = 'openai', [string]$Key = '')
    $prov = ([string]$Provider).Trim().ToLowerInvariant()
    $k = ([string]$Key).Trim()
    if ($prov -eq '' -or $k -eq '') { return [pscustomobject]@{ ok = $false; error = 'provider/key 不能为空' } }
    try {
        $sec = ConvertTo-SecureString -String $k -AsPlainText -Force
        $enc = ConvertFrom-SecureString -SecureString $sec
        $store = Read-LctAiCredStore
        $store[$prov] = [ordered]@{ key = $enc; savedAt = (Get-Date).ToString('s'); len = $k.Length }
        $path = Get-LctAiCredPath
        [IO.File]::WriteAllText($path, (($store | ConvertTo-Json -Depth 4)), (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ ok = $true; error = ''; path = $path }
    } catch { return [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
}

function Get-LctAiCredential {
    # 返回明文 key（仅内存）；解不出来就返回空
    param([string]$Provider = 'openai')
    $prov = ([string]$Provider).Trim().ToLowerInvariant()
    if ($prov -eq '') { return '' }
    $store = Read-LctAiCredStore
    if (-not $store.ContainsKey($prov)) { return '' }
    $node = $store[$prov]
    $enc = ''
    if ($null -ne $node -and $null -ne $node.PSObject.Properties['key']) { $enc = [string]$node.key }
    if ($enc -eq '') { return '' }
    try {
        $sec = ConvertTo-SecureString -String $enc
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return '' }
}

function Get-LctAiCredStatus {
    $store = Read-LctAiCredStore
    $items = New-Object System.Collections.ArrayList
    foreach ($k in @($store.Keys)) {
        $node = $store[$k]
        $len = 0; $at = ''
        if ($null -ne $node -and $null -ne $node.PSObject.Properties['len']) { $len = [int]$node.len }
        if ($null -ne $node -and $null -ne $node.PSObject.Properties['savedAt']) { $at = [string]$node.savedAt }
        $null = $items.Add([pscustomobject][ordered]@{ provider = [string]$k; configured = $true; keyLength = $len; savedAt = $at })
    }
    return @($items)
}

function Invoke-LctAiChat {
    # 统一调用三种协议，返回 {ok,text,error,httpStatus,url,provider}
    param(
        [AllowEmptyString()][string]$Endpoint = '',
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$Provider = '',
        [AllowEmptyString()][string]$ApiKey = '',
        [AllowEmptyString()][string]$SystemPrompt = '',
        [AllowEmptyString()][string]$UserPrompt = '',
        [int]$TimeoutSec = 60
    )
    $prov = Resolve-LctAiProvider -Provider $Provider -Endpoint $Endpoint
    $ep = ([string]$Endpoint).TrimEnd('/')
    if ($ep -eq '') { $ep = $(if ($prov -eq 'ollama') { 'http://127.0.0.1:11434' } else { '' }) }
    if ($ep -ne '' -and $ep -notmatch '^https?://') { $ep = 'http://' + $ep }
    $key = ([string]$ApiKey).Trim()
    if ($key -eq '' -and $prov -ne 'ollama') { $key = Get-LctAiCredential -Provider $prov }
    $o = [ordered]@{ ok = $false; text = ''; error = ''; httpStatus = 0; url = ''; provider = $prov; model = $Model }
    if ($ep -eq '') { $o.error = '缺少 endpoint（云端示例：https://api.deepseek.com/v1）'; return [pscustomobject]$o }

    $headers = @{}
    $body = $null
    $url = ''
    switch ($prov) {
        'anthropic' {
            $url = $(if ($ep -match '/v1/messages$') { $ep } else { $ep + '/v1/messages' })
            if ($key -ne '') { $headers['x-api-key'] = $key }
            $headers['anthropic-version'] = '2023-06-01'
            $body = [ordered]@{
                model = $Model; max_tokens = 64; temperature = 0.1; system = $SystemPrompt
                messages = @([ordered]@{ role = 'user'; content = $UserPrompt })
            }
        }
        'openai' {
            $url = $(if ($ep -match '/chat/completions$') { $ep } else { $ep + '/chat/completions' })
            if ($key -ne '') { $headers['Authorization'] = 'Bearer ' + $key }
            $body = [ordered]@{
                model = $Model; temperature = 0.1; max_tokens = 64
                messages = @(
                    [ordered]@{ role = 'system'; content = $SystemPrompt },
                    [ordered]@{ role = 'user'; content = $UserPrompt }
                )
            }
        }
        default {
            $url = $(if ($ep -match '/api/generate$') { $ep } else { $ep + '/api/generate' })
            if ($key -ne '') { $headers['Authorization'] = 'Bearer ' + $key }
            $body = [ordered]@{
                model = $Model; prompt = ($SystemPrompt + "`n" + $UserPrompt); stream = $false
                options = [ordered]@{ temperature = 0.1; num_predict = 64 }
            }
        }
    }
    $o.url = $url
    try {
        $bodyJson = ($body | ConvertTo-Json -Depth 6)
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)
        $req = @{
            Method = 'Post'; Uri = $url; Body = $bodyBytes
            ContentType = 'application/json; charset=utf-8'; TimeoutSec = $TimeoutSec
            UseBasicParsing = $true; ErrorAction = 'Stop'
        }
        if ($headers.Count -gt 0) { $req['Headers'] = $headers }
        $resp = Invoke-WebRequest @req
        $respBytes = $null
        try { $respBytes = $resp.RawContentStream.ToArray() } catch { $respBytes = $null }
        $respText = ''
        if ($null -ne $respBytes -and $respBytes.Length -gt 0) { $respText = [Text.Encoding]::UTF8.GetString($respBytes) }
        else { $respText = [string]$resp.Content }
        $o.httpStatus = [int]$resp.StatusCode
        $obj = $null
        try { $obj = ($respText | ConvertFrom-Json) } catch { $obj = $null }
        $txt = ''
        if ($null -ne $obj) {
            switch ($prov) {
                'anthropic' {
                    $c = $null
                    try { $c = $obj.content } catch { $c = $null }
                    if ($null -ne $c -and @($c).Count -gt 0 -and $null -ne @($c)[0].PSObject.Properties['text']) { $txt = [string]@($c)[0].text }
                }
                'openai' {
                    $ch = $null
                    try { $ch = $obj.choices } catch { $ch = $null }
                    if ($null -ne $ch -and @($ch).Count -gt 0 -and $null -ne @($ch)[0].PSObject.Properties['message']) { $txt = [string]@($ch)[0].message.content }
                }
                default {
                    if ($null -ne $obj.PSObject.Properties['response']) { $txt = [string]$obj.response }
                    elseif ($null -ne $obj.PSObject.Properties['message'] -and $null -ne $obj.message.PSObject.Properties['content']) { $txt = [string]$obj.message.content }
                }
            }
        }
        if ($txt -eq '') {
            $o.error = $prov + ' 返回里没有文本（前 160 字：' + $respText.Substring(0, [Math]::Min(160, $respText.Length)) + '）'
        } else { $o.ok = $true; $o.text = $txt }
    } catch {
        $st = 0
        try { $st = [int]$_.Exception.Response.StatusCode } catch { $st = 0 }
        $o.httpStatus = $st
        $hint = ''
        if ($st -eq 401 -or $st -eq 403) { $hint = '（API Key 无效或没权限：用 ai.cred -action set -provider ' + $prov + ' 配一个）' }
        elseif ($st -eq 404) { $hint = '（地址不对：OpenAI 兼容要写到 /v1 这一级，例如 https://api.deepseek.com/v1）' }
        elseif ($st -eq 429) { $hint = '（被限流或额度不足）' }
        elseif ($st -eq 0) { $hint = '（连不上：检查网络/域名/端口，本机 Ollama 默认 http://127.0.0.1:11434）' }
        $o.error = '调用 ' + $prov + ' 失败' + $(if ($st -gt 0) { ' [HTTP ' + $st + ']' } else { '' }) + $hint + '：' + $_.Exception.Message
    }
    return [pscustomobject]$o
}

function Invoke-LctAiCredentialVerb {
    # ai.cred：set / status / clear（密钥只进 DPAPI 密文文件）
    param([AllowEmptyString()][string]$Action = 'status', [AllowEmptyString()][string]$Provider = '', [AllowEmptyString()][string]$Key = '')
    $verb = 'ai.cred'
    $act = ([string]$Action).Trim().ToLowerInvariant()
    if ($act -eq '') { $act = 'status' }
    $prov = ([string]$Provider).Trim().ToLowerInvariant()
    switch ($act) {
        'set' {
            if ($prov -eq '') { return New-LctResult -Verb $verb -Errors @('缺少 provider（openai / anthropic / ollama）') }
            if (([string]$Key).Trim() -eq '') { return New-LctResult -Verb $verb -Errors @('缺少 key') }
            $r = Save-LctAiCredential -Provider $prov -Key $Key
            if (-not $r.ok) { return New-LctResult -Verb $verb -Errors @('保存失败：' + $r.error) }
            return New-LctResult -Verb $verb -Data ([pscustomobject][ordered]@{
                    action = 'set'; provider = $prov; saved = $true; path = $r.path
                    note = '已用 DPAPI（当前用户）加密保存；明文不落盘。换用户/换机器需重新配置。'
                    configured = @(Get-LctAiCredStatus)
                })
        }
        'clear' {
            if ($prov -eq '') { return New-LctResult -Verb $verb -Errors @('缺少 provider（要清哪个）') }
            $store = Read-LctAiCredStore
            if (-not $store.ContainsKey($prov)) {
                return New-LctResult -Verb $verb -Data ([pscustomobject][ordered]@{ action = 'clear'; provider = $prov; cleared = $false; note = '本来就没配' })
            }
            $store.Remove($prov)
            $path = Get-LctAiCredPath
            [IO.File]::WriteAllText($path, (($store | ConvertTo-Json -Depth 4)), (New-Object System.Text.UTF8Encoding($false)))
            return New-LctResult -Verb $verb -Data ([pscustomobject][ordered]@{ action = 'clear'; provider = $prov; cleared = $true; configured = @(Get-LctAiCredStatus) })
        }
        default {
            return New-LctResult -Verb $verb -Data ([pscustomobject][ordered]@{
                    action = 'status'; path = (Get-LctAiCredPath)
                    configured = @(Get-LctAiCredStatus)
                    note = '只显示 provider / 长度 / 时间，不返回明文 key'
                })
        }
    }
}

function Invoke-LctAiAuto {
    # 一键：大白话 → 翻译（若配了模型）→ 计划 →（可选）执行。写操作仍需人确认短语。
    param(
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$Provider = '',
        [AllowEmptyString()][string]$Endpoint = '',
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$ApiKey = '',
        [int]$TimeoutSec = 60,
        [switch]$Fallback,
        [switch]$Apply,
        [AllowEmptyString()][string]$Confirm = ''
    )
    $verb = 'ai.auto'
    $rawText = ([string]$Text).Trim()
    if ($rawText -eq '') { return New-LctResult -Verb $verb -Errors @('缺少 text（用一句话说你要做什么）') }
    $goal = $rawText
    $trans = $null
    $ep = ([string]$Endpoint).Trim()
    $mdl = ([string]$Model).Trim()
    if ($ep -ne '' -and $mdl -ne '') {
        try {
            $trans = Invoke-LctAiTranslate -Text $rawText -Endpoint $ep -Model $mdl -Provider $Provider -ApiKey $ApiKey -TimeoutSec $TimeoutSec -Fallback:$Fallback
        } catch { $trans = $null }
        if ($null -ne $trans -and $trans.ok -and $null -ne $trans.data -and [string]$trans.data.goal -ne '') {
            $goal = [string]$trans.data.goal
        }
    }
    $do = Invoke-LctAiDo -Goal $goal -Apply:$Apply -Confirm $Confirm
    $data = [pscustomobject][ordered]@{
        text          = $rawText
        goal          = $goal
        translated    = ($null -ne $trans -and $trans.ok)
        translate     = $(if ($null -ne $trans) { $trans.data } else { $null })
        applied       = [bool]$Apply
        plan          = $(if ($null -ne $do -and $null -ne $do.data -and $null -ne $do.data.PSObject.Properties['steps']) { @($do.data.steps) } else { @() })
        results       = $(if ($null -ne $do -and $null -ne $do.data -and $null -ne $do.data.PSObject.Properties['results']) { @($do.data.results) } else { @() })
        needConfirm   = $(if ($null -ne $do -and $null -ne $do.data -and $null -ne $do.data.PSObject.Properties['needConfirm']) { [bool]$do.data.needConfirm } else { $false })
        confirmPhrase = $(if ($null -ne $do -and $null -ne $do.data -and $null -ne $do.data.PSObject.Properties['confirmPhrase']) { [string]$do.data.confirmPhrase } else { '' })
    }
    $w = @(); if ($null -ne $do) { $w = @($do.warnings) }
    $e = @(); if ($null -ne $do) { $e = @($do.errors) }
    if ($null -ne $trans -and -not $trans.ok) { $w += ('翻译没成功，按原文当目标：' + ((@($trans.errors)) -join ' ')) }
    return New-LctResult -Verb $verb -Applied:([bool]($Apply -and $null -ne $do -and $do.applied)) -Warnings @($w) -Errors @($e) -Data $data
}

function Invoke-LctAiTranslate {
    # 把"大白话"翻成本工具能识别的 goal。支持 Ollama / OpenAI 兼容 / Anthropic 三种协议。
    # 只做翻译：不执行、不落盘、不碰系统。结果必须再走 ai.plan/ai.do，且 ai.do 仍要人确认。
    param(
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$Endpoint = 'http://127.0.0.1:11434',
        [AllowEmptyString()][string]$Model = 'qwen2.5:7b',
        [AllowEmptyString()][string]$Provider = '',
        [AllowEmptyString()][string]$ApiKey = '',
        [int]$TimeoutSec = 60,
        [switch]$Fallback
    )
    $verb = 'ai.translate'
    $warnings = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rawText = ([string]$Text).Trim()
    if ($rawText -eq '') {
        return New-LctResult -Verb $verb -Errors @('缺少 text（要翻译的大白话）') -Data ([pscustomobject][ordered]@{ text = ''; goal = ''; mode = 'error' })
    }
    $prov = Resolve-LctAiProvider -Provider $Provider -Endpoint $Endpoint

    $sysLines = @(
        '你是 Windows 本地工具的命令翻译器。把用户的话翻成一句目标，只输出这一句，不要解释、不要引号、不要代码块、不要标点结尾。',
        '目标里尽量用这些词：提权 / 管理员 / SYSTEM / 加载驱动 / 读内核 / 清理 / 权限 / 进程 / 设备 / 对象图 / 列出驱动。',
        '硬规则：',
        '1) 只翻译用户真正说到的内容。用户没提到的驱动名、地址、数字，一律不要编造；没说具体驱动就写"某个驱动"。',
        '2) 用户如果是在问"你能做什么/能干什么/有哪些功能/怎么用"，只输出四个字：能力清单',
        '3) 不要补充"需要管理员权限"这类说明。',
        '4) 用户只说卸载/清理驱动时，不要写成加载驱动。'
    )
    $sys = ($sysLines -join "`n")
    $user = '用户原话：' + $rawText + "`n目标："

    $chat = Invoke-LctAiChat -Endpoint $Endpoint -Model $Model -Provider $prov -ApiKey $ApiKey -SystemPrompt $sys -UserPrompt $user -TimeoutSec $TimeoutSec
    $sw.Stop()
    $raw = [string]$chat.text
    $mode = 'llm'
    $err = [string]$chat.error

    $goal = ConvertTo-LctAiGoalText -Raw $raw
    if ($goal -eq '') {
        if ($Fallback) {
            $mode = 'fallback'
            $goal = $rawText
            $null = $warnings.Add('翻译失败（' + $err + '），已按 -Fallback 用原文当目标')
        } else {
            $mode = 'error'
            if ($err -eq '') { $err = '模型输出为空（可能模型名不对，或地址指向的不是模型服务）' }
            return New-LctResult -Verb $verb -Errors @($err) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                    text = $rawText; goal = ''; raw = $raw; model = $Model; endpoint = [string]$chat.url
                    provider = $prov; httpStatus = $chat.httpStatus; ms = $sw.ElapsedMilliseconds; mode = 'error'
                })
        }
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
            text = $rawText; goal = $goal; raw = $raw; model = $Model; endpoint = [string]$chat.url
            provider = $prov; httpStatus = $chat.httpStatus; ms = $sw.ElapsedMilliseconds; mode = $mode
            note = '翻译只产生一句目标；执行仍要走 ai.plan/ai.do，写操作必须由人确认'
        })
}

function Test-LctAiConfirm {
    <#
    .SYNOPSIS
        校验并**消费**一次性确认短语（用后即焚）。返回 @{ok; error}
    #>
    param([AllowEmptyString()][string]$Phrase = '', [AllowEmptyString()][string]$Verb = '', $ArgBag = $null)
    $o = [ordered]@{ ok = $false; error = '' }
    $p = ([string]$Phrase).Trim()
    if ($p -eq '') { $o.error = '缺少 confirm（mutating 的 -Apply 必须带 ai.plan 发出的确认短语）'; return [pscustomobject]$o }
    if (-not $p.StartsWith($script:LctAiConfirmPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $o.error = '确认短语格式不对（应为 ' + $script:LctAiConfirmPrefix + '<8 位十六进制>）'
        return [pscustomobject]$o
    }
    $hex = $p.Substring($script:LctAiConfirmPrefix.Length)
    if ($hex -notmatch '^[0-9a-fA-F]{8}$') { $o.error = '确认短语里的随机段不是 8 位十六进制'; return [pscustomobject]$o }
    $dir = Get-LctAiPendingDir
    $file = Join-Path $dir (($hex.ToLowerInvariant()) + '.json')
    if (-not (Test-Path -LiteralPath $file)) { $o.error = '确认短语不存在或已使用（一次性；过期或已执行请重新 ai.plan）'; return [pscustomobject]$o }
    $rec = $null
    try { $rec = (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $o.error = '确认短语记录损坏'; return [pscustomobject]$o }
    try {
        $exp = [datetime]::Parse([string]$rec.expiresAt)
        if ((Get-Date) -gt $exp) {
            $null = Remove-LctAiPendingFile -Path $file
            $o.error = '确认短语已过期（' + $script:LctAiConfirmTtlSeconds + ' 秒），请重新 ai.plan'
            return [pscustomobject]$o
        }
    } catch { }
    if ($null -ne $rec.PSObject.Properties['used'] -and $rec.used -eq $true) {
        $o.error = '确认短语已使用过（一次性；请重新 ai.plan）'
        return [pscustomobject]$o
    }
    if ($Verb -ne '''' -and [string]$rec.verb -ne $Verb) {
        $o.error = ('确认短语是给 verb「' + [string]$rec.verb + '」的，不能用于「' + $Verb + '」')
        return [pscustomobject]$o
    }
    $h = Get-LctAiArgsHash -ArgBag $ArgBag
    if ([string]$rec.argsHash -ne '' -and $h -ne '' -and [string]$rec.argsHash -ne $h) {
        $o.error = '确认短语绑定的 args 与本次不一致（改了参数就要重新 plan + 重新确认）'
        return [pscustomobject]$o
    }
    $removed = Remove-LctAiPendingFile -Path $file
    if (-not $removed) {
        try {
            $rec | Add-Member -NotePropertyName used -NotePropertyValue $true -Force
            [IO.File]::WriteAllText($file, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    $o.ok = $true
    return [pscustomobject]$o
}

function Invoke-LctAiRun {
    <#
    .SYNOPSIS
        AI 执行入口：转调引擎 verb，但对 mutating + -Apply 强制要求一次性确认短语。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetVerb,
        $ArgBag = $null,
        [switch]$Apply,
        [AllowEmptyString()][string]$Confirm = ''
    )
    $verb = 'ai.run'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $t = ([string]$TargetVerb).Trim()
    if ($t -eq '') { return New-LctResult -Verb $verb -Errors @('缺少 verb（要执行的引擎能力名）') -Data ([pscustomobject]@{ verb = ''; applied = $false }) }
    if ($t -in @('ai.run', 'ai.plan', 'ai.manifest')) { return New-LctResult -Verb $verb -Errors @('ai.* 不能通过 ai.run 递归调用') -Data ([pscustomobject]@{ verb = $t; applied = $false }) }

    $mutating = $false
    try {
        $entry = @(Get-LctVerbTable) | Where-Object { [string]$_.verb -eq $t } | Select-Object -First 1
        if ($null -eq $entry) { return New-LctResult -Verb $verb -Errors @(('未知 verb：' + $t + '（用 ai.manifest 查可用的）')) -Data ([pscustomobject]@{ verb = $t; applied = $false }) }
        $mutating = [bool]$entry.mutating
    } catch { $null = $warnings.Add('查 verb 表失败，按只读处理：' + $_.Exception.Message) }

    $need = Get-LctAiElevationForVerb -Verb $t -Mutating $mutating
    $isAdmin = $false
    try { $isAdmin = [bool](Test-LctElevated) } catch { }
    if ($need -eq 'admin' -and (-not $isAdmin)) {
        $msg = ''
        try { $msg = (Test-LctCapabilityDriverLoad -IsAdmin $false -Action $t -IntegrityName ([string](Get-LctCapIntegrityLevel).name)).hint } catch { }
        if ($msg -eq '') { $msg = ('需要管理员/SYSTEM 权限才能 ' + $t + '：请先走提权路线（plugins.run cve-2026-49176）再执行') }
        return New-LctResult -Verb $verb -Errors @($msg) -Data ([pscustomobject][ordered]@{ verb = $t; applied = $false; needElevation = $true; blockedBy = 'elevation' })
    }
    if ($need -eq 'non-elevated' -and $isAdmin) {
        return New-LctResult -Verb $verb -Errors @(('verb「' + $t + '」要求非提权上下文（当前已提权）——请以普通用户身份运行本工具')) -Data ([pscustomobject][ordered]@{ verb = $t; applied = $false; blockedBy = 'must-be-non-elevated' })
    }

    if ($mutating -and $Apply) {
        $chk = Test-LctAiConfirm -Phrase $Confirm -Verb $t -ArgBag $ArgBag
        if (-not $chk.ok) {
            $null = $errors.Add('执行被拒（人未确认）：' + [string]$chk.error)
            return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ verb = $t; applied = $false; confirmRequired = $true; hint = '先在界面/终端里看到 ai.plan 给出的 confirmPhrase，再把它作为 confirm 传进来' })
        }
        $null = $warnings.Add('已消费一次性确认短语，开始执行 ' + $t)
    }
    if (-not $mutating) { $Apply = $false }   # 只读 verb 即使传了 -Apply 也按预览处理

    try {
        $r = Invoke-LctEngine -Verb $t -Args $ArgBag -Apply:$Apply
        try { Write-LctLog -Level 'change' -Message ('[ai.run] ' + $t + ' apply=' + [bool]$Apply) -Data @{ confirm = $(if ($Confirm -ne '') { 'provided' } else { '' }) } | Out-Null } catch { }
        return $r
    } catch {
        $null = $errors.Add('引擎异常：' + $_.Exception.Message)
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{ verb = $t; applied = $false })
    }
}

Export-ModuleMember -Function Get-LctAiManifest, Invoke-LctAiPlan, Invoke-LctAiRun, Invoke-LctAiDo, Invoke-LctAiAuto, Invoke-LctAiTranslate, Invoke-LctAiChat, Invoke-LctAiCredentialVerb, Get-LctAiCredStatus, Resolve-LctAiProvider, ConvertTo-LctAiGoalText, Test-LctAiConfirm, Get-LctAiElevationForVerb