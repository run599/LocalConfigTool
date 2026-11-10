# =====================================================================
# LocalConfigTool - Drivers.psm1
# 职责：自定义驱动加载（口径：指定一个 .sys，把它加载起来）
# 作者：task-1 (backend-drivers)
# 契约：docs\CONTRACT.md §3 Result / §7 铁律 / §10 集成约定 / §11.6 形状 / §12 驱动加载
# 导出（9 个，与 §12.3 逐字一致）：
#   Get-LctDriverStatus            （无参）
#   Get-LctDriverList              -Name
#   Get-LctDriverFileInfo          -Path
#   Load-LctDriver                 -Path -Name -StartType -Stage -Override -Apply
#   Start-LctDriver                -Name -Apply
#   Stop-LctDriver                 -Name -Apply
#   Remove-LctDriverService        -Name -Apply
#   Set-LctDriverTestSigning       -Enable -Disable -Apply
#   Get-LctDriverVerification      -Name
#
# ---- 口径（§12.1，操作者明确要求）----
#  * 功能就是「指定一个 .sys，把它加载起来」。**不对驱动做任何前瞻门槛**：
#    不要求已签名、不检查任何状态。签名与否交给操作系统判定，工具只把系统的
#    返回原文（退出码 + stdout/stderr 全文）照抄回传（577 / 578 / 193 / 1053 …）。
#  * 唯一门槛是「启动类型 / 服务名冲突」这类稳定性与可回滚性保护，与签名无关。
#  * applied=true 只代表我们执行了动作；**是否真的加载成功以系统返回为准**。
#
# ---- 本机实测（2026-10-26，Win10 19045.6466，Windows PowerShell 5.1）----
#  1) sc.exe 必须用「分离 token」形式：create <n> type= kernel binPath= <abs> start= demand。
#     写成单个 token 'binPath= "C:\x y\x.sys"' 时 sc.exe 会把引号**原样存进 ImagePath**
#     （实测存成 ' "C:\...\x.sys"'），驱动加载立刻报 123 文件名语法错误。分离 token 形式下
#     sc.exe 会规范化成 '\??\C:\...\x.sys'，这才是可加载的内核镜像路径（含空格路径也正确）。
#  2) 实测**不要**事后把 ImagePath 改写成不带 '\??\' 的裸路径：裸路径 sc start 直接报 123。
#  3) 无效镜像（把文本存成 .sys）：sc create 成功（Type=1/Start=3），sc start 报
#     '[SC] StartService FAILED with error 193.'；随后 Service Control Manager 记 7000/7026/219。
#     测试全程只用这种无效镜像，**绝不加载任何真实内核代码**。
#  4) sc.exe 的失败文本走 **stdout**（实测 query/start 失败文本都在 stdout，PS 5.1 下经 2>&1
#     会变成 ErrorRecord，本模块两种流都收，判定以退出码 + 合并原文为准）。
#  5) 未成功启动过的驱动服务**不会**出现在 Win32_SystemDriver 里（实测新注册的无效驱动查不到），
#     所以「驱动服务清单」以注册表 HKLM\SYSTEM\CurrentControlSet\Services 为权威来源，CIM 只补 State。
#
# ---- 铁律 ----
#  * 默认只预览，-Apply 才真做；每个动作写审计日志（Write-LctLog）。
#  * system / boot 启动类型必须 -Override（开机即载 = 蓝屏/无法启动高危路径）。
#  * 同名服务已存在 ⇒ 默认拒绝覆盖；-Override 时先 New-LctBackup 导出该服务注册表键。
#  * 卸载只删服务项，**绝不删 .sys 文件**。
#  * 禁止永久删除（Remove-Item 等一律禁止）；文件 UTF-8 带 BOM；.cmd 纯 ASCII。
#  * 不使用 Set-StrictMode；不弹窗；不使用 Write-Host（引擎 stdout 只能是最终 JSON）。
#  * 不用只读自动变量作变量名（$pid/$host/…）；不用 $Args 作形参名（本项目已因此出过事故）。
# =====================================================================

#region 依赖守卫（契约 §10.3 / §10.4）
# 规则：跨模块导入一律带 -Global；可用性以「模块是否装载成功」为准，不用 Get-Command 探测。
$script:LctDrvLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
$script:LctDrvBackupModule = Join-Path $PSScriptRoot 'Backup.psm1'
if ((Test-Path -LiteralPath $script:LctDrvLoggingModule) -and (-not (Get-Module -Name Logging))) {
    Import-Module $script:LctDrvLoggingModule -Force -Global -ErrorAction Stop
}
if ((Test-Path -LiteralPath $script:LctDrvBackupModule) -and (-not (Get-Module -Name Backup))) {
    Import-Module $script:LctDrvBackupModule -Force -Global -ErrorAction Stop
}
$script:LctDrvLoaded = [bool](Get-Module -Name Logging)
#endregion

#region 常量
$script:LctDrvStartAllowed = @('demand', 'system', 'boot', 'auto')
$script:LctDrvSelfPrefix = 'lctdrv'

# sc.exe / 内核返回码 → 参考解释。**这只是给读者的参考，系统原文永远照抄在 verdict.message 里。**
$script:LctDrvCodeHint = @{
    '1'    = '请求的服务不存在'
    '2'    = '系统找不到指定的文件（binPath 指向的 .sys 不存在）'
    '5'    = '拒绝访问（需要管理员 / SYSTEM 权限）'
    '19'   = '介质写保护'
    '87'   = '参数不正确'
    '123'  = '文件名、目录名或卷标语法不正确（ImagePath 不是可加载的内核镜像路径）'
    '127'  = '找不到指定的程序（导出/入口缺失）'
    '193'  = '不是有效的 Win32 应用程序（.sys 不是有效的 PE/驱动镜像格式）'
    '219'  = '驱动加载失败（原文见系统日志 Service Control Manager 219）'
    '577'  = '系统无法验证该文件的数字签名（DSE 拦截未签名 / 签名无效的驱动）'
    '578'  = '该文件的数字签名无效或已被篡改'
    '1053' = '服务没有及时响应启动或控制请求（SCM 超时：驱动入口未按期返回）'
    '1058' = '服务已被禁用，无法启动'
    '1060' = '指定的服务未安装'
    '1062' = '服务尚未启动'
    '1073' = '指定的服务已存在'
    '1290' = '代码完整性策略阻止加载未签名 / 不受信任的驱动（WDAC / CI 强制）'
}
#endregion

#region 私有：日志 / 结果条目 / 目录 / 文本落盘
function Write-LctDrvLog {
    param([string]$Verb = 'driver', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}

function New-LctDrvChange {
    param([string]$Target = '', [string]$Name = '', [string]$Before = '', [string]$After = '', [string]$Note = '', [string]$Kind = 'note')
    return [pscustomobject][ordered]@{ kind = $Kind; target = $Target; name = $Name; before = $Before; after = $After; note = $Note }
}

function Ensure-LctDrvDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    return $Path
}

function Write-LctDrvTextBom {
    # UTF-8 带 BOM（PS 5.1 才不会把中文按 GBK 解析）
    param([string]$Path, [AllowEmptyString()][string]$Text = '')
    $enc = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $enc)
    return $Path
}

function Write-LctDrvTextAsciiCrlf {
    # .cmd 必须纯 ASCII + CRLF（cmd.exe 按 OEM 代码页读它）
    param([string]$Path, [AllowEmptyString()][string]$Text = '')
    $t = $Text -replace "`r?`n", "`r`n"
    $enc = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($Path, $t, $enc)
    return $Path
}

function ConvertTo-LctDrvJson {
    param($Object, [int]$Depth = 10)
    return [string]($Object | ConvertTo-Json -Depth $Depth)
}

function First-LctDrvLine {
    # 把多行原文压成一行，便于塞进 changes / warnings；不改字，只合并空白。
    param([AllowEmptyString()][string]$Text = '', [int]$Max = 200)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return ($t.Substring(0, $Max) + '...') }
    return $t
}

function Format-LctDrvToken {
    param([AllowEmptyString()][string]$Token = '')
    if ($Token -match '\s') { return ('"' + $Token + '"') }
    return $Token
}
#endregion

#region 私有：路径 / 服务名 / 注册表画像
function Get-LctDrvBaseDir {
    # 不用 Get-LctVarDir（那会顺带建 logs/backups 目录）：只读 getter 也要保持「不落盘」的语义
    if (-not [string]::IsNullOrWhiteSpace($env:LCT_VAR_DIR)) { return $env:LCT_VAR_DIR }
    return (Join-Path (Get-LctToolRoot) 'var')
}

function Get-LctDrvSystemDir { return (Join-Path $env:SystemRoot 'System32') }
function Get-LctDrvSystemDriversDir { return (Join-Path $env:SystemRoot 'System32\drivers') }
function Get-LctDrvScExe { return (Join-Path (Get-LctDrvSystemDir) 'sc.exe') }
function Get-LctDrvBcdeditExe { return (Join-Path (Get-LctDrvSystemDir) 'bcdedit.exe') }

function Test-LctDrvServiceName {
    # 服务名白名单：字母数字 + _ . -（避免把不可信字符串拼进注册表路径 / sc 参数）
    param([AllowEmptyString()][string]$Name = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 128) { return $false }
    return [bool]($Name -match '^[A-Za-z0-9_.\-]+$')
}

function Get-LctDrvServiceKeyPath {
    param([string]$Name)
    return ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name)
}

function Get-LctDrvStartText {
    param([int]$Start = -1)
    if ($Start -eq 0) { return 'boot' }
    if ($Start -eq 1) { return 'system' }
    if ($Start -eq 2) { return 'auto' }
    if ($Start -eq 3) { return 'demand' }
    if ($Start -eq 4) { return 'disabled' }
    return 'unknown'
}

function Get-LctDrvTypeText {
    param([int]$Type = -1)
    if ($Type -lt 0) { return 'unknown' }
    $parts = New-Object System.Collections.ArrayList
    if (($Type -band 1) -eq 1) { $null = $parts.Add('kernel') }
    if (($Type -band 2) -eq 2) { $null = $parts.Add('filesystem') }
    if (($Type -band 16) -eq 16) { $null = $parts.Add('own-process') }
    if (($Type -band 32) -eq 32) { $null = $parts.Add('share-process') }
    if (($Type -band 256) -eq 256) { $null = $parts.Add('interactive') }
    if ($parts.Count -eq 0) { return ('0x' + ('{0:X}' -f $Type)) }
    return ($parts -join '+')
}

function ConvertTo-LctDrvLocalPath {
    # 注册表 ImagePath 常见三种形态：'\??\C:\...'、'\SystemRoot\System32\...'、'System32\...'
    # 返回「本地文件系统路径」（去掉 \??\ 与包裹引号；\SystemRoot 展开为 %SystemRoot%）。
    param([AllowEmptyString()][string]$ImagePath = '')
    $p = ([string]$ImagePath).Trim()
    if ($p.Length -gt 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2) }
    $p = $p -replace '^\\\?\?\\', ''
    if ($p -match '(?i)^\\SystemRoot\\') { $p = (Join-Path $env:SystemRoot $p.Substring(12)) }
    elseif ($p -match '(?i)^System32\\') { $p = (Join-Path $env:SystemRoot $p) }
    return $p.Trim()
}

function Get-LctDrvServiceRegistration {
    # 服务项的权威画像（注册表为准；本工具创建的服务也一定能读到）
    param([Parameter(Mandatory)][string]$Name)
    $keyPath = Get-LctDrvServiceKeyPath -Name $Name
    $exists = $false
    try { $exists = [bool](Test-Path -LiteralPath $keyPath) } catch { $exists = $false }
    $rawType = -1
    $rawStart = -1
    $imageRaw = ''
    $display = ''
    $objectName = ''
    $group = ''
    $readError = ''
    if ($exists) {
        try {
            $k = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            if ($null -ne $k) {
                if ($null -ne $k.PSObject.Properties['Type']) { try { $rawType = [int]$k.Type } catch { $rawType = -1 } }
                if ($null -ne $k.PSObject.Properties['Start']) { try { $rawStart = [int]$k.Start } catch { $rawStart = -1 } }
                if ($null -ne $k.PSObject.Properties['ImagePath']) { $imageRaw = [string]$k.ImagePath }
                if ($null -ne $k.PSObject.Properties['DisplayName']) { $display = [string]$k.DisplayName }
                if ($null -ne $k.PSObject.Properties['ObjectName']) { $objectName = [string]$k.ObjectName }
                if ($null -ne $k.PSObject.Properties['Group']) { $group = [string]$k.Group }
            }
        } catch { $readError = $_.Exception.Message }
    }
    return [pscustomobject][ordered]@{
        name        = $Name
        keyPath     = $keyPath
        exists      = $exists
        type        = $rawType
        typeText    = (Get-LctDrvTypeText -Type $rawType)
        start       = $rawStart
        startMode   = (Get-LctDrvStartText -Start $rawStart)
        imagePath   = $imageRaw
        localPath   = (ConvertTo-LctDrvLocalPath -ImagePath $imageRaw)
        displayName = $display
        objectName  = $objectName
        group       = $group
        readError   = $readError
    }
}

function Get-LctDrvCimDriver {
    param([string]$Name = '')
    if (-not (Test-LctDrvServiceName -Name $Name)) { return $null }
    try {
        $d = Get-CimInstance -ClassName Win32_SystemDriver -Filter ("Name='" + $Name + "'") -ErrorAction Stop
        if ($null -eq $d) { return $null }
        return $d
    } catch { return $null }
}

function Get-LctDrvCimStateMap {
    # 一次拉全（446 项 ~0.5s），避免逐条 CIM 查询
    $map = @{}
    $total = 0
    $err = ''
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop)) {
            $total++
            if ($null -ne $d.Name) { $map[[string]$d.Name] = [string]$d.State }
        }
    } catch { $err = $_.Exception.Message }
    return [pscustomobject][ordered]@{ map = $map; total = $total; error = $err }
}
#endregion

#region 私有：原生工具（sc.exe / bcdedit.exe）调用与判定
function Invoke-LctDrvTool {
    # 捕获：退出码 + stdout + stderr + 合并原文。
    # 注意：sc.exe 的失败文本常在 stdout；PS 5.1 下 2>&1 会把原生 stderr 变成 ErrorRecord，
    # 所以两种流都收，message 用合并后的原文（不改写、不美化）。
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $outList = New-Object System.Collections.ArrayList
    $errList = New-Object System.Collections.ArrayList
    $exit = -1
    try {
        $raw = @(& $FilePath @Arguments 2>&1)
        $exit = [int]$LASTEXITCODE
        foreach ($item in $raw) {
            if ($null -eq $item) { continue }
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $t = ''
                try { $t = [string]$item.Exception.Message } catch { $t = '' }
                if ([string]::IsNullOrWhiteSpace($t)) { try { $t = [string]$item.ToString() } catch { $t = '' } }
                $null = $errList.Add($t)
            } else {
                $null = $outList.Add([string]$item)
            }
        }
    } catch {
        $exit = -1
        $null = $errList.Add([string]$_.Exception.Message)
    } finally {
        $ErrorActionPreference = $prev
    }
    $stdoutText = ((@($outList) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $stderrText = ((@($errList) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $merged = $stdoutText
    if (-not [string]::IsNullOrEmpty($stderrText)) {
        if ([string]::IsNullOrWhiteSpace($merged)) { $merged = $stderrText } else { $merged = $merged + "`n" + $stderrText }
    }
    return [pscustomobject][ordered]@{
        file      = $FilePath
        arguments = @($Arguments)
        exitCode  = $exit
        stdout    = $stdoutText
        stderr    = $stderrText
        message   = $merged
    }
}

function ConvertTo-LctDrvExitHint {
    param([int]$Code = 0)
    $key = [string]$Code
    if ($script:LctDrvCodeHint.ContainsKey($key)) { return [string]$script:LctDrvCodeHint[$key] }
    return ''
}

function New-LctDrvVerdict {
    # 统一判定对象：exitCode / message（系统原文）/ osBlocked。
    # applied=true 只代表我们执行了动作；系统是否接受，看这里。
    param(
        [string]$Action = '',
        $Tool = $null,
        [switch]$OsBlocked,
        [string]$GoalMet = '',
        [string]$Extra = ''
    )
    $code = -1
    $msg = ''
    $stdoutText = ''
    $stderrText = ''
    if ($null -ne $Tool) {
        try { $code = [int]$Tool.exitCode } catch { $code = -1 }
        $msg = [string]$Tool.message
        $stdoutText = [string]$Tool.stdout
        $stderrText = [string]$Tool.stderr
    }
    $hex = ''
    if ($code -lt 0) { $hex = '0x' + ('{0:X8}' -f ([int64]$code + 4294967296)) }
    return [pscustomobject][ordered]@{
        action         = $Action
        exitCode       = $code
        exitCodeHex    = $hex
        message        = $msg
        stdout         = $stdoutText
        stderr         = $stderrText
        osBlocked      = [bool]$OsBlocked
        systemAccepted = ($code -eq 0)
        hint           = (ConvertTo-LctDrvExitHint -Code $code)
        goalMet        = $GoalMet
        note           = $Extra
    }
}

function Get-LctDrvCreateArguments {
    # 实测：必须是分离 token；sc.exe 会自行规范成 '\??\<abs>'。
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$BinPath, [string]$StartType = 'demand')
    return @('create', $Name, 'type=', 'kernel', 'binPath=', $BinPath, 'start=', $StartType)
}
#endregion

#region 私有：文件哈希 / 签名摘要（**仅信息，不作为门槛**）
function Get-LctDrvSignatureSummary {
    param([AllowEmptyString()][string]$Path = '')
    $o = [ordered]@{
        status = ''
        statusMessage = ''
        signerSubject = ''
        signerThumbprint = ''
        signerNotBefore = ''
        signerNotAfter = ''
        signatureClass = 'unknown'
        isMicrosoftSigner = $false
        likelyTestSigned = $false
        isSelfSigned = $false
        error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $o.error = '空路径'; return [pscustomobject]$o }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($null -ne $sig) {
            $o.status = [string]$sig.Status
            $o.statusMessage = [string]$sig.StatusMessage
            $cert = $sig.SignerCertificate
            if ($null -ne $cert) {
                $o.signerSubject = [string]$cert.Subject
                $o.signerThumbprint = [string]$cert.Thumbprint
                try { $o.signerNotBefore = $cert.NotBefore.ToString('s') } catch { }
                try { $o.signerNotAfter = $cert.NotAfter.ToString('s') } catch { }
            }
        }
    } catch {
        $o.error = $_.Exception.Message
    }
    $subj = [string]$o.signerSubject
    if ($subj -match '(?i)Microsoft') { $o.isMicrosoftSigner = $true }
    $st = [string]$o.status
    if ([string]::IsNullOrWhiteSpace($subj)) {
        if ($st -eq 'NotSigned') { $o.signatureClass = 'unsigned' }
        elseif ($st -eq 'UnknownError' -or $st -eq '') { $o.signatureClass = 'not-a-valid-image-or-unsigned' }
        else { $o.signatureClass = 'untrusted-no-cert' }
    } else {
        # 自签判定：Subject == Issuer，或链状态为 UntrustedRoot / NotTrusted。
        # 只有「自签」才算 test-signing；正规厂商证书（如 MICRO-STAR 走 GlobalSign 链、时间戳有效）
        # 必须归为 valid-vendor —— 不能因为「非微软」就误标成 test-signed（实测踩过：RTCore64 被误报）。
        $isSelfSigned = $false
        if ($null -ne $cert) {
            try { if ([string]$cert.Subject -eq [string]$cert.Issuer) { $isSelfSigned = $true } } catch { }
            if (-not $isSelfSigned -and $null -ne $sig) {
                try {
                    foreach ($csItem in @($sig.ChainStatus)) {
                        if ([string]$csItem.Status -match '(?i)^(UntrustedRoot|NotTrusted|PartialChain)$') { $isSelfSigned = $true; break }
                        if ([string]$csItem.StatusInformation -match '(?i)untrusted root|not trusted root') { $isSelfSigned = $true; break }
                    }
                } catch { }
            }
        }
        $o.isSelfSigned = $isSelfSigned
        if ($st -eq 'Valid') {
            if ($o.isMicrosoftSigner) { $o.signatureClass = 'microsoft-signed' }
            elseif ($isSelfSigned) { $o.signatureClass = 'valid-self-signed（test-signing 自签证书）'; $o.likelyTestSigned = $true }
            else { $o.signatureClass = 'valid-vendor（正规厂商签名，证书链受信）' }
        } else {
            $o.signatureClass = 'signed-but-not-trusted（自签 / 测试签名 / 链不受信）'
            $o.likelyTestSigned = $true
        }
    }
    return [pscustomobject]$o
}

function Get-LctDrvFileInfoInternal {
    param([AllowEmptyString()][string]$Path = '')
    $o = [ordered]@{
        path = $Path
        fullPath = ''
        exists = $false
        isFile = $false
        extension = ''
        lengthBytes = 0
        lastWrite = ''
        sha256 = ''
        isSysExtension = $false
        signatureClass = 'unknown'
        signatureStatus = ''
        signatureStatusMessage = ''
        signerSubject = ''
        signerThumbprint = ''
        signerNotBefore = ''
        signerNotAfter = ''
        isMicrosoftSigner = $false
        likelyTestSigned = $false
        note = '签名摘要仅作信息展示，**不作为加载门槛**（未签名镜像照样交给系统判定）'
        error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $o.error = '缺少路径'; return [pscustomobject]$o }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $o.exists = $true
        $o.fullPath = [string]$item.FullName
        $o.isFile = (-not $item.PSIsContainer)
        $o.extension = [string]$item.Extension
        $o.isSysExtension = ($o.extension -ieq '.sys')
        if ($o.isFile) {
            $o.lengthBytes = [long]$item.Length
            $o.lastWrite = $item.LastWriteTime.ToString('s')
        }
    } catch {
        $o.error = $_.Exception.Message
        return [pscustomobject]$o
    }
    if ($o.isFile) {
        try { $o.sha256 = [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $o.sha256 = '' }
        $sig = Get-LctDrvSignatureSummary -Path $Path
        $o.signatureClass = $sig.signatureClass
        $o.signatureStatus = $sig.status
        $o.signatureStatusMessage = $sig.statusMessage
        $o.signerSubject = $sig.signerSubject
        $o.signerThumbprint = $sig.signerThumbprint
        $o.signerNotBefore = $sig.signerNotBefore
        $o.signerNotAfter = $sig.signerNotAfter
        $o.isMicrosoftSigner = $sig.isMicrosoftSigner
        $o.likelyTestSigned = $sig.likelyTestSigned
    $o.isSelfSigned = $sig.isSelfSigned
        if (-not [string]::IsNullOrEmpty([string]$sig.error)) { $o.error = $sig.error }
    }
    return [pscustomobject]$o
}
#endregion

#region 私有：系统前提探测（Secure Boot / bcdedit / DeviceGuard）
function Get-LctDrvSecureBoot {
    $val = $null
    $src = 'unknown'
    $note = ''
    try {
        $val = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
        $src = 'Confirm-SecureBootUEFI'
    } catch { $note = $_.Exception.Message }
    if ($null -eq $val) {
        try {
            $k = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop
            if ($null -ne $k) {
                $val = ([int]$k.UEFISecureBootEnabled -eq 1)
                $src = 'registry UEFISecureBootEnabled'
            }
        } catch { if ([string]::IsNullOrEmpty($note)) { $note = $_.Exception.Message } }
    }
    if ($null -eq $val) { $src = 'unavailable' }
    return [pscustomobject][ordered]@{ value = $val; source = $src; error = $note }
}

function Get-LctDrvBcdSetting {
    # 优先 bcdedit /enum {current}（按行解析），失败则退到 SystemStartOptions。
    param([Parameter(Mandatory)][string]$Key)
    $vals = New-Object System.Collections.ArrayList
    $sources = New-Object System.Collections.ArrayList
    $raw = New-Object System.Collections.ArrayList
    $toolMsg = ''
    $exit = -1
    try {
        $t = Invoke-LctDrvTool -FilePath (Get-LctDrvBcdeditExe) -Arguments @('/enum', '{current}')
        $exit = [int]$t.exitCode
        $toolMsg = [string]$t.message
        if ($exit -eq 0) {
            foreach ($line in @([string]$t.stdout -split "`n")) {
                $ln = ([string]$line).Trim()
                if ($ln -match ('(?i)^' + [regex]::Escape($Key) + '\s+(\S+)')) {
                    $null = $vals.Add([string]$Matches[1])
                    $null = $sources.Add('bcdedit')
                    $null = $raw.Add($ln)
                }
            }
        }
    } catch { $toolMsg = $_.Exception.Message }
    if ($vals.Count -eq 0) {
        try {
            $v = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name SystemStartOptions -ErrorAction Stop
            if ($null -ne $v) {
                $sso = ([string]$v.SystemStartOptions).Trim()
                $null = $raw.Add('SystemStartOptions = ' + $sso)
                if ($Key -ieq 'testsigning' -and $sso -match '(?i)\bTESTSIGNING\b') {
                    $null = $vals.Add('Yes'); $null = $sources.Add('SystemStartOptions')
                } elseif ($Key -ieq 'nointegritychecks' -and $sso -match '(?i)\bNOINTEGRITYCHECKS\b') {
                    $null = $vals.Add('Yes'); $null = $sources.Add('SystemStartOptions')
                }
            }
        } catch { }
    }
    $value = ''
    $source = 'unknown'
    if ($vals.Count -gt 0) {
        $value = [string]$vals[$vals.Count - 1]
        $source = [string]$sources[$sources.Count - 1]
    } elseif ($exit -eq 0) {
        $value = 'No'
        $source = 'bcdedit(未列出=缺省 No)'
    }
    return [pscustomobject][ordered]@{
        key = $Key
        value = $value
        source = $source
        rawLines = @($raw)
        bcdeditExitCode = $exit
        bcdeditMessage = $toolMsg
    }
}

function Get-LctDrvDeviceGuard {
    $o = [ordered]@{
        available = $false
        vbsStatus = -1
        vbsStatusText = 'unknown'
        securityServicesRunning = @()
        securityServicesConfigured = @()
        hvciRunning = $false
        hvciConfigured = $false
        error = ''
    }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($null -ne $dg) {
            $o.available = $true
            try { $o.vbsStatus = [int]$dg.VirtualizationBasedSecurityStatus } catch { $o.vbsStatus = -1 }
            $o.securityServicesRunning = @($dg.SecurityServicesRunning)
            $o.securityServicesConfigured = @($dg.SecurityServicesConfigured)
            $o.hvciRunning = (@($dg.SecurityServicesRunning) -contains 2)
            $o.hvciConfigured = (@($dg.SecurityServicesConfigured) -contains 2)
        }
    } catch { $o.error = $_.Exception.Message }
    if ($o.vbsStatus -eq 0) { $o.vbsStatusText = '0 = 未启用' }
    elseif ($o.vbsStatus -eq 1) { $o.vbsStatusText = '1 = 已启用但未运行' }
    elseif ($o.vbsStatus -eq 2) { $o.vbsStatusText = '2 = 已启用并运行' }
    if (-not $o.available) {
        try {
            $hi = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name Enabled -ErrorAction Stop
            if ($null -ne $hi) { $o.hvciConfigured = ([int]$hi.Enabled -eq 1) }
        } catch { }
    }
    return [pscustomobject]$o
}

function Test-LctDrvTestSigningGate {
    # 纯判定函数（可被测试直接调用）：Secure Boot=True 时**拒绝开启** test-signing。
    param([string]$Action = 'enable', $SecureBoot = $null)
    $blocked = (($Action -eq 'enable') -and ($SecureBoot -eq $true))
    $reason = '允许（未命中协议禁止项）'
    if ($blocked) { $reason = 'Secure Boot=True：UEFI 会校验启动路径上的镜像签名，开启 test-signing 不被允许（协议拒绝）' }
    return [pscustomobject][ordered]@{
        action     = $Action
        secureBoot = $SecureBoot
        allowed    = (-not $blocked)
        reason     = $reason
    }
}

function Get-LctDrvSelfManagedServices {
    # 自管服务 = 名称以 lctdrv 开头的服务项（本工具创建；契约 §12.2 实测该前缀无占用）
    $items = New-Object System.Collections.ArrayList
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
            $nm = [string]$k.PSChildName
            if ($nm -notlike ($script:LctDrvSelfPrefix + '*')) { continue }
            $reg = Get-LctDrvServiceRegistration -Name $nm
            $cim = Get-LctDrvCimDriver -Name $nm
            $state = 'unknown'
            if ($null -ne $cim) { $state = [string]$cim.State }
            $null = $items.Add([pscustomobject][ordered]@{
                    name      = $nm
                    state     = $state
                    startMode = $reg.startMode
                    typeText  = $reg.typeText
                    imagePath = $reg.imagePath
                    keyPath   = $reg.keyPath
                })
        }
    } catch { }
    return @($items)
}
#endregion

#region 导出：只读 getter
function Get-LctDrvElevationMessage {
    # 未提权时的统一提示：不只要说"需要管理员权限"，还要给出**动作顺序**（先提权、再加载驱动）。
    # 依赖 Capabilities 模块时给出精确的完整性级别与完整指引；模块缺失时退化但仍保留顺序说明。
    param([AllowEmptyString()][string]$Action = '加载驱动')
    $integ = 'Unknown'
    try { $integ = [string](Get-LctCapIntegrityLevel).name } catch { }
    try {
        $gate = Test-LctCapabilityDriverLoad -IsAdmin $false -Action $Action -IntegrityName $integ
        if ($null -ne $gate -and [string]$gate.hint -ne '') {
            return ([string]$gate.message + '；本次未做任何改动。' + [string]$gate.hint)
        }
    } catch { }
    return ('需要管理员/SYSTEM 权限才能' + $Action + '：当前进程是' + $integ + '（未提权）；本次未做任何改动。' +
        '本工具默认以普通权限运行，无法注册/启动内核驱动 —— 请**先**用「提权」路线（把漏洞组件当插件加载，例如 plugins\cve-2026-49176）' +
        '把自己提升到管理员/SYSTEM，**再**回到本工具执行该操作；顺序不能反。')
}

function Get-LctDriverStatus {
    # 只读：Secure Boot / testsigning / nointegritychecks / VBS·HVCI / 驱动总数与运行数 / 自管服务
    $verb = 'driver.status'
    $secureBoot = Get-LctDrvSecureBoot
    $ts = Get-LctDrvBcdSetting -Key 'testsigning'
    $nic = Get-LctDrvBcdSetting -Key 'nointegritychecks'
    $dg = Get-LctDrvDeviceGuard
    $cim = Get-LctDrvCimStateMap
    $running = 0
    foreach ($stateVal in @($cim.map.Values)) { if ([string]$stateVal -ieq 'Running') { $running++ } }
    $self = @(Get-LctDrvSelfManagedServices)
    $driversDir = Get-LctDrvSystemDriversDir
    $dirExists = $false
    try { $dirExists = [bool](Test-Path -LiteralPath $driversDir -PathType Container) } catch { $dirExists = $false }
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    $bcdLines = @()
    $bcdLines += @($ts.rawLines)
    foreach ($l in @($nic.rawLines)) { if ($bcdLines -notcontains $l) { $bcdLines += $l } }
    try { Write-LctDrvLog -Verb $verb -Level info -Message '读取驱动加载前提状态' -Data @{ testSigning = $ts.value; secureBoot = $secureBoot.value; driverTotal = $cim.total; driverRunning = $running } | Out-Null } catch { }

    return [pscustomobject][ordered]@{
        checkedAt              = (Get-Date).ToString('s')
        elevated               = $elevated
        secureBoot             = $secureBoot.value
        secureBootSource       = $secureBoot.source
        secureBootProbeError   = $secureBoot.error
        testSigning            = $ts.value
        testSigningSource      = $ts.source
        testSigningBcdLines    = @($ts.rawLines)
        testSigningNote        = 'bcdedit /enum {current} 的原文见 testSigningBcdLines；本机实测 2026-10-26 testsigning=Yes（无需重启即生效）'
        noIntegrityChecks      = $nic.value
        noIntegrityChecksSource = $nic.source
        bcdeditRawLines        = @($bcdLines)
        bcdeditExitCode        = $ts.bcdeditExitCode
        bcdeditMessage         = $ts.bcdeditMessage
        vbs                    = [pscustomobject][ordered]@{
            available                 = $dg.available
            status                    = $dg.vbsStatus
            statusText                = $dg.vbsStatusText
            securityServicesRunning   = @($dg.securityServicesRunning)
            securityServicesConfigured = @($dg.securityServicesConfigured)
            hvciRunning               = $dg.hvciRunning
            hvciConfigured            = $dg.hvciConfigured
            error                     = $dg.error
        }
        driverTotal            = $cim.total
        driverRunning          = $running
        cimError               = $cim.error
        driversDirectory       = $driversDir
        driversDirectoryExists = $dirExists
        driversDirectoryWritable = $null
        driversDirectoryWritableNote = '未探测（只读 getter 不写盘）；契约 §12.2 实测可写=True（本机前提，不重复探测）'
        selfManagedPrefix      = $script:LctDrvSelfPrefix
        selfManagedServices    = @($self)
        selfManagedCount       = @($self).Count
        limitations            = @(
            '本工具不做签名 / 状态前瞻校验：未签名或无效镜像照样交给系统判定，原文照抄回传',
            '驱动服务清单以注册表 Services 键为权威：从未成功启动过的驱动不会出现在 Win32_SystemDriver 里'
        )
    }
}

function Get-LctDriverList {
    # 驱动服务清单（仅信息：state / startMode / sha256 / 签名摘要）
    # 注意：形参必须写成 param()（简单函数里漏了 param 的话，-Name 会被自动变量 $args 顶掉而静默为空）
    param([AllowEmptyString()][string]$Name = '')
    $verb = 'driver.list'
    $filterRaw = ([string]$Name).Trim()
    $filterOk = $true
    $err = ''
    if ($filterRaw -ne '' -and -not ($filterRaw -match '^[A-Za-z0-9_.\-*?]+$')) {
        $filterOk = $false
        $err = '服务名过滤串含非法字符（只允许字母数字与 _ . - * ?）：' + $filterRaw
    }
    $cim = Get-LctDrvCimStateMap
    if (-not [string]::IsNullOrEmpty([string]$cim.error) -and [string]::IsNullOrEmpty($err)) { $err = 'Win32_SystemDriver 枚举失败：' + $cim.error }
    $all = New-Object System.Collections.ArrayList
    $total = 0
    if ($filterOk) {
        try {
            foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Sort-Object PSChildName)) {
                $nm = [string]$k.PSChildName
                $reg = Get-LctDrvServiceRegistration -Name $nm
                if ($reg.type -lt 0) { continue }
                $isDriver = ((($reg.type -band 1) -eq 1) -or (($reg.type -band 2) -eq 2))
                if (-not $isDriver) { continue }
                $total++
                if ($filterRaw -ne '') {
                    if ($filterRaw -match '[\*\?]') { if ($nm -notlike $filterRaw) { continue } }
                    elseif ($nm -ine $filterRaw) { continue }
                }
                $state = 'stopped'
                if ($cim.map.ContainsKey($nm)) { $state = [string]$cim.map[$nm] }
                $null = $all.Add([pscustomobject][ordered]@{
                        name             = $nm
                        state            = $state
                        startMode        = $reg.startMode
                        type             = $reg.type
                        typeText         = $reg.typeText
                        path             = $reg.localPath
                        imagePathRaw     = $reg.imagePath
                        keyPath          = $reg.keyPath
                        sha256           = ''
                        signatureClass   = ''
                        signatureStatus  = ''
                        signerSubject    = ''
                        likelyTestSigned = $false
                        infoChecked      = $false
                    })
            }
        } catch {
            if (-not $err) { $err = '枚举服务注册表失败：' + $_.Exception.Message }
        }
    }
    # 全量签名核验实测 ~9s/446 项（只读信息，不值得每次页面刷新都付这个代价）：
    # 仅在「有过滤」或「条目数 <= 60」时核验 sha256 + 签名摘要。
    $infoChecked = 0
    if (@($all).Count -le 60) {
        for ($i = 0; $i -lt @($all).Count; $i++) {
            $p = [string]$all[$i].path
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try {
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
                $all[$i].sha256 = [string](Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash
                $sig = Get-LctDrvSignatureSummary -Path $p
                $all[$i].signatureClass = [string]$sig.signatureClass
                $all[$i].signatureStatus = [string]$sig.status
                $all[$i].signerSubject = [string]$sig.signerSubject
                $all[$i].likelyTestSigned = [bool]$sig.likelyTestSigned
                $all[$i].infoChecked = $true
                $infoChecked++
            } catch { }
        }
    }
    try { Write-LctDrvLog -Verb $verb -Level info -Message ('列出驱动服务 filter=' + $filterRaw) -Data @{ count = @($all).Count; total = $total; infoChecked = $infoChecked } | Out-Null } catch { }

    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    return [pscustomobject][ordered]@{
        items          = @($all)
        count          = @($all).Count
        total          = $total
        filtered       = ($filterRaw -ne '')
        filter         = $filterRaw
        infoChecked    = $infoChecked
        infoSkipped    = (@($all).Count - $infoChecked)
        infoPolicy     = 'sha256/签名摘要仅在「有过滤」或「条目数 <= 60」时核验（全量签名核验实测 ~9s/446 项）；签名只是信息，不作为加载门槛'
        cimDriverTotal = $cim.total
        driversDirectory = (Get-LctDrvSystemDriversDir)
        elevated       = $elevated
        error          = $err
        note           = '清单以注册表 Services 键为权威（Win32_SystemDriver 不列出从未成功启动过的驱动服务）'
    }
}

function Get-LctDriverFileInfo {
    # 单个 .sys 的 hash + 签名摘要（仅信息，不作为门槛；无效文件也不崩）
    # 注意：形参必须写成 param()（简单函数里漏了 param 的话，-Path 会被自动变量 $args 顶掉而静默为空）
    param([AllowEmptyString()][string]$Path = '')
    $info = Get-LctDrvFileInfoInternal -Path $Path
    try { Write-LctDrvLog -Verb 'driver.info' -Level info -Message '读取驱动文件信息' -Data @{ path = [string]$Path; exists = $info.exists; sha256 = $info.sha256; signatureStatus = $info.signatureStatus } | Out-Null } catch { }
    return $info
}
#endregion

#region 导出：动作（默认预览，-Apply 才真做）
function Load-LctDriver {
    # 主功能：注册（若不存在）+ 启动。返回 SCM 真实结果与错误原文。
    param(
        [AllowEmptyString()][string]$Path = '',
        [AllowEmptyString()][string]$Name = '',
        [AllowEmptyString()][string]$StartType = '',
        [switch]$Stage,
        [switch]$Override,
        [switch]$Apply
    )
    $verb = 'driver.load'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    $backupId = ''
    $createVerdict = $null
    $startVerdict = $null
    $stopVerdict = $null
    $deleteVerdict = $null
    $didAnything = $false
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }

    # ---- 1) 路径（唯一的前置检查是「文件在不在」，不做签名/状态前瞻）----
    $fullPath = ''
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 -Path：请给出 .sys 的路径')
    } else {
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $fullPath = [string](Resolve-Path -LiteralPath $Path).ProviderPath
            } elseif (Test-Path -LiteralPath $Path) {
                $null = $errors.Add('给定路径是目录而不是文件：' + $Path)
            } else {
                $null = $errors.Add('驱动文件不存在：' + $Path)
            }
        } catch { $null = $errors.Add('解析路径失败：' + $_.Exception.Message) }
    }
    $ext = ''
    if ($fullPath -ne '') { try { $ext = [string][IO.Path]::GetExtension($fullPath) } catch { $ext = '' } }
    if ($fullPath -ne '' -and $ext -ine '.sys') {
        $null = $warnings.Add('扩展名不是 .sys（实际 ' + $ext + '）：内核驱动通常是 .sys；本工具不代替系统判定，仍按给定文件加载')
    }

    # ---- 2) 服务名 ----
    $nm = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($nm) -and $fullPath -ne '') {
        try { $nm = [string][IO.Path]::GetFileNameWithoutExtension($fullPath) } catch { $nm = '' }
        if ($nm -ne '') { $null = $warnings.Add('未指定 -Name：按文件名推导服务名 = ' + $nm) }
    }
    $nameOk = (Test-LctDrvServiceName -Name $nm)
    if ($fullPath -ne '' -and -not $nameOk) {
        $null = $errors.Add('服务名非法或为空：' + $nm + '（只允许字母数字与 _ . -，长度 1..128）')
    }

    # ---- 3) 启动类型（system/boot = 开机即载高危路径，必须 -Override）----
    $st = ([string]$StartType).Trim().ToLower()
    if ($st -eq '') { $st = 'demand' }
    if ($script:LctDrvStartAllowed -notcontains $st) {
        $null = $errors.Add('非法 -StartType "' + $StartType + '"：只允许 demand / system / boot / auto')
    }
    if (($st -eq 'boot' -or $st -eq 'system') -and (-not $Override)) {
        $null = $errors.Add('启动类型 ' + $st + ' 会让驱动在开机早期即被加载（蓝屏 / 无法启动的高危路径），必须显式 -Override 才允许')
    }
    if (($st -eq 'boot' -or $st -eq 'system') -and $Override) {
        $null = $warnings.Add('[高危] 启动类型=' + $st + '：开机即载；若加载失败或与内核不兼容，可能直接蓝屏 / 系统无法启动。回滚需高级启动选项（F8）或 WinRE 离线删除服务项。')
    }

    # ---- 4) 同名服务冲突（默认拒绝；-Override 才覆盖，且先备份）----
    $reg = $null
    if ($nameOk) {
        $reg = Get-LctDrvServiceRegistration -Name $nm
        if ($reg.exists -and (-not $Override)) {
            $null = $errors.Add('同名服务已存在：' + $nm + '（Type=' + $reg.typeText + ' / Start=' + $reg.startMode + ' / ImagePath=' + $reg.imagePath + '）⇒ 默认拒绝覆盖；确需覆盖请显式 -Override（覆盖前会先把该服务注册表键导出为备份）')
        } elseif ($reg.exists -and $Override) {
            $null = $warnings.Add('-Override：将覆盖既有服务 ' + $nm + '（先 sc stop / sc delete，再重建；原注册表键会先写入备份，重建失败会自动尝试回滚）')
        }
    }

    # ---- 5) 目标镜像路径（-Stage = 先复制到 System32\drivers）----
    $stagedName = ''
    $stagedPath = ''
    $binPath = $fullPath
    $stagedExists = $false
    if ($fullPath -ne '' -and $Stage) {
        try {
            $stagedName = [string][IO.Path]::GetFileName($fullPath)
            $stagedPath = Join-Path (Get-LctDrvSystemDriversDir) $stagedName
            $binPath = $stagedPath
            $stagedExists = [bool](Test-Path -LiteralPath $stagedPath -PathType Leaf)
        } catch { $null = $errors.Add('计算暂存路径失败：' + $_.Exception.Message) }
        if ($stagedPath -ine $fullPath) {
            if ($stagedExists -and (-not $Override)) {
                $null = $errors.Add('-Stage 目标已存在同名文件：' + $stagedPath + '（覆盖它需要 -Override；原文件会先复制进备份目录）')
            } elseif ($stagedExists -and $Override) {
                $null = $warnings.Add('-Stage 将覆盖 System32\drivers 下已存在的同名 .sys（原文件先复制进备份目录）：' + $stagedPath)
            }
        } elseif ($stagedPath -ne '') {
            $null = $warnings.Add('-Stage：源文件已在 System32\drivers 内，无需复制，就地注册')
        }
    }
    if ($Apply -and (-not $elevated)) {
        $null = $errors.Add((Get-LctDrvElevationMessage -Action '注册 / 启动内核驱动服务'))
    }

    # ---- 6) 计划与预览 ----
    if ($errors.Count -eq 0) {
        if ($Stage -and $stagedPath -ne '' -and ($stagedPath -ine $fullPath)) { $null = $plan.Add('copy "' + $fullPath + '" -> "' + $stagedPath + '"') }
        if ($reg.exists) { $null = $plan.Add('sc.exe stop ' + $nm + '   ; sc.exe delete ' + $nm + '   (覆盖既有服务)') }
        $createArgs = Get-LctDrvCreateArguments -Name $nm -BinPath $binPath -StartType $st
        $null = $plan.Add('sc.exe ' + ((@($createArgs) | ForEach-Object { Format-LctDrvToken -Token ([string]$_) }) -join ' '))
        $null = $plan.Add('sc.exe start ' + $nm)
    }
    $beforeText = '(无此服务)'
    if ($null -ne $reg -and $reg.exists) { $beforeText = '已存在：Type=' + $reg.typeText + ' Start=' + $reg.startMode + ' ImagePath=' + $reg.imagePath }
    $null = $changes.Add((New-LctDrvChange -Target $nm -Name 'service' -Before $beforeText -After ('type= kernel, start= ' + $st + ', binPath= ' + $binPath) -Note 'sc.exe create'))
    $null = $changes.Add((New-LctDrvChange -Target $nm -Name 'start' -Before '(未启动)' -After 'sc.exe start（是否成功以系统返回为准）' -Note 'sc.exe start'))

    $dataBase = [ordered]@{
        name        = $nm
        path        = $fullPath
        binPath     = $binPath
        staged      = [bool]$Stage
        stagedPath  = $stagedPath
        startType   = $st
        override    = [bool]$Override
        elevated    = $elevated
        serviceKeyPath = ''
        serviceBefore = $reg
        plan        = @($plan)
        applied     = $false
        backupId    = ''
        limitations = @(
            '本工具不校验签名、不校验镜像有效性：未签名 / 无效镜像由系统在启动阶段拒绝，原文照抄回传',
            'applied=true 只表示本工具执行了动作；驱动是否真的被系统接受并运行以 data.verdict 与 driver.verify 为准'
        )
    }
    if ($reg -and $reg.exists -and ($st -eq 'boot' -or $st -eq 'system')) { $dataBase['riskNote'] = '开机即载高危路径（-Override 已确认）' }
    if ($nameOk) { $dataBase['serviceKeyPath'] = Get-LctDrvServiceKeyPath -Name $nm }

    if (-not $Apply) {
        $previewData = [ordered]@{}
        foreach ($k in $dataBase.Keys) { $previewData[$k] = $dataBase[$k] }
        $previewData['verdict'] = $null
        $previewData['verdictNote'] = '预览：未执行任何 sc.exe 动作'
        $previewData['serviceAfter'] = $null
        try { Write-LctDrvLog -Verb $verb -Level info -Message ('预览加载驱动 ' + $nm) -Data @{ name = $nm; path = $fullPath; binPath = $binPath; startType = $st; stage = [bool]$Stage; override = [bool]$Override; errors = @($errors) } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$previewData)
    }

    # ---- 7) 真的做 ----
    # 7.1 备份（覆盖既有服务 / 覆盖既有暂存文件时）
    if ($errors.Count -eq 0 -and ($reg.exists -or ($stagedExists -and $Override -and ($stagedPath -ine $fullPath)))) {
        try {
            $regPaths = @()
            if ($reg.exists) { $regPaths = @($reg.keyPath) }
            $bk = New-LctBackup -Verb $verb -Args @{ name = $nm; path = $fullPath; binPath = $binPath; startType = $st } -RegistryPaths $regPaths
            $backupId = [string]$bk.id
            $null = $warnings.Add('覆盖前已备份：backupId=' + $backupId + '（目录 ' + [string]$bk.dir + '）')
            if ($stagedExists -and $Override -and ($stagedPath -ine $fullPath)) {
                $filesDir = Ensure-LctDrvDir -Path (Join-Path ([string]$bk.dir) 'files')
                Copy-Item -LiteralPath $stagedPath -Destination (Join-Path $filesDir $stagedName) -Force
                $null = $warnings.Add('已存在同名 .sys 已复制进备份目录：' + (Join-Path $filesDir $stagedName) + '（本工具不会自动删文件）')
            }
        } catch {
            $null = $errors.Add('备份失败，已中止（没有备份就不做不可回滚的覆盖）：' + $_.Exception.Message)
        }
    }

    # 7.2 暂存复制
    if ($errors.Count -eq 0 -and $Stage -and $stagedPath -ne '' -and ($stagedPath -ine $fullPath)) {
        try {
            $null = Ensure-LctDrvDir -Path (Get-LctDrvSystemDriversDir)
            Copy-Item -LiteralPath $fullPath -Destination $stagedPath -Force
            $didAnything = $true
            $srcHash = ''
            $dstHash = ''
            try { $srcHash = [string](Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
            try { $dstHash = [string](Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
            if ([string]::IsNullOrEmpty($srcHash) -or $srcHash -ne $dstHash) {
                $null = $errors.Add('暂存复制校验失败（源 / 目标 SHA256 不一致）：' + $stagedPath)
            } else {
                $null = $changes.Add((New-LctDrvChange -Target $stagedPath -Name 'file' -Before ($(if ($stagedExists) { '已存在（已备份）' } else { '(无)' })) -After ('SHA256=' + $dstHash) -Note '复制到 System32\drivers'))
            }
        } catch { $null = $errors.Add('暂存复制失败：' + $_.Exception.Message) }
    }

    # 7.3 覆盖既有服务：先停后删
    if ($errors.Count -eq 0 -and $reg.exists) {
        $stopTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('stop', $nm)
        $didAnything = $true
        $stopGoal = '未达成'
        if ($stopTool.exitCode -eq 0) { $stopGoal = '已请求停止' }
        elseif ($stopTool.exitCode -eq 1062) { $stopGoal = '服务本来就未运行' }
        $stopVerdict = New-LctDrvVerdict -Action 'stop-existing' -Tool $stopTool -OsBlocked:($stopTool.exitCode -ne 0) -GoalMet $stopGoal
        if ($stopTool.exitCode -ne 0 -and $stopTool.exitCode -ne 1062) {
            $null = $warnings.Add('覆盖前 sc stop 未成功（exit=' + $stopTool.exitCode + '），继续尝试覆盖：' + (First-LctDrvLine -Text $stopTool.message))
        }
        $deleteTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('delete', $nm)
        $deleteVerdict = New-LctDrvVerdict -Action 'delete-existing' -Tool $deleteTool -OsBlocked:($deleteTool.exitCode -ne 0)
        if ($deleteTool.exitCode -ne 0) {
            $null = $errors.Add('覆盖前 sc delete 失败（exit=' + $deleteTool.exitCode + '）：' + (First-LctDrvLine -Text $deleteTool.message))
        } else {
            $null = $changes.Add((New-LctDrvChange -Target $nm -Name 'service' -Before ('Start=' + $reg.startMode + ' ImagePath=' + $reg.imagePath) -After '(已删除，准备重建)' -Note 'sc.exe delete（原键已备份 backupId=' + $backupId + '）'))
        }
    }

    # 7.4 注册
    if ($errors.Count -eq 0) {
        $createArgs = Get-LctDrvCreateArguments -Name $nm -BinPath $binPath -StartType $st
        $createTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments $createArgs
        $didAnything = $true
        $createVerdict = New-LctDrvVerdict -Action 'create' -Tool $createTool -OsBlocked:($createTool.exitCode -ne 0) -GoalMet ($(if ($createTool.exitCode -eq 0) { '服务项已创建' } else { '未创建' }))
        if ($createTool.exitCode -ne 0) {
            $null = $errors.Add('sc.exe create 失败（exit=' + $createTool.exitCode + '）：' + (First-LctDrvLine -Text $createTool.message))
            if ($backupId -ne '') {
                try {
                    $rb = Restore-LctBackup -Id $backupId -Apply
                    $null = $warnings.Add('已尝试用 backupId=' + $backupId + ' 回滚既有服务注册项（ok=' + [string]$rb.ok + '）：' + (First-LctDrvLine -Text (@($rb.errors) -join ' ') 120))
                } catch { $null = $warnings.Add('回滚既有服务注册项失败，请手工用备份目录里的 .reg 还原：' + $_.Exception.Message) }
            }
        } else {
            $null = $changes.Add((New-LctDrvChange -Target $nm -Name 'service' -Before '(不存在)' -After ('type= kernel, start= ' + $st + ', binPath= ' + $binPath) -Note 'sc.exe create 成功（系统原文照抄见 createVerdict.message）'))
        }
    }

    # 7.5 启动
    if ($errors.Count -eq 0) {
        $startTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('start', $nm)
        $didAnything = $true
        $startGoal = '动作已执行，系统在启动阶段拒绝（原文见 verdict.message）'
        if ($startTool.exitCode -eq 0) { $startGoal = '驱动已由系统接受并启动' }
        $startVerdict = New-LctDrvVerdict -Action 'start' -Tool $startTool -OsBlocked:($startTool.exitCode -ne 0) -GoalMet $startGoal
        $afterText = '启动成功'
        if ($startTool.exitCode -ne 0) { $afterText = '系统返回 exit=' + $startTool.exitCode + '：' + (First-LctDrvLine -Text $startTool.message) }
        $null = $changes.Add((New-LctDrvChange -Target $nm -Name 'start' -Before '(未启动)' -After $afterText -Note 'sc.exe start（原文照抄）'))
        if ($startTool.exitCode -ne 0) {
            $hint = ConvertTo-LctDrvExitHint -Code ([int]$startTool.exitCode)
            $warnText = '系统拒绝了驱动启动：exitCode=' + $startTool.exitCode + '；系统原文=' + (First-LctDrvLine -Text $startTool.message)
            if (-not [string]::IsNullOrEmpty($hint)) { $warnText += '；判定参考（非系统原文）=' + $hint }
            $null = $warnings.Add($warnText)
        }
    }

    # 7.6 收尾：复核服务项与最终判定
    $after = $null
    if ($nameOk) { $after = Get-LctDrvServiceRegistration -Name $nm }
    $verdict = $startVerdict
    if ($null -eq $verdict) { $verdict = $createVerdict }
    try {
        Write-LctDrvLog -Verb $verb -Level change -Message ('加载驱动动作已执行：' + $nm) -Data @{
            name = $nm; path = $fullPath; binPath = $binPath; startType = $st; stage = [bool]$Stage; override = [bool]$Override
            exitCode = $(if ($null -ne $verdict) { $verdict.exitCode } else { -1 }); osBlocked = $(if ($null -ne $verdict) { $verdict.osBlocked } else { $false })
            serviceExistsAfter = $(if ($null -ne $after) { $after.exists } else { $false }); backupId = $backupId; errors = @($errors)
        } | Out-Null
    } catch { }
    $applyData = [ordered]@{}
    foreach ($k in $dataBase.Keys) { $applyData[$k] = $dataBase[$k] }
    $applyData['applied'] = $didAnything
    $applyData['backupId'] = $backupId
    $applyData['verdict'] = $verdict
    $applyData['createVerdict'] = $createVerdict
    $applyData['startVerdict'] = $startVerdict
    $applyData['stopExistingVerdict'] = $stopVerdict
    $applyData['deleteExistingVerdict'] = $deleteVerdict
    $applyData['serviceAfter'] = $after
    $applyData['systemAccepted'] = $(if ($null -ne $verdict) { $verdict.systemAccepted } else { $false })
    return New-LctResult -Verb $verb -Applied:$didAnything -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data ([pscustomobject]$applyData)
}

function Start-LctDriver {
    # 只启动已有服务；回传 OS 判定原文
    param([AllowEmptyString()][string]$Name = '', [switch]$Apply)
    $verb = 'driver.start'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $st = ([string]$Name).Trim()
    if (-not (Test-LctDrvServiceName -Name $st)) {
        $null = $errors.Add('服务名非法或为空：' + $st)
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{ name = $st; verdict = $null; applied = $false })
    }
    $reg = Get-LctDrvServiceRegistration -Name $st
    if (-not $reg.exists) {
        $null = $errors.Add('服务不存在：' + $st + '（sc start 直接跑会是 1060 ' + (ConvertTo-LctDrvExitHint -Code 1060) + '；请先用 driver.load 注册）')
    }
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    if ($Apply -and $reg.exists -and (-not $elevated)) { $null = $errors.Add((Get-LctDrvElevationMessage -Action '启动驱动服务')) }
    $null = $changes.Add((New-LctDrvChange -Target $st -Name 'start' -Before ($(if ($reg.exists) { $reg.startMode + ' / ImagePath=' + $reg.imagePath } else { '(无此服务)' })) -After 'sc.exe start ' + $st -Note '原文照抄回传'))
    if (-not $Apply) {
        try { Write-LctDrvLog -Verb $verb -Level info -Message ('预览启动驱动 ' + $st) -Data @{ name = $st; exists = $reg.exists; errors = @($errors) } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                name = $st; serviceBefore = $reg; serviceAfter = $null; applied = $false; verdict = $null
                plan = @('sc.exe start ' + $st); elevated = $elevated
                limitations = @('是否真的启动成功以系统返回为准（data.verdict）')
            })
    }
    $verdict = $null
    $applied = $false
    if ($errors.Count -eq 0) {
        $tool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('start', $st)
        $applied = $true
        $goal = '动作已执行，系统在启动阶段拒绝（原文见 verdict.message）'
        if ($tool.exitCode -eq 0) { $goal = '驱动已由系统接受并启动' }
        $verdict = New-LctDrvVerdict -Action 'start' -Tool $tool -OsBlocked:($tool.exitCode -ne 0) -GoalMet $goal
        if ($tool.exitCode -ne 0) {
            $hint = ConvertTo-LctDrvExitHint -Code ([int]$tool.exitCode)
            $w = '系统拒绝了驱动启动：exitCode=' + $tool.exitCode + '；系统原文=' + (First-LctDrvLine -Text $tool.message)
            if (-not [string]::IsNullOrEmpty($hint)) { $w += '；判定参考（非系统原文）=' + $hint }
            $null = $warnings.Add($w)
        } else {
            $null = $warnings.Add('已启动（系统已接受）：' + (First-LctDrvLine -Text $tool.message))
        }
        try { Write-LctDrvLog -Verb $verb -Level change -Message ('启动驱动 ' + $st) -Data @{ name = $st; exitCode = $tool.exitCode; osBlocked = $verdict.osBlocked } | Out-Null } catch { }
    }
    $after = Get-LctDrvServiceRegistration -Name $st
    return New-LctResult -Verb $verb -Applied:$applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            name = $st; serviceBefore = $reg; serviceAfter = $after; applied = $applied; verdict = $verdict
            cimAfter = (Get-LctDrvCimDriver -Name $st); elevated = $elevated
            limitations = @('applied=true 只表示我们执行了 sc.exe start；是否真的运行以系统返回与 Service Control Manager 事件为准')
        })
}

function Stop-LctDriver {
    # 停止（不删服务项）
    param([AllowEmptyString()][string]$Name = '', [switch]$Apply)
    $verb = 'driver.stop'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $st = ([string]$Name).Trim()
    if (-not (Test-LctDrvServiceName -Name $st)) {
        $null = $errors.Add('服务名非法或为空：' + $st)
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{ name = $st; verdict = $null; applied = $false })
    }
    $reg = Get-LctDrvServiceRegistration -Name $st
    if (-not $reg.exists) { $null = $errors.Add('服务不存在：' + $st + '（sc stop 直接跑会是 1060 ' + (ConvertTo-LctDrvExitHint -Code 1060) + '）') }
    if (-not $Apply) {
        $null = $changes.Add((New-LctDrvChange -Target $st -Name 'stop' -Before ($reg.startMode + ' / ImagePath=' + $reg.imagePath) -After 'sc.exe stop ' + $st -Note '不删除服务项'))
        try { Write-LctDrvLog -Verb $verb -Level info -Message ('预览停止驱动 ' + $st) -Data @{ name = $st; errors = @($errors) } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                name = $st; serviceBefore = $reg; serviceAfter = $null; applied = $false; verdict = $null
                plan = @('sc.exe stop ' + $st); note = '停止不删除服务项，也不碰 .sys 文件'
            })
    }
    $verdict = $null
    $applied = $false
    if ($errors.Count -eq 0) {
        $tool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('stop', $st)
        $applied = $true
        $goal = '未达成'
        if ($tool.exitCode -eq 0) { $goal = '已请求停止' }
        elseif ($tool.exitCode -eq 1062) { $goal = '服务本来就未运行（目标状态已达成）' }
        $verdict = New-LctDrvVerdict -Action 'stop' -Tool $tool -OsBlocked:($tool.exitCode -ne 0) -GoalMet $goal
        if ($tool.exitCode -eq 0) {
            $null = $warnings.Add('已请求停止：' + (First-LctDrvLine -Text $tool.message))
        } else {
            $warnText = 'sc.exe stop 返回 exit=' + $tool.exitCode + '；系统原文=' + (First-LctDrvLine -Text $tool.message)
            if ($tool.exitCode -eq 1062) { $warnText += '；判定参考=服务未启动，目标状态已达成（不算失败）' }
            $null = $warnings.Add($warnText)
        }
        $null = $changes.Add((New-LctDrvChange -Target $st -Name 'stop' -Before ($reg.startMode + ' / ImagePath=' + $reg.imagePath) -After ('exit=' + $tool.exitCode + ' ' + (First-LctDrvLine -Text $tool.message 120)) -Note '不删除服务项'))
        try { Write-LctDrvLog -Verb $verb -Level change -Message ('停止驱动 ' + $st) -Data @{ name = $st; exitCode = $tool.exitCode; osBlocked = $verdict.osBlocked } | Out-Null } catch { }
    }
    $after = Get-LctDrvServiceRegistration -Name $st
    return New-LctResult -Verb $verb -Applied:$applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            name = $st; serviceBefore = $reg; serviceAfter = $after; applied = $applied; verdict = $verdict
            cimAfter = (Get-LctDrvCimDriver -Name $st)
        })
}

function Remove-LctDriverService {
    # 停止 + 删除服务项 + 生成 revert 产物；**绝不删 .sys 文件**
    param([AllowEmptyString()][string]$Name = '', [switch]$Apply)
    $verb = 'driver.unload'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $stopVerdict = $null
    $deleteVerdict = $null
    $st = ([string]$Name).Trim()
    if (-not (Test-LctDrvServiceName -Name $st)) {
        $null = $errors.Add('服务名非法或为空：' + $st)
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject][ordered]@{ name = $st; applied = $false; deleted = $false })
    }
    $reg = Get-LctDrvServiceRegistration -Name $st
    if (-not $reg.exists) { $null = $errors.Add('服务项不存在：' + $st + '（没有可卸载的服务项；sc delete 直接跑会是 1060 ' + (ConvertTo-LctDrvExitHint -Code 1060) + '）') }
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    if ($Apply -and $reg.exists -and (-not $elevated)) { $null = $errors.Add((Get-LctDrvElevationMessage -Action '停止 / 删除驱动服务项')) }
    $fileExists = $false
    if ($reg.exists -and -not [string]::IsNullOrWhiteSpace($reg.localPath)) {
        try { $fileExists = [bool](Test-Path -LiteralPath $reg.localPath -PathType Leaf) } catch { $fileExists = $false }
    }
    if ($reg.exists) {
        $null = $changes.Add((New-LctDrvChange -Target $st -Name 'stop' -Before ($reg.startMode + ' / ImagePath=' + $reg.imagePath) -After 'sc.exe stop ' + $st + '（失败不阻塞，如实记录）' -Note '卸载第 1 步'))
        $null = $changes.Add((New-LctDrvChange -Target $st -Name 'service' -Before ($reg.startMode + ' / ImagePath=' + $reg.imagePath) -After '(删除服务项，写入 revert 产物)' -Note '卸载第 2 步：sc.exe delete'))
        $null = $changes.Add((New-LctDrvChange -Target $reg.localPath -Name 'file' -Before ($(if ($fileExists) { '存在（' + $reg.imagePath + '）' } else { '文件不存在' })) -After '保留不动（本工具绝不删 .sys）' -Note '卸载第 3 步：不删文件'))
    }
    if (-not $Apply) {
        try { Write-LctDrvLog -Verb $verb -Level info -Message ('预览卸载驱动服务 ' + $st) -Data @{ name = $st; exists = $reg.exists; errors = @($errors) } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                name = $st; serviceKeyPath = $reg.keyPath; serviceBefore = $reg; applied = $false; deleted = $false
                filePath = $reg.localPath; fileExists = $fileExists; fileKept = $true
                plan = @('sc.exe stop ' + $st, 'sc.exe delete ' + $st, 'New-LctBackup + 生成 revert.cmd / revert.ps1 / revert.json', '不删除 .sys 文件')
                note = '预览：未执行任何 sc.exe 动作、未创建备份、未生成 revert 产物'
            })
    }
    $applied = $false
    $deleted = $false
    $revertCmdPath = ''
    $revertPs1Path = ''
    $revertJsonPath = ''
    if ($errors.Count -eq 0) {
        # 1) stop（失败不阻塞）
        $stopTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('stop', $st)
        $applied = $true
        $goal = '未达成'
        if ($stopTool.exitCode -eq 0) { $goal = '已请求停止' }
        elseif ($stopTool.exitCode -eq 1062) { $goal = '服务本来就未运行' }
        $stopVerdict = New-LctDrvVerdict -Action 'stop-before-delete' -Tool $stopTool -OsBlocked:($stopTool.exitCode -ne 0) -GoalMet $goal
        if ($stopTool.exitCode -eq 1062) { $null = $warnings.Add('sc stop：服务本来就未运行（1062），继续删除服务项') }
        elseif ($stopTool.exitCode -ne 0) { $null = $warnings.Add('sc stop 未成功（exit=' + $stopTool.exitCode + '），仍继续删除服务项：' + (First-LctDrvLine -Text $stopTool.message)) }
        # 2) 备份（删除前必须有可回滚的材料）
        $bk = $null
        try {
            $bk = New-LctBackup -Verb $verb -Args @{ name = $st; imagePath = $reg.imagePath; localPath = $reg.localPath; start = $reg.start; startMode = $reg.startMode; type = $reg.type } -RegistryPaths @($reg.keyPath)
            $backupId = [string]$bk.id
        } catch {
            $null = $errors.Add('备份失败，已中止（没有备份就不做删除）：' + $_.Exception.Message)
        }
        if ($errors.Count -eq 0 -and $null -ne $bk) {
            # 3) revert 产物（写进备份目录，便于和注册表备份放一起审计）
            $info = [pscustomobject][ordered]@{
                serviceName = $st
                imagePathRaw = $reg.imagePath
                binPathClean = $reg.localPath
                startType = $reg.startMode
                startValue = $reg.start
                typeText = $reg.typeText
                typeValue = $reg.type
                removedAt = (Get-Date).ToString('s')
                removedBy = ($env:USERDOMAIN + '\' + $env:USERNAME)
                elevated = $elevated
                restoredFromBackupId = $backupId
                note = '只重建服务项：不加载驱动、不触碰任何 .sys 文件'
            }
            $nonAscii = $false
            foreach ($v in @([string]$st, [string]$reg.imagePath, [string]$reg.localPath, [string]$reg.startMode)) {
                foreach ($ch in ([string]$v).ToCharArray()) { if ([int][char]$ch -gt 126) { $nonAscii = $true } }
            }
            try {
                $revertCmdPath = Write-LctDrvTextAsciiCrlf -Path (Join-Path ([string]$bk.dir) 'revert.cmd') -Text (Get-LctDrvRevertCmdText -Info $info)
                $revertPs1Path = Write-LctDrvTextBom -Path (Join-Path ([string]$bk.dir) 'revert.ps1') -Text (Get-LctDrvRevertPs1Text -Info $info)
                $revertJsonPath = Write-LctDrvTextBom -Path (Join-Path ([string]$bk.dir) 'revert.json') -Text (ConvertTo-LctDrvJson -Object $info -Depth 6)
            } catch { $null = $errors.Add('生成 revert 产物失败：' + $_.Exception.Message) }
            if ($nonAscii) {
                $null = $warnings.Add('服务名 / 原始路径含非 ASCII 字符：revert.cmd 已做 ASCII 化（非 ASCII 字符显示为 ?）以保证 .cmd 可读；精确重建请运行同目录下的 revert.ps1')
            }
            $null = $warnings.Add('revert 产物：' + $revertCmdPath + '（同目录 revert.ps1 / revert.json 为精确值）')
            # 4) delete
            $deleteTool = Invoke-LctDrvTool -FilePath (Get-LctDrvScExe) -Arguments @('delete', $st)
            $deleteVerdict = New-LctDrvVerdict -Action 'delete' -Tool $deleteTool -OsBlocked:($deleteTool.exitCode -ne 0) -GoalMet ($(if ($deleteTool.exitCode -eq 0) { '服务项已删除' } else { '未删除' }))
            if ($deleteTool.exitCode -ne 0) {
                $null = $errors.Add('sc.exe delete 失败（exit=' + $deleteTool.exitCode + '）：' + (First-LctDrvLine -Text $deleteTool.message))
            } else {
                $afterDelete = Get-LctDrvServiceRegistration -Name $st
                $deleted = (-not $afterDelete.exists)
                if (-not $deleted) { $null = $warnings.Add('sc delete 返回成功，但服务注册表键仍存在（可能被标记为「删除待完成」，重启后消失）：' + $reg.keyPath) }
            }
        }
    }
    try {
        Write-LctDrvLog -Verb $verb -Level change -Message ('卸载驱动服务 ' + $st + '（不删 .sys 文件）') -Data @{
            name = $st; deleted = $deleted; backupId = $backupId; filePath = $reg.localPath; fileKept = $true
            stopExitCode = $(if ($null -ne $stopVerdict) { $stopVerdict.exitCode } else { -1 }); deleteExitCode = $(if ($null -ne $deleteVerdict) { $deleteVerdict.exitCode } else { -1 }); errors = @($errors)
        } | Out-Null
    } catch { }
    $fileExistsAfter = $false
    if (-not [string]::IsNullOrWhiteSpace($reg.localPath)) {
        try { $fileExistsAfter = [bool](Test-Path -LiteralPath $reg.localPath -PathType Leaf) } catch { $fileExistsAfter = $false }
    }
    return New-LctResult -Verb $verb -Applied:$applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data ([pscustomobject][ordered]@{
            name = $st
            serviceKeyPath = $reg.keyPath
            serviceBefore = $reg
            serviceAfter = (Get-LctDrvServiceRegistration -Name $st)
            applied = $applied
            deleted = $deleted
            stopVerdict = $stopVerdict
            deleteVerdict = $deleteVerdict
            backupId = $backupId
            revertCmdPath = $revertCmdPath
            revertPs1Path = $revertPs1Path
            revertJsonPath = $revertJsonPath
            filePath = $reg.localPath
            fileExistsBefore = $fileExists
            fileExistsAfter = $fileExistsAfter
            fileKept = $true
            note = '只删服务项；.sys 文件保留不动（本工具不提供删除驱动文件的入口）'
        })
}

function Set-LctDriverTestSigning {
    # bcdedit /set testsigning on|off；记录原值；Secure Boot=True 时拒绝开启；标注需重启。
    param([switch]$Enable, [switch]$Disable, [switch]$Apply)
    $verb = 'driver.testsigning'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $bcd = Get-LctDrvBcdSetting -Key 'testsigning'
    $before = [string]$bcd.value
    $secureBoot = Get-LctDrvSecureBoot
    $action = ''
    if ($Enable.IsPresent -eq $Disable.IsPresent) {
        $null = $errors.Add('-Enable / -Disable 必须且只能指定一个（当前 Enable=' + $Enable.IsPresent + ' Disable=' + $Disable.IsPresent + '）')
    } elseif ($Enable) { $action = 'enable' } else { $action = 'disable' }
    $want = ''
    if ($action -eq 'enable') { $want = 'Yes' } elseif ($action -eq 'disable') { $want = 'No' }
    $gate = Test-LctDrvTestSigningGate -Action $action -SecureBoot $secureBoot.value
    if (-not $gate.allowed) { $null = $errors.Add($gate.reason) }
    $changed = ($before -ne $want)
    if ($action -ne '' -and -not $changed) { $null = $warnings.Add('当前 testsigning 已是 ' + $before + '：再写一次是同值操作（bcdedit 仍会执行，结果标注「无变化」）') }
    $bcdFlag = 'off'
    if ($action -eq 'enable') { $bcdFlag = 'on' }
    $needsRestartText = 'bcdedit 的写入需重启后才对启动路径生效；本机实测（2026-10-26）testsigning=Yes 已处于开启状态（§12.2：开启状态无需重启即已生效）。关闭则必须重启。'
    $null = $changes.Add((New-LctDrvChange -Target 'bcdedit testsigning' -Name 'testsigning' -Before $before -After $want -Note ('bcdedit.exe /set testsigning ' + $bcdFlag + '（需重启生效）')))
    $null = $warnings.Add('需重启生效：' + $needsRestartText)
    $dataBase = [ordered]@{
        action = $action
        enable = [bool]$Enable
        disable = [bool]$Disable
        before = $before
        after = $want
        changed = $changed
        needsRestart = $true
        needsRestartText = $needsRestartText
        secureBoot = $secureBoot.value
        secureBootSource = $secureBoot.source
        gate = $gate
        bcdSetting = $bcd
        bcdeditCommand = ('bcdedit.exe /set testsigning ' + $bcdFlag)
        applied = $false
        plan = @('bcdedit.exe /set testsigning ' + $bcdFlag)
        note = '本工具只如实回传 bcdedit 的退出码与原文；是否真正生效以重启后的 driver.status 为准'
    }
    if (-not $Apply) {
        $previewData = [ordered]@{}
        foreach ($k in $dataBase.Keys) { $previewData[$k] = $dataBase[$k] }
        $previewData['verdict'] = $null
        try { Write-LctDrvLog -Verb $verb -Level info -Message ('预览 testsigning ' + $action + '（原值 ' + $before + '）') -Data @{ action = $action; before = $before; want = $want; secureBoot = $secureBoot.value; allowed = $gate.allowed; errors = @($errors) } | Out-Null } catch { }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$previewData)
    }
    $verdict = $null
    $applied = $false
    if ($errors.Count -eq 0 -and $action -ne '') {
        $tool = Invoke-LctDrvTool -FilePath (Get-LctDrvBcdeditExe) -Arguments @('/set', 'testsigning', $bcdFlag)
        $applied = $true
        $verdict = New-LctDrvVerdict -Action ('set-testsigning-' + $bcdFlag) -Tool $tool -OsBlocked:($tool.exitCode -ne 0)
        if ($tool.exitCode -ne 0) { $null = $errors.Add('bcdedit 失败（exit=' + $tool.exitCode + '）：' + (First-LctDrvLine -Text $tool.message)) }
        else { $null = $warnings.Add('bcdedit 已执行成功（原文：' + (First-LctDrvLine -Text $tool.message 120) + '）；需重启生效') }
        try { Write-LctDrvLog -Verb $verb -Level change -Message ('testsigning 写入 ' + $bcdFlag + '（原值 ' + $before + '）') -Data @{ before = $before; want = $want; exitCode = $tool.exitCode; secureBoot = $secureBoot.value } | Out-Null } catch { }
    }
    $afterSetting = Get-LctDrvBcdSetting -Key 'testsigning'
    $applyData = [ordered]@{}
    foreach ($k in $dataBase.Keys) { $applyData[$k] = $dataBase[$k] }
    $applyData['applied'] = $applied
    $applyData['verdict'] = $verdict
    $applyData['afterReadBack'] = [string]$afterSetting.value
    $applyData['afterReadBackSource'] = [string]$afterSetting.source
    return New-LctResult -Verb $verb -Applied:$applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$applyData)
}
#endregion

#region 导出：加载后复核
function Get-LctDriverVerification {
    # 服务实际状态 + 是否真的运行 + 系统事件（7000/7026/219）原文
    param([AllowEmptyString()][string]$Name = '')
    $verb = 'driver.verify'
    $st = ([string]$Name).Trim()
    $o = [ordered]@{
        name = $st
        checkedAt = (Get-Date).ToString('s')
        nameValid = $false
        registered = $false
        keyPath = ''
        state = ''
        stateText = ''
        startMode = ''
        startValue = -1
        typeText = ''
        imagePath = ''
        localPath = ''
        fileExists = $false
        running = $false
        conclusion = 'unknown'
        conclusionText = '状态不明'
        verdictReason = ''
        events = @()
        eventCount = 0
        eventsRead = 0
        eventsError = ''
        scmDriverEventsRecent = @()
        evidence = @()
        limitations = @(
            '「真的在运行」以 Win32_SystemDriver 的 State=Running 为准（服务项存在 ≠ 驱动已加载）',
            '系统拒绝的原文来自 Service Control Manager 事件 7000/7026/219；若事件已被覆盖则无从判定，结论会是「状态不明」'
        )
        error = ''
    }
    if (-not (Test-LctDrvServiceName -Name $st)) {
        $o.error = '服务名非法或为空：' + $st
        $o.conclusionText = '状态不明（服务名为空或非法）'
        return [pscustomobject]$o
    }
    $o.nameValid = $true
    $reg = Get-LctDrvServiceRegistration -Name $st
    $o.registered = $reg.exists
    $o.keyPath = $reg.keyPath
    $o.startMode = $reg.startMode
    $o.startValue = $reg.start
    $o.typeText = $reg.typeText
    $o.imagePath = $reg.imagePath
    $o.localPath = $reg.localPath
    if (-not [string]::IsNullOrWhiteSpace($reg.localPath)) {
        try { $o.fileExists = [bool](Test-Path -LiteralPath $reg.localPath -PathType Leaf) } catch { $o.fileExists = $false }
    }
    $cim = Get-LctDrvCimDriver -Name $st
    if ($null -ne $cim) {
        $o.state = [string]$cim.State
        $o.stateText = [string]$cim.State
        $o.startMode = [string]$cim.StartMode
    } elseif ($reg.exists) {
        $o.state = 'NotListed'
        $o.stateText = '未出现在 Win32_SystemDriver（从未成功启动过 / 已被 SCM 移除）'
    } else {
        $o.state = 'NotInstalled'
        $o.stateText = '服务项不存在'
    }
    $o.running = ($o.state -ieq 'Running')
    # 系统事件原文（7000=服务启动失败 / 7026=引导期驱动加载失败 / 219=驱动加载失败）
    try {
        $raw = @(Get-WinEvent -LogName System -MaxEvents 400 -ErrorAction Stop)
        $o.eventsRead = @($raw).Count
        $evs = @($raw | Where-Object { $_.ProviderName -eq 'Service Control Manager' -and (@(7000, 7026, 219) -contains [int]$_.Id) })
        $matched = New-Object System.Collections.ArrayList
        $allScm = New-Object System.Collections.ArrayList
        foreach ($e in $evs) {
            $msg = ''
            try { $msg = [string]$e.Message } catch { $msg = '' }
            $entry = [pscustomobject][ordered]@{
                id       = [int]$e.Id
                time     = $e.TimeCreated.ToString('s')
                provider = [string]$e.ProviderName
                message  = $msg
                matchedBy = 'serviceName'
            }
            $null = $allScm.Add($entry)
            if ($msg -imatch [regex]::Escape($st)) { $null = $matched.Add($entry) }
        }
        $o.events = @($matched)
        $o.eventCount = @($matched).Count
        $o.scmDriverEventsRecent = @($allScm)
    } catch { $o.eventsError = $_.Exception.Message }
    # 三档结论
    if ($o.running) {
        $o.conclusion = 'running'
        $o.conclusionText = '真的在运行'
        $o.verdictReason = 'Win32_SystemDriver 的 State=Running（服务已加载在内核中）'
    } elseif ($reg.exists -and @($o.events).Count -gt 0) {
        $o.conclusion = 'os-rejected'
        $o.conclusionText = '被系统拒绝（有 Service Control Manager 失败事件原文）'
        $o.verdictReason = '服务项存在但未运行，且系统日志里有 ' + ((@($o.events) | ForEach-Object { '事件 ' + $_.id }) -join ' / ') + ' 指向该服务：' + (First-LctDrvLine -Text ([string]@($o.events)[0].message) 200)
    } elseif (-not $reg.exists) {
        $o.conclusion = 'unknown'
        $o.conclusionText = '状态不明（服务项不存在，可能已卸载或从未注册成功）'
        $o.verdictReason = '注册表里没有 ' + $reg.keyPath
    } else {
        $o.conclusion = 'unknown'
        $o.conclusionText = '状态不明（服务项存在但既未运行，也没有读到指向它的失败事件）'
        $o.verdictReason = '服务项存在、State=' + $o.state + '；近 ' + $o.eventsRead + ' 条系统日志里没有 7000/7026/219 指向它' + $(if ($o.eventsError) { '（事件读取失败：' + $o.eventsError + '）' } else { '' })
    }
    $o.evidence = @(
        'registry=' + $reg.keyPath + ' exists=' + $reg.exists + ' type=' + $reg.typeText + ' start=' + $reg.startMode + ' imagePath=' + $reg.imagePath,
        'cimState=' + $o.state,
        'eventsMatched=' + $o.eventCount + ' scanned=' + $o.eventsRead
    )
    try { Write-LctDrvLog -Verb $verb -Level info -Message ('复核驱动 ' + $st + ' → ' + $o.conclusionText) -Data @{ name = $st; state = $o.state; conclusion = $o.conclusion; events = $o.eventCount } | Out-Null } catch { }
    return [pscustomobject]$o
}
#endregion

#region 私有：revert 产物内容（ASCII .cmd + 精确 .ps1/.json）
function ConvertTo-LctDrvAsciiText {
    param([AllowEmptyString()][string]$Text = '')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Text).ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 32) { $null = $sb.Append(' ') }
        elseif ($code -gt 126) { $null = $sb.Append('?') }
        else { $null = $sb.Append($ch) }
    }
    return [string]$sb.ToString()
}

function ConvertTo-LctDrvCmdValue {
    # .cmd 里安全的值：纯 ASCII、% 双写、含空格或 cmd 元字符时加双引号（引号内的 & | < > ^ 是字面量）
    param([AllowEmptyString()][string]$Value = '')
    $v = ConvertTo-LctDrvAsciiText -Text $Value
    $v = $v -replace '%', '%%'
    if ($v -match '[\s&|<>^]') { return ('"' + $v + '"') }
    return $v
}

function ConvertTo-LctDrvPsLiteral {
    param([AllowEmptyString()][string]$Text = '')
    return ("'" + (([string]$Text) -replace "'", "''") + "'")
}

function Get-LctDrvRevertCmdText {
    # 纯 ASCII + CRLF；只重建服务项，不加载驱动、不删文件
    param($Info)
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add('@echo off')
    $null = $lines.Add('setlocal')
    $null = $lines.Add('REM ============================================================')
    $null = $lines.Add('REM LocalConfigTool driver-service revert (generated ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.removedAt)) + ')')
    $null = $lines.Add('REM Service       : ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.serviceName)))
    $null = $lines.Add('REM Original start: ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.startType)) + ' (registry Start=' + [string]$Info.startValue + ')')
    $null = $lines.Add('REM Original type : ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.typeText)) + ' (registry Type=' + [string]$Info.typeValue + ')')
    $null = $lines.Add('REM Original image: ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.imagePathRaw)))
    $null = $lines.Add('REM Removal backup: ' + (ConvertTo-LctDrvAsciiText -Text ([string]$Info.restoredFromBackupId)))
    $null = $lines.Add('REM NOTE: this rebuilds the SERVICE ENTRY only. It does not load')
    $null = $lines.Add('REM       the driver and it does not touch/delete any .sys file.')
    $null = $lines.Add('REM If the image path above shows ? instead of real characters,')
    $null = $lines.Add('REM run revert.ps1 in this folder for the exact values.')
    $null = $lines.Add('REM ============================================================')
    $null = $lines.Add('sc.exe stop ' + (ConvertTo-LctDrvCmdValue -Value ([string]$Info.serviceName)))
    $null = $lines.Add('sc.exe delete ' + (ConvertTo-LctDrvCmdValue -Value ([string]$Info.serviceName)))
    $null = $lines.Add('sc.exe create ' + (ConvertTo-LctDrvCmdValue -Value ([string]$Info.serviceName)) + ' type= kernel binPath= ' + (ConvertTo-LctDrvCmdValue -Value ([string]$Info.binPathClean)) + ' start= ' + (ConvertTo-LctDrvCmdValue -Value ([string]$Info.startType)))
    $null = $lines.Add('echo revert finished, last exit code = %ERRORLEVEL%')
    $null = $lines.Add('endlocal')
    return (($lines) -join "`r`n")
}

function Get-LctDrvRevertPs1Text {
    # UTF-8 带 BOM 的精确重建脚本（非 ASCII 路径也能正确重建）
    param($Info)
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add('# LocalConfigTool driver-service revert (exact values)')
    $null = $lines.Add('# 只重建服务项：不加载驱动、不删除任何文件（见 docs\CONTRACT.md §12.4 第 4 条）')
    $null = $lines.Add('# generated: ' + [string]$Info.removedAt + '  by ' + [string]$Info.removedBy)
    $null = $lines.Add('# removal backup id: ' + [string]$Info.restoredFromBackupId)
    $null = $lines.Add('$ErrorActionPreference = ''Continue''')
    $null = $lines.Add('$svcName = ' + (ConvertTo-LctDrvPsLiteral -Text ([string]$Info.serviceName)))
    $null = $lines.Add('$binPath = ' + (ConvertTo-LctDrvPsLiteral -Text ([string]$Info.binPathClean)))
    $null = $lines.Add('$startType = ' + (ConvertTo-LctDrvPsLiteral -Text ([string]$Info.startType)))
    $null = $lines.Add('$scExe = Join-Path $env:SystemRoot ''System32\sc.exe''')
    $null = $lines.Add('& $scExe stop $svcName 2>&1 | Out-Null')
    $null = $lines.Add('& $scExe delete $svcName 2>&1 | Out-Null')
    $null = $lines.Add('# 分离 token 形式：sc.exe 会自行规范成 \??\<abs>（见模块顶部实测 1）')
    $null = $lines.Add('& $scExe create $svcName ''type='' ''kernel'' ''binPath='' $binPath ''start='' $startType 2>&1 | ForEach-Object { [Console]::Out.WriteLine($_) }')
    $null = $lines.Add('[Console]::Out.WriteLine(''revert exit code = '' + $LASTEXITCODE)')
    $null = $lines.Add('$keyPath = ''HKLM:\SYSTEM\CurrentControlSet\Services\'' + $svcName')
    $null = $lines.Add('$k = Get-ItemProperty -LiteralPath $keyPath -ErrorAction SilentlyContinue')
    $null = $lines.Add('if ($null -ne $k) { [Console]::Out.WriteLine(''ImagePath now = '' + $k.ImagePath + '' / Start = '' + $k.Start) }')
    return (($lines) -join "`r`n")
}
#endregion

# =====================================================================
# 操作级简化（2026-10-31）：把"发明服务名 / 记住它 / 自己串三步"从用户手里拿掉
#   driver.use     = 加载 + 确认在跑（服务名自动推导，启动类型默认 demand）
#   driver.release = 卸载（给 名字 或 路径，路径会反查服务名）
#   driver.cleanup = 把本工具加载过的（服务名 lct*）全部卸掉
# =====================================================================
function Get-LctDrvServiceNameFromPath {
    # 给定 .sys 路径，按 ImagePath 的文件名反查已注册服务名（让用户不必记住服务名）
    param([AllowEmptyString()][string]$Path = '')
    $results = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    $leaf = ''
    try { $leaf = [IO.Path]::GetFileName($Path) } catch { $leaf = '' }
    if ($leaf -eq '') { return @() }
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
        try {
            $ip = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction Stop).ImagePath
        } catch { continue }
        if ($ip -eq '') { continue }
        $norm = ($ip -replace '^\\\?\?\\', '').Trim().Trim('"')
        try {
            if ([IO.Path]::GetFileName($norm) -ieq $leaf) { $null = $results.Add([string]$k.PSChildName) }
        } catch { }
    }
    return @($results)
}

function Invoke-LctDriverUse {
    <#
    .SYNOPSIS
        一条命令完成"加载并确认在跑"：服务名可省（从文件名推导），启动类型可省（默认 demand）。
    #>
    param(
        [AllowEmptyString()][string]$Path = '',
        [AllowEmptyString()][string]$Name = '',
        [AllowEmptyString()][string]$StartType = '',
        [switch]$Apply
    )
    $verb = 'driver.use'
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return New-LctResult -Verb $verb -Errors @('缺少 -Path：只要给出 .sys 路径即可（服务名与启动类型都会自动决定）') -Data ([pscustomobject][ordered]@{ path = ''; applied = $false })
    }
    $before = @(Get-LctDrvServiceNameFromPath -Path $Path)
    $load = Load-LctDriver -Path $Path -Name $Name -StartType $StartType -Apply:$Apply
    $svc = ''
    if ($null -ne $load -and $null -ne $load.data -and $null -ne $load.data.PSObject.Properties['name']) { $svc = [string]$load.data.name }
    if ($svc -eq '' -and @($before).Count -gt 0) { $svc = [string]@($before)[0] }

    $verify = $null
    $already = (@($before).Count -gt 0)
    if ($Apply -and $svc -ne '') {
        try { $verify = Get-LctDriverVerification -Name $svc } catch { $verify = $null }
    }

    $conclusion = ''
    $conclusionText = ''
    $loaded = $false
    if ($null -ne $verify -and $null -ne $verify.data) {
        if ($null -ne $verify.data.PSObject.Properties['conclusion']) { $conclusion = [string]$verify.data.conclusion }
        if ($null -ne $verify.data.PSObject.Properties['conclusionText']) { $conclusionText = [string]$verify.data.conclusionText }
        if ($null -ne $verify.data.PSObject.Properties['running']) { $loaded = [bool]$verify.data.running }
        elseif ($conclusion -ne '') { $loaded = ($conclusion -eq 'running') }
    }
    # 兜底：verify 取不到（事件日志读失败等）时直接问 SCM，避免"其实起来了却报没运行"
    if ($Apply -and $svc -ne '' -and -not $loaded) {
        try {
            $st = Get-LctDriverStatus -Name $svc
            if ($null -ne $st -and $null -ne $st.data) {
                $stateTxt = [string]$st.data.stateText
                if ($stateTxt -eq 'Running' -or [string]$st.data.state -eq 'Running') { $loaded = $true }
            }
        } catch { }
    }
    $steps = New-Object System.Collections.ArrayList
    if ($Apply) {
        if ($loaded) {
            $null = $steps.Add('驱动已在运行。想真正使用它（发 IOCTL）需要 profile：driver.profile.draft -Path "' + $Path + '" 出草案，人工审定后 driver.profile.save')
        } else {
            $null = $steps.Add('驱动没有跑起来：先看 data.verdict 与 data.verify 里的系统原文（常见：签名被拒 577 / 镜像无效 193 / 未提权）')
        }
        $null = $steps.Add('用完清理：driver.release -Path "' + $Path + '"（或 driver.cleanup 一次清掉本工具加载过的驱动（lct* 或指向样本库的））')
    } else {
        $null = $steps.Add('这是预览。加 -Apply 才会真的注册并启动；服务名推导结果见 data.serviceName')
    }

    return New-LctResult -Verb $verb -Applied:($Apply -and $load.ok) -Changes @($load.changes) -Warnings @($load.warnings) -Errors @($load.errors) -Data ([pscustomobject][ordered]@{
            path           = $Path
            serviceName    = $svc
            alreadyExisted = $already
            applied        = [bool]$Apply
            loaded         = $loaded
            verdict        = $(if ($null -ne $load.data -and $null -ne $load.data.PSObject.Properties['verdict']) { $load.data.verdict } else { $null })
            verify         = $verify
            nextSteps      = @($steps)
        })
}

function Invoke-LctDriverRelease {
    <#
    .SYNOPSIS
        一条命令卸载：给 -Name 或给 -Path（路径会按 ImagePath 文件名反查服务名），不用记名字。
    #>
    param([AllowEmptyString()][string]$Name = '', [AllowEmptyString()][string]$Path = '', [switch]$Apply)
    $verb = 'driver.release'
    $names = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Name)) { $null = $names.Add(([string]$Name).Trim()) }
    if ([string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($Path)) {
        foreach ($n in @(Get-LctDrvServiceNameFromPath -Path $Path)) { $null = $names.Add($n) }
    }
    if (@($names).Count -eq 0) {
        return New-LctResult -Verb $verb -Errors @('没找到对应服务：给 -Name，或给 -Path 让我按 ImagePath 的文件名反查') -Data ([pscustomobject][ordered]@{ applied = $false; released = @() })
    }
    $released = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    foreach ($n in @($names)) {
        $r = Remove-LctDriverService -Name $n -Apply:$Apply
        $ok = $false
        if ($null -ne $r) { $ok = [bool]$r.ok }
        if ($null -ne $r) {
            foreach ($e in @($r.errors)) { $null = $errors.Add([string]$e) }
            foreach ($w in @($r.warnings)) { $null = $warnings.Add([string]$w) }
        }
        $null = $released.Add([pscustomobject][ordered]@{ name = $n; ok = $ok })
    }
    return New-LctResult -Verb $verb -Applied:($Apply -and (@($released | Where-Object { $_.ok }).Count -gt 0)) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            path     = $Path
            applied  = [bool]$Apply
            released = @($released)
        })
}

function Invoke-LctDriverCleanup {
    <#
    .SYNOPSIS
        一条命令清理：卸掉所有服务名以 lct 开头的驱动服务（本工具默认前缀），不碰系统驱动。
    #>
    param([switch]$Apply)
    $verb = 'driver.cleanup'
    # 候选 = ① 服务名 lct*（本工具默认前缀）  ② ImagePath 指向本工具样本库 var\samples 的（名字可能来自文件名推导）
    # 只动这两类，绝不碰系统驱动。
    $sampleDir = ''
    try { $sampleDir = Join-Path (Get-LctVarDir) 'samples' } catch { $sampleDir = '' }
    $all = New-Object System.Collections.ArrayList
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
            $n = [string]$k.PSChildName
            $take = ($n -like 'lct*')
            if (-not $take -and $sampleDir -ne '') {
                try {
                    $ip = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name ImagePath -ErrorAction Stop).ImagePath
                    if ($ip -ne '') {
                        $norm = ($ip -replace '^\\\?\?\\', '').Trim().Trim('"')
                        if ($norm -like ($sampleDir + '\*')) { $take = $true }
                    }
                } catch { }
            }
            if ($take) { $null = $all.Add($n) }
        }
    } catch { }
    if (@($all).Count -eq 0) {
        return New-LctResult -Verb $verb -Data ([pscustomobject][ordered]@{
                applied = $false; candidates = @(); released = @()
                message = '没有本工具加载的驱动（既没有 lct* 服务，也没有指向样本库的服务）。如果桌面上还有 SYSTEM 命令行窗口，请手动关掉。'
            })
    }
    $released = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    foreach ($n in @($all)) {
        $r = Remove-LctDriverService -Name $n -Apply:$Apply
        $ok = $false
        if ($null -ne $r) { $ok = [bool]$r.ok }
        if ($null -ne $r) { foreach ($e in @($r.errors)) { $null = $errors.Add([string]$e) } }
        $null = $released.Add([pscustomobject][ordered]@{ name = $n; ok = $ok })
    }
    return New-LctResult -Verb $verb -Applied:($Apply -and (@($released | Where-Object { $_.ok }).Count -gt 0)) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            applied    = [bool]$Apply
            candidates = @($all)
            released   = @($released)
            message    = $(if ($Apply) { '已尝试卸载上面这些服务；卸载只删服务项、不删 .sys，并生成还原脚本' } else { '预览：加 -Apply 才会真的卸载' })
        })
}

Export-ModuleMember -Function Get-LctDriverStatus, Get-LctDriverList, Get-LctDriverFileInfo,
    Load-LctDriver, Start-LctDriver, Stop-LctDriver, Remove-LctDriverService, Set-LctDriverTestSigning,
    Get-LctDriverVerification, Invoke-LctDriverUse, Invoke-LctDriverRelease, Invoke-LctDriverCleanup