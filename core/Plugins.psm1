# LocalConfigTool - 插件子系统（职责：插件发现 / 清单校验 / 预览 / 执行）
# 作者：task-2（backend-plugins）。接口契约：docs\CONTRACT.md §5（plugins.list / plugins.show / plugins.run）。
# 导出：Get-LctPluginList Get-LctPlugin Invoke-LctPlugin
#
# 设计要点（硬性要求）：
#   * Invoke-LctPlugin 默认只预览：不传 -Apply 时【绝不启动任何进程、也不写任何文件】，
#     只回显解析后的命令行（参数已替换，secret 已脱敏）与 timeout。预览零副作用，便于自测直接核验。
#   * 传 -Apply 才执行：stdout/stderr 原样捕获，写入 var\logs\plugin-<id>-<时间戳>.log（UTF-8 带 BOM）；
#     返回 exitCode / logPath / stdoutTail / stderrTail / command；到点未退出则终止子进程树。
#   * 命令行模板支持 {name} 占位：优先用 plugin.json 的 entry.args；未声明时按 params 顺序自动生成
#     （非 bool → "-name" + 值；bool 为 true → "-name"，false → 整个参数省略）。
#   * secret 参数的真实值只进入子进程命令行；command、Result.data、日志与捕获输出中一律显示 ***。
#   * 参数校验：required 缺失报错；int 参数名为 timeout 时强制 1..600。
#   * 本模块不做任何删除；如将来需要清理文件，只能调用 Move-LctToRecycleBin（禁止 Remove-Item）。
#   * 数组约定：Get-LctPluginList 返回普通数组（与 core\Backup.psm1 的 Get-LctBackupList 一致）。
#     调用方（Engine）请用 @(Get-LctPluginList) 包裹以固定数组形状——只有 1 个插件时尤其必要，
#     否则 ConvertTo-Json 会把它序列化成对象而不是 [{...}]，与契约 §5 的 plugins.list 不符。
#   * 兼容 Windows PowerShell 5.1；不 Set-StrictMode；不依赖第三方模块。

# 独立 Import-Module 本文件时，自动补齐公共模块（不改动 Logging.psm1）
if (-not (Get-Command -Name Get-LctToolRoot -ErrorAction SilentlyContinue)) {
    $lctLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
    if (Test-Path -LiteralPath $lctLoggingModule) {
        Import-Module -Name $lctLoggingModule -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# 内部辅助
# ---------------------------------------------------------------------------

function Get-LctPluginsRoot {
    # 插件根目录：优先环境变量 LCT_PLUGIN_ROOT（Engine.ps1 -PluginRoot 会设置它，便于测试隔离），
    # 否则 <工具根>\plugins（与 Get-LctVarDir 的 LCT_VAR_DIR 约定同构）
    if ($env:LCT_PLUGIN_ROOT) { return $env:LCT_PLUGIN_ROOT }
    return (Join-Path (Get-LctToolRoot) 'plugins')
}

function Get-LctProp {
    # 从 Hashtable / PSCustomObject 上安全取属性（不存在返回 $null）
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function ConvertTo-LctCmdArg {
    # 按 Windows 命令行规则给单个参数加引号（Start-Process 的 -ArgumentList 不会自动加引号，必须自己做）
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $s = $Value -replace '(\\+)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Get-LctPowerShellExe {
    # 用当前宿主 PowerShell 跑 ps1 入口（保持与引擎相同的解释器语义）
    $cur = $null
    try { $cur = (Get-Process -Id $PID).Path } catch { $cur = $null }
    if ($cur -and (Test-Path -LiteralPath $cur)) { return $cur }
    $cand = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path -LiteralPath $cand) { return $cand }
    return 'powershell.exe'
}

function ConvertTo-LctPluginParamDef {
    # 归一化 plugin.json 的单个参数定义
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $name = [string](Get-LctProp $Raw 'name')
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $type = [string](Get-LctProp $Raw 'type')
    if (@('string','int','bool','path','secret') -notcontains $type) { $type = 'string' }
    $secret = [bool](Get-LctProp $Raw 'secret')
    if ($type -eq 'secret') { $secret = $true }
    return [pscustomobject][ordered]@{
        name     = $name
        title    = [string](Get-LctProp $Raw 'title')
        type     = $type
        required = [bool](Get-LctProp $Raw 'required')
        default  = (Get-LctProp $Raw 'default')
        secret   = $secret
        help     = [string](Get-LctProp $Raw 'help')
        min      = (Get-LctProp $Raw 'min')
        max      = (Get-LctProp $Raw 'max')
    }
}

function ConvertTo-LctPluginParamPublic {
    # 对外投影：只暴露契约里的字段；secret 参数不回显默认值
    param($Def)
    $default = $Def.default
    if ($Def.secret) { $default = '' }
    return [pscustomobject][ordered]@{
        name     = $Def.name
        title    = $Def.title
        type     = $Def.type
        required = [bool]$Def.required
        default  = $default
        secret   = [bool]$Def.secret
        help     = $Def.help
    }
}

function Get-LctPluginManifest {
    # 读取并校验 plugins\<id>\plugin.json
    param([Parameter(Mandatory)][string]$Dir)
    $jsonPath = Join-Path $Dir 'plugin.json'
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { throw "插件清单不存在: $jsonPath" }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 } catch { throw "无法读取插件清单: $jsonPath ($($_.Exception.Message))" }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "插件清单为空: $jsonPath" }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { throw "插件清单不是合法 JSON: $jsonPath ($($_.Exception.Message))" }
    if ($null -eq $obj) { throw "插件清单不是合法 JSON 对象: $jsonPath" }

    $id = [string](Get-LctProp $obj 'id')
    if ([string]::IsNullOrWhiteSpace($id)) { throw "插件清单缺少 id: $jsonPath" }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_]*$') { throw "插件 id 非法（只允许字母数字与 . - _）: $id" }

    $name = [string](Get-LctProp $obj 'name'); if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
    $version = [string](Get-LctProp $obj 'version'); if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.0.0' }
    $risk = [string](Get-LctProp $obj 'risk')
    if (@('lab-only','high','medium') -notcontains $risk) { $risk = 'high' }

    $entry = Get-LctProp $obj 'entry'
    $kind = [string](Get-LctProp $entry 'kind')
    # 契约 §12.3：种类合法性由 PluginSdk 的种类注册表判定；PluginSdk 未装载时退回 v1 白名单。
    $kindAllowed = @('ps1', 'exe')
    if (Get-Command Get-LctPluginKindRegistry -ErrorAction SilentlyContinue) {
        $kindReg = Get-LctPluginKindRegistry
        if ($kindReg -and @($kindReg.Keys).Count -gt 0) { $kindAllowed = @($kindReg.Keys) }
    }
    if ($kindAllowed -notcontains $kind) { throw "插件 $id 的 entry.kind 不在种类注册表里（当前: '$kind'；可用: $(@($kindAllowed) -join ', ')）" }
    $rel = [string](Get-LctProp $entry 'path')
    if ([string]::IsNullOrWhiteSpace($rel)) { throw "插件 $id 缺少 entry.path" }
    if ($rel -match '\.\.') { throw "插件 $id 的 entry.path 不得包含 ..（禁止越出插件目录）" }
    if ([IO.Path]::IsPathRooted($rel)) { $entryPath = $rel } else { $entryPath = Join-Path $Dir $rel }

    $params = New-Object System.Collections.ArrayList
    foreach ($rp in @(Get-LctProp $obj 'params')) {
        $pd = ConvertTo-LctPluginParamDef -Raw $rp
        if ($null -ne $pd) { $null = $params.Add($pd) }
    }

    $entryArgs = New-Object System.Collections.ArrayList
    foreach ($a in @(Get-LctProp $entry 'args')) { if ($null -ne $a) { $null = $entryArgs.Add([string]$a) } }

    $outputs = New-Object System.Collections.ArrayList
    foreach ($o in @(Get-LctProp $obj 'outputs')) { if ($null -ne $o) { $null = $outputs.Add([string]$o) } }

    # ---- 契约 §12.2/§12.3：PluginSdk 存在时才做 v2 校验（清单版本/能力/种类/完整性）----
    # 这是「防御式挂钩」：SDK 未装载（或装载失败）时行为与 v1 完全一致，绝不因新功能破坏老插件。
    $sdkInfo = $null
    if (Get-Command Test-LctPluginManifestV2 -ErrorAction SilentlyContinue) {
        $sdkInfo = Test-LctPluginManifestV2 -Obj $obj -Dir $Dir -Id $id
        if ($null -ne $sdkInfo -and $sdkInfo.ok -eq $false) {
            throw ("插件 $id 清单校验未通过: " + (@($sdkInfo.errors) -join '; '))
        }
    }

    return [pscustomobject][ordered]@{
        id           = $id
        name         = $name
        version      = $version
        description  = [string](Get-LctProp $obj 'description')
        risk         = $risk
        note         = [string](Get-LctProp $obj 'note')
        dir          = $Dir
        manifestPath = $jsonPath
        entryKind    = $kind
        entryPath    = $entryPath
        entryArgs    = @($entryArgs)
        params       = @($params)
        outputs      = @($outputs)
        # ---- v2 字段（v1 清单下为降级值，不影响老行为）----
        manifestVersion = $(if ($sdkInfo) { [int]$sdkInfo.manifestVersion } else { 1 })
        degraded        = $(if ($sdkInfo) { [bool]$sdkInfo.degraded } else { $true })
        capabilities    = @($(if ($sdkInfo) { @($sdkInfo.capabilities) } else { @() }))
        kinds           = @($(if ($sdkInfo) { @($sdkInfo.kinds) } else { @() }))
        engineApiOk     = $(if ($sdkInfo) { [bool]$sdkInfo.engineApiOk } else { $true })
        sdkWarnings     = @($(if ($sdkInfo) { @($sdkInfo.warnings) } else { @() }))
    }
}

function ConvertTo-LctPluginDetail {
    # 契约 §5 plugins.show / plugins.list 的插件对象
    param($Manifest)
    $publicParams = New-Object System.Collections.ArrayList
    foreach ($pd in @($Manifest.params)) {
        $null = $publicParams.Add((ConvertTo-LctPluginParamPublic -Def $pd))
    }
    return [pscustomobject][ordered]@{
        id           = $Manifest.id
        name         = $Manifest.name
        version      = $Manifest.version
        risk         = $Manifest.risk
        description  = $Manifest.description
        note         = $Manifest.note
        params       = @($publicParams)
        path         = $Manifest.dir
        dir          = $Manifest.dir
        entryKind    = $Manifest.entryKind
        entryPath    = $Manifest.entryPath
        entryArgs    = @($Manifest.entryArgs)
        outputs      = @($Manifest.outputs)
        manifestPath = $Manifest.manifestPath
        # ---- v2（P0）：把清单版本与能力声明暴露给界面，装载前就能逐条列出该插件要用什么 ----
        manifestVersion = $(if ($Manifest.PSObject.Properties['manifestVersion']) { $Manifest.manifestVersion } else { 1 })
        degraded        = $(if ($Manifest.PSObject.Properties['degraded']) { $Manifest.degraded } else { $true })
        capabilities    = @($(if ($Manifest.PSObject.Properties['capabilities']) { @($Manifest.capabilities) } else { @() }))
        kinds           = @($(if ($Manifest.PSObject.Properties['kinds']) { @($Manifest.kinds) } else { @() }))
        engineApiOk     = $(if ($Manifest.PSObject.Properties['engineApiOk']) { $Manifest.engineApiOk } else { $true })
        sdkWarnings     = @($(if ($Manifest.PSObject.Properties['sdkWarnings']) { @($Manifest.sdkWarnings) } else { @() }))
    }
}

function ConvertTo-LctParamTable {
    # 把 params（Hashtable / PSCustomObject / JSON 字符串 / $null）统一成大小写不敏感的 Hashtable
    param($Params)
    $h = @{}
    if ($null -eq $Params) { return $h }
    $src = $Params
    if ($src -is [string]) {
        if ([string]::IsNullOrWhiteSpace($src)) { return $h }
        try { $src = $src | ConvertFrom-Json } catch { throw "params 不是合法 JSON: $($_.Exception.Message)" }
    }
    if ($null -eq $src) { return $h }
    if ($src -is [System.Collections.IDictionary]) {
        foreach ($k in @($src.Keys)) { $h[[string]$k] = $src[$k] }
        return $h
    }
    foreach ($p in @($src.PSObject.Properties)) { $h[$p.Name] = $p.Value }
    return $h
}

function Resolve-LctPluginValues {
    # 校验 + 类型归一化。values = 真实值；display = 脱敏值；secrets = 需要擦除的明文
    param($ManifestParams, [hashtable]$Table)
    $values = @{}
    $display = @{}
    $errors = New-Object System.Collections.ArrayList
    $secrets = New-Object System.Collections.ArrayList
    foreach ($pd in @($ManifestParams)) {
        $given = $Table.ContainsKey($pd.name)
        $raw = $null
        if ($given) {
            $raw = $Table[$pd.name]
        } elseif ($null -ne $pd.default) {
            $isBlankDefault = ($pd.default -is [string]) -and [string]::IsNullOrWhiteSpace([string]$pd.default)
            if (-not $isBlankDefault) { $raw = $pd.default }
        }
        $isEmpty = ($null -eq $raw) -or (($raw -is [string]) -and [string]::IsNullOrEmpty([string]$raw))
        if ($isEmpty) {
            if ($pd.required) { $null = $errors.Add("缺少必填参数: $($pd.name)（$(if ($pd.title) { $pd.title } else { $pd.name })）") }
            continue
        }

        $val = $null
        $ok = $true
        if ($pd.type -eq 'int') {
            $n = 0
            if (-not [int]::TryParse([string]$raw, [ref]$n)) {
                $ok = $false
                $null = $errors.Add("参数 $($pd.name) 需要整数，收到 '$raw'")
            } else {
                if (@('timeout','timeoutsec') -contains ([string]$pd.name).ToLowerInvariant()) {
                    if ($n -lt 1 -or $n -gt 600) {
                        $ok = $false
                        $null = $errors.Add("参数 $($pd.name) 必须在 1..600 秒之间（收到 $n）")
                    }
                }
                if ($ok -and $null -ne $pd.min -and $n -lt [int]$pd.min) { $ok = $false; $null = $errors.Add("参数 $($pd.name) 不能小于 $($pd.min)") }
                if ($ok -and $null -ne $pd.max -and $n -gt [int]$pd.max) { $ok = $false; $null = $errors.Add("参数 $($pd.name) 不能大于 $($pd.max)") }
                if ($ok) { $val = $n }
            }
        } elseif ($pd.type -eq 'bool') {
            if ($raw -is [bool]) { $val = $raw }
            elseif ([string]$raw -match '^(?i:true|1|yes|on|是)$') { $val = $true }
            elseif ([string]$raw -match '^(?i:false|0|no|off|否)$') { $val = $false }
            else { $ok = $false; $null = $errors.Add("参数 $($pd.name) 需要布尔值，收到 '$raw'") }
        } else {
            $val = [string]$raw
        }
        if (-not $ok) { continue }

        $values[$pd.name] = $val
        if ($pd.secret) {
            $display[$pd.name] = '***'
            if (-not [string]::IsNullOrEmpty([string]$val)) { $null = $secrets.Add([string]$val) }
        } else {
            $display[$pd.name] = $val
        }
    }
    return [pscustomobject]@{ values = $values; display = $display; errors = @($errors); secrets = @($secrets) }
}

function Expand-LctToken {
    # {name} 占位替换；bool 为 true 展开成 "-name"，false 展开成空串（该 token 会被丢弃）
    param([string]$Text, [hashtable]$Values, [hashtable]$Display, [switch]$Redact)
    $out = $Text
    foreach ($k in @($Values.Keys)) {
        $token = '{' + $k + '}'
        if ($out.IndexOf($token) -lt 0) { continue }
        $val = $Values[$k]
        if ($val -is [bool]) {
            if ($val) { $rep = '-' + $k } else { $rep = '' }
        } elseif ($Redact) {
            $rep = [string]$Display[$k]
        } else {
            $rep = [string]$val
        }
        $out = $out.Replace($token, $rep)
    }
    return $out
}

function Build-LctArgTokens {
    # 生成实际传给子进程的参数数组（Redact 时只用于回显/日志）
    param($Manifest, [hashtable]$Values, [hashtable]$Display, [switch]$Redact)
    $tokens = New-Object System.Collections.ArrayList
    if (@($Manifest.entryArgs).Count -gt 0) {
        foreach ($t in @($Manifest.entryArgs)) {
            $s = Expand-LctToken -Text ([string]$t) -Values $Values -Display $Display -Redact:$Redact
            if (-not [string]::IsNullOrWhiteSpace($s)) { $null = $tokens.Add($s) }
        }
        return @($tokens)
    }
    foreach ($pd in @($Manifest.params)) {
        if (-not $Values.ContainsKey($pd.name)) { continue }
        if ($pd.type -eq 'bool') {
            if ([bool]$Values[$pd.name]) { $null = $tokens.Add('-' + $pd.name) }
            continue
        }
        $null = $tokens.Add('-' + $pd.name)
        if ($Redact -and $pd.secret) { $null = $tokens.Add('***') } else { $null = $tokens.Add([string]$Values[$pd.name]) }
    }
    return @($tokens)
}

function ConvertFrom-LctRawBytes {
    # 先按严格 UTF-8 解码，失败（非法字节）再退回系统 ANSI 代码页，避免中文乱码
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $b = $Bytes
    if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) {
        if ($b.Length -eq 3) { return '' }
        $n = $b.Length - 3
        $nb = New-Object byte[] $n
        [Array]::Copy($b, 3, $nb, 0, $n)
        $b = $nb
    }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $strict.GetString($b) } catch { }
    try { return [System.Text.Encoding]::Default.GetString($b) } catch { }
    return ''
}

function Get-LctTail {
    param([string]$Text, [int]$MaxLength = 2000)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    return ('...(已截断，仅显示末尾 ' + $MaxLength + ' 字符)' + "`r`n" + $Text.Substring($Text.Length - $MaxLength))
}

function Stop-LctProcessTree {
    # 超时清理：先递归结束子进程，再结束自身（避免留下 PoC 依赖的中间进程）
    param([Parameter(Mandatory)][int]$ProcId)
    $children = @()
    try {
        $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ProcId" -ErrorAction SilentlyContinue)
    } catch {
        $children = @()
    }
    foreach ($c in $children) {
        try { Stop-LctProcessTree -ProcId ([int]$c.ProcessId) } catch { }
    }
    try { Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue } catch { }
}

function Invoke-LctPluginProcess {
    # 启动子进程并抓取 stdout/stderr（原始字节），超时终止整棵子进程树
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$ArgumentString,
        [string]$WorkingDirectory = '',
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = $ArgumentString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $msOut = New-Object System.IO.MemoryStream
    $msErr = New-Object System.IO.MemoryStream
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = $proc.Start()
    $tOut = $proc.StandardOutput.BaseStream.CopyToAsync($msOut)
    $tErr = $proc.StandardError.BaseStream.CopyToAsync($msErr)

    $exited = $false
    try { $exited = $proc.WaitForExit($TimeoutSeconds * 1000) } catch { $exited = $false }
    $timedOut = -not $exited
    if ($timedOut) {
        Stop-LctProcessTree -ProcId $proc.Id
        try { $null = $proc.WaitForExit(5000) } catch { }
    }
    foreach ($t in @($tOut, $tErr)) { try { $null = $t.Wait(5000) } catch { } }
    $sw.Stop()

    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }
    $outBytes = $msOut.ToArray()
    $errBytes = $msErr.ToArray()
    try { $msOut.Dispose() } catch { }
    try { $msErr.Dispose() } catch { }
    try { $proc.Dispose() } catch { }

    return [pscustomobject]@{
        exitCode = $exitCode
        timedOut = $timedOut
        seconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        stdout   = (ConvertFrom-LctRawBytes -Bytes $outBytes)
        stderr   = (ConvertFrom-LctRawBytes -Bytes $errBytes)
    }
}

# ---------------------------------------------------------------------------
# 导出函数
# ---------------------------------------------------------------------------

function Get-LctPluginList {
    # 契约 §5 plugins.list：列出全部有效插件（清单无效的目录跳过并记警告日志）
    $out = New-Object System.Collections.ArrayList
    $root = Get-LctPluginsRoot
    $dirs = @()
    if (Test-Path -LiteralPath $root -PathType Container) {
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    foreach ($d in $dirs) {
        $m = $null
        try {
            $m = Get-LctPluginManifest -Dir $d.FullName
        } catch {
            Write-LctLog -Verb 'plugins.list' -Level warn -Message "跳过无效插件目录: $($d.FullName) - $($_.Exception.Message)" | Out-Null
            continue
        }
        $null = $out.Add((ConvertTo-LctPluginDetail -Manifest $m))
    }
    return @($out)
}

function Get-LctPlugin {
    # 契约 §5 plugins.show：单个插件详情（含 entry 解析后的绝对路径）
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -match '[\\/]' -or $Id -match '\.\.') { throw "非法插件 id: $Id" }
    $dir = Join-Path (Get-LctPluginsRoot) $Id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "插件不存在: $Id（未找到目录 $dir）" }
    $m = Get-LctPluginManifest -Dir $dir
    if ($m.id -ne $Id) { throw "插件 id 与目录名不一致: 目录=$Id 清单=$($m.id)" }
    return (ConvertTo-LctPluginDetail -Manifest $m)
}

function Invoke-LctPlugin {
    <#
      .SYNOPSIS
        预览或执行一个插件（契约 §5 plugins.run）。
      .DESCRIPTION
        不带 -Apply：只解析命令行与 timeout 并回显，绝不启动进程、绝不写文件。
        带 -Apply：执行入口，捕获 stdout/stderr 到 var\logs\plugin-<id>-<时间戳>.log，返回退出码与输出尾部。
      .PARAMETER Plugin
        插件 id（plugins\<id> 目录名，与 plugin.json 的 id 一致）。别名 -Id（Engine.psm1 用 -Id 调用）。
      .PARAMETER Params
        参数对象（Hashtable / PSCustomObject / JSON 字符串），键名对应 plugin.json 的 params[].name。
      .PARAMETER Timeout
        执行超时秒数（1..600）。优先级：调用方显式给的 params.timeout（最具体）> 本参数 > 插件自身默认值。
        最终的进程超时会与传给插件的 timeout 参数保持一致。
      .PARAMETER Apply
        显式执行开关。不加则只预览。
    #>
    param(
        [Parameter(Mandatory)][Alias('Id')][string]$Plugin,
        $Params = $null,
        [int]$Timeout = 0,
        [switch]$Apply
    )

    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $m = $null
    try {
        if ($Plugin -match '[\\/]' -or $Plugin -match '\.\.') { throw "非法插件 id: $Plugin" }
        $dir = Join-Path (Get-LctPluginsRoot) $Plugin
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "插件不存在: $Plugin" }
        $m = Get-LctPluginManifest -Dir $dir
        if ($m.id -ne $Plugin) { throw "插件 id 与目录名不一致: 目录=$Plugin 清单=$($m.id)" }
    } catch {
        $null = $errors.Add("插件不可用: $($_.Exception.Message)")
    }

    if ($null -eq $m) {
        if ($Apply) {
            Write-LctLog -Verb 'plugins.run' -Level error -Message "插件不可用: $Plugin" | Out-Null
        }
        return New-LctResult -Verb 'plugins.run' -Errors @($errors) -Warnings @($warnings) `
            -Data ([pscustomobject][ordered]@{ command = ''; resolvedParams = [pscustomobject]@{}; timeout = 0 })
    }

    # ---- 参数解析与校验 ----
    $table = @{}
    try { $table = ConvertTo-LctParamTable -Params $Params } catch { $null = $errors.Add($_.Exception.Message) }

    # 未声明参数：忽略并告警（避免手写 JSON 的笔误被静默吞掉）
    $declared = @()
    foreach ($pd in @($m.params)) { $declared += ([string]$pd.name).ToLowerInvariant() }
    foreach ($k in @($table.Keys)) {
        if ($declared -notcontains ([string]$k).ToLowerInvariant()) { $null = $warnings.Add("忽略未声明参数: $k") }
    }

    if ($Timeout -lt 0 -or $Timeout -gt 600) { $null = $errors.Add("timeout 必须在 1..600 秒之间（收到 $Timeout）") }
    $declaresTimeout = ($declared -contains 'timeout')
    # Engine 侧 plugins.run 的默认实现总会传 -Timeout 120，因此只有调用方【没有显式】给 params.timeout
    # 时才把工具级 -Timeout 注入进去，否则会静默覆盖插件自己的参数。
    $pluginTimeoutGiven = ($declaresTimeout -and $table.ContainsKey('timeout'))
    if (-not $pluginTimeoutGiven -and $Timeout -gt 0 -and $declaresTimeout) { $table['timeout'] = $Timeout }

    $resolved = Resolve-LctPluginValues -ManifestParams $m.params -Table $table
    foreach ($e in @($resolved.errors)) { $null = $errors.Add($e) }
    $values = $resolved.values
    $display = $resolved.display

    # ---- 进程超时：与传给插件的 timeout 参数取同一个值（避免"插件以为有 300s，120s 就被杀"）----
    $procTimeout = 120
    if ($pluginTimeoutGiven -and $values.ContainsKey('timeout')) { $procTimeout = [int]$values['timeout'] }
    elseif ($Timeout -gt 0) { $procTimeout = $Timeout }
    elseif ($values.ContainsKey('timeout')) { $procTimeout = [int]$values['timeout'] }
    elseif ($table.ContainsKey('timeout')) {
        $n = 0
        if ([int]::TryParse([string]$table['timeout'], [ref]$n)) { $procTimeout = $n }
    }
    $procTimeout = [int][Math]::Min([Math]::Max($procTimeout, 1), 600)
    if ($declaresTimeout) {
        $values['timeout'] = $procTimeout
        $display['timeout'] = $procTimeout
    }

    # ---- 命令行解析 ----
    # 契约 §12.3 / docs\PLUGIN-SDK.md §4：kind 分派查表，不再写 if/else 分支。
    # **加新种类 = 在下面这张表里加一条**（种类合法性另由 PluginSdk 的种类注册表校验）。
    $handlerTable = @{
        'ps1' = { param($mp) @{ exe = (Get-LctPowerShellExe); prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mp.entryPath) } }
        'exe' = { param($mp) @{ exe = [string]$mp.entryPath; prefix = @() } }
    }
    $exePath = $m.entryPath
    $prefix = @()
    $kindHandler = $handlerTable[[string]$m.entryKind]
    if ($null -eq $kindHandler) {
        $null = $errors.Add("插件入口种类 '$($m.entryKind)' 在本执行器里还没有 handler（注册表已声明但执行器未接线）")
    } else {
        $resolved = & $kindHandler $m
        $exePath = [string]$resolved.exe
        $prefix = @($resolved.prefix)
    }
    if (-not (Test-Path -LiteralPath $m.entryPath -PathType Leaf)) {
        $null = $errors.Add("插件入口不存在: $($m.entryPath)")
    }

    $realTokens = @(Build-LctArgTokens -Manifest $m -Values $values -Display $display)
    $displayTokens = @(Build-LctArgTokens -Manifest $m -Values $values -Display $display -Redact)

    $undeclaredInTemplate = $null
    foreach ($a in @($realTokens + $displayTokens)) {
        if ($a -match '\{[A-Za-z0-9_\-]+\}') { $undeclaredInTemplate = $a; break }
    }
    if ($undeclaredInTemplate) { $null = $errors.Add("命令行模板引用了未声明的参数: $undeclaredInTemplate") }

    $realArgString = (@(($prefix + $realTokens) | ForEach-Object { ConvertTo-LctCmdArg ([string]$_) }) -join ' ').Trim()
    $displayArgString = (@(($prefix + $displayTokens) | ForEach-Object { ConvertTo-LctCmdArg ([string]$_) }) -join ' ').Trim()
    $displayCommand = ((ConvertTo-LctCmdArg $exePath) + ' ' + $displayArgString).Trim()

    # data.resolvedParams：按声明顺序、secret 脱敏
    $publicResolved = [ordered]@{}
    foreach ($pd in @($m.params)) {
        if ($values.ContainsKey($pd.name)) {
            if ($pd.secret) { $publicResolved[$pd.name] = '***' } else { $publicResolved[$pd.name] = $values[$pd.name] }
        }
    }

    if ($errors.Count -gt 0) {
        if ($Apply) {
            Write-LctLog -Verb 'plugins.run' -Level error -Message "插件调用参数有误: $($m.id)" -Data ([ordered]@{ plugin = $m.id; errors = @($errors) }) | Out-Null
        }
        return New-LctResult -Verb 'plugins.run' -Errors @($errors) -Warnings @($warnings) `
            -Data ([pscustomobject][ordered]@{ command = ''; resolvedParams = [pscustomobject]$publicResolved; timeout = $procTimeout })
    }

    if ($m.risk -in @('high', 'lab-only')) {
        $riskNote = if ($m.note) { $m.note } else { '' }
        $null = $warnings.Add("插件风险等级为 $($m.risk)：$riskNote 请仅在自有测试环境中运行。".Trim())
    }

    # ---- 预览：不启动进程、不写文件 ----
    if (-not $Apply) {
        return New-LctResult -Verb 'plugins.run' -Warnings @($warnings) -Errors @() `
            -Changes @([pscustomobject]@{ kind = 'plugin'; target = $m.id; name = $m.entryPath; before = '(未执行)'; after = $displayCommand; note = '预览：未启动任何进程；加 -Apply 才会执行' }) `
            -Data ([pscustomobject][ordered]@{
                command        = $displayCommand
                resolvedParams = [pscustomobject]$publicResolved
                timeout        = $procTimeout
            })
    }

    # ---- 执行：日志落 var\logs\plugin-<id>-<时间戳>.log ----
    $null = $warnings.Add('插件直接执行外部入口，本工具不会为插件执行创建备份；请自行确认已有还原手段。')
    $logDir = Join-Path (Get-LctVarDir) 'logs'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeId = ($m.id -replace '[^0-9A-Za-z\.\-_]', '_')
    $logPath = Join-Path $logDir ("plugin-$safeId-$stamp.log")
    if (Test-Path -LiteralPath $logPath) {
        $logPath = Join-Path $logDir ("plugin-$safeId-$stamp-" + (Get-Random -Maximum 100000) + '.log')
    }

    $startedAt = Get-Date
    Write-LctLog -Verb 'plugins.run' -Level change -Message "开始执行插件 $($m.id)" `
        -Data ([ordered]@{ plugin = $m.id; command = $displayCommand; timeout = $procTimeout }) | Out-Null

    $stdoutText = ''
    $stderrText = ''
    $exitCode = $null
    $timedOut = $false
    $seconds = 0
    try {
        $r = Invoke-LctPluginProcess -ExePath $exePath -ArgumentString $realArgString -WorkingDirectory $m.dir -TimeoutSeconds $procTimeout
        $stdoutText = $r.stdout
        $stderrText = $r.stderr
        $exitCode = $r.exitCode
        $timedOut = $r.timedOut
        $seconds = $r.seconds
    } catch {
        $null = $errors.Add("插件进程启动/执行失败: $($_.Exception.Message)")
    }
    $finishedAt = Get-Date

    # secret 明文即便被插件回显，也要从日志与返回值里擦掉
    foreach ($sv in @($resolved.secrets)) {
        if (-not [string]::IsNullOrEmpty($sv)) {
            $stdoutText = $stdoutText.Replace($sv, '***')
            $stderrText = $stderrText.Replace($sv, '***')
        }
    }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('# LocalConfigTool 插件执行日志（UTF-8）')
    $null = $sb.AppendLine("plugin: $($m.id)")
    $null = $sb.AppendLine("name: $($m.name)")
    $null = $sb.AppendLine("version: $($m.version)")
    $null = $sb.AppendLine("risk: $($m.risk)")
    $null = $sb.AppendLine('verb: plugins.run')
    $null = $sb.AppendLine('applied: True')
    $null = $sb.AppendLine("started: $($startedAt.ToString('s'))")
    $null = $sb.AppendLine("finished: $($finishedAt.ToString('s'))")
    $null = $sb.AppendLine("durationSeconds: $seconds")
    $null = $sb.AppendLine("elevated: $(Test-LctElevated)")
    $null = $sb.AppendLine("timeoutSeconds: $procTimeout")
    $null = $sb.AppendLine("timedOut: $timedOut")
    $null = $sb.AppendLine("exitCode: $(if ($null -eq $exitCode) { '(unknown)' } else { $exitCode })")
    $null = $sb.AppendLine("command: $displayCommand")
    $null = $sb.AppendLine("workingDirectory: $($m.dir)")
    $null = $sb.AppendLine("resolvedParams: $(ConvertTo-LctJson -Object ([pscustomobject]$publicResolved) -Depth 6)")
    $null = $sb.AppendLine('--- stdout ---')
    $null = $sb.AppendLine($stdoutText)
    $null = $sb.AppendLine('--- stderr ---')
    $null = $sb.AppendLine($stderrText)

    try {
        [IO.File]::WriteAllText($logPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        $null = $errors.Add("写插件日志失败: $($_.Exception.Message)")
    }

    if ($timedOut) {
        $null = $errors.Add("插件执行超时（$procTimeout 秒），已终止其子进程树；请查看日志 $logPath")
    } elseif ($null -eq $exitCode) {
        if ($errors.Count -eq 0) { $null = $errors.Add('未能取得插件退出码（进程可能被强制终止）') }
    } elseif ([int]$exitCode -ne 0) {
        $null = $errors.Add("插件退出码非 0: $exitCode（详见日志 $logPath）")
    }

    $changes = @([pscustomobject]@{
        kind   = 'plugin'
        target = $m.id
        name   = $m.entryPath
        before = '(未执行)'
        after  = ('exitCode=' + $(if ($null -eq $exitCode) { '(unknown)' } else { $exitCode }))
        note   = ('日志: ' + $logPath)
    })

    Write-LctLog -Verb 'plugins.run' -Level $(if ($timedOut -or ($null -ne $exitCode -and [int]$exitCode -ne 0)) { 'warn' } else { 'change' }) `
        -Message "插件执行结束: $($m.id) exitCode=$(if ($null -eq $exitCode) { '(unknown)' } else { $exitCode })" `
        -Data ([ordered]@{ plugin = $m.id; exitCode = $exitCode; timedOut = $timedOut; logPath = $logPath }) | Out-Null

    return New-LctResult -Verb 'plugins.run' -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -Data ([pscustomobject][ordered]@{
            exitCode        = $exitCode
            logPath         = $logPath
            stdoutTail      = (Get-LctTail -Text $stdoutText)
            stderrTail      = (Get-LctTail -Text $stderrText)
            command         = $displayCommand
            resolvedParams  = [pscustomobject]$publicResolved
            timeout         = $procTimeout
            timedOut        = $timedOut
            durationSeconds = $seconds
        })
}

Export-ModuleMember -Function Get-LctPluginList, Get-LctPlugin, Invoke-LctPlugin