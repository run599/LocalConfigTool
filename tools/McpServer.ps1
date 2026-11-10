# LocalConfigTool - tools\McpServer.ps1
#
# MCP（Model Context Protocol）服务器：把本工具暴露成一个可以被 AI 宿主挂载的工具集。
#
# 本工具的身份：**系统分析 / 本地配置管理工具 + 标准 MCP 服务器**，不是恶意软件。
#   不自我传播、不隐藏、不窃取数据；不预置 exploit 或漏洞驱动二进制；
#   写操作默认只预览，AI 必须拿到人给的一次性确认短语才能 -Apply。
# 传输 = 标准输入/输出上的 JSON-RPC 2.0（每行一条消息），这是 MCP 的 stdio 传输形态。
#
# 暴露 4 个工具（渐进披露：不把 68 个 verb 一股脑塞给模型）：
#   lct_manifest  {}                                        取机器可读能力清单（含 needsElevation / blockedNow / 预置流程）
#   lct_status    {}                                        当前权限画像（isAdmin / integrityLevel / canLoadDriver）
#   lct_plan      {goal}                                    把一句话目标转成有序执行计划；为第一个可执行的写操作发一次性确认短语
#   lct_call      {verb, args?, apply?, confirm?}           执行：mutating 且 apply=true 时必须带 confirm（人确认后才给）
#
# 为什么要这层：AI 直接裸调 Engine.ps1 也能跑，但拿不到"现在能不能做/该按什么顺序做"的元信息，
# 也绕过了确认闸门。这里把元信息与闸门固化进服务器，AI 只要按协议说话就行。
#
# 安全约定：
#   * 每个请求都写审计日志（var\logs\ai-mcp-<日期>.log），含 verb / apply / 是否有 confirm。
#   * mutating 的 -Apply 必须出示 ai.plan 发出的一次性短语（10 分钟、绑定 verb+args、用后即焚）。
#   * 本服务器不调用任何 LLM，也不做网络 IO；它只是把引擎能力按 MCP 协议转出去。
#
# 启动：powershell -NoProfile -ExecutionPolicy Bypass -File tools\McpServer.ps1
param(
    [string]$ToolRoot = '',
    [string]$LogDir = ''
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::InputEncoding = $utf8 } catch { }
try { [Console]::OutputEncoding = $utf8 } catch { }
try { $OutputEncoding = $utf8 } catch { }

if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $ToolRoot = Split-Path -Parent $PSScriptRoot
} else {
    $ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $ToolRoot 'var\logs' }
if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
$logFile = Join-Path $LogDir ('ai-mcp-' + (Get-Date).ToString('yyyyMMdd') + '.log')

function Write-AiLog([string]$Level, [string]$Message, $Extra = $null) {
    try {
        $line = ('[' + (Get-Date).ToString('s') + '] [' + $Level + '] ' + $Message)
        if ($null -ne $Extra) { try { $line += ' ' + ($Extra | ConvertTo-Json -Depth 5 -Compress) } catch { } }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Write-McpJson($Object) {
    $json = ($Object | ConvertTo-Json -Depth 12 -Compress)
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Write-McpResult($Id, $Result) {
    Write-McpJson([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result })
}

function Write-McpError($Id, [int]$Code, [string]$Message, $Data = $null) {
    $err = [ordered]@{ code = $Code; message = $Message }
    if ($null -ne $Data) { $err['data'] = $Data }
    Write-McpJson([ordered]@{ jsonrpc = '2.0'; id = $Id; error = $err })
}

function Get-ToolList {
    return @(
        [pscustomobject][ordered]@{
            name        = 'lct_manifest'
            description = '取 LocalConfigTool 的机器可读能力清单：每个 verb 的 mutating / needsElevation / blockedNow，两条预置流程（elevate-then-drive、draft-then-send），以及安全规则。建议每次会话先调用它。'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{}; required = @() }
        },
        [pscustomobject][ordered]@{
            name        = 'lct_status'
            description = '当前权限画像：isAdmin / integrityLevel / canLoadDriver / 两条能力路线的可用性 / 前置条件提示（只读）。用来判断"现在到底能不能加载驱动"。'
            inputSchema = [ordered]@{ type = 'object'; properties = [ordered]@{}; required = @() }
        },
        [pscustomobject][ordered]@{
            name        = 'lct_plan'
            description = '把一句话目标（中文/英文均可）转成确定性有序执行计划，并给第一个可执行的写操作发一次性确认短语。只读、不执行。'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{ goal = [ordered]@{ type = 'string'; description = '目标，例如：提权到system然后加载我的驱动' } }
                required   = @('goal')
            }
        },
        [pscustomobject][ordered]@{
            name        = 'lct_call'
            description = '执行一个引擎 verb。只读 verb 直接执行；mutating 的 verb 必须 apply=true 且带 confirm（来自 lct_plan 的一次性短语）。未提权时驱动类操作会被拦住并返回原因。'
            inputSchema = [ordered]@{
                type       = 'object'
                properties = [ordered]@{
                    verb    = [ordered]@{ type = 'string'; description = '引擎 verb 名，例如 driver.load / driver.map / capability.status' }
                    args    = [ordered]@{ type = 'object'; description = '该 verb 的参数对象（可为空）' }
                    apply   = [ordered]@{ type = 'boolean'; description = '是否真正执行（默认 false=预览）' }
                    confirm = [ordered]@{ type = 'string'; description = 'mutating + apply=true 时必填：lct_plan 给出的一次性确认短语' }
                }
                required   = @('verb')
            }
        }
    )
}

function ConvertTo-ToolContent($EngineResult) {
    # 把引擎 Result 变成 MCP 的 content 结构：文本里放完整 JSON，便于模型直接读
    $ok = $false
    try { $ok = [bool]$EngineResult.ok } catch { }
    $text = ''
    try { $text = ($EngineResult | ConvertTo-Json -Depth 12 -Compress) } catch { $text = '{"ok":false,"errors":["结果序列化失败"]}' }
    return [ordered]@{
        content = @([ordered]@{ type = 'text'; text = $text })
        isError = (-not $ok)
    }
}

function Invoke-Tool([string]$Name, $Arguments) {
    $argObj = $null
    if ($null -ne $Arguments) { $argObj = $Arguments }
    switch ($Name) {
        'lct_manifest' { return (ConvertTo-ToolContent (Get-LctAiManifest)) }
        'lct_status' { return (ConvertTo-ToolContent (Get-LctCapabilities)) }
        'lct_plan' {
            $goal = ''
            if ($null -ne $argObj -and $null -ne $argObj.PSObject.Properties['goal']) { $goal = [string]$argObj.goal }
            return (ConvertTo-ToolContent (Invoke-LctAiPlan -Goal $goal))
        }
        'lct_call' {
            $verb = ''
            $a = $null
            $apply = $false
            $confirm = ''
            if ($null -ne $argObj) {
                if ($null -ne $argObj.PSObject.Properties['verb']) { $verb = [string]$argObj.verb }
                if ($null -ne $argObj.PSObject.Properties['args']) { $a = $argObj.args }
                if ($null -ne $argObj.PSObject.Properties['apply']) { $apply = [bool]$argObj.apply }
                if ($null -ne $argObj.PSObject.Properties['confirm']) { $confirm = [string]$argObj.confirm }
            }
            return (ConvertTo-ToolContent (Invoke-LctAiRun -TargetVerb $verb -ArgBag $a -Apply:$apply -Confirm $confirm))
        }
        default { throw ('未知工具: ' + $Name) }
    }
}

# ---- 导入引擎（一次导入，之后每次调用毫秒级） ----
$engineModule = Join-Path $ToolRoot 'core\Engine.psm1'
try {
    Import-Module $engineModule -Force -Global -ErrorAction Stop -Verbose:$false -WarningAction SilentlyContinue 4>$null 6>$null
    Write-AiLog 'info' 'McpServer 启动' @{ toolRoot = $ToolRoot; pid = $PID }
} catch {
    Write-AiLog 'error' ('导入引擎失败: ' + $_.Exception.Message)
    # 仍然要能回协议错误，而不是静默退出
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ($line.Trim() -eq '') { continue }
    $req = $null
    try { $req = $line | ConvertFrom-Json -ErrorAction Stop } catch {
        Write-McpError $null -32700 ('JSON 解析失败: ' + $_.Exception.Message)
        continue
    }
    $id = $null
    if ($null -ne $req.PSObject.Properties['id']) { $id = $req.id }
    $method = ''
    if ($null -ne $req.PSObject.Properties['method']) { $method = [string]$req.method }

    try {
        switch ($method) {
            'initialize' {
                Write-McpResult $id ([ordered]@{
                        protocolVersion = '2024-11-05'
                        capabilities    = [ordered]@{ tools = [ordered]@{} }
                        serverInfo      = [ordered]@{ name = 'local-config-tool'; version = '1.0.0'; toolRoot = $ToolRoot }
                    })
            }
            'notifications/initialized' { }
            'ping' { Write-McpResult $id ([ordered]@{ pong = $true }) }
            'tools/list' { Write-McpResult $id ([ordered]@{ tools = @(Get-ToolList) }) }
            'tools/call' {
                $name = ''
                $argsObj = $null
                if ($null -ne $req.PSObject.Properties['params']) {
                    if ($null -ne $req.params.PSObject.Properties['name']) { $name = [string]$req.params.name }
                    if ($null -ne $req.params.PSObject.Properties['arguments']) { $argsObj = $req.params.arguments }
                }
                Write-AiLog 'call' ('tools/call ' + $name) @{ args = $argsObj }
                $out = Invoke-Tool -Name $name -Arguments $argsObj
                Write-McpResult $id $out
            }
            default {
                if ($method -ne '') { Write-McpError $id -32601 ('未知方法: ' + $method) }
            }
        }
    } catch {
        $msg = $_.Exception.Message
        Write-AiLog 'error' ('处理 ' + $method + ' 失败: ' + $msg)
        Write-McpError $id -32603 $msg
    }
}
Write-AiLog 'info' 'McpServer 退出（EOF）'
exit 0
