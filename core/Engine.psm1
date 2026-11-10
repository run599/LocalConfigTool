# LocalConfigTool - 引擎（职责：装载能力模块 + verb 分发表 + 统一 Result）
# 维护者：Lead。契约见 docs\CONTRACT.md §5。
# 原则：本模块不实现业务逻辑，只做编排与降级（某模块未就绪时返回 ok=false，而不是崩掉）。
# 设计教训（2026-10-25 实测，来之不易）：
#   1) 装载器必须自给自足：绝不在装载阶段调用被装载模块的函数。曾经在 catch 里调 Write-LctLog，
#      结果 Logging 一失败就引发连锁异常，Engine.psm1 整体装载失败、引擎完全无输出。
#   2) 不要用 Get-Command 探测跨模块函数是否存在：模块作用域下它会误报（实测 availability.Logging=false，
#      但同一进程里 New-LctResult 实际可调用）。可用性改为「模块是否装载成功」，缺函数的错误交给 try/catch。
#   3) -Global 导入 + 收尾重导 Logging：各能力模块内部还会自己 Import 一次 Logging（落在其模块作用域），
#      会把全局那份顶掉；所有模块装载完之后必须再 -Global 重导一次 Logging。
#   4) 不使用 Write-Host（引擎 stdout 只允许出现最终 JSON，由 Engine.ps1 输出）。

$script:LctCore = $PSScriptRoot
$script:LctLoadErrors = New-Object System.Collections.ArrayList
$script:LctLoaded = New-Object System.Collections.ArrayList

foreach ($m in @('Logging', 'Backup', 'Registry', 'Accounts', 'Plugins', 'PluginSdk', 'Processes', 'Wdac', 'WatchHost', 'Drivers', 'DriverProfiles', 'DriverMap', 'Capabilities', 'Ai', 'Samples')) {
    $path = Join-Path $script:LctCore ($m + '.psm1')
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try {
        Import-Module $path -Force -Global -ErrorAction Stop
        $null = $script:LctLoaded.Add($m)
    } catch {
        $null = $script:LctLoadErrors.Add(($m + ': ' + $_.Exception.Message))
    }
}

# 收尾：再以 -Global 重导一次 Logging（见设计教训 3）
$lctLoggingPath = Join-Path $script:LctCore 'Logging.psm1'
if (Test-Path -LiteralPath $lctLoggingPath) {
    try {
        Import-Module $lctLoggingPath -Force -Global -ErrorAction Stop
        if ($script:LctLoaded -notcontains 'Logging') { $null = $script:LctLoaded.Add('Logging') }
    } catch {
        $null = $script:LctLoadErrors.Add('Logging(全局重导): ' + $_.Exception.Message)
    }
}

function Get-LctLoadErrors { return @($script:LctLoadErrors) }
function Get-LctLoadedModules { return @($script:LctLoaded) }

function Write-LctSafeLog {
    # 日志可用才写；不可用就静默（降级路径必须能跑）
    param([string]$Verb = 'engine', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data | Out-Null } catch { }
}

function New-LctFallbackResult {
    # 不依赖任何模块的最小 Result（与契约 §3 同形状），用于 Logging 不可用时的兜底
    param([string]$Verb, $Errors = @(), $Warns = @())
    return [pscustomobject][ordered]@{
        ok       = (@($Errors).Count -eq 0)
        verb     = $Verb
        applied  = $false
        changes  = @()
        warnings = @($Warns)
        errors   = @($Errors)
        backupId = ''
        log      = ''
        data     = $null
    }
}

function New-LctResultSafe {
    # 先真的调用一次 New-LctResult（存在性靠调用/捕获判断，不靠 Get-Command）；
    # 不可用时退回等形状的兜底对象。这样即使 Logging 缺失，引擎也永远返回契约形状。
    param([string]$Verb, [switch]$Applied, $Changes = @(), $Warnings = @(), $Errors = @(), [string]$BackupId = '', $Data = $null)
    try {
        return New-LctResult -Verb $Verb -Applied:$Applied -Changes $Changes -Warnings $Warnings -Errors $Errors -BackupId $BackupId -Data $Data
    } catch {
        $r = New-LctFallbackResult -Verb $Verb -Errors $Errors -Warns $Warnings
        $r.applied = [bool]$Applied
        $r.changes = @($Changes)
        $r.backupId = $BackupId
        $r.data = $Data
        return $r
    }
}

function Get-LctAvailability {
    # 以「模块装载成功」为准（不用 Get-Command，见设计教训 2）
    return [pscustomobject][ordered]@{
        Logging  = ($script:LctLoaded -contains 'Logging')
        Backup   = ($script:LctLoaded -contains 'Backup')
        Registry = ($script:LctLoaded -contains 'Registry')
        Accounts = ($script:LctLoaded -contains 'Accounts')
        Plugins  = ($script:LctLoaded -contains 'Plugins')
        Presets  = (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $script:LctCore) 'presets'))
        Processes = ($script:LctLoaded -contains 'Processes')
        Wdac      = ($script:LctLoaded -contains 'Wdac')
        WatchHost = ($script:LctLoaded -contains 'WatchHost')
        PluginSdk = ($script:LctLoaded -contains 'PluginSdk')
        Drivers   = ($script:LctLoaded -contains 'Drivers')
        DriverProfiles = ($script:LctLoaded -contains 'DriverProfiles')
        DriverMap      = ($script:LctLoaded -contains 'DriverMap')
        Capabilities   = ($script:LctLoaded -contains 'Capabilities')
        Ai             = ($script:LctLoaded -contains 'Ai')
        Samples        = ($script:LctLoaded -contains 'Samples')
    }
}

# ---- verb 自描述表（前端据此生成界面；与契约 §5 一一对应） ----
$script:LctVerbTable = @(
    [pscustomobject]@{ verb = 'engine.verbs'; summary = '列出引擎能力（前端据此生成界面）'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'presets.list'; summary = '列出预设包'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'presets.show'; summary = '查看预设包详情'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'preset'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'presets.apply'; summary = '应用预设项（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'preset'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'item'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'itemArgs'; type = 'object'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'registry.get'; summary = '读取注册表值'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'registry.set'; summary = '写入注册表值（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'value'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'type'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'registry.delete'; summary = '删除注册表值或子键（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'account.status'; summary = '账户/UAC/自动登录快照'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'account.admin'; summary = '内置 Administrator 启用/禁用（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'enable'; type = 'bool'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'account.uac'; summary = 'UAC 开关（默认只预览，需重启生效）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'enable'; type = 'bool'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'account.autologon'; summary = '自动登录开关（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'enable'; type = 'bool'; required = $true }
            [pscustomobject]@{ name = 'user'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'passwordFile'; type = 'path'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'plugins.list'; summary = '列出提权工具插件'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'plugins.show'; summary = '查看插件详情'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'plugin'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'plugins.run'; summary = '预览/执行插件（执行需 -Apply）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'plugin'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'params'; type = 'object'; required = $false }
            [pscustomobject]@{ name = 'timeout'; type = 'int'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'backup.list'; summary = '列出备份'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'backup.show'; summary = '查看备份详情'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'id'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'backup.restore'; summary = '还原备份（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'id'; type = 'string'; required = $true }
        ) }
)

# --- 13.y profile 另存（草案 → 审定 → 落盘；默认只预览） ---
$script:LctVerbTable += @(
    [pscustomobject]@{ verb = 'driver.profile.save'; summary = '另存 profile 到 var\driver-profiles（默认只预览；先校验后写盘；覆盖需 -Override 且先备份）'; mutating = $true; args = @([pscustomobject]@{ name = 'id'; type = 'string'; required = $true }, [pscustomobject]@{ name = 'json'; type = 'string'; required = $true }, [pscustomobject]@{ name = 'override'; type = 'bool'; required = $false }) }
)
# --- 13.x 新增能力：驱动通用化（每驱一份 profile + 少量内核原语的通用执行器） ---
$script:LctVerbTable += @(
    [pscustomobject]@{ verb = 'driver.profile.list'; summary = '列出驱动 profile（内置/用户/插件来源）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'source'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'driver.profile.show'; summary = '查看单个 profile 的完整内容'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'id'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.profile.validate'; summary = 'profile 校验：schema + .sys 指纹 + 沙盒自检（不碰内核）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'id'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'driver.profile.draft'; summary = '静态起草 profile（只读；产物是草案，不可直接执行）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.devices'; summary = '解析服务的 .sys 路径与候选控制入口（只测试能否打开，不发 IOCTL）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.ctl.send'; summary = '通用原语执行器：按 profile 发 IOCTL（默认预览，打印缓冲区十六进制）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'profile'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'action'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'payload'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'overrideBsod'; type = 'bool'; required = $false }
        ) }
                [pscustomobject]@{ verb = 'driver.kernelbase'; summary = '取内核镜像基址（ntoskrnl）：给 payload 里的 @ntoskrnl 用，省掉"自己去查地址"（只读）'; mutating = $false; args = @() },
            [pscustomobject]@{ verb = 'driver.use'; summary = '一条命令加载并确认在跑：服务名自动推导、启动类型默认 demand（不用发明/记名字）'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'path'; type = 'path'; required = $true }
        [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'startType'; type = 'string'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'driver.release'; summary = '一条命令卸载：给 name 或 path（按 ImagePath 反查服务名，不用记）'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'path'; type = 'path'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'driver.cleanup'; summary = '一条命令清理：卸掉所有 lct* 服务（本工具默认前缀），不碰系统驱动'; mutating = $true; args = @() },
        [pscustomobject]@{ verb = 'samples.list'; summary = '样本库目录：内置规则（名称/CVE/来源 URL/SHA256/风险）+ 本机是否已获取、哈希是否对得上（只读）'; mutating = $false; args = @() },
    [pscustomobject]@{ verb = 'samples.get'; summary = '按目录条目（或 ad-hoc url+sha256）获取样本：预览不落盘；-Apply 才下载，且必须通过 SHA256 校验（不符丢弃）'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'id'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'url'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'sha256'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'ai.manifest'; summary = 'AI 机器可读清单：全部 verb（mutating / needsElevation / blockedNow）+ 预置流程 + 安全规则（只读）'; mutating = $false; args = @() },
            [pscustomobject]@{ verb = 'ai.translate'; summary = '把大白话翻成 goal：支持 Ollama / OpenAI 兼容（DeepSeek/Kimi/智谱…）/ Anthropic；只翻译不执行，连不上会明确报错'; mutating = $false; args = @(
        [pscustomobject]@{ name = 'text'; type = 'string'; required = $true }
        [pscustomobject]@{ name = 'endpoint'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'model'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'provider'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'apiKey'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'timeoutSec'; type = 'int'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'ai.cred'; summary = '管理云端 API Key（DPAPI 当前用户加密存 var\ai\credential.json）：action=set/status/clear，明文不落盘'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'action'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'provider'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'key'; type = 'string'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'ai.auto'; summary = '一键：大白话→（配了模型就翻译）→计划→（带 confirm 才）执行；本地/云端都行，写操作仍需人确认'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'text'; type = 'string'; required = $true }
        [pscustomobject]@{ name = 'provider'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'endpoint'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'model'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'apiKey'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'timeoutSec'; type = 'int'; required = $false }
        [pscustomobject]@{ name = 'apply'; type = 'bool'; required = $false }
        [pscustomobject]@{ name = 'confirm'; type = 'string'; required = $false }
    ) },
        [pscustomobject]@{ verb = 'ai.do'; summary = 'AI 一键流水线：一句话 → 完整计划（参数已解析，样本库自动识别）→ 逐步执行；写步骤必须带人确认短语'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'goal'; type = 'string'; required = $true }
        [pscustomobject]@{ name = 'apply'; type = 'bool'; required = $false }
        [pscustomobject]@{ name = 'confirm'; type = 'string'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'ai.plan'; summary = 'AI 计划：把一句目标转成确定性有序步骤（只读、不执行；并为第一个可执行的 mutating 步骤发一次性确认短语）'; mutating = $false; args = @(
        [pscustomobject]@{ name = 'goal'; type = 'string'; required = $true }
    ) },
    [pscustomobject]@{ verb = 'ai.run'; summary = 'AI 执行：转调引擎 verb；mutating 的 -Apply 必须带 ai.plan 发出的一次性确认短语（人确认后才给）'; mutating = $true; args = @(
        [pscustomobject]@{ name = 'verb'; type = 'string'; required = $true }
        [pscustomobject]@{ name = 'args'; type = 'object'; required = $false }
        [pscustomobject]@{ name = 'apply'; type = 'bool'; required = $false }
        [pscustomobject]@{ name = 'confirm'; type = 'string'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'capability.status'; summary = '能力路线与前置条件：当前权限画像（管理员/完整性级别）+ 两条路线的可用性 + 「先提权再加载驱动」的指引（只读）'; mutating = $false; args = @() },
    [pscustomobject]@{ verb = 'driver.map'; summary = '对象图映射：\Device 设备对象 ↔ \Driver 驱动对象 ↔ 服务名（只读；附 PnP 权威旁证）'; mutating = $false; args = @(
        [pscustomobject]@{ name = 'service'; type = 'string'; required = $false }
        [pscustomobject]@{ name = 'maxLinks'; type = 'int'; required = $false }
        [pscustomobject]@{ name = 'includeUnresolved'; type = 'bool'; required = $false }
    ) },
    [pscustomobject]@{ verb = 'driver.ctl.verify'; summary = 'canary 握手（默认只做文件指纹证明；加 -Apply 才真发 canary IOCTL）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'profile'; type = 'string'; required = $true }
        ) }
)
# --- 12.x 新增能力：自定义驱动加载（签名只做信息展示，能否加载交给系统判定并如实回传） ---
$script:LctVerbTable += @(
    [pscustomobject]@{ verb = 'driver.status'; summary = '驱动加载前提与现状：Secure Boot / test-signing / DSE / 驱动数与运行数'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'driver.list'; summary = '驱动服务清单（含 hash 与签名摘要，仅信息）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'driver.info'; summary = '单个 .sys 的 hash/签名摘要（不作为加载门槛）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.load'; summary = '指定 .sys 并加载（注册+启动；签名交给系统判定并如实回传错误原文）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'startType'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'stage'; type = 'bool'; required = $false }
            [pscustomobject]@{ name = 'override'; type = 'bool'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'driver.start'; summary = '启动已有驱动服务（回传系统判定原文）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.stop'; summary = '停止驱动服务（不删服务项）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.unload'; summary = '卸载：停服务 + 删服务项 + 生成 revert.cmd（不删 .sys 文件）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'driver.testsigning'; summary = '开关 test-signing（需重启生效；Secure Boot=True 时拒绝开启）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'enable'; type = 'bool'; required = $false }
            [pscustomobject]@{ name = 'disable'; type = 'bool'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'driver.verify'; summary = '加载后复核：真的在运行/被系统拒绝/状态不明 + 系统事件原文'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $true }
        ) }
)
# --- 11.x 新增能力：进程监控 / 加载阻断(IFEO) / WDAC 黑名单 ---
$script:LctVerbTable += @(
    [pscustomobject]@{ verb = 'process.list'; summary = '进程快照（可按名称/用户过滤）'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'user'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'includeSystem'; type = 'bool'; required = $false }
            [pscustomobject]@{ name = 'limit'; type = 'int'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'process.detail'; summary = '单个进程详情 + 能否终止的实测结论'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'id'; type = 'int'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'process.kill'; summary = '终止进程（默认只预览；关键/安全软件需 override）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'id'; type = 'int'; required = $false }
            [pscustomobject]@{ name = 'name'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'override'; type = 'bool'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'process.watch.start'; summary = '会话内看门狗：被杀后复活再杀（不落地持久化）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'targets'; type = 'stringList'; required = $true }
            [pscustomobject]@{ name = 'intervalSec'; type = 'int'; required = $false }
            [pscustomobject]@{ name = 'durationSec'; type = 'int'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'process.watch.status'; summary = '看门狗状态与计数'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'process.watch.stop'; summary = '停止看门狗'; mutating = $true; args = @() }
    [pscustomobject]@{ verb = 'process.watch.log'; summary = '看门狗事件日志'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'process.block.set'; summary = 'IFEO 重定向：让目标程序无法启动（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'reason'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'process.block.remove'; summary = '回滚 IFEO 重定向；默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'path'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'process.block.list'; summary = '当前由本工具设置的重定向清单'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'wdac.status'; summary = '代码完整性(WDAC)状态：CI/策略/Secure Boot'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'wdac.rules.list'; summary = '自管黑名单规则'; mutating = $false; args = @() }
    [pscustomobject]@{ verb = 'wdac.rules.add'; summary = '新增黑名单规则（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'kind'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'value'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'reason'; type = 'string'; required = $false }
        ) }
    [pscustomobject]@{ verb = 'wdac.rules.remove'; summary = '删除黑名单规则（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'kind'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'value'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'wdac.policy.build'; summary = '用 ConfigCI 生成策略（审计优先，产物落 var\\wdac\\staging）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'mode'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'scanPath'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'wdac.policy.validate'; summary = '策略安全门：无 allow 机制/命中系统目录/缺救命绳 一律拒绝强制'; mutating = $false; args = @(
            [pscustomobject]@{ name = 'xmlPath'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'wdac.deploy'; summary = '部署策略（需手输确认文本；需重启生效）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'xmlPath'; type = 'string'; required = $true }
            [pscustomobject]@{ name = 'mode'; type = 'string'; required = $false }
            [pscustomobject]@{ name = 'confirmText'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'wdac.revert'; summary = '按备份戳回滚策略（默认只预览）'; mutating = $true; args = @(
            [pscustomobject]@{ name = 'stamp'; type = 'string'; required = $true }
        ) }
    [pscustomobject]@{ verb = 'wdac.verify'; summary = '重启后校验：判定是否可安全转强制'; mutating = $false; args = @() }
)
function Get-LctVerbTable { return $script:LctVerbTable }

function New-LctNotReadyResult {
    param([string]$Verb, [string]$What)
    return New-LctResultSafe -Verb $Verb -Errors @("依赖未就绪：$What（模块尚未实现或装载失败）")
}

function Get-LctPresetDir { return (Join-Path (Split-Path -Parent $script:LctCore) 'presets') }

function Read-LctPresetPacks {
    # presets\*.json：每个文件可以是单个包对象，也可以是包数组
    $dir = Get-LctPresetDir
    $packs = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $raw = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8)
            $obj = $raw | ConvertFrom-Json
            if ($obj -is [System.Array]) { foreach ($p in $obj) { $null = $packs.Add($p) } }
            else { $null = $packs.Add($obj) }
        } catch {
            Write-LctSafeLog -Verb 'presets' -Level warn -Message ("预设包解析失败: " + $f.Name) -Data @{ error = $_.Exception.Message }
        }
    }
    return @($packs)
}

function Get-LctPresetPack {
    param([string]$Id)
    foreach ($p in @(Read-LctPresetPacks)) { if ($p.id -eq $Id) { return $p } }
    return $null
}

function ConvertTo-LctBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ([string]$Value -match '^(?i:true|1|yes|on|enable|启用)$')
}

function Get-LctArgValue {
    # 从 PSCustomObject / hashtable 里安全取值（缺属性返回 $null，不抛）
    param($Container, [string]$Name)
    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IDictionary]) { if ($Container.Contains($Name)) { return $Container[$Name] }; return $null }
    $p = $Container.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}


function Test-LctResultLike {
    # 判断模块返回值是否已经是标准 Result（含 ok/changes/verb 三个属性）
    param($R)
    if ($null -eq $R) { return $false }
    try { return [bool]($R.PSObject.Properties['ok'] -and $R.PSObject.Properties['changes'] -and $R.PSObject.Properties['verb']) } catch { return $false }
}

function Use-LctModuleReturn {
    # 模块可以返回「裸数据」或「完整 Result」，这里统一：
    #   Result -> 原样透传（不再包一层，否则前端会拿到 data.data.value 这种双层结构）
    #   裸数据 -> 包成 Result（getter 放 data；action 额外标注 applied 未知）
    param([string]$Verb, $R, [switch]$Action)
    if (Test-LctResultLike $R) { return $R }
    $res = New-LctResultSafe -Verb $Verb -Data $R
    if ($Action -and $null -ne $R) {
        $res.warnings = @($res.warnings) + @('模块未返回标准 Result，applied 状态未知（契约 §5 要求 action 类返回 Result）')
    }
    return $res
}
function Invoke-LctEngine {
    # 统一入口：任何异常都转成 Result(errors)，绝不抛出。
    # 不预先用 Get-Command 判断模块是否可用 —— 直接调用，缺函数由 catch 变成可读错误。
    param([Parameter(Mandatory)][string]$Verb, $Args = $null, [switch]$Apply)
    $a = $Args
    try {
        switch ($Verb) {
            'engine.verbs' {
                $varDir = ''
                try { $varDir = Get-LctVarDir } catch { }
                $isElevated = $false
                try { $isElevated = Test-LctElevated } catch { }
                return Use-LctModuleReturn -Verb $Verb -R ([pscustomobject]@{
                        verbs        = (Get-LctVerbTable)
                        availability = (Get-LctAvailability)
                        loadErrors   = (Get-LctLoadErrors)
                        toolRoot     = (Split-Path -Parent $script:LctCore)
                        varDir       = $varDir
                        elevated     = $isElevated
                    })
            }
            'presets.list' {
                $list = @(Read-LctPresetPacks | Select-Object id, name, description, risk, @{n = 'itemCount'; e = { @($_.items).Count } })
                return New-LctResultSafe -Verb $Verb -Data $list
            }
            'presets.show' {
                $pack = Get-LctPresetPack (Get-LctArgValue $a 'preset')
                if (-not $pack) { return New-LctResultSafe -Verb $Verb -Errors @("预设包不存在: " + (Get-LctArgValue $a 'preset')) }
                return New-LctResultSafe -Verb $Verb -Data $pack
            }
            'presets.apply' {
                $pack = Get-LctPresetPack (Get-LctArgValue $a 'preset')
                if (-not $pack) { return New-LctResultSafe -Verb $Verb -Errors @("预设包不存在: " + (Get-LctArgValue $a 'preset')) }
                $itemId = Get-LctArgValue $a 'item'
                $items = @($pack.items | Where-Object { (-not $itemId) -or ($_.id -eq $itemId) })
                if (@($items).Count -eq 0) { return New-LctResultSafe -Verb $Verb -Errors @("预设项不存在: $itemId") }
                $changes = New-Object System.Collections.ArrayList
                $warnings = New-Object System.Collections.ArrayList
                $errors = New-Object System.Collections.ArrayList
                $plan = New-Object System.Collections.ArrayList
                $lastBackup = ''
                foreach ($it in $items) {
                    $subArgs = $it.args
                    if ($itemId -and (Get-LctArgValue $a 'itemArgs')) { $subArgs = Get-LctArgValue $a 'itemArgs' }
                    $null = $plan.Add([pscustomobject]@{ item = $it.id; title = $it.title; verb = $it.verb; args = $subArgs })
                    if ($it.verb -eq 'presets.apply') { $null = $errors.Add("预设项不允许嵌套 presets.apply: " + $it.id); continue }
                    $r = Invoke-LctEngine -Verb $it.verb -Args $subArgs -Apply:$Apply
                    foreach ($c in @($r.changes)) { $null = $changes.Add($c) }
                    foreach ($w in @($r.warnings)) { $null = $warnings.Add($w) }
                    foreach ($e in @($r.errors)) { $null = $errors.Add(("[{0}] {1}" -f $it.id, $e)) }
                    if ($r.backupId) { $lastBackup = $r.backupId }
                }
                return New-LctResultSafe -Verb $Verb -Applied:$Apply -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $lastBackup -Data ([pscustomobject]@{ preset = $pack.id; plan = @($plan) })
            }
            'registry.get' {
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctRegistryValue -Path (Get-LctArgValue $a 'path') -Name (Get-LctArgValue $a 'name'))
            }
            'registry.set' {
                return Use-LctModuleReturn -Verb $Verb -Action -R (Set-LctRegistryValue -Path (Get-LctArgValue $a 'path') -Name (Get-LctArgValue $a 'name') -Value (Get-LctArgValue $a 'value') -Type (Get-LctArgValue $a 'type') -Apply:$Apply)
            }
            'registry.delete' {
                return Use-LctModuleReturn -Verb $Verb -Action -R (Remove-LctRegistryValue -Path (Get-LctArgValue $a 'path') -Name (Get-LctArgValue $a 'name') -Apply:$Apply)
            }
            'account.status' {
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctAccountStatus)
            }
            'account.admin' {
                return Use-LctModuleReturn -Verb $Verb -Action -R (Set-LctAdminAccount -Enable (ConvertTo-LctBool (Get-LctArgValue $a 'enable')) -Apply:$Apply)
            }
            'account.uac' {
                return Use-LctModuleReturn -Verb $Verb -Action -R (Set-LctUac -Enable (ConvertTo-LctBool (Get-LctArgValue $a 'enable')) -Apply:$Apply)
            }
            'account.autologon' {
                $pf = Get-LctArgValue $a 'passwordFile'
                if ($pf) { return Set-LctAutologon -Enable (ConvertTo-LctBool (Get-LctArgValue $a 'enable')) -User (Get-LctArgValue $a 'user') -PasswordFile $pf -Apply:$Apply }
                return Use-LctModuleReturn -Verb $Verb -Action -R (Set-LctAutologon -Enable (ConvertTo-LctBool (Get-LctArgValue $a 'enable')) -User (Get-LctArgValue $a 'user') -Apply:$Apply)
            }
            'plugins.list' {
                return Use-LctModuleReturn -Verb $Verb -R (@(Get-LctPluginList))
            }
            'plugins.show' {
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctPlugin -Id (Get-LctArgValue $a 'plugin'))
            }
            'plugins.run' {
                $t = Get-LctArgValue $a 'timeout'
                if (-not $t) { $t = 120 }
                return Use-LctModuleReturn -Verb $Verb -Action -R (Invoke-LctPlugin -Id (Get-LctArgValue $a 'plugin') -Params (Get-LctArgValue $a 'params') -Timeout ([int]$t) -Apply:$Apply)
            }
            'backup.list' {
                return Use-LctModuleReturn -Verb $Verb -R (@(Get-LctBackupList))
            }
            'backup.show' {
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctBackup -Id (Get-LctArgValue $a 'id'))
            }
            'backup.restore' {
                $r = Restore-LctBackup -Id (Get-LctArgValue $a 'id') -Apply:$Apply
                # 账户快照交给 Accounts 模块（依赖方向：Backup 刻意不认识 Accounts）
                if ($Apply -and $r.data -and $r.data.accountSnapshot) {
                    try {
                        $ra = Restore-LctAccountState -Snapshot $r.data.accountSnapshot -Apply
                        $r.changes = @($r.changes) + @($ra.changes)
                        $r.errors = @($r.errors) + @($ra.errors)
                        $r.warnings = @($r.warnings) + @($ra.warnings)
                        $r.ok = (@($r.errors).Count -eq 0)
                    } catch {
                        $r.warnings = @($r.warnings) + @('备份含账户快照，但账户还原失败/未实现: ' + $_.Exception.Message)
                    }
                }
                return $r
            }
            # ---- 进程监控 / 加载阻断 ----
            'process.list' {
                $nm = Get-LctArgValue $a 'name'; $us = Get-LctArgValue $a 'user'
                $lim = Get-LctArgValue $a 'limit'; if (-not $lim) { $lim = 200 }
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctProcessList -Name $nm -User $us -IncludeSystem:(ConvertTo-LctBool (Get-LctArgValue $a 'includeSystem')) -Limit ([int]$lim))
            }
            'process.detail' {
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctProcessDetail -Id ([int](Get-LctArgValue $a 'id')) -Name (Get-LctArgValue $a 'name'))
            }
            'process.kill' {
                $kId = Get-LctArgValue $a 'id'; if (-not $kId) { $kId = 0 }
                return Stop-LctProcess -Id ([int]$kId) -Name (Get-LctArgValue $a 'name') -Path (Get-LctArgValue $a 'path') -Override:(ConvertTo-LctBool (Get-LctArgValue $a 'override')) -Apply:$Apply
            }
            'process.watch.start' {
                $tg = Get-LctArgValue $a 'targets'
                if ($tg -isnot [array]) { $tg = @($tg) }
                $iv = Get-LctArgValue $a 'intervalSec'; if (-not $iv) { $iv = 2 }
                $du = Get-LctArgValue $a 'durationSec'; if (-not $du) { $du = 300 }
                if (-not $Apply) { return New-LctResultSafe -Verb $Verb -Data ([pscustomobject]@{ preview = $true; targets = @($tg); intervalSec = [int]$iv; durationSec = [int]$du; note = '预览：未启动看门狗宿主；加 -Apply 才会真正开始监控' }) }
                return Start-LctWatchHost -Targets @($tg) -IntervalSec ([int]$iv) -DurationSec ([int]$du)
            }
            'process.watch.status' { return Get-LctWatchHostStatus }
            'process.watch.stop' { if (-not $Apply) { return New-LctResultSafe -Verb $Verb -Data ([pscustomobject]@{ preview = $true; note = '预览：未停止看门狗宿主；加 -Apply 才会真正停止' }) } ; return Stop-LctWatchHost }
            'process.watch.log' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctProcessWatchLog -Limit 50) }
            'process.block.set' { return Set-LctProcessBlock -Path (Get-LctArgValue $a 'path') -Reason (Get-LctArgValue $a 'reason') -Blocker (Get-LctArgValue $a 'blocker') -Hive ([string]$(if (Get-LctArgValue $a 'hive') { [string](Get-LctArgValue $a 'hive') } else { 'HKLM' })) -Override:(ConvertTo-LctBool (Get-LctArgValue $a 'override')) -Apply:$Apply }
            'process.block.remove' { return Remove-LctProcessBlock -Path (Get-LctArgValue $a 'path') -Hive ([string]$(if (Get-LctArgValue $a 'hive') { [string](Get-LctArgValue $a 'hive') } else { 'Auto' })) -Override:(ConvertTo-LctBool (Get-LctArgValue $a 'override')) -Apply:$Apply }
            'process.block.list' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctProcessBlockList) }
            # ---- WDAC 黑名单 ----
            'wdac.status' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctWdacStatus) }
            'wdac.rules.list' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctWdacRules) }
            'wdac.rules.add' { return Add-LctWdacRule -Kind (Get-LctArgValue $a 'kind') -Value (Get-LctArgValue $a 'value') -Reason (Get-LctArgValue $a 'reason') -Apply:$Apply }
            'wdac.rules.remove' { return Remove-LctWdacRule -Kind (Get-LctArgValue $a 'kind') -Value (Get-LctArgValue $a 'value') -Apply:$Apply }
            'wdac.policy.build' {
                $md = Get-LctArgValue $a 'mode'; if (-not $md) { $md = 'audit' }
                return New-LctWdacPolicy -Mode ([string]$md) -ScanPath (Get-LctArgValue $a 'scanPath') -Apply:$Apply
            }
            'wdac.policy.validate' { return Use-LctModuleReturn -Verb $Verb -R (Test-LctWdacPolicy -XmlPath (Get-LctArgValue $a 'xmlPath')) }
            'wdac.deploy' {
                $md = Get-LctArgValue $a 'mode'; if (-not $md) { $md = 'audit' }
                return Deploy-LctWdacPolicy -XmlPath (Get-LctArgValue $a 'xmlPath') -Mode ([string]$md) -ConfirmText (Get-LctArgValue $a 'confirmText') -Apply:$Apply
            }
            'wdac.revert' { return Restore-LctWdacPolicy -Stamp (Get-LctArgValue $a 'stamp') -Apply:$Apply }
            'wdac.verify' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctWdacVerify) }
            # ---- 驱动加载（§12：不做签名门槛，以系统判定为准） ----
            'driver.status' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverStatus) }
            'driver.list' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverList -Name (Get-LctArgValue $a 'name')) }
            'driver.info' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverFileInfo -Path (Get-LctArgValue $a 'path')) }
            'driver.load' {
                $st = Get-LctArgValue $a 'startType'; if (-not $st) { $st = 'demand' }
                return Load-LctDriver -Path (Get-LctArgValue $a 'path') -Name (Get-LctArgValue $a 'name') -StartType ([string]$st) -Stage:(ConvertTo-LctBool (Get-LctArgValue $a 'stage')) -Override:(ConvertTo-LctBool (Get-LctArgValue $a 'override')) -Apply:$Apply
            }
            'driver.start' { return Start-LctDriver -Name (Get-LctArgValue $a 'name') -Apply:$Apply }
            'driver.stop' { return Stop-LctDriver -Name (Get-LctArgValue $a 'name') -Apply:$Apply }
            'driver.unload' { return Remove-LctDriverService -Name (Get-LctArgValue $a 'name') -Apply:$Apply }
            'driver.testsigning' { return Set-LctDriverTestSigning -Enable:(ConvertTo-LctBool (Get-LctArgValue $a 'enable')) -Disable:(ConvertTo-LctBool (Get-LctArgValue $a 'disable')) -Apply:$Apply }
            'driver.verify' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverVerification -Name (Get-LctArgValue $a 'name')) }
            # ---- 驱动 profile（§13：接口不自描述 ⇒ 自研走 ABI、第三方走 profile；能力建立在少量原语上） ----
            'driver.profile.list' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverProfileList -Source (Get-LctArgValue $a 'source')) }
            'driver.profile.show' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverProfileShow -Id (Get-LctArgValue $a 'id')) }
            'driver.profile.validate' { return Use-LctModuleReturn -Verb $Verb -R (Test-LctDriverProfile -Id (Get-LctArgValue $a 'id') -Path (Get-LctArgValue $a 'path')) }
            'driver.profile.draft' { return Use-LctModuleReturn -Verb $Verb -R (New-LctDriverProfileDraft -Path (Get-LctArgValue $a 'path')) }
            'driver.devices' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverDevices -Name (Get-LctArgValue $a 'name')) }
            'driver.ctl.send' {
                $pl = Get-LctArgValue $a 'payload'
                if ($null -ne $pl -and $pl -isnot [string]) { $pl = ($pl | ConvertTo-Json -Depth 8 -Compress) }
                return Invoke-LctDriverCtl -Profile (Get-LctArgValue $a 'profile') -Action (Get-LctArgValue $a 'action') -Payload ([string]$pl) -OverrideBsod:(ConvertTo-LctBool (Get-LctArgValue $a 'overrideBsod')) -Apply:$Apply
            }
            'driver.ctl.verify' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverCtlVerify -Profile (Get-LctArgValue $a 'profile')) }
                                                'driver.kernelbase' { return Use-LctModuleReturn -Verb $Verb -R (New-LctResult -Verb $Verb -Data (Get-LctKernelBaseAddress)) }
                                    'driver.use' {
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctDriverUse -Path (Get-LctArgValue $a 'path') -Name (Get-LctArgValue $a 'name') -StartType (Get-LctArgValue $a 'startType') -Apply:$Apply)
            }
            'driver.release' {
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctDriverRelease -Name (Get-LctArgValue $a 'name') -Path (Get-LctArgValue $a 'path') -Apply:$Apply)
            }
            'driver.cleanup' { return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctDriverCleanup -Apply:$Apply) }
                        'samples.list' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctSampleCatalog) }
            'samples.get' {
                $sid = [string](Get-LctArgValue $a 'id')
                $surl = [string](Get-LctArgValue $a 'url')
                $ssha = [string](Get-LctArgValue $a 'sha256')
                $sname = [string](Get-LctArgValue $a 'name')
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctSampleGet -Id $sid -Url $surl -Sha256 $ssha -Name $sname -Apply:$Apply)
            }
            'ai.manifest' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctAiManifest) }
                                    'ai.translate' {
                $tText = [string](Get-LctArgValue $a 'text')
                $tEp = [string](Get-LctArgValue $a 'endpoint')
                $tModel = [string](Get-LctArgValue $a 'model')
                $tProv = [string](Get-LctArgValue $a 'provider')
                $tKey = [string](Get-LctArgValue $a 'apiKey')
                $tTo = 60
                try { $x = Get-LctArgValue $a 'timeoutSec'; if ($null -ne $x -and [string]$x -ne '') { $tTo = [int]$x } } catch { $tTo = 60 }
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiTranslate -Text $tText -Endpoint $tEp -Model $tModel -Provider $tProv -ApiKey $tKey -TimeoutSec $tTo)
            }
            'ai.cred' {
                $cAct = [string](Get-LctArgValue $a 'action')
                $cProv = [string](Get-LctArgValue $a 'provider')
                $cKey = [string](Get-LctArgValue $a 'key')
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiCredentialVerb -Action $cAct -Provider $cProv -Key $cKey)
            }
            'ai.auto' {
                $aText = [string](Get-LctArgValue $a 'text')
                $aProv = [string](Get-LctArgValue $a 'provider')
                $aEp = [string](Get-LctArgValue $a 'endpoint')
                $aModel = [string](Get-LctArgValue $a 'model')
                $aKey = [string](Get-LctArgValue $a 'apiKey')
                $aTo = 60
                try { $x = Get-LctArgValue $a 'timeoutSec'; if ($null -ne $x -and [string]$x -ne '') { $aTo = [int]$x } } catch { $aTo = 60 }
                $aApply = $false
                try { $aApply = ConvertTo-LctBool (Get-LctArgValue $a 'apply') } catch { $aApply = $false }
                if ($Apply) { $aApply = $true }
                $aConfirm = [string](Get-LctArgValue $a 'confirm')
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiAuto -Text $aText -Provider $aProv -Endpoint $aEp -Model $aModel -ApiKey $aKey -TimeoutSec $aTo -Apply:$aApply -Confirm $aConfirm)
            }
                        'ai.do' {
                $dgoal = [string](Get-LctArgValue $a 'goal')
                $dapply = $false
                try { $dapply = ConvertTo-LctBool (Get-LctArgValue $a 'apply') } catch { $dapply = $false }
                if ($Apply) { $dapply = $true }
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiDo -Goal $dgoal -Apply:$dapply -Confirm ([string](Get-LctArgValue $a 'confirm')))
            }
            'ai.plan' { return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiPlan -Goal ([string](Get-LctArgValue $a 'goal'))) }
            'ai.run' {
                $tgt = [string](Get-LctArgValue $a 'verb')
                $targs = Get-LctArgValue $a 'args'
                $tapply = $false
                try { $tapply = ConvertTo-LctBool (Get-LctArgValue $a 'apply') } catch { $tapply = $false }
                if ($Apply) { $tapply = $true }
                return Use-LctModuleReturn -Verb $Verb -R (Invoke-LctAiRun -TargetVerb $tgt -ArgBag $targs -Apply:$tapply -Confirm ([string](Get-LctArgValue $a 'confirm')))
            }
            'capability.status' { return Use-LctModuleReturn -Verb $Verb -R (Get-LctCapabilities) }
            'driver.map' {
                $mlRaw = Get-LctArgValue $a 'maxLinks'
                $mlInt = 3000
                if ($null -ne $mlRaw -and [string]$mlRaw -ne '') { try { $mlInt = [int]$mlRaw } catch { $mlInt = 3000 } }
                $incRaw = Get-LctArgValue $a 'includeUnresolved'
                if ($null -eq $incRaw -or [string]$incRaw -eq '') { $incUnres = $true } else { $incUnres = ConvertTo-LctBool $incRaw }
                return Use-LctModuleReturn -Verb $Verb -R (Get-LctDriverObjectMap -Service (Get-LctArgValue $a 'service') -MaxLinks $mlInt -IncludeUnresolved $incUnres)
            }
            'driver.profile.save' {
                $js = Get-LctArgValue $a 'json'
                if ($null -ne $js -and $js -isnot [string]) { $js = ($js | ConvertTo-Json -Depth 12 -Compress) }
                return Save-LctDriverProfile -Id (Get-LctArgValue $a 'id') -Json ([string]$js) -Override:(ConvertTo-LctBool (Get-LctArgValue $a 'override')) -Apply:$Apply
            }
            default {
                return New-LctResultSafe -Verb $Verb -Errors @("未知 verb: $Verb")
            }
        }
    } catch {
        $msg = "引擎异常: " + $_.Exception.Message
        if ($_.Exception -is [System.Management.Automation.CommandNotFoundException]) {
            $msg = "依赖未就绪：" + $_.Exception.Message
        }
        return New-LctResultSafe -Verb $Verb -Errors @($msg, ($_.InvocationInfo.PositionMessage -replace "`r`n", ' '))
    }
}

Export-ModuleMember -Function Invoke-LctEngine, Get-LctVerbTable, Get-LctAvailability, Read-LctPresetPacks,
    Get-LctPresetPack, Get-LctLoadErrors, Get-LctLoadedModules