# =====================================================================
# LocalConfigTool - Wdac.psm1
# 职责：WDAC（Windows Defender Application Control）自管黑名单：
#       规则维护 / 策略生成 / 安全门校验 / legacy 部署 / 回滚 / 重启后验证
# 作者：task-5 (backend-wdac)
# 契约：docs\CONTRACT.md §3 Result / §7 铁律 / §10 集成约定 / §11.3 §11.5
# 导出：Get-LctWdacStatus Get-LctWdacRules Add-LctWdacRule Remove-LctWdacRule
#       New-LctWdacPolicy Test-LctWdacPolicy Deploy-LctWdacPolicy Restore-LctWdacPolicy Get-LctWdacVerify
#
# ---- 本机实测结论（2026-10-25/26，Win10 19045.6466，Windows PowerShell 5.1）----
#  1) Secure Boot=False ⇒ 未签名策略可加载；CiTool.exe 不存在 ⇒ 只能走 legacy：
#     System32\CodeIntegrity\SiPolicy.p7b，**重启才生效**（无法在线更新）。
#  2) New-CIPolicy 缺 -ScanPath 会做全盘 + 卷影扫描（实测耗时长、巨量警告、产出巨大 XML）
#     ⇒ 本模块缺 -ScanPath 直接拒绝执行。
#  3) New-CIPolicy -Level None -Deny -ScanPath <dir> 产出的 <FileRules/>、<Signers/> 都是空的
#     ⇒ 这种策略没有任何 allow 机制，本模块的安全门判为「禁止强制部署」（只允许审计）。
#  4) 官方 standalone deny 配方（MS Learn「Create App Control Deny Policy」Best Practices）：
#     以 %windir%\schemas\CodeIntegrity\ExamplePolicies\AllowAll.xml 为基底合并 deny 规则。
#     该基底含 Enabled:UMCI + <Allow FileName="*"> 且被两个签名场景引用（真 allow 机制）
#     ⇒ 本模块默认采用它；只有 AllowAll.xml 缺失时才退化成「无 allow 机制，仅可审计」的兜底基底。
#  5) Set-RuleOption 编号实测：3=Enabled:Audit Mode，6=Enabled:Unsigned System Integrity Policy，
#     9=Enabled:Advanced Boot Options Menu，10=Enabled:Boot Audit On Failure，
#     12=Required:Enforce Store Applications。
#  6) Merge-CIPolicy -Rules <New-CIPolicyRule 的对象> 在本机报类型转换错误 ⇒ 改为先用
#     New-CIPolicy -Rules 产 deny.xml，再 Merge-CIPolicy -PolicyPaths base,deny。
#  7) New-CIPolicyRule -FilePathRule <不存在的文件> 会抛异常 ⇒ 这类规则改走 XML 直写 <Deny> 元素
#     （元素形状与 ConfigCI 自己的输出一致，并统一用 ConvertFrom-CIPolicy 做 schema 校验）。
#  8) WDAC 默认对「用户可写目录里的 FilePath 规则」不生效（Runtime FilePath Rule Protection）
#     ⇒ 只告警，并在 README/结果里提示改用 hash 或 fileName。
#  9) 事件 ID（用于重启后验证）：3078/3080/3112=审计放行（would have been blocked），
#     3076/3077/3079/3081/3083/3104=实际拦截，3095-3116=策略刷新/激活。
#
# ---- 铁律 ----
#  * 默认只预览：写/部署动作没有 -Apply 时绝不落盘、绝不复制任何文件。
#  * 系统写入前必须先全量备份（var\backups\wdac-<stamp>\），并生成 revert.cmd（含 F8/WinRE 恢复步骤）。
#  * 任何删除只用 Move-LctToRecycleBin；本文件禁止出现 Remove-Item 之类的永久删除命令。
#  * 失败即拒绝（fail-closed）：无法证明安全就不允许强制部署。
#  * 不使用 Set-StrictMode；不弹窗、不交互；不使用 Write-Host（引擎 stdout 只能是最终 JSON）。
#  * 落盘文件一律 UTF-8 带 BOM；.cmd 一律纯 ASCII。
# =====================================================================

#region 依赖守卫（契约 §10.3 / §10.4）
# 规则：跨模块导入一律带 -Global；可用性以「模块是否装载成功」为准，不用 Get-Command 探测。
$script:LctLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
if ((Test-Path -LiteralPath $script:LctLoggingModule) -and (-not (Get-Module -Name Logging))) {
    Import-Module $script:LctLoggingModule -Force -Global -ErrorAction Stop
}
$script:LctLoaded = [bool](Get-Module -Name Logging)
#endregion

#region 常量
$script:LctWdacNs = 'urn:schemas-microsoft-com:sipolicy'
$script:LctWdacOptNum = @{
    AuditMode          = 3
    UnsignedSIP        = 6
    AdvancedBootMenu   = 9
    BootAuditOnFailure = 10
}
$script:LctWdacOptName = @{
    AuditMode              = 'Enabled:Audit Mode'
    UnsignedSIP            = 'Enabled:Unsigned System Integrity Policy'
    AdvancedBootMenu       = 'Enabled:Advanced Boot Options Menu'
    BootAuditOnFailure     = 'Enabled:Boot Audit On Failure'
    UMCI                   = 'Enabled:UMCI'
    RuntimePathProtection  = 'Disabled:Runtime FilePath Rule Protection'
}
$script:LctWdacEventIds = @{
    Policy = @(3095, 3096, 3097, 3099, 3100, 3101, 3102, 3103, 3105, 3108, 3109, 3110, 3116)
    Audit  = @(3078, 3080, 3082, 3112)
    Block  = @(3076, 3077, 3079, 3081, 3083, 3104)
}
$script:LctWdacConfirm = @{
    audit   = 'I-UNDERSTAND-AUDIT'
    enforce = 'I-UNDERSTAND-ENFORCE'
}
#endregion

#region 私有：路径
function Get-LctWdacBaseDir {
    # 不用 Get-LctVarDir（那会顺带建 logs/backups 目录）：只读 getter 也要保持「不落盘」的语义
    if (-not [string]::IsNullOrWhiteSpace($env:LCT_VAR_DIR)) { $base = $env:LCT_VAR_DIR }
    else { $base = Join-Path (Get-LctToolRoot) 'var' }
    return $base
}
function Get-LctWdacRootPath { return (Join-Path (Get-LctWdacBaseDir) 'wdac') }
function Get-LctWdacStagingPath { return (Join-Path (Get-LctWdacRootPath) 'staging') }
function Get-LctWdacRulesPath { return (Join-Path (Get-LctWdacRootPath) 'rules.json') }
function Get-LctWdacHistoryPath { return (Join-Path (Get-LctWdacRootPath) 'rules-history') }
function Get-LctWdacBackupRoot { return (Join-Path (Get-LctWdacBaseDir) 'backups') }
function Get-LctWdacSystemDir { return (Join-Path $env:SystemRoot 'System32\CodeIntegrity') }
function Get-LctWdacSystemPolicyPath { return (Join-Path (Get-LctWdacSystemDir) 'SiPolicy.p7b') }
function Get-LctWdacActivePolicyDir { return (Join-Path (Get-LctWdacSystemDir) 'CiPolicies\Active') }
function Get-LctWdacAllowAllPath { return (Join-Path $env:windir 'schemas\CodeIntegrity\ExamplePolicies\AllowAll.xml') }
function Ensure-LctDir {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    return $Path
}
#endregion

#region 私有：日志 / 结果 / 变更条目
function Write-LctWdacLog {
    param([string]$Verb = 'wdac', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}
function New-LctWdacChange {
    param([string]$Target = '', [string]$Name = '', [string]$Before = '', [string]$After = '', [string]$Note = '', [string]$Kind = 'note')
    return [pscustomobject][ordered]@{ kind = $Kind; target = $Target; name = $Name; before = $Before; after = $After; note = $Note }
}
function New-LctWdacStamp {
    $chars = '0123456789abcdef'.ToCharArray()
    $r = -join (1..6 | ForEach-Object { $chars[(Get-Random -Maximum 16)] })
    return ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $r)
}
#endregion

#region 私有：文件 / 哈希 / 文本落盘
function Get-LctWdacFileHash {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' }
}
function Get-LctWdacFileInfo {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ path = $Path; exists = $false; length = 0; sha256 = ''; lastWrite = '' }
    }
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $len = 0; $lw = ''
    if ($null -ne $i) { if ($i -isnot [array]) { $len = [long]$i.Length; $lw = $i.LastWriteTime.ToString('s') } }
    return [pscustomobject][ordered]@{ path = $Path; exists = $true; length = $len; sha256 = (Get-LctWdacFileHash -Path $Path); lastWrite = $lw }
}
function Write-LctWdacTextBom {
    # UTF-8 带 BOM（PS 5.1 才不会把中文按 GBK 解析）
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text = '')
    $enc = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $enc)
    return $Path
}
function Write-LctWdacTextAsciiCrlf {
    # .cmd 必须纯 ASCII + CRLF
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text = '')
    $t = $Text -replace "`r?`n", "`r`n"
    $enc = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($Path, $t, $enc)
    return $Path
}
function Get-LctWdacSha256Text {
    param([AllowEmptyString()][string]$Text = '')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}
function ConvertTo-LctWdacJson {
    param($Object, [int]$Depth = 10)
    return [string]($Object | ConvertTo-Json -Depth $Depth)
}
#endregion

#region 私有：自管规则库（var\wdac\rules.json）
function Get-LctWdacRuleStore {
    $p = Get-LctWdacRulesPath
    $rules = New-Object System.Collections.ArrayList
    $err = ''
    $exists = Test-Path -LiteralPath $p
    if ($exists) {
        try {
            $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($r in @($obj.rules)) {
                    if ($null -eq $r) { continue }
                    $null = $rules.Add([pscustomobject][ordered]@{
                            id     = [string]$r.id
                            kind   = [string]$r.kind
                            value  = [string]$r.value
                            reason = [string]$r.reason
                            added  = [string]$r.added
                        })
                }
            }
        } catch { $err = $_.Exception.Message }
    }
    return [pscustomobject][ordered]@{ path = $p; exists = $exists; rules = @($rules); error = $err }
}
function Save-LctWdacRuleStore {
    # 写前把旧版本快照到 rules-history\（本工具自管状态的回滚点）
    param($Rules, [string]$Verb = 'wdac.rules', [string]$Message = '')
    $p = Get-LctWdacRulesPath
    $null = Ensure-LctDir -Path (Get-LctWdacRootPath)
    if (Test-Path -LiteralPath $p) {
        $hist = Ensure-LctDir -Path (Get-LctWdacHistoryPath)
        $snap = Join-Path $hist ('rules-' + (New-LctId -Prefix 'before') + '.json')
        Copy-Item -LiteralPath $p -Destination $snap -Force
    }
    $payload = [ordered]@{
        version = 1
        updated = (Get-Date).ToString('s')
        count   = @($Rules).Count
        rules   = @($Rules)
    }
    Write-LctWdacTextBom -Path $p -Text (ConvertTo-LctWdacJson -Object $payload -Depth 10) | Out-Null
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "自管黑名单已更新（$(@($Rules).Count) 条）" }
    Write-LctWdacLog -Verb $Verb -Level 'change' -Message $Message -Data @{ path = $p; count = @($Rules).Count } | Out-Null
    return $p
}
function Get-LctWdacRuleId {
    param([string]$Kind, [string]$Value)
    # WDAC schema 的 RuleID 只允许 [A-Za-z0-9_] 且必须以 ID_ 开头。
    # 实测：形如 'r-path-abc123' 的 ID 会被 ConvertFrom-CIPolicy 以
    # "The 'RuleID' attribute is invalid ... according to its datatype" 拒绝。
    $h = Get-LctWdacSha256Text -Text ($Kind.ToLower() + '|' + $Value.ToLower())
    return ('ID_DENY_LCT_' + $Kind.ToUpper() + '_' + $h.Substring(0, 12).ToUpper())
}
function ConvertTo-LctWdacRuleValue {
    param([string]$Kind, [string]$Value)
    $v = ([string]$Value).Trim().Trim([char]34).Trim()
    switch ($Kind.ToLower()) {
        'path' { return ([Environment]::ExpandEnvironmentVariables($v)).Trim() }
        'filename' { return $v }
        'hash' {
            $parts = @(($v -replace '\s', '') -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToUpper() })
            return ($parts -join ',')
        }
        default { return $v }
    }
}
function Test-LctWdacCriticalPath {
    # 返回命中的原因（空串=未命中）。系统目录 / 驱动 / 启动关键组件。
    param([string]$Path)
    $raw = ([string]$Path).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $v = ([Environment]::ExpandEnvironmentVariables($raw)).Trim()
    $vl = $v.ToLower()
    if ($vl.StartsWith('\\?\')) { $vl = $vl.Substring(4) }
    $win = ([Environment]::ExpandEnvironmentVariables('%SystemRoot%')).Trim().TrimEnd('\').ToLower()
    if ($win -and ($vl -eq $win -or $vl.StartsWith($win + '\'))) { return "Windows 系统目录（$raw）" }
    foreach ($pfEnv in @('ProgramFiles', 'ProgramFiles(x86)')) {
        $pf = [Environment]::GetEnvironmentVariable($pfEnv)
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        $wa = ((Join-Path $pf 'WindowsApps')).ToLower().TrimEnd('\')
        if ($vl -eq $wa -or $vl.StartsWith($wa + '\')) { return "WindowsApps（$raw）" }
    }
    if ($vl -match '\.sys$') { return "驱动文件 .sys（$raw）" }
    if ($vl -match '\\(ntoskrnl|hal|ci|winload|winresume|bootmgfw)\.(exe|dll)$') { return "启动关键组件（$raw）" }
    return ''
}
function Test-LctWdacCriticalName {
    # 只按文件名判断（供 fileName 类规则 / path 类规则的末段名）
    param([string]$Name)
    $n = ([string]$Name).Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($n)) { return '' }
    $rxCritical = '^(ntoskrnl|hal|ci|winload|winresume|bootmgr|winlogon|csrss|smss|services|lsass|svchost|explorer|dwm|fontdrvhost|wininit|userinit|sihost|msmpeng|nissrv|mssense|sensecncproxy|securityhealthservice|avguard|avgnt|avgwdsvc|avira[a-z0-9]*)\.(exe|dll)$'
    if ($n -match $rxCritical) { return "系统/安全关键组件（$Name）" }
    return ''
}
function Test-LctWdacRiskyName {
    param([string]$Name)
    $n = ([string]$Name).Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($n)) { return '' }
    $rx = '^(cmd|powershell|pwsh|conhost|taskmgr|mmc|regedit|msconfig|notepad|control|rundll32|regsvr32|wscript|cscript|mshta|bitsadmin|certutil)\.exe$'
    if ($n -match $rx) { return "常用管理/脚本工具（$Name）" }
    return ''
}
function Test-LctWdacUserWritablePath {
    # WDAC 默认（Runtime FilePath Rule Protection 生效时）忽略用户可写目录里的 FilePath 规则
    param([string]$Path)
    $v = ([string]$Path).Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($v)) { return '' }
    if ($v.StartsWith('\\')) { return 'UNC/网络路径' }
    foreach ($e in @('%TEMP%', '%TMP%', '%USERPROFILE%', '%LOCALAPPDATA%', '%APPDATA%', '%ProgramData%', '%PUBLIC%')) {
        $x = ([Environment]::ExpandEnvironmentVariables($e)).Trim().TrimEnd('\').ToLower()
        if ([string]::IsNullOrWhiteSpace($x) -or $x.Contains('%')) { continue }
        if ($v -eq $x -or $v.StartsWith($x + '\')) { return $e }
    }
    if ($v -match '\\users\\') { return 'Users' }
    if ($v -match '\\programdata\\') { return 'ProgramData' }
    if ($v -match '\\\$recycle\.bin\\') { return 'RecycleBin' }
    return ''
}
function Test-LctWdacRuleInput {
    # 规则输入校验：返回 @{ ok; kind; value; errors; warnings }
    param([string]$Kind, [string]$Value)
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $k = ([string]$Kind).Trim().ToLower()
    if (@('path', 'filename', 'hash') -notcontains $k) {
        $null = $errors.Add("不支持的 -Kind：'$Kind'（只允许 path / fileName / hash）")
        return [pscustomobject][ordered]@{ ok = $false; kind = $k; value = ([string]$Value).Trim(); errors = @($errors); warnings = @($warnings) }
    }
    $raw = ([string]$Value).Trim().Trim([char]34).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $null = $errors.Add('-Value 不能为空')
        return [pscustomobject][ordered]@{ ok = $false; kind = $k; value = ''; errors = @($errors); warnings = @($warnings) }
    }
    $v = ConvertTo-LctWdacRuleValue -Kind $k -Value $raw
    if ($k -eq 'path') {
        if ($v -notmatch '^([A-Za-z]:\\|\\\\)') { $null = $errors.Add("path 类必须是完整路径（如 C:\Tools\evil.exe）或 UNC 路径，收到：'$v'") }
        if ($v -match '^[A-Za-z]:\\$') { $null = $errors.Add("拒绝把盘根目录作为 deny 目标：'$v'（FilePath 规则只接受文件）") }
        elseif (Test-Path -LiteralPath $v -PathType Container) { $null = $errors.Add("目标是目录而不是文件：'$v'（FilePath deny 规则只接受文件）") }
        elseif (-not (Test-Path -LiteralPath $v)) { $null = $warnings.Add("目标文件当前不存在：'$v'（策略仍会写入该路径规则，但对不存在的文件无实际拦截效果）") }
        $loc = Test-LctWdacCriticalPath -Path $v
        if ($loc) {
            $null = $errors.Add("拒绝：deny 规则命中系统关键位置（$loc）。拦截系统组件/驱动会导致无法启动；如确需拦截此处的恶意文件，请改用 hash 规则（不受路径门禁限制）。")
        }
        $nm = Test-LctWdacCriticalName -Name ([IO.Path]::GetFileName($v))
        if ($nm) { $null = $warnings.Add("注意：规则目标是关键组件名（$nm）。若该文件确实是系统组件，拦截它会造成系统不稳定。") }
        $rk = Test-LctWdacRiskyName -Name ([IO.Path]::GetFileName($v))
        if ($rk) { $null = $warnings.Add("注意：目标是$rk，拦截后这些工具可能无法启动。") }
    }
    elseif ($k -eq 'filename') {
        if ($v -match '[\\/:]') { $null = $errors.Add("fileName 类只接受纯文件名，不能含路径分隔符：'$v'（按完整路径拦截请用 path 类）") }
        if ($v -match '^\*$' -or $v -match '^\*\.\*$') { $null = $errors.Add("拒绝：fileName 为全通配（$v）会拦截所有程序。") }
        elseif ($v -match '^\*\.[A-Za-z0-9]+$') { $null = $errors.Add("拒绝：'$v' 会拦截该扩展名的全部程序（含系统与安全软件），风险过高；请写明具体文件名或改用 hash。") }
        elseif ($v -match '[*?]') { $null = $warnings.Add("含通配符的 fileName 规则面较宽：'$v'（建议改用具体文件名或 hash）") }
        if ($v -match '\.sys$') { $null = $errors.Add("拒绝：deny 规则命中驱动（.sys）：'$v'") }
        $nm = Test-LctWdacCriticalName -Name $v
        if ($nm) { $null = $errors.Add("拒绝：fileName 命中系统/安全关键组件（$nm）——按名字拦截会波及全系统。如确需拦截，请改用 hash 规则或具体 path。") }
        $rk = Test-LctWdacRiskyName -Name $v
        if ($rk) { $null = $warnings.Add("注意：目标是$rk，按名字拦截会让这些工具全局无法启动。") }
    }
    else {
        foreach ($h in @($v -split ',')) {
            if ([string]::IsNullOrWhiteSpace($h)) { continue }
            if ($h -notmatch '^[0-9A-F]+$') { $null = $errors.Add("hash 必须是十六进制字符串：'$h'") }
            elseif (@(32, 40, 64) -notcontains $h.Length) { $null = $errors.Add("hash 长度必须是 32/40/64 位十六进制（MD5/SHA1/SHA256），收到长度 $($h.Length)：'$h'") }
            elseif ($h.Length -eq 32) { $null = $warnings.Add("MD5（32 位）哈希强度低且 WDAC 较少使用，建议改用 SHA256（64 位）：'$h'") }
        }
        if ($v -match ',') { $null = $warnings.Add("同一规则含多个哈希：WDAC 按「任一命中即拒绝」处理。") }
    }
    return [pscustomobject][ordered]@{ ok = ($errors.Count -eq 0); kind = $k; value = $v; errors = @($errors); warnings = @($warnings) }
}
#endregion

#region 私有：策略 XML 分析（安全门的数据来源）
function Get-LctWdacPolicyAnalysis {
    param([Parameter(Mandatory)][string]$XmlPath)
    $a = [ordered]@{
        xmlPath                    = $XmlPath
        exists                     = $false
        length                     = 0
        sha256                     = ''
        parseError                 = ''
        mode                       = 'unknown'
        options                    = @()
        counts                     = [pscustomobject][ordered]@{ fileRules = 0; denyRules = 0; allowRules = 0; signers = 0; allowRefs = 0; denyRefs = 0 }
        denyRules                  = @()
        hasAllowMechanism          = $false
        allowMechanismText         = ''
        hasAuditMode               = $false
        hasAdvancedBootOptionsMenu = $false
        hasBootAuditOnFailure      = $false
        hasUnsignedSIP             = $false
        hasUMCI                    = $false
        runtimePathProtectionOn    = $true
        criticalHits               = @()
        criticalNameHits           = @()
        userWritableHits           = @()
        auditBlockers              = @()
        enforceBlockers            = @()
        canDeployAudit             = $false
        canDeployEnforce           = $false
    }
    if ([string]::IsNullOrWhiteSpace($XmlPath) -or -not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
        $a.auditBlockers = @("策略 XML 不存在：$XmlPath")
        $a.enforceBlockers = @("策略 XML 不存在：$XmlPath")
        return [pscustomobject]$a
    }
    $a.exists = $true
    $fi = Get-LctWdacFileInfo -Path $XmlPath
    $a.length = $fi.length
    $a.sha256 = $fi.sha256
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.Load($XmlPath) } catch {
        $a.parseError = $_.Exception.Message
        $a.auditBlockers = @("策略 XML 解析失败：$($a.parseError)")
        $a.enforceBlockers = @($a.auditBlockers)
        return [pscustomobject]$a
    }

    $opts = New-Object System.Collections.ArrayList
    foreach ($n in @($doc.SelectNodes("//*[local-name()='Rules']/*[local-name()='Rule']/*[local-name()='Option']"))) {
        $null = $opts.Add(([string]$n.InnerText).Trim())
    }
    $a.options = @($opts)
    $a.hasAuditMode = ($a.options -contains $script:LctWdacOptName.AuditMode)
    $a.hasAdvancedBootOptionsMenu = ($a.options -contains $script:LctWdacOptName.AdvancedBootMenu)
    $a.hasBootAuditOnFailure = ($a.options -contains $script:LctWdacOptName.BootAuditOnFailure)
    $a.hasUnsignedSIP = ($a.options -contains $script:LctWdacOptName.UnsignedSIP)
    $a.hasUMCI = ($a.options -contains $script:LctWdacOptName.UMCI)
    $a.runtimePathProtectionOn = -not ($a.options -contains $script:LctWdacOptName.RuntimePathProtection)
    $a.mode = if ($a.hasAuditMode) { 'audit' } else { 'enforce' }

    $denyNodes = @($doc.SelectNodes("//*[local-name()='FileRules']/*[local-name()='Deny']"))
    $allowNodes = @($doc.SelectNodes("//*[local-name()='FileRules']/*[local-name()='Allow' or local-name()='FileAttrib' or local-name()='FileName' or local-name()='FilePath']"))
    $signerNodes = @($doc.SelectNodes("//*[local-name()='Signers']/*"))
    $refNodes = @($doc.SelectNodes("//*[local-name()='FileRulesRef']/*[local-name()='FileRuleRef']"))

    $allowIds = @{}
    foreach ($n in $allowNodes) { $id = [string]$n.GetAttribute('ID'); if ($id) { $allowIds[$id] = $true } }
    $denyIds = @{}
    foreach ($n in $denyNodes) { $id = [string]$n.GetAttribute('ID'); if ($id) { $denyIds[$id] = $true } }
    $allowRefs = 0; $denyRefs = 0
    foreach ($r in $refNodes) {
        $rid = [string]$r.GetAttribute('RuleID')
        if ($allowIds.ContainsKey($rid)) { $allowRefs++ }
        elseif ($denyIds.ContainsKey($rid)) { $denyRefs++ }
    }
    $a.counts = [pscustomobject][ordered]@{
        fileRules  = @($doc.SelectNodes("//*[local-name()='FileRules']/*")).Count
        denyRules  = $denyNodes.Count
        allowRules = $allowNodes.Count
        signers    = $signerNodes.Count
        allowRefs  = $allowRefs
        denyRefs   = $denyRefs
    }

    $recs = New-Object System.Collections.ArrayList
    $crit = New-Object System.Collections.ArrayList
    $critWarn = New-Object System.Collections.ArrayList
    $uw = New-Object System.Collections.ArrayList
    foreach ($d in $denyNodes) {
        $attr = ''; $val = ''
        foreach ($cand in @('FilePath', 'FileName', 'Hash', 'PackageFamilyName', 'InternalName', 'FileDescription', 'ProductName')) {
            if ($d.HasAttribute($cand)) { $attr = $cand; $val = [string]$d.GetAttribute($cand); break }
        }
        $rid = [string]$d.GetAttribute('ID')
        $null = $recs.Add([pscustomobject][ordered]@{ id = $rid; attribute = $attr; value = $val })
        if ($attr -eq 'FilePath') {
            $loc = Test-LctWdacCriticalPath -Path $val
            if ($loc) { $null = $crit.Add([pscustomobject][ordered]@{ ruleId = $rid; attribute = $attr; value = $val; reason = $loc; severity = 'error' }) }
            $nm = Test-LctWdacCriticalName -Name ([IO.Path]::GetFileName($val))
            if ($nm) { $null = $critWarn.Add([pscustomobject][ordered]@{ ruleId = $rid; attribute = $attr; value = $val; reason = $nm; severity = 'warn' }) }
            if ($a.runtimePathProtectionOn) {
                $why = Test-LctWdacUserWritablePath -Path $val
                if ($why) { $null = $uw.Add([pscustomobject][ordered]@{ ruleId = $rid; value = $val; reason = "位于用户可写位置（$why）" }) }
            }
        }
        elseif ($attr -eq 'FileName') {
            $nm = Test-LctWdacCriticalName -Name $val
            if ($nm) { $null = $crit.Add([pscustomobject][ordered]@{ ruleId = $rid; attribute = $attr; value = $val; reason = $nm; severity = 'error' }) }
            if ($val -match '\.sys$') { $null = $crit.Add([pscustomobject][ordered]@{ ruleId = $rid; attribute = $attr; value = $val; reason = '驱动文件 .sys'; severity = 'error' }) }
            elseif ($val -match '[*?]') { $null = $critWarn.Add([pscustomobject][ordered]@{ ruleId = $rid; attribute = $attr; value = $val; reason = '含通配符的 fileName 规则面较宽'; severity = 'warn' }) }
        }
    }
    $a.denyRules = @($recs)
    $a.criticalHits = @($crit)
    $a.criticalNameHits = @($critWarn)
    $a.userWritableHits = @($uw)

    if ($allowRefs -gt 0) { $a.hasAllowMechanism = $true; $a.allowMechanismText = "有：$allowRefs 条 allow 文件规则被签名场景引用（Allow/FileAttrib 规则共 $($allowNodes.Count) 条）" }
    elseif ($signerNodes.Count -gt 0) { $a.hasAllowMechanism = $true; $a.allowMechanismText = "有：<Signers> 含 $($signerNodes.Count) 个签名者" }
    else { $a.hasAllowMechanism = $false; $a.allowMechanismText = '无：<Signers> 为空，且没有任何 allow 文件规则被签名场景引用' }

    $defects = New-Object System.Collections.ArrayList
    if ($denyNodes.Count -eq 0) { $null = $defects.Add('规则条数为 0：<FileRules> 里没有任何 deny 规则，部署无意义且徒增风险') }
    foreach ($h in @($crit)) { $null = $defects.Add("deny 规则命中系统关键位置：$($h.reason)") }

    $auditB = New-Object System.Collections.ArrayList
    foreach ($d in @($defects)) { $null = $auditB.Add($d) }
    if ($a.mode -ne 'audit') { $null = $auditB.Add('该策略不含 Enabled:Audit Mode（是强制模式），不能用 audit 模式部署') }

    $enfB = New-Object System.Collections.ArrayList
    foreach ($d in @($defects)) { $null = $enfB.Add($d) }
    if ($a.mode -ne 'enforce') { $null = $enfB.Add('该策略含 Enabled:Audit Mode（审计模式）：要用 enforce 部署，请先以 -Mode enforce 重新构建策略') }
    if (-not $a.hasAllowMechanism) { $null = $enfB.Add('策略没有任何 allow 机制（Signers 与 allow 文件规则引用都为空）：无法证明其余程序会被放行 ⇒ 禁止强制部署（只允许 audit）') }
    if (-not $a.hasAdvancedBootOptionsMenu) { $null = $enfB.Add('缺少 Enabled:Advanced Boot Options Menu（坏策略救命绳）⇒ 拒绝强制部署') }
    if (-not $a.hasBootAuditOnFailure) { $null = $enfB.Add('缺少 Enabled:Boot Audit On Failure（坏策略救命绳）⇒ 拒绝强制部署') }

    $a.auditBlockers = @($auditB)
    $a.enforceBlockers = @($enfB)
    $a.canDeployAudit = ($auditB.Count -eq 0)
    $a.canDeployEnforce = ($enfB.Count -eq 0)
    return [pscustomobject]$a
}
#endregion

#region 私有：ConfigCI 调用封装 / XML 直写 deny 规则
function Invoke-LctWdacTool {
    # 捕获所有输出流（含 Write-Host 走的信息流 6），保证引擎 stdout 只出现最终 JSON
    param([Parameter(Mandatory)][scriptblock]$Action)
    $lines = New-Object System.Collections.ArrayList
    $err = ''
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Action *>&1 | ForEach-Object { $null = $lines.Add([string]$_) }
    } catch {
        $err = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return [pscustomobject][ordered]@{ ok = [string]::IsNullOrEmpty($err); error = $err; output = @($lines) }
}
function Add-LctWdacDenyRuleToXml {
    # 把 deny 规则直写进策略 XML（<Deny> + 用户态签名场景的 <FileRuleRef>），与 ConfigCI 自己的输出同形状。
    # 完成后统一由 ConvertFrom-CIPolicy 做 schema 校验。
    param([Parameter(Mandatory)][string]$XmlPath, [Parameter(Mandatory)]$Rules)
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($XmlPath)
    $ns = $script:LctWdacNs
    $added = 0
    $fr = $doc.DocumentElement.SelectSingleNode("//*[local-name()='FileRules']")
    if ($null -eq $fr) {
        $fr = $doc.CreateElement('FileRules', $ns)
        $signers = $doc.DocumentElement.SelectSingleNode("//*[local-name()='Signers']")
        if ($null -ne $signers) { $null = $doc.DocumentElement.InsertBefore($fr, $signers) }
        else { $null = $doc.DocumentElement.AppendChild($fr) }
    }
    $scen = $doc.DocumentElement.SelectSingleNode("//*[local-name()='SigningScenario' and @Value='12']")
    if ($null -eq $scen) {
        $scens = $doc.DocumentElement.SelectSingleNode("//*[local-name()='SigningScenarios']")
        if ($null -eq $scens) { $scens = $doc.DocumentElement.AppendChild($doc.CreateElement('SigningScenarios', $ns)) }
        $scen = $doc.CreateElement('SigningScenario', $ns)
        $scen.SetAttribute('Value', '12')
        $scen.SetAttribute('ID', 'ID_SIGNINGSCENARIO_WINDOWS')
        $null = $scens.AppendChild($scen)
    }
    $ps = $scen.SelectSingleNode("*[local-name()='ProductSigners']")
    if ($null -eq $ps) { $ps = $scen.AppendChild($doc.CreateElement('ProductSigners', $ns)) }
    $refs = $ps.SelectSingleNode("*[local-name()='FileRulesRef']")
    if ($null -eq $refs) { $refs = $ps.AppendChild($doc.CreateElement('FileRulesRef', $ns)) }
    # 已存在的 deny（同属性 + 同值）不重复写
    $existing = @{}
    foreach ($d in @($doc.SelectNodes("//*[local-name()='FileRules']/*[local-name()='Deny']"))) {
        foreach ($cand in @('FilePath', 'FileName', 'Hash')) {
            if ($d.HasAttribute($cand)) { $existing[($cand + '|' + ([string]$d.GetAttribute($cand)).ToLower())] = $true; break }
        }
    }
    foreach ($r in @($Rules)) {
        if ($null -eq $r) { continue }
        $kind = ([string]$r.kind).ToLower()
        $attr = switch ($kind) { 'path' { 'FilePath' } 'filename' { 'FileName' } 'hash' { 'Hash' } default { '' } }
        if ([string]::IsNullOrEmpty($attr)) { continue }
        $val = [string]$r.value
        if ($existing.ContainsKey(($attr + '|' + $val.ToLower()))) { continue }
        $id = [string]$r.id
        if ([string]::IsNullOrWhiteSpace($id) -or ($id -notmatch '^ID_[A-Za-z0-9_]+$')) { $id = Get-LctWdacRuleId -Kind $kind -Value $val }
        $node = $doc.CreateElement('Deny', $ns)
        $node.SetAttribute('ID', $id)
        $friendly = 'LCT deny ' + $kind + ': ' + $val
        if (-not [string]::IsNullOrWhiteSpace([string]$r.reason)) { $friendly = $friendly + ' - ' + ([string]$r.reason) }
        if ($friendly.Length -gt 200) { $friendly = $friendly.Substring(0, 200) }
        $node.SetAttribute('FriendlyName', $friendly)
        $node.SetAttribute($attr, $val)
        $null = $fr.AppendChild($node)
        $ref = $doc.CreateElement('FileRuleRef', $ns)
        $ref.SetAttribute('RuleID', $id)
        $null = $refs.AppendChild($ref)
        $existing[($attr + '|' + $val.ToLower())] = $true
        $added++
    }
    $doc.Save($XmlPath)
    return $added
}
#endregion

#region 私有：文档模板
function Get-LctWdacStagingReadme {
    param($Data)
    $tpl = @'
LocalConfigTool - WDAC 黑名单策略（staging 产物说明）
================================================================
生成时间：{{TIME}}
模式：{{MODE}}   （audit = 只记录不拦截；enforce = 强制拦截）
扫描目录（-ScanPath）：{{SCAN}}
策略基底：{{BASE}}
deny 规则条数：{{RULECOUNT}}（官方工具链序列化 {{OFFICIAL}} 条 / XML 直写注入 {{DOM}} 条）
allow 机制：{{ALLOWMECH}}
策略 XML：{{XML}}
  SHA256 {{XMLSHA}}
二进制策略：{{CIP}}
  SHA256 {{CIPSHA}}
规则快照：{{RULES}}
策略 ID：{{POLICYID}}
规则选项：{{OPTIONS}}

【部署顺序（审计先落地 → 重启验证 → 再转强制）】
1) 审计部署（需管理员；UI 会要求手输 I-UNDERSTAND-AUDIT）
     Engine.ps1 -Verb wdac.deploy -Apply -ArgsFile <json>
       json: { "xmlPath": "{{XML}}", "mode": "audit", "confirmText": "I-UNDERSTAND-AUDIT" }
     等价直接调用：
       Deploy-LctWdacPolicy -XmlPath "{{XML}}" -Mode audit -ConfirmText 'I-UNDERSTAND-AUDIT' -Apply
2) 重启。本机 CiTool.exe 不存在，legacy SiPolicy.p7b 只有重启才加载。
3) 重启后验证：Engine.ps1 -Verb wdac.verify -Out json
     判定为「可安全转强制」再进第 4 步；「尚不明确 / 危险」都不要转强制。
4) 强制部署：先重新构建 enforce 策略
     New-LctWdacPolicy -Mode enforce -ScanPath "{{SCAN}}" -Apply
   再以 -Mode enforce -ConfirmText 'I-UNDERSTAND-ENFORCE' 部署（安全门会再次校验）。

【回滚】
  · 部署时会在 var\backups\wdac-<stamp>\ 下生成 revert.cmd（管理员运行，内含逐步说明）
  · 或调用：Restore-LctWdacPolicy -Stamp <stamp> -Apply（然后重启）
  · 开机失败时：连按 F8 → 高级启动选项（禁用驱动程序强制签名 / 最近一次的正确配置）；
    或用 WinRE 离线把 %SystemRoot%\System32\CodeIntegrity\SiPolicy.p7b 改名后重启。

【已知限制（务必先读）】
  1) 「用户态黑名单」的语义无法在重启前证明：策略只有重启加载后才生效。本工具只能保证产物与配置正确，
     不能保证拦截行为——必须重启后用 wdac.verify 读审计日志（3078/3080/3112=审计放行，3076/3077=实际拦截）。
  2) 没有任何 allow 机制的策略（例如只用 New-CIPolicy -Level None -Deny 生成的空策略）会被安全门
     禁止强制部署，只允许审计。
  3) WDAC 默认忽略「用户可写目录里的 FilePath 规则」（Runtime FilePath Rule Protection）
     ⇒ Desktop / Temp / Users 等位置的拦截建议改用 hash 或 fileName 规则。
  4) 未签名策略（Enabled:Unsigned System Integrity Policy）只在 Secure Boot 关闭（本机 False）时可加载。
  5) 在线更新策略（CiTool --update-policy）在本机不可用；任何变更都需要重启。
'@
    $t = $tpl
    $t = $t.Replace('{{TIME}}', [string]$Data.time)
    $t = $t.Replace('{{MODE}}', [string]$Data.mode)
    $t = $t.Replace('{{SCAN}}', [string]$Data.scanPath)
    $t = $t.Replace('{{BASE}}', [string]$Data.baseSource)
    $t = $t.Replace('{{RULECOUNT}}', [string]$Data.ruleCount)
    $t = $t.Replace('{{OFFICIAL}}', [string]$Data.officialCount)
    $t = $t.Replace('{{DOM}}', [string]$Data.domCount)
    $t = $t.Replace('{{ALLOWMECH}}', [string]$Data.allowMechanismText)
    $t = $t.Replace('{{XML}}', [string]$Data.xmlPath)
    $t = $t.Replace('{{XMLSHA}}', [string]$Data.xmlSha)
    $t = $t.Replace('{{CIP}}', [string]$Data.cipPath)
    $t = $t.Replace('{{CIPSHA}}', [string]$Data.cipSha)
    $t = $t.Replace('{{RULES}}', [string]$Data.rulesSnapshot)
    $t = $t.Replace('{{POLICYID}}', [string]$Data.policyId)
    $t = $t.Replace('{{OPTIONS}}', [string]$Data.options)
    return $t
}
function Get-LctWdacBackupReadme {
    param($Data)
    $tpl = @'
LocalConfigTool - WDAC 部署备份 / 回滚说明
================================================================
备份戳（stamp）：{{STAMP}}
备份时间：{{TIME}}
部署模式：{{MODE}}
策略来源：{{XML}}
  SHA256 {{XMLSHA}}
实际部署文件：{{TARGET}}
  SHA256 {{TARGETSHA}}
部署前的系统策略：{{PREVSIP}}
CiPolicies\Active 备份：{{ACTIVE}}
本机 CI 强制状态（部署时）：{{CI}}

【回滚步骤（任选其一）】
A. 图形方式：右键本目录下的 revert.cmd → 以管理员身份运行 → 按提示输入 YES → 重启。
B. 命令行（管理员 PowerShell）：
     Restore-LctWdacPolicy -Stamp "{{STAMP}}" -Apply
   然后重启。
C. 手动：把本目录 backup\SiPolicy.p7b 复制回
     %SystemRoot%\System32\CodeIntegrity\SiPolicy.p7b
   （若部署前本机没有该文件，则把部署后的那个文件改名或删除，使其不再被加载），然后重启。

【改完必须重启】本机 CiTool.exe 不存在，legacy SiPolicy.p7b 只有重启后才加载/卸载。

【开机失败时的离线恢复】
1) 开机过程中连按 F8，进入「高级启动选项」：
     - 选择「禁用驱动程序强制签名」或「最近一次的正确配置」进入系统，再执行上面的回滚。
2) 若进不去系统，用 Windows 安装介质或恢复分区启动到 WinRE → 疑难解答 → 命令提示符：
     注意 WinRE 下盘符可能不同（例如 D: 才是系统盘）：
       ren D:\Windows\System32\CodeIntegrity\SiPolicy.p7b SiPolicy.p7b.disabled
     然后重启。
3) 也可以先打开 F8 启动菜单以便下次更容易进入恢复界面（管理员命令行执行一次即可）：
     bcdedit /set {bootmgr} displaybootmenu yes
     bcdedit /set {current} bootmenupolicy legacy

【策略选项（救命绳）】
{{OPTIONS}}

【已知限制】
1) 「用户态黑名单」语义无法在重启前证明：只能重启后用 wdac.verify 读 CodeIntegrity 审计日志确认。
2) 未签名策略只在 Secure Boot 关闭时可加载（本机 Secure Boot={{SECUREBOOT}}）。
'@
    $t = $tpl
    $t = $t.Replace('{{STAMP}}', [string]$Data.stamp)
    $t = $t.Replace('{{TIME}}', [string]$Data.time)
    $t = $t.Replace('{{MODE}}', [string]$Data.mode)
    $t = $t.Replace('{{XML}}', [string]$Data.xmlPath)
    $t = $t.Replace('{{XMLSHA}}', [string]$Data.xmlSha)
    $t = $t.Replace('{{TARGET}}', [string]$Data.target)
    $t = $t.Replace('{{TARGETSHA}}', [string]$Data.targetSha)
    $t = $t.Replace('{{PREVSIP}}', [string]$Data.previousSiPolicy)
    $t = $t.Replace('{{ACTIVE}}', [string]$Data.activeBackup)
    $t = $t.Replace('{{CI}}', [string]$Data.ciText)
    $t = $t.Replace('{{OPTIONS}}', [string]$Data.options)
    $t = $t.Replace('{{SECUREBOOT}}', [string]$Data.secureBoot)
    return $t
}
function Get-LctWdacRevertCmd {
    # 纯 ASCII（cmd.exe 按 OEM 代码页读取；中文一律放 README.txt）
    param($Data)
    $tpl = @'
@echo off
rem ==================================================================
rem  WDAC revert helper  -  generated by LocalConfigTool (wdac.deploy)
rem  deploy time : {{TIME}}
rem  mode        : {{MODE}}
rem  This file lives inside the backup folder, so %~dp0 is that folder.
rem  Usage: right-click -> Run as administrator, then REBOOT.
rem ==================================================================
setlocal EnableExtensions
set "CI=%SystemRoot%\System32\CodeIntegrity"
set "HERE=%~dp0"
set "PREV=%HERE%backup\SiPolicy.p7b"
set "ABSENT=%HERE%backup\SiPolicy.p7b.absent"
echo This will revert the WDAC policy deployed by LocalConfigTool.
echo   mode          : {{MODE}}
echo   policy target : %CI%\SiPolicy.p7b
echo   backup folder : %HERE%
echo.
set /p CONFIRM=Type YES and press Enter to continue:
if /I not "%CONFIRM%"=="YES" goto :cancel

if exist "%PREV%" (
  echo [revert] restoring the previous SiPolicy.p7b from the backup ...
  if exist "%CI%\SiPolicy.p7b" attrib -r -s -h "%CI%\SiPolicy.p7b" 2>nul
  copy /y "%PREV%" "%CI%\SiPolicy.p7b"
  goto :done
)
if exist "%ABSENT%" (
  echo [revert] no policy file existed before deployment - disabling the deployed file ...
  if exist "%CI%\SiPolicy.p7b" attrib -r -s -h "%CI%\SiPolicy.p7b" 2>nul
  if exist "%CI%\SiPolicy.p7b" move /y "%CI%\SiPolicy.p7b" "%CI%\SiPolicy.p7b.disabled-{{STAMP}}"
  goto :done
)
echo [revert] WARNING: no backup marker found - nothing to do.
goto :done

:done
echo.
echo [revert] done. A REBOOT is required for the change to take effect.
echo.
echo Recovery steps if Windows does not boot (offline):
echo   1) Press F8 repeatedly while booting to open Advanced Boot Options,
echo      then pick "Disable Driver Signature Enforcement" or "Last Known Good".
echo   2) Or boot Windows RE (install media / recovery partition) -> Troubleshoot
echo      -> Command Prompt. Drive letters may differ there (system drive may be D:):
echo        ren D:\Windows\System32\CodeIntegrity\SiPolicy.p7b SiPolicy.p7b.disabled
echo   3) Optional boot menu aids (run once in an elevated shell):
echo        bcdedit /set {bootmgr} displaybootmenu yes
echo        bcdedit /set {current} bootmenupolicy legacy
echo.
pause
exit /b 0

:cancel
echo [revert] cancelled - nothing changed.
exit /b 1
'@
    $t = $tpl
    $t = $t.Replace('{{TIME}}', [string]$Data.time)
    $t = $t.Replace('{{MODE}}', [string]$Data.mode)
    $t = $t.Replace('{{STAMP}}', [string]$Data.stamp)
    return $t
}
#endregion

#region 公开：只读状态 / 规则清单
function Get-LctWdacStatus {
    $notes = New-Object System.Collections.ArrayList
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }

    $sb = 'Unknown'
    try { $sb = [string](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { $null = $notes.Add('Secure Boot 状态无法读取（非 UEFI 或权限不足）：' + $_.Exception.Message) }

    $ciRaw = -1; $ciText = 'Unknown'; $vbsRaw = -1
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        $ciRaw = [int]$dg.CodeIntegrityPolicyEnforcementStatus
        $vbsRaw = [int]$dg.VirtualizationBasedSecurityStatus
        $ciText = switch ($ciRaw) { 0 { 'Off' } 1 { 'Audit' } 2 { 'Enforced' } default { 'Unknown' } }
    } catch { $null = $notes.Add('Win32_DeviceGuard 不可用：' + $_.Exception.Message) }
    $vbsText = 'Unknown'
    switch ($vbsRaw) { 0 { $vbsText = 'Off' } 1 { $vbsText = 'EnabledNotRunning' } 2 { $vbsText = 'Running' } }

    $sysDir = Get-LctWdacSystemDir
    $si = Get-LctWdacFileInfo -Path (Get-LctWdacSystemPolicyPath)
    $active = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-LctWdacActivePolicyDir) -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $null = $active.Add([pscustomobject][ordered]@{
                name   = $f.Name
                path   = $f.FullName
                length = [long]$f.Length
                sha256 = (Get-LctWdacFileHash -Path $f.FullName)
            })
    }
    $drv = Get-LctWdacFileInfo -Path (Join-Path $sysDir 'driversipolicy.p7b')
    $vbs = Get-LctWdacFileInfo -Path (Join-Path $sysDir 'VbsSiPolicy.p7b')

    $stagingXml = Join-Path (Get-LctWdacStagingPath) 'policy.xml'
    $stagingCip = Join-Path (Get-LctWdacStagingPath) 'policy.cip'
    $staging = Get-LctWdacFileInfo -Path $stagingXml
    $store = Get-LctWdacRuleStore
    if ($store.error) { $null = $notes.Add('rules.json 解析失败：' + $store.error) }

    $restart = $false; $restartReason = ''
    if ($si.exists -and $ciRaw -eq 0) {
        $restart = $true
        $restartReason = 'System32\CodeIntegrity\SiPolicy.p7b 已存在，但 CI 强制状态仍为 Off ⇒ 策略尚未生效，需重启'
    } elseif ($si.exists -and $staging.exists -and ($si.sha256 -ne (Get-LctWdacFileHash -Path $stagingCip))) {
        $restartReason = '已部署策略与 staging 产物的二进制哈希不一致（可能是部署后重新构建过；请用 wdac.verify 复核）'
    }
    if (-not (Test-Path -LiteralPath $sysDir)) { $null = $notes.Add('未找到 CodeIntegrity 目录：' + $sysDir) }

    return [pscustomobject][ordered]@{
        elevated                = $elevated
        secureBoot              = $sb
        ciEnforcement           = $ciRaw
        ciEnforcementText       = $ciText
        ciEnforced              = ($ciRaw -eq 2)
        ciToolPresent           = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\CiTool.exe'))
        configCiPresent         = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\ConfigCI\ConfigCI.psd1'))
        systemDir               = $sysDir
        systemPolicyPath        = $si.path
        systemPolicyExists      = $si.exists
        systemPolicyLength      = $si.length
        systemPolicySha256      = $si.sha256
        systemPolicyLastWrite   = $si.lastWrite
        activePolicies          = @($active)
        driverPolicy            = $drv
        vbsPolicy               = $vbs
        vbsStatus               = $vbsRaw
        vbsStatusText           = $vbsText
        stagingDir              = (Get-LctWdacStagingPath)
        stagingPolicyPath       = $staging.path
        stagingPolicyExists     = $staging.exists
        stagingPolicySha256     = $staging.sha256
        stagingCipPath          = $stagingCip
        rulesPath               = $store.path
        rulesCount              = @($store.rules).Count
        restartRequired         = $restart
        restartRequiredReason   = $restartReason
        notes                   = @($notes)
    }
}

function Get-LctWdacRules {
    # getter：返回裸数据（引擎侧用 @(...) 包成数组 → data 即规则数组）
    $store = Get-LctWdacRuleStore
    if ($store.error) { Write-LctWdacLog -Verb 'wdac.rules.list' -Level 'warn' -Message 'rules.json 解析失败' -Data @{ error = $store.error } | Out-Null }
    return @($store.rules)
}
#endregion

#region 公开：规则增删
function Add-LctWdacRule {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Value,
        [string]$Reason = '',
        [switch]$Apply
    )
    $verb = 'wdac.rules.add'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $chk = Test-LctWdacRuleInput -Kind $Kind -Value $Value
    foreach ($e in @($chk.errors)) { $null = $errors.Add($e) }
    foreach ($w in @($chk.warnings)) { $null = $warnings.Add($w) }
    $store = Get-LctWdacRuleStore
    if ($store.error) { $null = $errors.Add('rules.json 解析失败（请先修复或删除该文件）：' + $store.error) }
    if ($errors.Count -gt 0) {
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; reason = $Reason; rulesPath = $store.path; totalCount = @($store.rules).Count
            })
    }
    $existing = $null
    foreach ($r in @($store.rules)) {
        if (([string]$r.kind).ToLower() -eq $chk.kind -and ([string]$r.value).ToLower() -eq $chk.value.ToLower()) { $existing = $r; break }
    }
    if ($null -ne $existing) {
        $null = $warnings.Add('该规则已存在，未做改动（幂等）。')
        $null = $changes.Add((New-LctWdacChange -Target $store.path -Name $chk.value -Before $chk.value -After $chk.value -Note '无变化（规则已存在）'))
        Write-LctWdacLog -Verb $verb -Level 'info' -Message '规则已存在，跳过' -Data @{ kind = $chk.kind; value = $chk.value } | Out-Null
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; reason = [string]$existing.reason; rule = $existing
                existedAlready = $true; rulesPath = $store.path; totalCount = @($store.rules).Count; applied = $false
            })
    }
    $rule = [pscustomobject][ordered]@{
        id     = (Get-LctWdacRuleId -Kind $chk.kind -Value $chk.value)
        kind   = $chk.kind
        value  = $chk.value
        reason = $Reason
        added  = (Get-Date).ToString('s')
    }
    if (-not $Apply) {
        $null = $warnings.Add('预览：未写入 rules.json。确认后请加 -Apply。')
        $null = $changes.Add((New-LctWdacChange -Target $store.path -Name $chk.value -Before '(不存在)' -After ('新增 ' + $chk.kind + ' 规则') -Note '预览'))
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; reason = $Reason; rule = $rule; existedAlready = $false
                rulesPath = $store.path; totalCount = (@($store.rules).Count + 1); applied = $false
            })
    }
    $rules = @($store.rules) + @($rule)
    $p = Save-LctWdacRuleStore -Rules $rules -Verb $verb -Message ("新增黑名单规则：" + $chk.kind + ' ' + $chk.value)
    $null = $changes.Add((New-LctWdacChange -Target $p -Name $chk.value -Before '(不存在)' -After ('新增 ' + $chk.kind + ' 规则') -Note ([string]$Reason)))
    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
            kind = $chk.kind; value = $chk.value; reason = $Reason; rule = $rule; existedAlready = $false
            rulesPath = $p; totalCount = @($rules).Count; applied = $true
        })
}

function Remove-LctWdacRule {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Value,
        [switch]$Apply
    )
    $verb = 'wdac.rules.remove'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $chk = Test-LctWdacRuleInput -Kind $Kind -Value $Value
    foreach ($e in @($chk.errors)) { $null = $errors.Add($e) }
    $store = Get-LctWdacRuleStore
    if ($store.error) { $null = $errors.Add('rules.json 解析失败（请先修复该文件）：' + $store.error) }
    if ($errors.Count -gt 0) {
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; removed = $null; rulesPath = $store.path; totalCount = @($store.rules).Count
            })
    }
    $hit = $null
    foreach ($r in @($store.rules)) {
        if (([string]$r.kind).ToLower() -eq $chk.kind -and ([string]$r.value).ToLower() -eq $chk.value.ToLower()) { $hit = $r; break }
    }
    if ($null -eq $hit) {
        $null = $warnings.Add('规则不存在，无需删除（幂等）。')
        $null = $changes.Add((New-LctWdacChange -Target $store.path -Name $chk.value -Before '(不存在)' -After '(不存在)' -Note '无变化'))
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; removed = $null; existed = $false; rulesPath = $store.path; totalCount = @($store.rules).Count; applied = $false
            })
    }
    if (-not $Apply) {
        $null = $warnings.Add('预览：未修改 rules.json。确认后请加 -Apply。')
        $null = $changes.Add((New-LctWdacChange -Target $store.path -Name $chk.value -Before ($chk.kind + ' 规则') -After '(移除)' -Note '预览'))
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                kind = $chk.kind; value = $chk.value; removed = $hit; existed = $true; rulesPath = $store.path
                totalCount = (@($store.rules).Count - 1); applied = $false
            })
    }
    $keep = New-Object System.Collections.ArrayList
    foreach ($r in @($store.rules)) {
        if (([string]$r.kind).ToLower() -eq $chk.kind -and ([string]$r.value).ToLower() -eq $chk.value.ToLower()) { continue }
        $null = $keep.Add($r)
    }
    $p = Save-LctWdacRuleStore -Rules @($keep) -Verb $verb -Message ("删除黑名单规则：" + $chk.kind + ' ' + $chk.value)
    $null = $changes.Add((New-LctWdacChange -Target $p -Name $chk.value -Before ($chk.kind + ' 规则') -After '(移除)' -Note ([string]$hit.reason)))
    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
            kind = $chk.kind; value = $chk.value; removed = $hit; existed = $true; rulesPath = $p; totalCount = @($keep).Count; applied = $true
        })
}
#endregion

#region 公开：构建策略（默认 audit；-ScanPath 必填）
function New-LctWdacPolicy {
    param(
        [ValidateSet('audit', 'enforce')][string]$Mode = 'audit',
        [string]$ScanPath = '',
        [switch]$Apply
    )
    $verb = 'wdac.policy.build'
    $mode = ([string]$Mode).ToLower()
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $staging = Get-LctWdacStagingPath
    $xmlPath = Join-Path $staging 'policy.xml'
    $cipPath = Join-Path $staging 'policy.cip'
    $readmePath = Join-Path $staging 'README.txt'
    $rulesSnap = Join-Path $staging 'rules.json'

    # ---- 1) -ScanPath 必填（缺省会全盘 + 卷影扫描）----
    $scanFull = ''
    if ([string]::IsNullOrWhiteSpace($ScanPath)) {
        $null = $errors.Add('缺少 -ScanPath：New-CIPolicy 在不指定 -ScanPath 时会做全盘 + 卷影扫描（实测耗时极长、刷出巨量警告并产出巨大 XML），本函数拒绝执行。请指定一个具体目录。')
    } elseif (-not (Test-Path -LiteralPath $ScanPath -PathType Container)) {
        $null = $errors.Add('-ScanPath 不是已存在的目录：' + $ScanPath)
    } else {
        try { $scanFull = (Resolve-Path -LiteralPath $ScanPath -ErrorAction Stop).ProviderPath } catch { $scanFull = $ScanPath }
        if ($scanFull -match '^[A-Za-z]:\\?$') { $null = $errors.Add('-ScanPath 不能是盘根目录（' + $scanFull + '）：那等于全盘扫描。请指定具体子目录。') }
    }
    if ($errors.Count -gt 0) {
        Write-LctWdacLog -Verb $verb -Level 'warn' -Message '策略构建被拒绝（参数不合规）' -Data @{ mode = $mode; scanPath = $ScanPath; errors = @($errors) } | Out-Null
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; scanPath = $ScanPath; stagingDir = $staging; xmlPath = $xmlPath; cipPath = $cipPath; applied = $false; refused = $true
            })
    }

    # ---- 2) 自管规则 ----
    $store = Get-LctWdacRuleStore
    if ($store.error) { $null = $errors.Add('rules.json 解析失败（请先修复该文件）：' + $store.error) }
    $rules = New-Object System.Collections.ArrayList
    foreach ($r in @($store.rules)) {
        $chk = Test-LctWdacRuleInput -Kind ([string]$r.kind) -Value ([string]$r.value)
        if (-not $chk.ok) {
            $null = $errors.Add('规则库含非法规则（' + [string]$r.kind + ' ' + [string]$r.value + '）：' + (@($chk.errors) -join ' / '))
            continue
        }
        $null = $rules.Add([pscustomobject][ordered]@{ id = [string]$r.id; kind = $chk.kind; value = $chk.value; reason = [string]$r.reason })
    }
    if ($errors.Count -eq 0 -and $rules.Count -eq 0) {
        $null = $errors.Add('自管黑名单当前没有规则（' + $store.path + '）：只靠 deny 规则的策略若 <FileRules> 为空就没有任何拦截语义，拒绝构建。请先 Add-LctWdacRule。')
    }
    if ($errors.Count -gt 0) {
        Write-LctWdacLog -Verb $verb -Level 'warn' -Message '策略构建被拒绝（规则库不合规）' -Data @{ errors = @($errors) } | Out-Null
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{
                mode = $mode; scanPath = $scanFull; stagingDir = $staging; xmlPath = $xmlPath; cipPath = $cipPath
                rulesPath = $store.path; rulesCount = $rules.Count; applied = $false; refused = $true
            })
    }

    # ---- 3) 预览 ----
    if (-not $Apply) {
        $null = $warnings.Add('预览：未运行 ConfigCI 工具链，staging 目录未写入任何文件。确认后请加 -Apply。')
        $null = $warnings.Add('产物将落在：' + $staging)
        $null = $changes.Add((New-LctWdacChange -Target $xmlPath -Name 'policy.xml' -Before '(旧产物/无)' -After ($mode + ' 策略（' + $rules.Count + ' 条 deny 规则）') -Note '预览'))
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; scanPath = $scanFull; stagingDir = $staging; xmlPath = $xmlPath; cipPath = $cipPath
                rulesSnapshotPath = $rulesSnap; readmePath = $readmePath; rulesPath = $store.path
                rulesCount = $rules.Count; allowAllPath = (Get-LctWdacAllowAllPath); needRestart = $true
                restartText = '策略构建完成后需 Deploy + 重启才生效。'; applied = $false; dryRun = $true
            })
    }

    # ---- 4) 落盘构建 ----
    $null = Ensure-LctDir -Path $staging
    $build = Ensure-LctDir -Path (Join-Path $staging '_build')
    $time = (Get-Date).ToString('s')
    $baseSource = ''
    $policyPaths = @()
    $officialCount = 0
    $domCount = 0

    $allowAll = Get-LctWdacAllowAllPath
    if (Test-Path -LiteralPath $allowAll -PathType Leaf) {
        $baseXml = Join-Path $build 'base-allowall.xml'
        Copy-Item -LiteralPath $allowAll -Destination $baseXml -Force
        $policyPaths += $baseXml
        $baseSource = 'MS 官方 ' + $allowAll + '（含 Enabled:UMCI + Allow FileName="*" 且被两个签名场景引用，即官方 standalone deny 配方）'
    } else {
        $gen = Join-Path $build 'base-generated.xml'
        $r = Invoke-LctWdacTool -Action { New-CIPolicy -FilePath $gen -Level None -Deny -ScanPath $scanFull -ErrorAction Stop }
        if ((-not $r.ok) -or (-not (Test-Path -LiteralPath $gen))) {
            $null = $errors.Add('生成策略基底失败：' + $r.error + ' ' + (@($r.output) -join ' | '))
            return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                    mode = $mode; scanPath = $scanFull; stagingDir = $staging; xmlPath = $xmlPath; applied = $false
                })
        }
        $policyPaths += $gen
        $baseSource = '兜底：New-CIPolicy -Level None -Deny -ScanPath（无 AllowAll.xml；该基底 <FileRules/> 与 <Signers/> 为空 ⇒ 无 allow 机制，只能审计部署）'
        $null = $warnings.Add('未找到 ' + $allowAll + '（AllowAll 官方基底）⇒ 已改用 New-CIPolicy 兜底基底；该基底没有任何 allow 机制，安全门会禁止 enforce 部署。')
    }

    # path 类规则且目标文件存在 ⇒ 走官方 New-CIPolicyRule 序列化；其余（fileName / hash / 目标不存在）⇒ XML 直写
    $official = New-Object System.Collections.ArrayList
    $dom = New-Object System.Collections.ArrayList
    foreach ($rule in @($rules)) {
        $usedOfficial = $false
        if (([string]$rule.kind -eq 'path') -and (Test-Path -LiteralPath ([string]$rule.value) -PathType Leaf)) {
            $obj = $null
            try { $obj = New-CIPolicyRule -Deny -FilePathRule ([string]$rule.value) -ErrorAction Stop } catch { $obj = $null }
            if ($null -ne $obj) {
                $null = $official.Add([pscustomobject][ordered]@{ rule = $rule; obj = $obj })
                $usedOfficial = $true
            }
        }
        if (-not $usedOfficial) { $null = $dom.Add($rule) }
    }
    if ($official.Count -gt 0) {
        $denyXml = Join-Path $build 'deny-official.xml'
        $objs = @($official | ForEach-Object { $_.obj })
        $r = Invoke-LctWdacTool -Action { New-CIPolicy -FilePath $denyXml -Rules $objs -ScanPath $scanFull -ErrorAction Stop }
        if ($r.ok -and (Test-Path -LiteralPath $denyXml)) {
            $policyPaths += $denyXml
            $officialCount = $official.Count
        } else {
            $null = $warnings.Add('官方 New-CIPolicyRule 序列化失败，已全部改为 XML 直写：' + $r.error + ' ' + (@($r.output) -join ' | '))
            foreach ($o in @($official)) { $null = $dom.Add($o.rule) }
            $officialCount = 0
        }
    }

    $merged = Join-Path $build 'merged.xml'
    $r = Invoke-LctWdacTool -Action { Merge-CIPolicy -PolicyPaths $policyPaths -OutputFilePath $merged -ErrorAction Stop }
    if ((-not $r.ok) -or (-not (Test-Path -LiteralPath $merged))) {
        $null = $errors.Add('Merge-CIPolicy 失败：' + $r.error + ' ' + (@($r.output) -join ' | '))
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; scanPath = $scanFull; stagingDir = $staging; xmlPath = $xmlPath; applied = $false
            })
    }
    Copy-Item -LiteralPath $merged -Destination $xmlPath -Force

    if ($dom.Count -gt 0) { $domCount = Add-LctWdacDenyRuleToXml -XmlPath $xmlPath -Rules @($dom) }

    # ---- 规则选项手术（救命绳 / audit 模式）----
    # 选项号来自实测：3=Audit Mode，6=Unsigned SIP，9=Advanced Boot Options Menu，10=Boot Audit On Failure
    $needAdd = New-Object System.Collections.ArrayList
    $null = $needAdd.Add([pscustomobject]@{ name = $script:LctWdacOptName.UnsignedSIP; num = $script:LctWdacOptNum.UnsignedSIP })
    $null = $needAdd.Add([pscustomobject]@{ name = $script:LctWdacOptName.AdvancedBootMenu; num = $script:LctWdacOptNum.AdvancedBootMenu })
    $null = $needAdd.Add([pscustomobject]@{ name = $script:LctWdacOptName.BootAuditOnFailure; num = $script:LctWdacOptNum.BootAuditOnFailure })
    if ($mode -eq 'audit') { $null = $needAdd.Add([pscustomobject]@{ name = $script:LctWdacOptName.AuditMode; num = $script:LctWdacOptNum.AuditMode }) }
    $optPlan = @($needAdd)
    $auditModeNum = $script:LctWdacOptNum.AuditMode
    $enforceMode = ($mode -eq 'enforce')
    $opsResult = Invoke-LctWdacTool -Action {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($xmlPath)
        $have = @{}
        foreach ($n in @($doc.SelectNodes("//*[local-name()='Rules']/*[local-name()='Rule']/*[local-name()='Option']"))) { $have[([string]$n.InnerText).Trim()] = $true }
        foreach ($it in @($optPlan)) {
            if (-not $have.ContainsKey([string]$it.name)) { Set-RuleOption -FilePath $xmlPath -Option ([int]$it.num) -ErrorAction Stop }
        }
        if ($enforceMode) { Set-RuleOption -FilePath $xmlPath -Option $auditModeNum -Delete -ErrorAction Stop }
    }
    if (-not $opsResult.ok) { $null = $warnings.Add('Set-RuleOption 阶段报告异常：' + $opsResult.error) }

    $name = 'LCT WDAC Blacklist (' + $mode + ')'
    $idResult = Invoke-LctWdacTool -Action { Set-CIPolicyIdInfo -FilePath $xmlPath -ResetPolicyID -PolicyName $name -ErrorAction Stop }
    if (-not $idResult.ok) { $null = $warnings.Add('Set-CIPolicyIdInfo 失败（PolicyID 未重置）：' + $idResult.error) }

    $conv = Invoke-LctWdacTool -Action { ConvertFrom-CIPolicy -XmlFilePath $xmlPath -BinaryFilePath $cipPath -ErrorAction Stop }
    if ((-not $conv.ok) -or (-not (Test-Path -LiteralPath $cipPath))) {
        $null = $errors.Add('ConvertFrom-CIPolicy 失败（策略 XML 可能不符合 schema）：' + $conv.error + ' ' + (@($conv.output) -join ' | '))
    }

    # 规则快照 + README
    $snapPayload = [ordered]@{ version = 1; snapshotTime = $time; mode = $mode; scanPath = $scanFull; count = $rules.Count; rules = @($rules) }
    Write-LctWdacTextBom -Path $rulesSnap -Text (ConvertTo-LctWdacJson -Object $snapPayload -Depth 10) | Out-Null

    $analysis = Get-LctWdacPolicyAnalysis -XmlPath $xmlPath
    # 只按「本次构建的目标模式」取安全门结论：enforce 构建不该被 audit 的
    # 「策略不含 Audit Mode，不能用 audit 部署」这类模式提示判为失败（Deploy 用同一套判定）。
    $selfBlockers = @($analysis.auditBlockers)
    if ($mode -eq 'enforce') { $selfBlockers = @($analysis.enforceBlockers) }
    foreach ($b in $selfBlockers) { $null = $errors.Add('构建结果未通过安全门（' + $mode + '）：' + $b) }
    if (-not $analysis.hasAllowMechanism) {
        $null = $warnings.Add('该策略没有 allow 机制（' + $analysis.allowMechanismText + '）⇒ 禁止强制部署，只允许审计部署。')
    }
    if (@($analysis.userWritableHits).Count -gt 0) {
        $null = $warnings.Add("有 $(@($analysis.userWritableHits).Count) 条 deny FilePath 规则位于用户可写目录：WDAC 默认（Runtime FilePath Rule Protection）不会生效 ⇒ 建议改用 hash 或 fileName 规则。")
    }
    if (-not $analysis.hasUnsignedSIP) { $null = $warnings.Add('策略缺少 Enabled:Unsigned System Integrity Policy：本机 Secure Boot=False，未签名策略将无法加载。') }
    if (-not $analysis.hasUMCI) { $null = $warnings.Add('策略未启用 Enabled:UMCI：deny 规则对用户态程序的拦截可能不生效。') }

    $policyId = ''
    try {
        $d = New-Object System.Xml.XmlDocument
        $d.Load($xmlPath)
        $n = $d.SelectSingleNode("//*[local-name()='PolicyID']")
        if ($null -ne $n) { $policyId = [string]$n.InnerText }
    } catch { }

    Write-LctWdacTextBom -Path $readmePath -Text (Get-LctWdacStagingReadme -Data ([pscustomobject][ordered]@{
                time = $time; mode = $mode; scanPath = $scanFull; baseSource = $baseSource
                ruleCount = $rules.Count; officialCount = $officialCount; domCount = $domCount
                allowMechanismText = $analysis.allowMechanismText; xmlPath = $xmlPath
                xmlSha = (Get-LctWdacFileHash -Path $xmlPath); cipPath = $cipPath
                cipSha = (Get-LctWdacFileHash -Path $cipPath); rulesSnapshot = $rulesSnap
                policyId = $policyId; options = (@($analysis.options) -join ' ; ')
            })) | Out-Null

    $null = $changes.Add((New-LctWdacChange -Target $xmlPath -Name 'policy.xml' -Before '(旧产物/无)' -After ($mode + ' 策略（' + $rules.Count + ' 条 deny 规则）') -Note 'ConfigCI 构建'))
    $null = $changes.Add((New-LctWdacChange -Target $cipPath -Name 'policy.cip' -Before '(旧产物/无)' -After '二进制策略（ConvertFrom-CIPolicy）' -Note ''))
    $null = $changes.Add((New-LctWdacChange -Target $readmePath -Name 'README.txt' -Before '(旧产物/无)' -After '部署/回滚说明' -Note ''))

    Write-LctWdacLog -Verb $verb -Level 'change' -Message ('已构建 ' + $mode + ' 策略，' + $rules.Count + ' 条 deny 规则') -Data @{
        xmlPath = $xmlPath; cipPath = $cipPath; sha256 = (Get-LctWdacFileHash -Path $xmlPath); hasAllowMechanism = $analysis.hasAllowMechanism
    } | Out-Null

    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            mode = $mode; scanPath = $scanFull; baseSource = $baseSource; stagingDir = $staging; buildDir = $build
            xmlPath = $xmlPath; cipPath = $cipPath; rulesSnapshotPath = $rulesSnap; readmePath = $readmePath
            policyId = $policyId; rulesCount = $rules.Count; officialRuleCount = $officialCount; domRuleCount = $domCount
            policySha256 = (Get-LctWdacFileHash -Path $xmlPath); cipSha256 = (Get-LctWdacFileHash -Path $cipPath)
            options = @($analysis.options); hasAllowMechanism = $analysis.hasAllowMechanism; allowMechanismText = $analysis.allowMechanismText
            canDeployAudit = $analysis.canDeployAudit; canDeployEnforce = $analysis.canDeployEnforce
            enforceBlockers = @($analysis.enforceBlockers); userWritableHits = @($analysis.userWritableHits)
            needRestart = $true
            restartText = 'legacy SiPolicy.p7b 需重启才生效（本机 CiTool.exe 不存在）：部署后必须重启才能验证。'
            applied = $true
        })
}
#endregion

#region 公开：安全门
function Test-LctWdacPolicy {
    param([Parameter(Mandatory)][string]$XmlPath)
    $verb = 'wdac.policy.validate'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $a = Get-LctWdacPolicyAnalysis -XmlPath $XmlPath

    if (-not $a.exists) {
        $null = $errors.Add('策略 XML 不存在：' + $XmlPath)
    } elseif (-not [string]::IsNullOrEmpty($a.parseError)) {
        $null = $errors.Add('策略 XML 解析失败：' + $a.parseError)
    } else {
        # 硬门禁（任何模式都不许部署）：无规则 / 命中系统关键位置
        if ($a.counts.denyRules -eq 0) { $null = $errors.Add('规则条数为 0：<FileRules> 里没有任何 deny 规则，部署无意义且徒增风险 ⇒ 拒绝') }
        foreach ($h in @($a.criticalHits)) { $null = $errors.Add('deny 规则命中系统关键位置：' + $h.reason) }
        foreach ($h in @($a.criticalNameHits)) { $null = $warnings.Add('注意：deny 规则目标是关键组件名（' + $h.reason + '），拦截它可能造成系统不稳定。') }
        foreach ($h in @($a.userWritableHits)) {
            $null = $warnings.Add('deny FilePath 规则位于用户可写位置（' + $h.reason + '）：' + $h.value + ' —— WDAC 默认（Runtime FilePath Rule Protection）不会生效，建议改用 hash 或 fileName。')
        }
        if (-not $a.hasUnsignedSIP) { $null = $warnings.Add('缺少 Enabled:Unsigned System Integrity Policy：本机 Secure Boot=False，未签名策略将无法加载（会被静默忽略）。') }
        if ($a.hasAllowMechanism -and ($a.allowMechanismText -like '*Allow*')) { $null = $warnings.Add('策略的 allow 机制：' + $a.allowMechanismText + ' ⇒ 放行一切、仅靠 deny 规则拦截，拦截范围完全取决于 deny 规则是否命中。') }

        $lifeSavers = @()
        if (-not $a.hasAdvancedBootOptionsMenu) { $lifeSavers += '缺少 Enabled:Advanced Boot Options Menu（坏策略救命绳）' }
        if (-not $a.hasBootAuditOnFailure) { $lifeSavers += '缺少 Enabled:Boot Audit On Failure（坏策略救命绳）' }

        if ($a.mode -eq 'enforce') {
            # 强制意图：allow 机制 + 两条救命绳一律进 errors（硬拒绝）
            if (-not $a.hasAllowMechanism) {
                $null = $errors.Add('策略没有任何 allow 机制（' + $a.allowMechanismText + '）：无法证明其余程序会被放行 ⇒ 禁止强制部署（只允许 audit）')
            }
            foreach ($ls in $lifeSavers) { $null = $errors.Add($ls + ' ⇒ 拒绝强制部署') }
        } else {
            # 审计模式：不拦审计部署，但把「不可转强制」的原因显式说出来
            if (-not $a.hasAllowMechanism) {
                $null = $warnings.Add('策略没有任何 allow 机制（' + $a.allowMechanismText + '）：仅允许审计部署，禁止转强制。')
            }
            foreach ($ls in $lifeSavers) { $null = $warnings.Add($ls + '：转强制前必须补上。') }
        }
    }

    $data = [pscustomobject][ordered]@{
        xmlPath                    = $a.xmlPath
        exists                     = $a.exists
        sha256                     = $a.sha256
        parseError                 = $a.parseError
        mode                       = $a.mode
        counts                     = $a.counts
        options                    = @($a.options)
        denyRules                  = @($a.denyRules)
        hasAllowMechanism          = $a.hasAllowMechanism
        allowMechanismText         = $a.allowMechanismText
        hasAuditMode               = $a.hasAuditMode
        hasAdvancedBootOptionsMenu = $a.hasAdvancedBootOptionsMenu
        hasBootAuditOnFailure      = $a.hasBootAuditOnFailure
        hasUnsignedSIP             = $a.hasUnsignedSIP
        hasUMCI                    = $a.hasUMCI
        runtimePathProtectionOn    = $a.runtimePathProtectionOn
        criticalHits               = @($a.criticalHits)
        userWritableHits           = @($a.userWritableHits)
        auditBlockers              = @($a.auditBlockers)
        enforceBlockers            = @($a.enforceBlockers)
        canDeployAudit             = $a.canDeployAudit
        canDeployEnforce           = $a.canDeployEnforce
    }
    Write-LctWdacLog -Verb $verb -Level 'info' -Message ('安全门校验 ' + $XmlPath) -Data @{
        mode = $a.mode; denyRules = $a.counts.denyRules; hasAllowMechanism = $a.hasAllowMechanism
        canDeployAudit = $a.canDeployAudit; canDeployEnforce = $a.canDeployEnforce; errors = @($errors)
    } | Out-Null
    return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data $data
}
#endregion

#region 公开：部署（legacy SiPolicy.p7b）
function Deploy-LctWdacPolicy {
    param(
        [Parameter(Mandatory)][string]$XmlPath,
        [ValidateSet('audit', 'enforce')][string]$Mode = 'audit',
        [string]$ConfirmText = '',
        [switch]$Apply
    )
    $verb = 'wdac.deploy'
    $mode = ([string]$Mode).ToLower()
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $staging = Get-LctWdacStagingPath
    $target = Get-LctWdacSystemPolicyPath
    $expect = [string]$script:LctWdacConfirm[$mode]
    $stamp = ''
    $backupDir = ''
    $revertCmd = ''

    # ---- 1) 安全门（先于任何文件操作）----
    $a = Get-LctWdacPolicyAnalysis -XmlPath $XmlPath
    $blockers = @()
    if ($mode -eq 'enforce') { $blockers = @($a.enforceBlockers) } else { $blockers = @($a.auditBlockers) }
    foreach ($b in $blockers) { $null = $errors.Add('安全门拒绝（' + $mode + '）：' + $b) }

    # ---- 2) confirm 文本（必须精确匹配；此前不得复制任何文件）----
    if ($ConfirmText -ne $expect) {
        $got = if ([string]::IsNullOrEmpty($ConfirmText)) { '(空)' } else { "'$ConfirmText'" }
        $null = $errors.Add("确认文本不正确：$mode 部署必须精确输入 -ConfirmText '$expect'（区分大小写），收到 $got。本次未备份、未复制、未改动任何文件。")
    }

    if ($errors.Count -gt 0) {
        Write-LctWdacLog -Verb $verb -Level 'warn' -Message '部署被拒绝（安全门或确认文本）' -Data @{ mode = $mode; xmlPath = $XmlPath; errors = @($errors) } | Out-Null
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; xmlPath = $XmlPath; applied = $false; requireRestart = $true; needRestart = $true
                requiredConfirmText = $expect; backupDir = ''; backupStamp = ''; backupId = ''; revertCmdPath = ''
                targetPolicyPath = $target; canDeployAudit = $a.canDeployAudit; canDeployEnforce = $a.canDeployEnforce
                auditBlockers = @($a.auditBlockers); enforceBlockers = @($a.enforceBlockers)
                restartText = '本次未部署，无重启要求。'
            })
    }

    # ---- 3) 预览（不备份、不复制）----
    if (-not $Apply) {
        $null = $warnings.Add('预览：未创建备份、未复制任何文件。确认后请加 -Apply。')
        $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before '(现有策略)' -After ($mode + ' 策略：' + $XmlPath) -Note '预览'))
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; xmlPath = $XmlPath; applied = $false; requireRestart = $true; needRestart = $true
                requiredConfirmText = $expect; backupDir = ''; backupStamp = ''; backupId = ''; revertCmdPath = ''
                targetPolicyPath = $target; xmlSha256 = $a.sha256
                canDeployAudit = $a.canDeployAudit; canDeployEnforce = $a.canDeployEnforce
                restartText = 'legacy SiPolicy.p7b 需重启才生效（本机 CiTool.exe 不存在）。'
                recoverySteps = @('F8 → 高级启动选项 → 禁用驱动程序强制签名 / 最近一次的正确配置', 'WinRE 离线：重命名 %SystemRoot%\System32\CodeIntegrity\SiPolicy.p7b 后重启')
                dryRun = $true
            })
    }

    # ---- 4) 提权检查 ----
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    if (-not $elevated) {
        $null = $errors.Add('部署需要管理员权限（当前进程未提权）。未创建备份、未改动任何文件。')
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                mode = $mode; xmlPath = $XmlPath; applied = $false; elevated = $false; requireRestart = $true; needRestart = $true
                requiredConfirmText = $expect; backupDir = ''; backupStamp = ''; backupId = ''; revertCmdPath = ''; targetPolicyPath = $target
            })
    }

    # ---- 5) 全量备份 + revert.cmd ----
    $stamp = New-LctWdacStamp
    $backupDir = Ensure-LctDir -Path (Join-Path (Get-LctWdacBackupRoot) ('wdac-' + $stamp))
    $bkFiles = Ensure-LctDir -Path (Join-Path $backupDir 'backup')
    $prevSi = Get-LctWdacFileInfo -Path $target
    $prevText = ''
    if ($prevSi.exists) {
        Copy-Item -LiteralPath $target -Destination (Join-Path $bkFiles 'SiPolicy.p7b') -Force
        $prevText = $prevSi.path + "（$($prevSi.length) 字节，SHA256 $($prevSi.sha256)）"
    } else {
        Write-LctWdacTextAsciiCrlf -Path (Join-Path $bkFiles 'SiPolicy.p7b.absent') -Text $target | Out-Null
        $prevText = '部署前本机没有 ' + $target
    }
    $activeBackupText = '(无文件)'
    $activeDir = Get-LctWdacActivePolicyDir
    $activeFiles = @(Get-ChildItem -LiteralPath $activeDir -File -Force -ErrorAction SilentlyContinue)
    if ($activeFiles.Count -gt 0) {
        $destActive = Ensure-LctDir -Path (Join-Path $bkFiles 'CiPolicies-Active')
        foreach ($f in $activeFiles) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destActive $f.Name) -Force }
        $activeBackupText = "$($activeFiles.Count) 个文件 → " + $destActive
    }
    # 目录清单（审计用；只读，不复制）
    $manifest = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-LctWdacSystemDir) -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $null = $manifest.Add([pscustomobject][ordered]@{
                rel = $f.FullName.Substring((Get-LctWdacSystemDir).Length)
                length = [long]$f.Length
                sha256 = (Get-LctWdacFileHash -Path $f.FullName)
                lastWrite = $f.LastWriteTime.ToString('s')
            })
    }

    # revert.cmd（纯 ASCII）+ README.txt（UTF-8 BOM）
    $revertCmd = Write-LctWdacTextAsciiCrlf -Path (Join-Path $backupDir 'revert.cmd') -Text (Get-LctWdacRevertCmd -Data ([pscustomobject][ordered]@{ time = (Get-Date).ToString('s'); mode = $mode; stamp = $stamp }))
    $readmePath = Join-Path $backupDir 'README.txt'

    # 目标二进制：由已校验的 XML 现场转换，保证「部署的二进制 = 校验过的 XML」
    $deployCip = Join-Path $staging ('deploy-' + $stamp + '.cip')
    $conv = Invoke-LctWdacTool -Action { ConvertFrom-CIPolicy -XmlFilePath $XmlPath -BinaryFilePath $deployCip -ErrorAction Stop }
    $deploySha = Get-LctWdacFileHash -Path $deployCip
    if ((-not $conv.ok) -or [string]::IsNullOrEmpty($deploySha)) {
        $null = $errors.Add('把已校验的 XML 转成二进制策略失败：' + $conv.error + ' ' + (@($conv.output) -join ' | '))
    }

    $secureBoot = 'Unknown'
    try { $secureBoot = [string](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { }
    $ciText = 'Unknown'
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        $ciText = switch ([int]$dg.CodeIntegrityPolicyEnforcementStatus) { 0 { 'Off' } 1 { 'Audit' } 2 { 'Enforced' } default { 'Unknown' } }
    } catch { }

    Write-LctWdacTextBom -Path $readmePath -Text (Get-LctWdacBackupReadme -Data ([pscustomobject][ordered]@{
                stamp = $stamp; time = (Get-Date).ToString('s'); mode = $mode; xmlPath = $XmlPath; xmlSha = $a.sha256
                target = $target; targetSha = $deploySha; previousSiPolicy = $prevText; activeBackup = $activeBackupText
                ciText = $ciText; options = (@($a.options) -join ' ; '); secureBoot = $secureBoot
            })) | Out-Null

    if ($errors.Count -gt 0) {
        Write-LctWdacLog -Verb $verb -Level 'error' -Message '部署准备阶段失败（未复制策略文件）' -Data @{ errors = @($errors); backupDir = $backupDir } | Out-Null
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -BackupId ('wdac-' + $stamp) -Data ([pscustomobject][ordered]@{
                mode = $mode; xmlPath = $XmlPath; applied = $false; backupDir = $backupDir; backupStamp = $stamp
                backupId = 'wdac-' + $stamp; revertCmdPath = $revertCmd; readmePath = $readmePath; targetPolicyPath = $target
                needRestart = $true; requireRestart = $true; requiredConfirmText = $expect
            })
    }

    # 写权限探测（创建 + 回收站，不留残余）
    $writable = $false
    try {
        $probe = Join-Path (Get-LctWdacSystemDir) ('.lct-write-probe-' + $stamp + '.tmp')
        Write-LctWdacTextAsciiCrlf -Path $probe -Text 'probe'
        $writable = (Test-Path -LiteralPath $probe)
        $null = Move-LctToRecycleBin -Path $probe
    } catch {
        $writable = $false
        $null = $warnings.Add('写入探测异常：' + $_.Exception.Message)
    }
    if (-not $writable) {
        $null = $errors.Add('无法写入 ' + (Get-LctWdacSystemDir) + '：请确认以管理员（或 SYSTEM）身份运行，且该目录无额外 ACL/占用保护。本次未部署策略（备份与 revert.cmd 已保留）。')
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -BackupId ('wdac-' + $stamp) -Data ([pscustomobject][ordered]@{
                mode = $mode; xmlPath = $XmlPath; applied = $false; backupDir = $backupDir; backupStamp = $stamp
                backupId = 'wdac-' + $stamp; revertCmdPath = $revertCmd; readmePath = $readmePath; targetPolicyPath = $target
                needRestart = $true; requireRestart = $true; requiredConfirmText = $expect
            })
    }

    # ---- 6) 部署 ----
    $copied = $false
    try {
        Copy-Item -LiteralPath $deployCip -Destination $target -Force
        if (Test-Path -LiteralPath $target) { attrib.exe -r -s -h $target 2>$null | Out-Null }
        $copied = $true
    } catch {
        $null = $errors.Add('复制策略到 ' + $target + ' 失败：' + $_.Exception.Message)
    }
    if ($copied) {
        $newSha = Get-LctWdacFileHash -Path $target
        if ($newSha -ne $deploySha) {
            $null = $errors.Add('部署后哈希校验不一致（期望 ' + $deploySha + '，实际 ' + $newSha + '）⇒ 已尝试回滚。')
            try {
                if ($prevSi.exists) { Copy-Item -LiteralPath (Join-Path $bkFiles 'SiPolicy.p7b') -Destination $target -Force }
                else { $null = Move-LctToRecycleBin -Path $target }
            } catch { $null = $warnings.Add('回滚失败，请手工用 revert.cmd 处理：' + $_.Exception.Message) }
        }
    }

    # meta.json（与 Backup 模块同形的可读元数据 + wdac 段）
    $meta = [ordered]@{
        id = 'wdac-' + $stamp; verb = $verb; created = (Get-Date).ToString('s')
        user = "$env:USERDOMAIN\$env:USERNAME"; elevated = $elevated
        args = [ordered]@{ mode = $mode; xmlPath = $XmlPath; confirmText = '(provided)' }
        registryPaths = @(); hasAccountState = $false
        files = @((Join-Path $bkFiles 'SiPolicy.p7b'), (Join-Path $bkFiles 'SiPolicy.p7b.absent'), $revertCmd, $readmePath, $deployCip)
        notes = @('备份目录：backup\（部署前的 SiPolicy.p7b 或 .absent 标记、CiPolicies\Active 全量副本）')
        wdac = [ordered]@{
            stamp = $stamp; mode = $mode; targetPolicyPath = $target; xmlPath = $XmlPath
            xmlSha256 = $a.sha256; deployedCip = $deployCip; deployedSha256 = $deploySha
            previousSystemPolicy = [ordered]@{ exists = $prevSi.exists; path = $prevSi.path; length = $prevSi.length; sha256 = $prevSi.sha256 }
            activePolicies = @($activeFiles | ForEach-Object { $_.Name })
            secureBoot = $secureBoot; ciEnforcement = $ciText
        }
    }
    Write-LctWdacTextBom -Path (Join-Path $backupDir 'meta.json') -Text (ConvertTo-LctWdacJson -Object $meta -Depth 10) | Out-Null
    Write-LctWdacTextBom -Path (Join-Path $backupDir 'manifest-before.json') -Text (ConvertTo-LctWdacJson -Object ([ordered]@{ dir = (Get-LctWdacSystemDir); takenAt = (Get-Date).ToString('s'); files = @($manifest) }) -Depth 10) | Out-Null

    $null = $changes.Add((New-LctWdacChange -Target $backupDir -Name 'backup' -Before '(部署前状态)' -After ('wdac-' + $stamp) -Note '全量备份 + revert.cmd'))
    if ($errors.Count -eq 0) { $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before $prevText -After ($mode + ' 策略（SHA256 ' + $deploySha + '）') -Note 'legacy 单策略路径')) }

    $null = $warnings.Add('需重启生效：本机 CiTool.exe 不存在，legacy SiPolicy.p7b 只有重启后才加载。')
    $null = $warnings.Add('恢复：运行 ' + $revertCmd + '（管理员，含逐步说明），或 Restore-LctWdacPolicy -Stamp ' + $stamp + ' -Apply，然后重启。')
    $recoverySteps = @(
        '重启后先跑 wdac.verify：判定「可安全转强制」才继续转强制。',
        '开机失败时连按 F8 → 高级启动选项 → 禁用驱动程序强制签名 或 最近一次的正确配置。',
        '进不去系统时用 WinRE → 命令提示符：ren <系统盘>:\Windows\System32\CodeIntegrity\SiPolicy.p7b SiPolicy.p7b.disabled（WinRE 下盘符可能不同）。'
    )
    foreach ($s in $recoverySteps) { $null = $warnings.Add($s) }

    Write-LctWdacLog -Verb $verb -Level 'change' -Message ('已部署 ' + $mode + ' 策略到 ' + $target + '（需重启生效）') -Data @{
        stamp = $stamp; backupDir = $backupDir; deployedSha256 = $deploySha; errors = @($errors)
    } | Out-Null

    return New-LctResult -Verb $verb -Applied:($errors.Count -eq 0) -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -BackupId ('wdac-' + $stamp) -Data ([pscustomobject][ordered]@{
            mode = $mode; xmlPath = $XmlPath; xmlSha256 = $a.sha256
            applied = ($errors.Count -eq 0); elevated = $elevated
            backupDir = $backupDir; backupStamp = $stamp; backupId = 'wdac-' + $stamp
            revertCmdPath = $revertCmd; readmePath = $readmePath; manifestPath = (Join-Path $backupDir 'manifest-before.json')
            targetPolicyPath = $target; deployedCipPath = $deployCip; deployedSha256 = $deploySha
            previousSystemPolicy = [pscustomobject][ordered]@{ exists = $prevSi.exists; path = $prevSi.path; length = $prevSi.length; sha256 = $prevSi.sha256 }
            needRestart = $true; requireRestart = $true; restartText = '需重启生效：legacy SiPolicy.p7b 只在重启时加载（CiTool.exe 不存在，无法在线更新）。'
            recoverySteps = $recoverySteps; restoreCommandHint = 'Restore-LctWdacPolicy -Stamp ' + $stamp + ' -Apply'
            requiredConfirmText = $expect; canDeployAudit = $a.canDeployAudit; canDeployEnforce = $a.canDeployEnforce
            options = @($a.options)
        })
}
#endregion

#region 公开：回滚
function Restore-LctWdacPolicy {
    param([Parameter(Mandatory)][string]$Stamp, [switch]$Apply)
    $verb = 'wdac.revert'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $target = Get-LctWdacSystemPolicyPath
    $root = Get-LctWdacBackupRoot

    $dir = ''
    if (-not [string]::IsNullOrWhiteSpace($Stamp) -and (Test-Path -LiteralPath $Stamp -PathType Container)) {
        $dir = (Resolve-Path -LiteralPath $Stamp -ErrorAction Stop).ProviderPath
    } else {
        foreach ($cand in @((Join-Path $root $Stamp), (Join-Path $root ('wdac-' + $Stamp)))) {
            if (Test-Path -LiteralPath $cand -PathType Container) { $dir = $cand; break }
        }
    }
    if ([string]::IsNullOrEmpty($dir)) {
        $avail = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'wdac-*' } | Sort-Object Name -Descending | ForEach-Object { $_.Name })
        $listText = if (@($avail).Count -gt 0) { @($avail) -join ', ' } else { '(无)' }
        $null = $errors.Add("备份不存在：'$Stamp'（在 $root 下找不到该备份目录）。现有 wdac 备份：$listText")
        Write-LctWdacLog -Verb $verb -Level 'warn' -Message '回滚被拒绝：备份不存在' -Data @{ stamp = $Stamp; backupRoot = $root } | Out-Null
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{
                stamp = $Stamp; backupDir = ''; exists = $false; applied = $false; availableStamps = @($avail)
            })
    }

    $bkFiles = Join-Path $dir 'backup'
    $prev = Join-Path $bkFiles 'SiPolicy.p7b'
    $absent = Join-Path $bkFiles 'SiPolicy.p7b.absent'
    $hasPrev = Test-Path -LiteralPath $prev -PathType Leaf
    $hasAbsent = Test-Path -LiteralPath $absent -PathType Leaf
    $si = Get-LctWdacFileInfo -Path $target
    $mode = '未知'
    $metaPath = Join-Path $dir 'meta.json'
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = (Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            if ($meta.wdac -and $meta.wdac.mode) { $mode = [string]$meta.wdac.mode }
        } catch { $null = $warnings.Add('meta.json 读取失败（按目录内容推断）：' + $_.Exception.Message) }
    }
    $plan = New-Object System.Collections.ArrayList
    if ($hasPrev) { $null = $plan.Add('把备份的 SiPolicy.p7b 复制回 ' + $target) }
    elseif ($hasAbsent) { $null = $plan.Add('部署前本机没有策略文件 ⇒ 把当前部署的 ' + $target + ' 送回收站') }
    else { $null = $plan.Add('备份里既没有 SiPolicy.p7b 也没有 .absent 标记 ⇒ 无法判定原状态') }
    $activeBk = Join-Path $bkFiles 'CiPolicies-Active'
    if (Test-Path -LiteralPath $activeBk) { $null = $plan.Add('把 CiPolicies\Active 的备份副本复制回去') }

    if (-not $Apply) {
        foreach ($p in @($plan)) { $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before '(当前部署的策略)' -After $p -Note '预览')) }
        $null = $warnings.Add('预览：未改动任何文件。确认后请加 -Apply（然后重启）。')
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
                stamp = $Stamp; backupDir = $dir; mode = $mode; exists = $true; applied = $false
                plan = @($plan); systemPolicyExists = $si.exists; systemPolicySha256 = $si.sha256
                needRestart = $true; restartText = '回滚同样需要重启才生效。'; dryRun = $true
            })
    }

    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    if (-not $elevated) {
        $null = $errors.Add('回滚需要管理员权限（当前进程未提权）。未改动任何文件。')
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{ stamp = $Stamp; backupDir = $dir; applied = $false; elevated = $false })
    }

    $didChange = $false
    if ($hasPrev) {
        try {
            Copy-Item -LiteralPath $prev -Destination $target -Force
            $didChange = $true
            $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before ('SHA256 ' + $si.sha256) -After ('还原为备份 SHA256 ' + (Get-LctWdacFileHash -Path $prev)) -Note '还原部署前策略'))
        } catch { $null = $errors.Add('还原 SiPolicy.p7b 失败：' + $_.Exception.Message) }
    } elseif ($hasAbsent) {
        if ($si.exists) {
            try {
                $ok = Move-LctToRecycleBin -Path $target
                if ($ok) {
                    $didChange = $true
                    $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before ('部署的策略 SHA256 ' + $si.sha256) -After '(已送回收站：部署前本机无此文件)' -Note '移除部署策略'))
                } else { $null = $errors.Add('把 ' + $target + ' 送回收站失败（返回 false）。') }
            } catch { $null = $errors.Add('移除部署策略失败：' + $_.Exception.Message) }
        } else {
            $null = $changes.Add((New-LctWdacChange -Target $target -Name 'SiPolicy.p7b' -Before '(不存在)' -After '(不存在)' -Note '无变化：系统上本来就没有策略文件'))
            $null = $warnings.Add('系统上本来就没有 ' + $target + '，无需移除。')
        }
    } else {
        $null = $errors.Add('备份内容不完整：既没有 SiPolicy.p7b 也没有 SiPolicy.p7b.absent 标记，无法判定原状态，拒绝改动系统。备份目录：' + $dir)
    }
    if (Test-Path -LiteralPath $activeBk) {
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $activeBk -File -Force)) {
                Copy-Item -LiteralPath $f.FullName -Destination (Join-Path (Get-LctWdacActivePolicyDir) $f.Name) -Force
                $null = $changes.Add((New-LctWdacChange -Target (Join-Path (Get-LctWdacActivePolicyDir) $f.Name) -Name $f.Name -Before '(现状态)' -After '(备份副本)' -Note 'CiPolicies\Active 还原'))
            }
            $didChange = $true
        } catch { $null = $errors.Add('还原 CiPolicies\Active 失败：' + $_.Exception.Message) }
    }

    $recoverySteps = @(
        '重启后跑 wdac.verify 确认 CI 强制状态与策略文件已回到预期。',
        '开机失败时连按 F8 → 高级启动选项 → 禁用驱动程序强制签名 或 最近一次的正确配置。',
        'WinRE 离线：ren <系统盘>:\Windows\System32\CodeIntegrity\SiPolicy.p7b SiPolicy.p7b.disabled'
    )
    $null = $warnings.Add('回滚需要重启才生效（legacy SiPolicy.p7b 只在重启时加载/卸载）。')
    foreach ($s in $recoverySteps) { $null = $warnings.Add($s) }

    Write-LctWdacLog -Verb $verb -Level 'change' -Message ('已回滚备份 ' + (Split-Path -Leaf $dir)) -Data @{ backupDir = $dir; didChange = $didChange; errors = @($errors) } | Out-Null

    return New-LctResult -Verb $verb -Applied:($didChange -and $errors.Count -eq 0) -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -BackupId (Split-Path -Leaf $dir) -Data ([pscustomobject][ordered]@{
            stamp = $Stamp; backupDir = $dir; mode = $mode; exists = $true; applied = ($didChange -and $errors.Count -eq 0)
            restoredPreviousPolicy = $hasPrev; removedDeployedPolicy = ($hasAbsent -and $didChange -and (-not $hasPrev))
            systemPolicyPath = $target; systemPolicyExists = (Test-Path -LiteralPath $target)
            needRestart = $true; restartText = '需重启生效。'; recoverySteps = $recoverySteps
        })
}
#endregion

#region 公开：重启后验证
function Get-LctWdacCiEvents {
    param([int]$MaxEvents = 300)
    $res = [ordered]@{
        logName = 'Microsoft-Windows-CodeIntegrity/Operational'; available = $false; scanned = 0; error = ''
        lastEventTime = ''; policyEvents = @(); auditEvents = @(); blockEvents = @()
    }
    try {
        $ev = @(Get-WinEvent -LogName $res.logName -MaxEvents $MaxEvents -ErrorAction Stop)
        $res.available = $true
        $res.scanned = @($ev).Count
        $pol = New-Object System.Collections.ArrayList
        $aud = New-Object System.Collections.ArrayList
        $blk = New-Object System.Collections.ArrayList
        foreach ($e in $ev) {
            $id = [int]$e.Id
            if ($pol.Count -eq 0 -and $aud.Count -eq 0 -and $blk.Count -eq 0) { }
            $msg = ''
            try { $msg = ([string]$e.Message -replace '\s+', ' ') } catch { }
            if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
            $rec = [pscustomobject][ordered]@{ time = $e.TimeCreated.ToString('s'); id = $id; message = $msg }
            if ($script:LctWdacEventIds.Block -contains $id) { $null = $blk.Add($rec) }
            elseif ($script:LctWdacEventIds.Audit -contains $id) { $null = $aud.Add($rec) }
            elseif ($script:LctWdacEventIds.Policy -contains $id) { $null = $pol.Add($rec) }
        }
        foreach ($c in @($pol, $aud, $blk)) { $c.Reverse() }
        $res.policyEvents = @($pol)
        $res.auditEvents = @($aud)
        $res.blockEvents = @($blk)
        if (@($ev).Count -gt 0) { $res.lastEventTime = $ev[0].TimeCreated.ToString('s') }
    } catch {
        $res.error = $_.Exception.Message
        try {
            $li = Get-WinEvent -ListLog $res.logName -ErrorAction Stop
            $res.available = $true
            $res.error = '读取事件失败（日志存在，记录数 ' + [string]$li.RecordCount + '）：' + $res.error
        } catch { $res.available = $false }
    }
    return [pscustomobject]$res
}

function Get-LctWdacVerify {
    $sys = Get-LctWdacFileInfo -Path (Get-LctWdacSystemPolicyPath)
    $stagingCip = Join-Path (Get-LctWdacStagingPath) 'policy.cip'
    $stCip = Get-LctWdacFileInfo -Path $stagingCip
    $stagingXml = Join-Path (Get-LctWdacStagingPath) 'policy.xml'
    $stXml = Get-LctWdacFileInfo -Path $stagingXml
    $active = @(Get-ChildItem -LiteralPath (Get-LctWdacActivePolicyDir) -File -Force -ErrorAction SilentlyContinue)

    $ciRaw = -1; $ciText = 'Unknown'
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        $ciRaw = [int]$dg.CodeIntegrityPolicyEnforcementStatus
        $ciText = switch ($ciRaw) { 0 { 'Off' } 1 { 'Audit' } 2 { 'Enforced' } default { 'Unknown' } }
    } catch { }

    $ev = Get-LctWdacCiEvents -MaxEvents 300
    $hashMatch = $null
    if ($sys.exists -and $stCip.exists) { $hashMatch = ($sys.sha256 -eq $stCip.sha256) }
    $needsRestart = ($sys.exists -and $ciRaw -eq 0)

    $verdict = 'unclear'; $text = '尚不明确'; $reason = ''
    $recs = New-Object System.Collections.ArrayList
    if (@($ev.blockEvents).Count -gt 0) {
        $verdict = 'dangerous'; $text = '危险'
        $reason = '审计阶段已经出现实际拦截事件（' + @($ev.blockEvents).Count + ' 条，如 3076/3077）：转强制前必须先确认这些拦截没有打掉正常程序/系统组件。'
        $null = $recs.Add('先看 data.events.blockEvents 里的文件列表，确认被拦的都是你确实想拦的目标。')
    } elseif (-not $sys.exists) {
        $verdict = 'unclear'; $text = '尚不明确'
        $reason = '未发现系统策略文件（' + $sys.path + '）：还没部署，或已被回滚。'
        $null = $recs.Add('先执行 audit 部署（Deploy-LctWdacPolicy -Mode audit -ConfirmText I-UNDERSTAND-AUDIT -Apply）并重启。')
    } elseif ($needsRestart) {
        $verdict = 'unclear'; $text = '尚不明确'
        $reason = '策略文件已就位，但 CI 强制状态仍为 Off ⇒ 尚未重启生效，当前机器上没有策略在跑。'
        $null = $recs.Add('重启后再跑 wdac.verify。')
    } elseif ($hashMatch -eq $false) {
        $verdict = 'dangerous'; $text = '危险'
        $reason = '系统上的策略文件哈希（' + $sys.sha256 + '）与 staging 产物 policy.cip（' + $stCip.sha256 + '）不一致 ⇒ 将要强制的策略并非当前已加载/已审过的那一个。'
        $null = $recs.Add('重新构建并重新部署，确保部署的二进制来自刚校验过的 XML。')
    } elseif ($ciRaw -eq 1 -and $hashMatch -eq $true -and @($ev.auditEvents).Count -gt 0) {
        $verdict = 'safe-to-enforce'; $text = '可安全转强制'
        $reason = '策略已在审计模式运行，哈希与 staging 一致，且审计日志已记录策略评估事件（' + @($ev.auditEvents).Count + ' 条）⇒ 可以转强制。'
        $null = $recs.Add('转强制：先 New-LctWdacPolicy -Mode enforce -Apply 重新构建，再用 -ConfirmText I-UNDERSTAND-ENFORCE 部署。')
    } elseif ($ciRaw -eq 1 -and $hashMatch -eq $true) {
        $verdict = 'unclear'; $text = '尚不明确'
        $reason = '策略已加载且哈希与 staging 一致，但审计日志里还没有策略评估事件（3078/3080/3112）⇒ 还没有证据表明它真的在评估/放行程序。'
        $null = $recs.Add('先运行你打算拦截的目标程序，再看 wdac.verify；若始终没有审计事件，检查策略是否真的加载。')
    } elseif ($ciRaw -eq 2) {
        $verdict = if ($hashMatch -eq $true) { 'safe-to-enforce' } else { 'unclear' }
        $text = switch ($verdict) { 'safe-to-enforce' { '可安全转强制' } default { '尚不明确' } }
        $reason = '策略已处于强制模式，且审计/拦截事件中没有出现非预期拦截。'
        $null = $recs.Add('如出现程序被拦，立刻用 Restore-LctWdacPolicy 回滚并重启。')
    } else {
        $verdict = 'unclear'; $text = '尚不明确'
        $reason = '策略文件与 CI 状态组合无法判定（CI=' + $ciText + '，matchesStaging=' + [string]$hashMatch + '）。'
    }

    return [pscustomobject][ordered]@{
        verdict              = $verdict
        verdictText          = $text
        verdictReason        = $reason
        ciEnforcement        = $ciRaw
        ciEnforcementText    = $ciText
        ciToolPresent        = (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\CiTool.exe'))
        systemPolicy         = $sys
        stagingPolicy        = $stXml
        stagingPolicyCip     = $stCip
        matchesStaging       = $hashMatch
        needsRestart         = $needsRestart
        activePolicyCount    = @($active).Count
        events               = $ev
        recommendations      = @($recs)
        rulesCount           = @((Get-LctWdacRuleStore).rules).Count
        checkedAt            = (Get-Date).ToString('s')
        limitations          = @(
            '「用户态黑名单」语义无法在重启前证明：策略只有重启加载后才生效。',
            '审计放行事件（3078/3080/3112）只能证明策略在评估文件，不能证明你想要的拦截一定会发生；必须实测目标程序。',
            '本机 CiTool.exe 不存在，策略变更只能靠重启生效（无法在线更新）。'
        )
    }
}
#endregion

Export-ModuleMember -Function Get-LctWdacStatus, Get-LctWdacRules, Add-LctWdacRule, Remove-LctWdacRule,
    New-LctWdacPolicy, Test-LctWdacPolicy, Deploy-LctWdacPolicy, Restore-LctWdacPolicy, Get-LctWdacVerify