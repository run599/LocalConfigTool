# =====================================================================
# LocalConfigTool - DriverProfiles.psm1
# 职责：驱动通用化的「数据层 + 用户态原语执行引擎」（契约 §13）。
#   * 驱动控制接口不自描述 ⇒ 只有两条路：自研驱动遵守我们发布的 ABI，或每个驱动一份
#     profile（纯数据）描述「怎么调用它」。通用的是「格式 + 引擎」，不是驱动。
#   * 本模块只做 L2（profile 数据/校验）+ L3 的用户态执行器（按 profile 发 DeviceIoControl）。
#     **不做内核操作、不做 stager、不逆向成品**（能力层的 exec.cmd 由用户态 stager 负责）。
# 作者：task-3 (backend-driverprofiles)
# 契约：docs\CONTRACT.md §3 Result / §10.3-10.4 集成铁律 / §11.6 形状陷阱 / §13 驱动通用化
# 导出（8 个 = §13.5 的 7 个 + Lead 裁定的 driver.profile.save）：
#   Get-LctDriverProfileList  -Source <builtin|user|plugin|''>     -> 包装对象 {items,count,...}
#   Get-LctDriverProfileShow  -Id <string>                          -> 包装对象 {items,count,profile,...}
#   Test-LctDriverProfile     -Id <string> -Path <string>           -> Result（schema + 指纹 + 内存沙盒；不碰内核）
#   New-LctDriverProfileDraft -Path <.sys>                          -> Result（静态草案；needsReview=true，不可执行）
#   Get-LctDriverDevices      -Name <service>                       -> 包装对象 {items,count,...}（不发任何 IOCTL）
#   Invoke-LctDriverCtl       -Profile -Action -Payload -OverrideBsod -Apply -> Result（默认只预览，-Apply 才 CreateFile+DeviceIoControl）
#   Get-LctDriverCtlVerify    -Profile <string>                     -> 包装对象（指纹 + 可打开性 + canary 计划；默认不发 IOCTL）
#   Save-LctDriverProfile     -Id -Json -Override -Apply            -> Result（草案→审定→另存；只写 var\driver-profiles，JSON 无 BOM）
#
# ---- 铁律（违反即返工，见 §13.6）----
#  1. 默认预览：ctl.send 不带 -Apply 时**绝不发任何 IOCTL、绝不 CreateFile 设备**，只打印将发送的
#     IOCTL 与缓冲区十六进制（按 profile 布局打包）。每个动作写审计日志（Write-LctLog）。
#  2. profile 必须过校验才允许执行；target.sha256 与实际 .sys 不符 ⇒ 拒绝（布局错版本必蓝屏）。
#  3. 写类原语必须记原值并可还原：kwrite 强制返回 before 并生成还原脚本；拿不到原值 ⇒ 拒绝执行写。
#  4. risk.level=bsod 的动作默认禁用，需显式 -OverrideBsod（命中时 warnings 标 [高危]）；盲扫类
#     动作（kind=blindscan）另需 -IUnderstand。both 命中都写审计日志。
#  5. profile 是**纯数据**：不含任何可执行代码（schema 会拒绝 $(、反引号、Invoke-* 等代码片段）。
#  6. draft 只是草案：必须带 confidence(0..1) 与 needsReview=true，产出的 actions 为空 ⇒ 不可直接执行。
#  7. 测试不得对真实设备发未知 IOCTL：测试只允许 (a) 不存在的设备断言错误分类；(b) 预览路径断言打包；
#     (c) 假设备名断言定位失败。
#  8. 不用只读自动变量作变量名（$pid/$host/...）；不用 $Args 作形参名；不 Set-StrictMode（PS 5.1 目标）。
#     文件 UTF-8 带 BOM；禁止直接永久删除（走 Move-LctToRecycleBin）。
#
# ---- 本机实测（2026-10-27，Win10 19045.6466，Windows PowerShell 5.1.19041.6456）----
#  1) CreateFileW 的三种设备入口写法都可用（实测 \\.\Nsi / \??\Nsi / \\?\GLOBALROOT\Device\Nsi
#     全部成功）；不存在的设备返回 Win32 错误 2。**必须用 P/Invoke 拿原始错误码**：
#     [IO.File]::Open('\\.\LctNoSuchDevice') 抛的是 IOException，Win32 码被吞成 0x80131501。
#  2) [IO.Directory]::GetFileSystemEntries('\\.\GLOBALROOT\Device') 报「文件名语法不正确」⇒ 用户态
#     文件系统 API 枚举不了 \Device，必须走 NT API。实测 NtOpenDirectoryObject + NtQueryDirectoryObject
#     可枚举 \GLOBAL??（本机 313 个符号链接，第二圈返回 STATUS_NO_MORE_ENTRIES 0x8000001A/DOS 259）。
#  3) 符号链接目标要用 NtOpenSymbolicLinkObject(access=1) + NtQuerySymbolicLinkObject；用目录句柄打
#     符号链接会返回 0xC0000024（STATUS_OBJECT_TYPE_MISMATCH）。实测 \GLOBAL??\Nsi -> \Device\Nsi。
#  4) 设备接口枚举走 cfgmgr32 CM_Get_Device_Interface_ListW（GUID_DEVINTERFACE_DISK 实测 9 条）。
#  5) 驱动 → 服务名的**权威映射在用户态不存在**：本模块不假装能映射，只按「名字匹配 + 设备可打开性」
#     如实报告，匹配不到就明确写 matched=0 / supported=false，绝不虚构。
#  6) [guid].ToByteArray() 给出的是 Windows 内存布局（Data1/2/3 小端、Data4 原序），profile 的 guid
#     类型按此打包；bytes 字段接受十六进制字符串。
# =====================================================================

#region 依赖守卫（契约 §10.3 / §10.4：跨模块导入必须 -Global；可用性以模块装载为准，不用 Get-Command 探测）
$script:LctPrfLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
if ((Test-Path -LiteralPath $script:LctPrfLoggingModule) -and (-not (Get-Module -Name Logging))) {
    Import-Module $script:LctPrfLoggingModule -Force -Global -ErrorAction Stop
}
$script:LctPrfLoaded = [bool](Get-Module -Name Logging)
#endregion

#region 常量
$script:LctPrfKinds = @('u8', 'u16', 'u32', 'u64', 'i32', 'i64', 'bytes', 'cstr', 'guid', 'handle')
$script:LctPrfFixedSize = @{ 'u8' = 1; 'u16' = 2; 'u32' = 4; 'u64' = 8; 'i32' = 4; 'i64' = 8; 'guid' = 16; 'handle' = 8 }
$script:LctPrfRisks = @('low', 'medium', 'bsod')
$script:LctPrfMethods = @('buffered', 'neither', 'inout')
$script:LctPrfStrategies = @('symlink', 'interfaceGuid', 'serviceImagePath')
$script:LctPrfActionKinds = @('read', 'write', 'control', 'blindscan', 'handshake')
$script:LctPrfSources = @('builtin', 'user', 'plugin')
$script:LctPrfMaxBytes = 1048576          # 单字段上限 1MB
$script:LctPrfMaxHexDump = 256            # rawOutHex / hexdump 截断长度
$script:LctPrfMaxStrings = 400            # 字符串扫描上限（静态草案）
$script:LctPrfMaxIoctl = 64               # IOCTL 候选上限
$script:LctPrfDevPrefixes = @('\Device\', '\??\', '\DosDevices\', '\GLOBALROOT\', 'Device\')
# 设备控制接口 GUID 常量（只读枚举用）
$script:LctPrfGuidDevInterfaceDisk = '{53f56307-b6bf-11d0-94f2-00a0c91efb8b}'
# Win32 错误码 → 参考解释。**这只是给读者的参考，系统原文永远照抄在 message 里。**
$script:LctPrfWin32Hint = @{
    '1'   = '功能不受支持（ERROR_INVALID_FUNCTION）：驱动不认这个 IOCTL'
    '2'   = '系统找不到指定的文件/设备（ERROR_FILE_NOT_FOUND）：设备对象不存在'
    '3'   = '系统找不到指定的路径（ERROR_PATH_NOT_FOUND）：设备名写法不对或路径不存在'
    '5'   = '拒绝访问（ERROR_ACCESS_DENIED）：权限不足，或设备被独占/未授予该访问权'
    '6'   = '句柄无效（ERROR_INVALID_HANDLE）'
    '31'  = '连到系统上的设备没有发挥作用（ERROR_GEN_FAILURE）：驱动返回一般性失败'
    '32'  = '设备已被占用（ERROR_SHARING_VIOLATION）：通常说明**设备存在**但已独占打开'
    '87'  = '参数错误（ERROR_INVALID_PARAMETER）：IOCTL 代码或缓冲区不被支持'
    '122' = '输出缓冲区不足（ERROR_INSUFFICIENT_BUFFER）'
    '234' = '还有更多数据（ERROR_MORE_DATA）：输出缓冲区不足，需要更大缓冲'
    '1058' = '服务已被禁用（ERROR_SERVICE_DISABLED）：驱动没在跑'
    '1168' = '找不到元素（ERROR_NOT_FOUND）'
    '433' = '指定的设备不存在（ERROR_NO_SUCH_DEVICE）'
}
# NTSTATUS → 说明（只列本模块真正会用到的）
$script:LctPrfNtHint = @{
    '0xC0000008' = '句柄无效（STATUS_INVALID_HANDLE）'
    '0xC0000022' = '拒绝访问（STATUS_ACCESS_DENIED）'
    '0xC0000023' = '缓冲区太小（STATUS_BUFFER_TOO_SMALL）'
    '0xC0000024' = '对象类型不匹配（STATUS_OBJECT_TYPE_MISMATCH，例如用目录句柄打开符号链接）'
    '0xC0000034' = '对象名不存在（STATUS_OBJECT_NAME_NOT_FOUND）'
    '0xC0000033' = '对象名无效（STATUS_OBJECT_NAME_INVALID）'
    '0x8000001A' = '没有更多条目（STATUS_NO_MORE_ENTRIES）'
}
# 纯数据守卫：出现这些片段即认为 profile 里塞了「可执行代码」，schema 直接拒绝
$script:LctPrfCodeSmell = @('\$\(', '`')
$script:LctPrfCodeSmellRegex = '(?i)\b(iex|Invoke-Expression|Invoke-Command|Add-Type|Invoke-WebRequest|Start-Process|New-Object|Set-Item|Remove-Item|Out-File|Export-ModuleMember)\b'
#endregion

#region 私有：小工具（路径 / 日志 / JSON / 十六进制 / 文本）
function Get-LctPrfToolRoot {
    param()
    if ($script:LctPrfRoot) { return $script:LctPrfRoot }
    $r = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $script:LctPrfRoot = $r
    return $r
}

function Get-LctPrfVarBase {
    # 刻意不用 Get-LctVarDir（那会顺带建 logs/backups）：只读 getter 也要保持「不落盘」的语义
    param()
    if (-not [string]::IsNullOrWhiteSpace($env:LCT_VAR_DIR)) { return $env:LCT_VAR_DIR }
    return (Join-Path (Get-LctPrfToolRoot) 'var')
}

function Get-LctPrfPluginRoot {
    param()
    if (-not [string]::IsNullOrWhiteSpace($env:LCT_PLUGIN_ROOT)) { return $env:LCT_PLUGIN_ROOT }
    return (Join-Path (Get-LctPrfToolRoot) 'plugins')
}

function Write-LctPrfLog {
    param([string]$Verb = 'driver.profile', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}

function New-LctPrfChange {
    param([string]$Target = '', [string]$Name = '', [string]$Before = '', [string]$After = '', [string]$Note = '', [string]$Kind = 'note')
    return [pscustomobject][ordered]@{ kind = $Kind; target = $Target; name = $Name; before = $Before; after = $After; note = $Note }
}

function ConvertTo-LctPrfJson {
    param($Object, [int]$Depth = 10)
    return [string]($Object | ConvertTo-Json -Depth $Depth)
}

function ConvertTo-LctPrfJsonCompress {
    param($Object, [int]$Depth = 10)
    return [string]($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Get-LctPrfOneLine {
    param([AllowEmptyString()][string]$Text = '', [int]$Max = 200)
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return ($t.Substring(0, $Max) + '...') }
    return $t
}

function Get-LctPrfProp {
    param($Bag, [string]$Name, $Default = $null)
    if ($null -eq $Bag) { return $Default }
    if ($Bag -is [System.Collections.IDictionary]) {
        if ($Bag.Contains($Name)) { return $Bag[$Name] }
        return $Default
    }
    if ($Bag -is [string]) { return $Default }
    $p = $Bag.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Test-LctPrfProp {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $false }
    if ($Bag -is [System.Collections.IDictionary]) { return [bool]($Bag.Contains($Name)) }
    if ($Bag -is [string]) { return $false }
    return [bool]($null -ne $Bag.PSObject.Properties[$Name])
}

function ConvertTo-LctPrfPlain {
    # JSON 对象 → 纯 hashtable/array（内部一律用它，避免 PSObject 属性访问的意外行为）
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 16) { return $Value }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = ConvertTo-LctPrfPlain -Value $Value[$k] -Depth ($Depth + 1) }
        return $h
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in @($Value.PSObject.Properties)) { $h[[string]$p.Name] = ConvertTo-LctPrfPlain -Value $p.Value -Depth ($Depth + 1) }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { $null = $arr.Add((ConvertTo-LctPrfPlain -Value $item -Depth ($Depth + 1))) }
        return , @($arr)
    }
    return $Value
}

function Align-LctPrfOffset {
    param([int]$Offset = 0, [int]$Step = 1)
    if ($Step -le 1) { return $Offset }
    $r = $Offset % $Step
    if ($r -eq 0) { return $Offset }
    return ($Offset + ($Step - $r))
}

function ConvertTo-LctPrfHex {
    param([byte[]]$Bytes, [int]$Max = 0)
    if ($null -eq $Bytes) { return '' }
    $take = $Bytes.Length
    $cut = $false
    if ($Max -gt 0 -and $take -gt $Max) { $take = $Max; $cut = $true }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $take; $i++) { $null = $sb.Append(('{0:x2}' -f [int]$Bytes[$i])) }
    if ($cut) { $null = $sb.Append('..(truncated,total=' + $Bytes.Length + ')') }
    return [string]$sb.ToString()
}

function Format-LctPrfHexDump {
    # 十六进制 + ASCII 双栏；不可打印字符用 '.'（预览必须让人肉眼看得出缓冲区内容）
    param([byte[]]$Bytes, [int]$Max = 256)
    $lines = New-Object System.Collections.ArrayList
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @($lines) }
    $take = $Bytes.Length
    if ($Max -gt 0 -and $take -gt $Max) { $take = $Max }
    $off = 0
    while ($off -lt $take) {
        $n = [Math]::Min(16, ($take - $off))
        $hex = New-Object System.Text.StringBuilder
        $asc = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 16; $i++) {
            if ($i -lt $n) {
                $b = [int]$Bytes[$off + $i]
                $null = $hex.Append(('{0:x2} ' -f $b))
                if ($b -ge 32 -and $b -le 126) { $null = $asc.Append([char]$b) } else { $null = $asc.Append('.') }
            } else { $null = $hex.Append('   ') }
            if ($i -eq 7) { $null = $hex.Append(' ') }
        }
        $null = $lines.Add(('{0:x8}  {1} |{2}|' -f $off, ([string]$hex.ToString()), ([string]$asc.ToString())))
        $off += 16
    }
    if ($Bytes.Length -gt $take) { $null = $lines.Add(('... 只显示前 ' + $take + ' 字节，共 ' + $Bytes.Length + ' 字节')) }
    return @($lines)
}

function ConvertFrom-LctPrfHexBytes {
    # 十六进制文本 → byte[]。接受 'DEADBEEF' / 'aa bb cc' / '0xAA,0xBB' / '{guid}' / 数字数组
    param($Value = $null)
    if ($null -eq $Value) { return [pscustomobject][ordered]@{ ok = $true; bytes = $null; error = '' } }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        $arr = New-Object System.Collections.Generic.List[byte]
        foreach ($item in $Value) {
            $n = ConvertTo-LctPrfUInt64 -Value $item
            if ($null -eq $n -or $n -gt 255) { return [pscustomobject][ordered]@{ ok = $false; bytes = $null; error = '字节数组里出现非法的字节值' } }
            $arr.Add([byte]$n)
        }
        return [pscustomobject][ordered]@{ ok = $true; bytes = $arr.ToArray(); error = '' }
    }
    $t = [string]$Value
    $t = $t.Trim()
    if ($t -eq '') { return [pscustomobject][ordered]@{ ok = $true; bytes = (New-Object byte[] 0); error = '' } }
    $t = $t -replace '(?i)0x', ''
    $t = $t -replace '[^0-9a-fA-F]', ''
    if (($t.Length % 2) -ne 0) { return [pscustomobject][ordered]@{ ok = $false; bytes = $null; error = '十六进制字符个数是奇数，无法按字节解析' } }
    if ($t.Length -eq 0) { return [pscustomobject][ordered]@{ ok = $false; bytes = $null; error = '没有可解析的十六进制字符' } }
    $bytes = New-Object byte[] ($t.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        try { $bytes[$i] = [byte][Convert]::ToInt32($t.Substring($i * 2, 2), 16) } catch { return [pscustomobject][ordered]@{ ok = $false; bytes = $null; error = '十六进制解析失败: ' + $_.Exception.Message } }
    }
    return [pscustomobject][ordered]@{ ok = $true; bytes = $bytes; error = '' }
}

function ConvertTo-LctPrfUInt64 {
    param($Value = $null)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [uint64]) { return [uint64]$Value }
    if ($Value -is [uint32] -or $Value -is [uint16] -or $Value -is [byte]) { return [uint64]$Value }
    if ($Value -is [int64]) { if ([int64]$Value -lt 0) { return $null }; return [uint64]([int64]$Value) }
    if ($Value -is [int32]) { if ([int32]$Value -lt 0) { return $null }; return [uint64]([int32]$Value) }
    if ($Value -is [int16]) { if ([int16]$Value -lt 0) { return $null }; return [uint64]([int16]$Value) }
    if ($Value -is [string]) {
        $t = ([string]$Value).Trim()
        if ($t -eq '') { return $null }
        try { return [uint64]$t } catch { return $null }
    }
    try { return [uint64]$Value } catch { return $null }
}

function ConvertTo-LctPrfInt64 {
    param($Value = $null)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [int64]) { return [int64]$Value }
    if ($Value -is [int32] -or $Value -is [int16] -or $Value -is [byte]) { return [int64]$Value }
    if ($Value -is [uint64]) { if ([uint64]$Value -gt 9223372036854775807) { return $null }; return [int64]$Value }
    if ($Value -is [uint32] -or $Value -is [uint16]) { return [int64]$Value }
    if ($Value -is [string]) {
        $t = ([string]$Value).Trim()
        if ($t -eq '') { return $null }
        try { return [int64]$t } catch { return $null }
    }
    try { return [int64]$Value } catch { return $null }
}

function ConvertTo-LctPrfSafeName {
    param([AllowEmptyString()][string]$Text = '')
    $t = ([string]$Text) -replace '[^0-9A-Za-z\.\-_]', '_'
    if ($t.Length -gt 96) { $t = $t.Substring(0, 96) }
    if ($t -eq '') { $t = 'x' }
    return $t
}

function ConvertTo-LctPrfAsciiText {
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

function Write-LctPrfTextBom {
    param([string]$Path, [AllowEmptyString()][string]$Text = '')
    $enc = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $enc)
    return $Path
}

function Write-LctPrfTextAsciiCrlf {
    param([string]$Path, [AllowEmptyString()][string]$Text = '')
    $t = ([string]$Text) -replace "`r?`n", "`r`n"
    $enc = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($Path, $t, $enc)
    return $Path
}

function Ensure-LctPrfDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    return $Path
}

function Get-LctPrfSha256 {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch { return '' }
}
#endregion

#region 私有：类型系统 + 打包/解包/内存沙盒（纯内存，不碰设备）
function ConvertTo-LctPrfFieldSpec {
    # profile 里的字段描述 → 归一化规范
    #   numeric / guid / handle：定长；bytes：len 定长、lenFrom(取该字段的**值**当长度)、lenOf(取该字段的**字节大小**当长度)
    #   cstr：可选 len 作为容量（不足补 0）；无 len 时按内容 UTF-8 长度 + NUL 动态定长
    param($Field, [string]$Where = '')
    $o = [ordered]@{
        name = ''; kind = ''; size = -1; fixed = $false; len = -1; lenRef = ''; lenOf = ''
        optional = $false; ok = $false; error = ''
    }
    if ($null -eq $Field -or $Field -isnot [System.Collections.IDictionary]) { $o.error = ($Where + '字段描述必须是对象 {name,type}'); return [pscustomobject]$o }
    $nm = [string](Get-LctPrfProp -Bag $Field -Name 'name' -Default '')
    $ty = [string](Get-LctPrfProp -Bag $Field -Name 'type' -Default '')
    $o.name = $nm
    $o.kind = $ty.ToLower()
    if ($nm -eq '') { $o.error = ($Where + '字段缺少 name'); return [pscustomobject]$o }
    if ($nm -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $o.error = ($Where + "字段名 '$nm' 非法（只允许字母/数字/下划线且不以数字开头）"); return [pscustomobject]$o }
    if ($ty -eq '') { $o.error = ($Where + "字段 '$nm' 缺少 type"); return [pscustomobject]$o }
    if ($script:LctPrfKinds -notcontains $o.kind) { $o.error = ($Where + "字段 '$nm' 类型未知: '$ty'（首版支持 " + ($script:LctPrfKinds -join '/') + '）'); return [pscustomobject]$o }
    if (Test-LctPrfProp -Bag $Field -Name 'optional') { $o.optional = [bool](Get-LctPrfProp -Bag $Field -Name 'optional') }
    $hasLen = Test-LctPrfProp -Bag $Field -Name 'len'
    $hasLenRef = Test-LctPrfProp -Bag $Field -Name 'lenFrom'
    $hasLenOf = Test-LctPrfProp -Bag $Field -Name 'lenOf'
    if ($script:LctPrfFixedSize.ContainsKey($o.kind)) {
        if ($hasLen -or $hasLenRef -or $hasLenOf) { $o.error = ($Where + "类型 $($o.kind) 不接受 len/lenFrom/lenOf"); return [pscustomobject]$o }
        $o.size = [int]$script:LctPrfFixedSize[$o.kind]
        $o.fixed = $true
        $o.ok = $true
        return [pscustomobject]$o
    }
    if ($o.kind -eq 'bytes') {
        $n = 0
        if ($hasLen) { $n++ }
        if ($hasLenRef) { $n++ }
        if ($hasLenOf) { $n++ }
        if ($n -ne 1) { $o.error = ($Where + "bytes 字段 '$nm' 必须且只能给 len / lenFrom / lenOf 中的一个"); return [pscustomobject]$o }
        if ($hasLen) {
            $v = ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $Field -Name 'len')
            if ($null -eq $v) { $o.error = ($Where + "bytes 字段 '$nm' 的 len 不是非负整数"); return [pscustomobject]$o }
            if ($v -gt $script:LctPrfMaxBytes) { $o.error = ($Where + "bytes 字段 '$nm' 的 len 超过上限 $($script:LctPrfMaxBytes)"); return [pscustomobject]$o }
            $o.len = [int]$v
            $o.size = [int]$v
            $o.fixed = $true
        } elseif ($hasLenRef) {
            $o.lenRef = [string](Get-LctPrfProp -Bag $Field -Name 'lenFrom')
            if ($o.lenRef -eq '') { $o.error = ($Where + "bytes 字段 '$nm' 的 lenFrom 为空"); return [pscustomobject]$o }
        } else {
            $o.lenOf = [string](Get-LctPrfProp -Bag $Field -Name 'lenOf')
            if ($o.lenOf -eq '') { $o.error = ($Where + "bytes 字段 '$nm' 的 lenOf 为空"); return [pscustomobject]$o }
        }
        $o.ok = $true
        return [pscustomobject]$o
    }
    # cstr
    if ($hasLenRef -or $hasLenOf) { $o.error = ($Where + "cstr 字段 '$nm' 不接受 lenFrom/lenOf（需要变长缓冲请用 bytes）"); return [pscustomobject]$o }
    if ($hasLen) {
        $v = ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $Field -Name 'len')
        if ($null -eq $v -or $v -lt 1) { $o.error = ($Where + "cstr 字段 '$nm' 的 len（容量）必须 >= 1"); return [pscustomobject]$o }
        if ($v -gt $script:LctPrfMaxBytes) { $o.error = ($Where + "cstr 字段 '$nm' 的 len 超过上限 $($script:LctPrfMaxBytes)"); return [pscustomobject]$o }
        $o.len = [int]$v
        $o.size = [int]$v
        $o.fixed = $true
    }
    $o.ok = $true
    return [pscustomobject]$o
}

function ConvertTo-LctPrfFieldBytes {
    # 单个字段 → 字节。$Size 已由调用方算好（定长或动态长度）
    param($Spec, $Value = $null, [int]$Size = 0)
    $r = [ordered]@{ ok = $false; bytes = $null; display = ''; error = '' }
    if ($Size -lt 0) { $r.error = '字段大小未确定'; return [pscustomobject]$r }
    $kind = [string]$Spec.kind
    if ($kind -eq 'guid') {
        $b = $null
        if ($null -eq $Value -and $Spec.optional) { $b = New-Object byte[] 16 }
        elseif ($Value -is [string]) {
            $t = ([string]$Value).Trim().Trim('{', '}')
            if ($t -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                try { $b = ([guid]$t).ToByteArray() } catch { $r.error = 'guid 解析失败: ' + $_.Exception.Message; return [pscustomobject]$r }
            } else {
                $h = ConvertFrom-LctPrfHexBytes -Value $t
                if (-not $h.ok) { $r.error = $h.error; return [pscustomobject]$r }
                $b = $h.bytes
            }
        } else {
            $h = ConvertFrom-LctPrfHexBytes -Value $Value
            if (-not $h.ok) { $r.error = $h.error; return [pscustomobject]$r }
            $b = $h.bytes
        }
        if ($null -eq $b -or $b.Length -ne 16) { $r.error = "guid 字段需要 16 字节，实际 $($b.Length) 字节"; return [pscustomobject]$r }
        try { $r.display = ([guid]$b).ToString('D') } catch { $r.display = ConvertTo-LctPrfHex -Bytes $b }
        $r.bytes = $b
        $r.ok = $true
        return [pscustomobject]$r
    }
    if ($kind -eq 'bytes') {
        if ($null -eq $Value -and $Spec.optional) { $Value = '' }
        $h = ConvertFrom-LctPrfHexBytes -Value $Value
        if (-not $h.ok) { $r.error = $h.error; return [pscustomobject]$r }
        $b = $h.bytes
        if ($null -eq $b) { $b = New-Object byte[] 0 }
        if ($b.Length -ne $Size) { $r.error = ("需要 $Size 字节，实际 $($b.Length) 字节（payload 里的十六进制长度必须正好等于字段长度）"); return [pscustomobject]$r }
        $r.bytes = $b
        $r.display = ConvertTo-LctPrfHex -Bytes $b
        $r.ok = $true
        return [pscustomobject]$r
    }
    if ($kind -eq 'cstr') {
        if ($null -eq $Value -and $Spec.optional) { $Value = '' }
        if ($null -eq $Value) { $r.error = 'cstr 字段需要字符串值'; return [pscustomobject]$r }
        $txt = [string]$Value
        $enc = [Text.Encoding]::UTF8.GetBytes($txt)
        $need = $enc.Length + 1
        if ($Spec.fixed -and $Spec.len -gt 0) { $need = $Spec.len }
        if (($enc.Length + 1) -gt $need) { $r.error = ("字符串的 UTF-8 长度($($enc.Length))+NUL 超过字段容量 $need"); return [pscustomobject]$r }
        $b = New-Object byte[] $need
        for ($i = 0; $i -lt $enc.Length; $i++) { $b[$i] = $enc[$i] }
        $r.bytes = $b
        $r.display = $txt
        $r.ok = $true
        return [pscustomobject]$r
    }
    # 数值 / handle
    if ($kind -eq 'handle') {
        $u = ConvertTo-LctPrfUInt64 -Value $Value
        if ($null -eq $u) { if ($null -eq $Value -and $Spec.optional) { $u = [uint64]0 } else { $r.error = 'handle 字段需要非负整数或 0x 十六进制'; return [pscustomobject]$r } }
        $r.bytes = [BitConverter]::GetBytes([uint64]$u)
        $r.display = [string]$u
        $r.ok = $true
        return [pscustomobject]$r
    }
    if ($kind -eq 'i32' -or $kind -eq 'i64') {
        $i = ConvertTo-LctPrfInt64 -Value $Value
        if ($null -eq $i) { if ($null -eq $Value -and $Spec.optional) { $i = [int64]0 } else { $r.error = ($kind + ' 字段需要整数（可负）'); return [pscustomobject]$r } }
        if ($kind -eq 'i32') {
            if ($i -lt -2147483648 -or $i -gt 2147483647) { $r.error = 'i32 超出范围'; return [pscustomobject]$r }
            $r.bytes = [BitConverter]::GetBytes([int32]$i)
        } else { $r.bytes = [BitConverter]::GetBytes([int64]$i) }
        $r.display = [string]$i
        $r.ok = $true
        return [pscustomobject]$r
    }
    $u = ConvertTo-LctPrfUInt64 -Value $Value
    if ($null -eq $u) { if ($null -eq $Value -and $Spec.optional) { $u = [uint64]0 } else { $r.error = ($kind + ' 字段需要非负整数（十六进制可用 0x 前缀）'); return [pscustomobject]$r } }
    switch ($kind) {
        'u8' {
            if ($u -gt 255) { $r.error = 'u8 超出范围 0..255'; return [pscustomobject]$r }
            $r.bytes = [BitConverter]::GetBytes([byte]$u)
        }
        'u16' {
            if ($u -gt 65535) { $r.error = 'u16 超出范围 0..65535'; return [pscustomobject]$r }
            $r.bytes = [BitConverter]::GetBytes([uint16]$u)
        }
        'u32' {
            if ($u -gt 4294967295) { $r.error = 'u32 超出范围'; return [pscustomobject]$r }
            $r.bytes = [BitConverter]::GetBytes([uint32]$u)
        }
        default { $r.bytes = [BitConverter]::GetBytes([uint64]$u) }
    }
    $r.display = [string]$u
    $r.ok = $true
    return [pscustomobject]$r
}

function ConvertTo-LctPrfBuffer {
    # 按 profile 的字段表 + layout 打包（小端；每个字段按 min(字段大小, layout.align) 对齐）
    param($Fields, $Layout, $Values = $null)
    $align = 8
    if ($null -ne $Layout) { $align = [int](Get-LctPrfProp -Bag $Layout -Name 'align' -Default 8) }
    if ($align -lt 1) { $align = 1 }
    if ($align -gt 64) { $align = 64 }
    $specs = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($f in @($Fields)) {
        $i++
        $null = $specs.Add((ConvertTo-LctPrfFieldSpec -Field $f -Where ("第 $i 个 ")))
    }
    foreach ($s in @($specs)) {
        if (-not $s.ok) { return [pscustomobject][ordered]@{ ok = $false; error = $s.error; bytes = $null; size = 0; plan = @() } }
    }
    $out = New-Object System.Collections.Generic.List[byte]
    $plan = New-Object System.Collections.ArrayList
    $sizes = @{}
    $vals = @{}
    $defaulted = New-Object System.Collections.ArrayList
    foreach ($s in @($specs)) {
        $raw = $null
        $wasDefaulted = $false
        $has = Test-LctPrfProp -Bag $Values -Name $s.name
        if ($has) { $raw = Get-LctPrfProp -Bag $Values -Name $s.name }
        elseif (-not $s.optional) {
            # 宽松默认：payload 没给的字段按 0 填充（padding 类字段不必重复写）。
            # 但名字会记进 defaulted 交给上层做 warning —— 免得「字段名写错」被静默忽略。
            $wasDefaulted = $true
            $null = $defaulted.Add($s.name)
        }
        $sz = [int]$s.size
        if ($sz -lt 0) {
            if ($s.kind -eq 'bytes') {
                if ($s.lenRef -ne '') {
                    if (-not $sizes.ContainsKey($s.lenRef)) { return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "' 的 lenFrom='" + $s.lenRef + "' 必须是排在它前面的字段"); bytes = $null; size = 0; plan = @() } }
                    $refNum = ConvertTo-LctPrfUInt64 -Value $vals[$s.lenRef]
                    if ($null -eq $refNum) { return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "' 的 lenFrom='" + $s.lenRef + "' 的值不是非负整数"); bytes = $null; size = 0; plan = @() } }
                    $sz = [int]$refNum
                } elseif ($s.lenOf -ne '') {
                    if (-not $sizes.ContainsKey($s.lenOf)) { return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "' 的 lenOf='" + $s.lenOf + "' 必须是排在它前面的字段"); bytes = $null; size = 0; plan = @() } }
                    $sz = [int]$sizes[$s.lenOf]
                } else {
                    return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "' 的长度无法确定"); bytes = $null; size = 0; plan = @() }
                }
            } elseif ($s.kind -eq 'cstr') {
                $txt = ''
                if ($null -ne $raw) { $txt = [string]$raw }
                $sz = ([Text.Encoding]::UTF8.GetByteCount($txt)) + 1
            }
        }
        if ($sz -lt 0 -or $sz -gt $script:LctPrfMaxBytes) { return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "' 的长度非法/超限: $sz"); bytes = $null; size = 0; plan = @() } }
        if ($wasDefaulted) {
            if ($s.kind -eq 'bytes') { $raw = ('00' * [Math]::Max(0, $sz)) }
            elseif ($s.kind -eq 'cstr') { $raw = '' }
            elseif ($s.kind -eq 'guid') { $raw = '00000000-0000-0000-0000-000000000000' }
            else { $raw = 0 }
        }
        $step = [Math]::Min($sz, $align)
        if ($step -lt 1) { $step = 1 }
        while (($out.Count % $step) -ne 0) { $out.Add(0) }
        $off = $out.Count
        $enc = ConvertTo-LctPrfFieldBytes -Spec $s -Value $raw -Size $sz
        if (-not $enc.ok) { return [pscustomobject][ordered]@{ ok = $false; error = ("字段 '" + $s.name + "': " + $enc.error); bytes = $null; size = 0; plan = @() } }
        foreach ($b in @($enc.bytes)) { $out.Add($b) }
        $sizes[$s.name] = $sz
        $vals[$s.name] = $enc.display
        $null = $plan.Add([pscustomobject][ordered]@{ name = $s.name; kind = $s.kind; offset = $off; size = $sz; value = $enc.display })
    }
    return [pscustomobject][ordered]@{ ok = $true; error = ''; bytes = $out.ToArray(); size = $out.Count; plan = @($plan); defaulted = @($defaulted) }
}

function ConvertFrom-LctPrfBuffer {
    # 按 profile 的 out 字段表解包（小端），与 ConvertTo-LctPrfBuffer 用同一套对齐规则
    param($Fields, $Layout, [byte[]]$Buffer, [int]$Length = -1)
    $align = 8
    if ($null -ne $Layout) { $align = [int](Get-LctPrfProp -Bag $Layout -Name 'align' -Default 8) }
    if ($align -lt 1) { $align = 1 }
    if ($align -gt 64) { $align = 64 }
    $total = 0
    if ($null -ne $Buffer) { $total = $Buffer.Length }
    if ($Length -ge 0 -and $Length -lt $total) { $total = $Length }
    $specs = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($f in @($Fields)) {
        $i++
        $null = $specs.Add((ConvertTo-LctPrfFieldSpec -Field $f -Where ("第 $i 个 ")))
    }
    foreach ($s in @($specs)) {
        if (-not $s.ok) { return [pscustomobject][ordered]@{ ok = $false; error = $s.error; truncated = $false; values = [ordered]@{}; plan = @(); consumed = 0 } }
    }
    $values = [ordered]@{}
    $plan = New-Object System.Collections.ArrayList
    $sizes = @{}
    $nums = @{}
    $consumed = 0
    foreach ($s in @($specs)) {
        $sz = [int]$s.size
        if ($sz -lt 0) {
            if ($s.kind -eq 'bytes') {
                if ($s.lenRef -ne '') {
                    if (-not $nums.ContainsKey($s.lenRef)) { return [pscustomobject][ordered]@{ ok = $false; error = ("解包：字段 '" + $s.name + "' 的 lenFrom='" + $s.lenRef + "' 必须先解出"); truncated = $false; values = [ordered]@{}; plan = @(); consumed = 0 } }
                    $sz = [int]$nums[$s.lenRef]
                } elseif ($s.lenOf -ne '') {
                    if (-not $sizes.ContainsKey($s.lenOf)) { return [pscustomobject][ordered]@{ ok = $false; error = ("解包：字段 '" + $s.name + "' 的 lenOf='" + $s.lenOf + "' 必须先解出"); truncated = $false; values = [ordered]@{}; plan = @(); consumed = 0 } }
                    $sz = [int]$sizes[$s.lenOf]
                }
            } elseif ($s.kind -eq 'cstr') {
                $sz = $total - $consumed
                if ($sz -lt 1) { $sz = 1 }
            }
        }
        if ($sz -lt 0) { return [pscustomobject][ordered]@{ ok = $false; error = ("解包：字段 '" + $s.name + "' 长度无法确定"); truncated = $false; values = [ordered]@{}; plan = @(); consumed = 0 } }
        $step = [Math]::Min($sz, $align)
        if ($step -lt 1) { $step = 1 }
        $off = (Align-LctPrfOffset -Offset $consumed -Step $step)
        if (($off + $sz) -gt $total) {
            return [pscustomobject][ordered]@{ ok = $false; error = ("输出缓冲不足：字段 '" + $s.name + "' 需要读到第 " + ($off + $sz) + " 字节，实际只有 $total 字节"); truncated = $true; values = $values; plan = @($plan); consumed = $consumed }
        }
        $chunk = New-Object byte[] $sz
        [Array]::Copy($Buffer, $off, $chunk, 0, $sz)
        $kind = [string]$s.kind
        $v = $null
        $isNum = $false
        switch ($kind) {
            'u8' { $v = [uint64]$chunk[0]; $isNum = $true }
            'u16' { $v = [uint64][BitConverter]::ToUInt16($chunk, 0); $isNum = $true }
            'u32' { $v = [uint64][BitConverter]::ToUInt32($chunk, 0); $isNum = $true }
            'u64' { $v = [uint64][BitConverter]::ToUInt64($chunk, 0); $isNum = $true }
            'i32' { $v = [int64][BitConverter]::ToInt32($chunk, 0); $isNum = $true }
            'i64' { $v = [int64][BitConverter]::ToInt64($chunk, 0); $isNum = $true }
            'handle' { $v = [uint64][BitConverter]::ToUInt64($chunk, 0); $isNum = $true }
            'guid' {
                try { $v = ([guid]$chunk).ToString('D') } catch { $v = ConvertTo-LctPrfHex -Bytes $chunk }
            }
            'bytes' { $v = ConvertTo-LctPrfHex -Bytes $chunk }
            'cstr' {
                $end = $sz
                for ($k = 0; $k -lt $sz; $k++) { if ($chunk[$k] -eq 0) { $end = $k; break } }
                if ($end -eq 0) { $v = '' } else {
                    $sub = New-Object byte[] $end
                    [Array]::Copy($chunk, 0, $sub, 0, $end)
                    $v = [Text.Encoding]::UTF8.GetString($sub)
                }
            }
        }
        $values[$s.name] = $v
        if ($isNum) { $nums[$s.name] = $v }
        $sizes[$s.name] = $sz
        $null = $plan.Add([pscustomobject][ordered]@{ name = $s.name; kind = $kind; offset = $off; size = $sz; value = $v })
        $consumed = $off + $sz
    }
    return [pscustomobject][ordered]@{ ok = $true; error = ''; truncated = $false; values = $values; plan = @($plan); consumed = $consumed }
}

function Get-LctPrfSyntheticValue {
    # 沙盒自检用的合成值（确定性；只用于内存里跑一遍，不碰设备）
    param($Spec, $RefLengths = $null)
    $kind = [string]$Spec.kind
    if ($kind -eq 'u8') { return 17 }
    if ($kind -eq 'u16') { return 4370 }
    if ($kind -eq 'u32') { return 287454020 }
    if ($kind -eq 'u64') { return [uint64]'0x1122334455667788' }
    if ($kind -eq 'i32') { return -2000000000 }
    if ($kind -eq 'i64') { return -2000000000000000 }
    if ($kind -eq 'handle') { return [uint64]'0x1122334455667788' }
    if ($kind -eq 'guid') { return '11223344-5566-7788-99aa-bbccddeeff00' }
    if ($kind -eq 'cstr') { return 'lct' }
    if ($kind -eq 'bytes') {
        $n = 0
        if ($Spec.fixed) { $n = [int]$Spec.len }
        else { $n = 4 }
        if ($n -lt 1) { $n = 1 }
        $parts = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $n; $i++) { $null = $parts.Add(('{0:x2}' -f ($i + 1))) }
        return ($parts -join '')
    }
    return 0
}

function Get-LctPrfSyntheticSet {
    # 为字段表生成一套可打包的合成值；被 lenFrom 引用的字段给一个「像长度」的值
    param($Fields)
    $specs = New-Object System.Collections.ArrayList
    foreach ($f in @($Fields)) { $null = $specs.Add((ConvertTo-LctPrfFieldSpec -Field $f)) }
    $lenFromRefs = @{}
    foreach ($s in @($specs)) { if ($s.ok -and $s.lenRef -ne '') { $lenFromRefs[$s.lenRef] = $true } }
    $set = @{}
    foreach ($s in @($specs)) {
        if (-not $s.ok) { continue }
        if ($lenFromRefs.ContainsKey($s.name)) { $set[$s.name] = 4 }
        else { $set[$s.name] = Get-LctPrfSyntheticValue -Spec $s }
    }
    # 第二遍：bytes(lenFrom/lenOf) 的字节长度必须与字段实际大小一致，否则沙盒会把自己误报成失败
    foreach ($s in @($specs)) {
        if (-not $s.ok -or $s.kind -ne 'bytes' -or $s.fixed) { continue }
        $need = 4
        if ($s.lenOf -ne '') {
            foreach ($r in @($specs)) { if ($r.ok -and $r.name -eq $s.lenOf -and [int]$r.size -gt 0) { $need = [int]$r.size } }
        } elseif ($s.lenRef -ne '' -and $set.ContainsKey($s.lenRef)) {
            $nv = ConvertTo-LctPrfUInt64 -Value $set[$s.lenRef]
            if ($null -ne $nv -and $nv -ge 1 -and $nv -le 64) { $need = [int]$nv }
        }
        if ($need -lt 1) { $need = 1 }
        $parts2 = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $need; $i++) { $null = $parts2.Add(('{0:x2}' -f ($i + 1))) }
        $set[$s.name] = ($parts2 -join '')
    }
    return $set
}

function Invoke-LctPrfSandbox {
    # 内存沙盒：把 in/out 各打包解包一遍（不碰设备）。out 用「打包→解包→比对」验证解包器。
    param($Profile, [int]$MaxActions = 32)
    $checks = New-Object System.Collections.ArrayList
    $actions = Get-LctPrfProp -Bag $Profile -Name 'actions'
    if ($null -eq $actions -or $actions -isnot [System.Collections.IDictionary]) {
        $null = $checks.Add([pscustomobject][ordered]@{ name = 'sandbox.actions'; passed = $false; detail = 'actions 不是对象，无法沙盒自检' })
        return [pscustomobject][ordered]@{ passed = $false; checks = @($checks); actionCount = 0 }
    }
    $layout = Get-LctPrfProp -Bag $Profile -Name 'layout'
    $names = @($actions.Keys | Sort-Object)
    $n = 0
    foreach ($an in $names) {
        if ($n -ge $MaxActions) { break }
        $n++
        $act = $actions[$an]
        $inFields = @(Get-LctPrfProp -Bag $act -Name 'in' -Default @())
        $outFields = @(Get-LctPrfProp -Bag $act -Name 'out' -Default @())
        $inSet = Get-LctPrfSyntheticSet -Fields $inFields
        $p = ConvertTo-LctPrfBuffer -Fields $inFields -Layout $layout -Values $inSet
        if ($inFields.Count -eq 0) { $p = [pscustomobject][ordered]@{ ok = $true; error = ''; bytes = (New-Object byte[] 0); size = 0; plan = @() } }
        $null = $checks.Add([pscustomobject][ordered]@{
                name   = ('sandbox.pack.in[' + $an + ']')
                passed = [bool]$p.ok
                detail = $(if ($p.ok) { ('size=' + $p.size + ' hex=' + (ConvertTo-LctPrfHex -Bytes $p.bytes)) } else { [string]$p.error })
            })
        if ($outFields.Count -gt 0) {
            $outSet = Get-LctPrfSyntheticSet -Fields $outFields
            $po = ConvertTo-LctPrfBuffer -Fields $outFields -Layout $layout -Values $outSet
            if (-not $po.ok) {
                $null = $checks.Add([pscustomobject][ordered]@{ name = ('sandbox.roundtrip.out[' + $an + ']'); passed = $false; detail = ('out 打包失败: ' + $po.error) })
            } else {
                $un = ConvertFrom-LctPrfBuffer -Fields $outFields -Layout $layout -Buffer $po.bytes -Length $po.size
                $bad = New-Object System.Collections.ArrayList
                if (-not $un.ok) { $null = $bad.Add('解包失败: ' + $un.error) }
                else {
                    foreach ($k in @($outSet.Keys)) {
                        $want = $outSet[$k]
                        $got = $null
                        if ($un.values.Contains($k)) { $got = $un.values[$k] }
                        $same = $false
                        if ($null -ne $got) {
                            if ($got -is [string] -and $want -is [string]) { $same = ($got -ieq $want) }
                            else {
                                $a = ConvertTo-LctPrfUInt64 -Value $got
                                $b = ConvertTo-LctPrfUInt64 -Value $want
                                if ($null -ne $a -and $null -ne $b) { $same = ($a -eq $b) }
                                else { $same = ([string]$got -eq [string]$want) }
                            }
                        }
                        if (-not $same) { $null = $bad.Add(($k + ': 期望 ' + [string]$want + ' 实际 ' + [string]$got)) }
                    }
                }
                $null = $checks.Add([pscustomobject][ordered]@{
                        name   = ('sandbox.roundtrip.out[' + $an + ']')
                        passed = (@($bad).Count -eq 0)
                        detail = $(if (@($bad).Count -eq 0) { ('size=' + $po.size + ' hex=' + (ConvertTo-LctPrfHex -Bytes $po.bytes) + ' 解包回读一致') } else { (@($bad) -join ' / ') })
                    })
            }
        }
    }
    $failed = 0
    foreach ($c in @($checks)) { if (-not $c.passed) { $failed++ } }
    return [pscustomobject][ordered]@{ passed = ($failed -eq 0); checks = @($checks); actionCount = $n }
}

function Get-LctPrfFieldSpecLoop {
    # 供 schema 校验/沙盒按同一套规则遍历字段表（避免重复实现）
    param($Fields)
    $list = New-Object System.Collections.ArrayList
    foreach ($f in @($Fields)) { $null = $list.Add((ConvertTo-LctPrfFieldSpec -Field $f)) }
    return @($list)
}
#endregion

#region 私有：schema 校验（纯数据检查：字段/类型/ioctl/risk/layout + 可执行代码守卫）
function Get-LctPrfAllStrings {
    # 递归收集 profile 里所有字符串（键与值）——用于「纯数据」守卫
    param($Value, [string]$Path = '$', [int]$Depth = 0)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Value -or $Depth -gt 12) { return @($out) }
    if ($Value -is [string]) {
        if (([string]$Value).Trim() -ne '') { $null = $out.Add([pscustomobject][ordered]@{ path = $Path; text = [string]$Value }) }
        return @($out)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in @($Value.Keys)) {
            $sub = (Get-LctPrfAllStrings -Value $Value[$k] -Path ($Path + '.' + [string]$k) -Depth ($Depth + 1))
            foreach ($x in @($sub)) { $null = $out.Add($x) }
        }
        return @($out)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $Value) {
            $sub = (Get-LctPrfAllStrings -Value $item -Path ($Path + '[' + $i + ']') -Depth ($Depth + 1))
            foreach ($x in @($sub)) { $null = $out.Add($x) }
            $i++
        }
        return @($out)
    }
    return @($out)
}

function Test-LctPrfProfileSchema {
    # profile 纯数据 schema 校验（**不做文件指纹比对**：那部分在 Test-LctDriverProfile 里）
    param($Profile, [string]$ProfilePath = '', [string]$ExpectedId = '')
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $info = [ordered]@{
        id = ''; kind = ''; engineApi = 0; fileName = ''; sha256 = ''; sha256AnyOf = @()
        strategy = ''; riskLevel = ''; method = 'buffered'; align = 0; endian = ''; actionCount = 0
        actions = @(); serviceNameHint = ''; interfaceGuid = ''; candidates = @()
    }
    if ($null -eq $Profile -or $Profile -isnot [System.Collections.IDictionary]) {
        $null = $errors.Add('profile 必须是 JSON 对象（顶层是 {…}）')
        return [pscustomobject][ordered]@{ ok = $false; errors = @($errors); warnings = @($warnings); info = [pscustomobject]$info }
    }
    # ---- id / kind / engineApi ----
    $id = [string](Get-LctPrfProp -Bag $Profile -Name 'id' -Default '')
    $info.id = $id
    if ($id -eq '') { $null = $errors.Add('缺 profile.id（必填，用于 -Profile <id> 引用）') }
    elseif ($id -notmatch '^[A-Za-z0-9._\-]{1,128}$') { $null = $errors.Add("profile.id '$id' 非法（只允许字母/数字/点/下划线/连字符，长度 1..128）") }
    elseif ($ExpectedId -ne '' -and $id -ne $ExpectedId) { $null = $errors.Add("profile.id '$id' 与请求的 id '$ExpectedId' 不一致") }
    $kind = [string](Get-LctPrfProp -Bag $Profile -Name 'kind' -Default '')
    $info.kind = $kind
    if ($kind -eq '') { $null = $errors.Add('缺 profile.kind（必须为 ''driver-profile''）') }
    elseif ($kind -ne 'driver-profile') { $null = $errors.Add("profile.kind='$kind' 不是 'driver-profile'（本引擎只接受驱动适配描述）") }
    $api = ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $Profile -Name 'engineApi')
    if ($null -eq $api) { $null = $errors.Add('缺 profile.engineApi（整数，本版支持 1..2）') }
    elseif ($api -lt 1 -or $api -gt 2) { $null = $errors.Add("profile.engineApi=$api 不受支持（本版只支持 1..2）") }
    else { $info.engineApi = [int]$api }
    # ---- target ----
    $target = Get-LctPrfProp -Bag $Profile -Name 'target'
    if ($null -eq $target -or $target -isnot [System.Collections.IDictionary]) {
        $null = $errors.Add('缺 target 对象（至少要 { "sha256": "<.sys 指纹>" }）')
    } else {
        $sha = [string](Get-LctPrfProp -Bag $target -Name 'sha256' -Default '')
        $info.fileName = [string](Get-LctPrfProp -Bag $target -Name 'fileName' -Default '')
        $anyOf = @(Get-LctPrfProp -Bag $target -Name 'sha256AnyOf' -Default @())
        if ($sha -eq '' -and $anyOf.Count -eq 0) {
            $null = $errors.Add('缺 target.sha256（必填：.sys 的 SHA-256 指纹；可用 sha256AnyOf[] 给多个版本）')
        }
        if ($sha -ne '') {
            if ($sha -notmatch '^[0-9a-fA-F]{64}$') { $null = $errors.Add("target.sha256 不是 64 位十六进制: '$sha'") }
            else { $info.sha256 = $sha.ToLower() }
        }
        $i2 = 0
        foreach ($a in $anyOf) {
            $i2++
            $t = [string]$a
            if ($t -notmatch '^[0-9a-fA-F]{64}$') { $null = $errors.Add("target.sha256AnyOf[$i2] 不是 64 位十六进制: '$t'") }
            else { $info.sha256AnyOf += $t.ToLower() }
        }
        if ($info.fileName -eq '') { $null = $warnings.Add('target.fileName 为空：指纹校验/路径解析只能靠 locate.serviceNameHint 或显式 -Path') }
        elseif ($info.fileName -notmatch '(?i)\.sys$') { $null = $warnings.Add("target.fileName '$($info.fileName)' 不是 .sys 结尾（非驱动文件？）") }
        foreach ($k in @($target.Keys)) {
            if (@('sha256', 'sha256AnyOf', 'fileName') -notcontains [string]$k) { $null = $warnings.Add("target 里有引擎不认识的键 '$k'（会被忽略）") }
        }
    }
    # ---- locate ----
    $locate = Get-LctPrfProp -Bag $Profile -Name 'locate'
    if ($null -eq $locate -or $locate -isnot [System.Collections.IDictionary]) {
        $null = $errors.Add('缺 locate 对象（如 { "strategy": "symlink", "candidates": ["\??\RTCore64"] }）')
    } else {
        $strategy = [string](Get-LctPrfProp -Bag $locate -Name 'strategy' -Default '')
        $info.strategy = $strategy
        if ($strategy -eq '') { $null = $errors.Add('缺 locate.strategy（symlink | interfaceGuid | serviceImagePath）') }
        elseif ($script:LctPrfStrategies -notcontains $strategy) { $null = $errors.Add("locate.strategy='$strategy' 非法（可选 " + ($script:LctPrfStrategies -join ' | ') + '）') }
        $cands = @(Get-LctPrfProp -Bag $locate -Name 'candidates' -Default @())
        $info.candidates = $cands
        foreach ($c in $cands) { if ([string]::IsNullOrWhiteSpace([string]$c)) { $null = $errors.Add('locate.candidates 里有空字符串') } }
        $ig = [string](Get-LctPrfProp -Bag $locate -Name 'interfaceGuid' -Default '')
        $info.interfaceGuid = $ig
        $info.serviceNameHint = [string](Get-LctPrfProp -Bag $locate -Name 'serviceNameHint' -Default '')
        if ($strategy -eq 'symlink' -and $cands.Count -eq 0) { $null = $errors.Add('locate.strategy=symlink 时 candidates 不能为空（至少给一个符号链接候选，如 \\??\\X）') }
        if ($strategy -eq 'interfaceGuid') {
            if ($ig -eq '') { $null = $errors.Add('locate.strategy=interfaceGuid 时必须给 locate.interfaceGuid') }
            elseif ($ig -notmatch '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?$') { $null = $errors.Add("locate.interfaceGuid 不是合法 GUID: '$ig'") }
        }
        if ($strategy -eq 'serviceImagePath' -and $info.serviceNameHint -eq '') { $null = $errors.Add('locate.strategy=serviceImagePath 时必须给 locate.serviceNameHint（服务名）') }
        foreach ($k in @($locate.Keys)) {
            if (@('strategy', 'candidates', 'interfaceGuid', 'serviceNameHint', 'openAccess', 'notes') -notcontains [string]$k) { $null = $warnings.Add("locate 里有引擎不认识的键 '$k'（会被忽略）") }
        }
    }
    # ---- actions ----
    $actions = Get-LctPrfProp -Bag $Profile -Name 'actions'
    if ($null -eq $actions -or $actions -isnot [System.Collections.IDictionary]) {
        $null = $errors.Add('缺 actions 对象（至少要一个动作，如 "kread": { "ioctl": "0x80002048", "in": [...], "out": [...] }）')
    } elseif (@($actions.Keys).Count -eq 0) {
        $null = $errors.Add('actions 为空：空 actions 的 profile 不能执行，也不能当作可用 profile（静态草案请走 driver.profile.draft）')
    } else {
        $names = New-Object System.Collections.ArrayList
        foreach ($an in @($actions.Keys)) {
            $aname = [string]$an
            $act = $actions[$an]
            $where = ("actions['" + $aname + "'].")
            if ($aname -notmatch '^[A-Za-z_][A-Za-z0-9_.\-]{0,63}$') { $null = $errors.Add("动作名 '$aname' 非法（字母/数字/下划线/点/连字符，且不以数字开头）") }
            if ($null -eq $act -or $act -isnot [System.Collections.IDictionary]) { $null = $errors.Add($where + '必须是对象'); continue }
            $null = $names.Add($aname)
            $kindA = [string](Get-LctPrfProp -Bag $act -Name 'kind' -Default '')
            if ($kindA -ne '' -and ($script:LctPrfActionKinds -notcontains $kindA)) { $null = $errors.Add($where + "kind='$kindA' 非法（可选 " + ($script:LctPrfActionKinds -join ' | ') + '）') }
            $rc = [string](Get-LctPrfProp -Bag $act -Name 'riskCode' -Default '')
            $ioctl = [string](Get-LctPrfProp -Bag $act -Name 'ioctl' -Default '')
            if ($ioctl -eq '') {
                if ($kindA -ne 'blindscan') { $null = $errors.Add($where + '缺 ioctl（0x 开头的十六进制；只有 kind=blindscan 才允许缺省）') }
            } elseif ($ioctl -notmatch '^0x[0-9a-fA-F]{1,8}$') {
                $null = $errors.Add($where + "ioctl='$ioctl' 非法：必须是 0x 开头的十六进制（1..8 位）")
            } else {
                $iv = ConvertTo-LctPrfUInt64 -Value $ioctl
                if ($null -eq $iv -or $iv -gt 4294967295) { $null = $errors.Add($where + "ioctl='$ioctl' 超出 32 位") }
            }
            foreach ($side in @('in', 'out')) {
                $raw = Get-LctPrfProp -Bag $act -Name $side
                if ($null -eq $raw) { continue }
                if ($raw -isnot [System.Collections.IEnumerable] -or $raw -is [string]) { $null = $errors.Add($where + $side + ' 必须是数组'); continue }
                $i = 0
                foreach ($f in @($raw)) {
                    $i++
                    $spec = ConvertTo-LctPrfFieldSpec -Field $f -Where ($where + $side + '[' + $i + '] ')
                    if (-not $spec.ok) { $null = $errors.Add($spec.error) }
                }
            }
            # lenFrom/lenOf 必须引用同一个动作里、且排在它前面的字段
            foreach ($side in @('in', 'out')) {
                $fl = @(Get-LctPrfProp -Bag $act -Name $side -Default @())
                $specs = @(Get-LctPrfFieldSpecLoop -Fields $fl)
                $before = New-Object System.Collections.ArrayList
                foreach ($s in $specs) {
                    if ($s.ok -and $s.lenRef -ne '') { if (-not ($before -contains $s.lenRef)) { $null = $errors.Add($where + $side + " 字段 '$($s.name)' 的 lenFrom='$($s.lenRef)' 必须先于它出现") } }
                    if ($s.ok -and $s.lenOf -ne '') { if (-not ($before -contains $s.lenOf)) { $null = $errors.Add($where + $side + " 字段 '$($s.name)' 的 lenOf='$($s.lenOf)' 必须先于它出现") } }
                    if ($s.ok) { $null = $before.Add($s.name) }
                }
            }
            foreach ($k in @($act.Keys)) {
                if (@('ioctl', 'in', 'out', 'kind', 'risk', 'readBack', 'notes', 'openAccess', 'blindScanFrom', 'blindScanTo', 'riskCode') -notcontains [string]$k) {
                    $null = $warnings.Add($where + "有引擎不认识的键 '$k'（会被忽略）")
                }
            }
            if (Test-LctPrfProp -Bag $act -Name 'risk') {
                $ra = Get-LctPrfProp -Bag $act -Name 'risk'
                $lv = ''
                if ($ra -is [System.Collections.IDictionary]) { $lv = [string](Get-LctPrfProp -Bag $ra -Name 'level' -Default '') }
                elseif ($ra -is [string]) { $lv = [string]$ra }
                if ($lv -ne '' -and ($script:LctPrfRisks -notcontains $lv)) { $null = $errors.Add($where + "risk.level='$lv' 非法（" + ($script:LctPrfRisks -join ' | ') + '）') }
            }
        }
        $info.actionCount = $names.Count
        $info.actions = @($names)
        if ($names.Count -eq 0) { $null = $errors.Add('actions 里没有任何动作') }
    }
    # ---- layout ----
    $layout = Get-LctPrfProp -Bag $Profile -Name 'layout'
    if ($null -eq $layout) {
        $warnings.Add('未声明 layout：默认 { method: buffered, align: 8, endian: little }') | Out-Null
        $info.method = 'buffered'; $info.align = 8; $info.endian = 'little'
    } elseif ($layout -isnot [System.Collections.IDictionary]) {
        $null = $errors.Add('layout 必须是对象')
    } else {
        $m = [string](Get-LctPrfProp -Bag $layout -Name 'method' -Default 'buffered')
        $info.method = $m
        if ($script:LctPrfMethods -notcontains $m) { $null = $errors.Add("layout.method='$m' 非法（" + ($script:LctPrfMethods -join ' | ') + '）') }
        $al = ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $layout -Name 'align' -Default 8)
        if ($null -eq $al -or $al -lt 1 -or $al -gt 64) { $null = $errors.Add('layout.align 必须是 1..64 的整数') }
        elseif (($al -band ($al - 1)) -ne 0) { $null = $errors.Add("layout.align=$al 不是 2 的幂") }
        else { $info.align = [int]$al }
        $en = [string](Get-LctPrfProp -Bag $layout -Name 'endian' -Default 'little')
        $info.endian = $en
        if ($en -ne 'little') { $null = $errors.Add("layout.endian='$en' 不被支持：首版只支持小端（little）") }
    }
    # ---- risk ----
    $risk = Get-LctPrfProp -Bag $Profile -Name 'risk'
    if ($null -eq $risk) { $info.riskLevel = 'medium' }
    elseif ($risk -is [System.Collections.IDictionary]) {
        $lv = [string](Get-LctPrfProp -Bag $risk -Name 'level' -Default 'medium')
        $info.riskLevel = $lv
        if ($script:LctPrfRisks -notcontains $lv) { $null = $errors.Add("risk.level='$lv' 非法（" + ($script:LctPrfRisks -join ' | ') + '）') }
        if ($lv -eq 'bsod') {
            $notes = [string](Get-LctPrfProp -Bag $risk -Name 'notes' -Default '')
            if ($notes.Trim() -eq '') { $null = $warnings.Add('risk.level=bsod 却没有 risk.notes：请写清「写坏哪个参数会蓝屏」') }
        }
    } elseif ($risk -is [string]) { $info.riskLevel = [string]$risk; $null = $warnings.Add('risk 写成了字符串（建议用对象 { level, notes }）') }
    else { $null = $errors.Add('risk 必须是对象或字符串') }
    # ---- requires / handshake ----
    foreach ($k in @($Profile.Keys)) {
        if (@('id', 'kind', 'engineApi', 'target', 'locate', 'handshake', 'actions', 'layout', 'risk', 'requires', 'readBackAction', 'description', 'author', 'source', 'draft') -notcontains [string]$k) {
            $null = $warnings.Add("profile 顶层有引擎不认识的键 '$k'（会被忽略）")
        }
    }
    $hs = Get-LctPrfProp -Bag $Profile -Name 'handshake'
    if ($null -ne $hs) {
        if ($hs -isnot [System.Collections.IDictionary]) { $null = $errors.Add('handshake 必须是对象') }
        else {
            $ha = [string](Get-LctPrfProp -Bag $hs -Name 'action' -Default '')
            if ($ha -ne '' -and $null -ne $actions -and $actions -is [System.Collections.IDictionary]) {
                if (-not $actions.Contains($ha)) { $null = $errors.Add("handshake.action='$ha' 不在 actions 里（握手动作必须已声明）") }
            }
            $ex = Get-LctPrfProp -Bag $hs -Name 'expect'
            if ($null -ne $ex -and $ex -is [System.Collections.IDictionary]) {
                $ei = [string](Get-LctPrfProp -Bag $ex -Name 'ioctl' -Default '')
                if ($ei -ne '' -and $ei -notmatch '^0x[0-9a-fA-F]{1,8}$') { $null = $errors.Add("handshake.expect.ioctl 非法: '$ei'") }
                if ($ei -ne '' -and $ha -ne '' -and $null -ne $actions -and $actions.Contains($ha)) {
                    $ai = [string](Get-LctPrfProp -Bag $actions[$ha] -Name 'ioctl' -Default '')
                    if ($ai -ne '' -and ($ai.ToLower() -ne $ei.ToLower())) { $null = $errors.Add("handshake.expect.ioctl=$ei 与 actions['$ha'].ioctl=$ai 不一致") }
                }
                $mo = ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $ex -Name 'minOutBytes' -Default 0)
                if ($null -eq $mo) { $null = $errors.Add('handshake.expect.minOutBytes 必须是非负整数') }
            }
        }
    }
    $req = Get-LctPrfProp -Bag $Profile -Name 'requires'
    if ($null -ne $req -and $req -is [System.Collections.IDictionary]) {
        $el = [string](Get-LctPrfProp -Bag $req -Name 'elevation' -Default '')
        if ($el -ne '' -and @('admin', 'system') -notcontains $el) { $null = $errors.Add("requires.elevation='$el' 非法（admin | system）") }
    }
    # ---- 静态草案守卫：needsReview=true 的草案不得当可用 profile ----
    $draftBlock = Get-LctPrfProp -Bag $Profile -Name 'draft'
    if ($null -ne $draftBlock) {
        $nr = Get-LctPrfProp -Bag $draftBlock -Name 'needsReview'
        if ($null -ne $nr -and [bool]$nr) {
            $null = $errors.Add('这是静态草案（draft.needsReview=true）：草案不是可用 profile，必须先人工确认设备名/IOCTL/输入结构并补全 actions 后另存（契约 §13.6 第 6 条）')
        }
    }
    # ---- 纯数据守卫：profile 不得含可执行代码 ----
    foreach ($s in @(Get-LctPrfAllStrings -Value $Profile)) {
        $t = [string]$s.text
        $hit = ''
        foreach ($smell in $script:LctPrfCodeSmell) { if ($t.Contains($smell)) { $hit = $smell; break } }
        if ($hit -eq '' -and $t -match $script:LctPrfCodeSmellRegex) { $hit = $Matches[0] }
        if ($hit -ne '') {
            $null = $errors.Add('profile 是纯数据，检测到疑似可执行代码片段（' + $s.path + ' 含 "' + $hit + '"）；引擎永不 eval profile 内容，此类 profile 一律拒绝')
        }
    }
    return [pscustomobject][ordered]@{
        ok = (@($errors).Count -eq 0); errors = @($errors); warnings = @($warnings); info = [pscustomobject]$info
    }
}

function Write-LctPrfValidationLog {
    param([string]$Verb, [string]$Id, [string]$Path, [bool]$Ok, $Errors, $Warnings)
    $data = [ordered]@{ id = $Id; path = $Path; ok = $Ok; errorCount = @($Errors).Count; warningCount = @($Warnings).Count; errors = @($Errors); warnings = @($Warnings) }
    $lvl = 'info'
    if (-not $Ok) { $lvl = 'warn' }
    $null = Write-LctPrfLog -Verb $Verb -Level $lvl -Message ('profile 校验 id=' + $Id + ' ok=' + $Ok) -Data $data
    return ''
}
#endregion

#region 私有：profile 来源与查找（builtin=core\driver-profiles、user=var\driver-profiles、plugin=plugins\<id>\driver-profiles）
function Get-LctPrfSourceDirs {
    param([AllowEmptyString()][string]$Source = '')
    $s = ([string]$Source).Trim().ToLower()
    $want = @()
    if ($s -eq '') { $want = @('builtin', 'user', 'plugin') } else { $want = @($s) }
    $list = New-Object System.Collections.ArrayList
    foreach ($w in $want) {
        if ($w -eq 'builtin') {
            $null = $list.Add([pscustomobject][ordered]@{ source = 'builtin'; dir = (Join-Path (Get-LctPrfToolRoot) 'core\driver-profiles') })
        } elseif ($w -eq 'user') {
            $null = $list.Add([pscustomobject][ordered]@{ source = 'user'; dir = (Join-Path (Get-LctPrfVarBase) 'driver-profiles') })
        } elseif ($w -eq 'plugin') {
            $proot = Get-LctPrfPluginRoot
            if (Test-Path -LiteralPath $proot) {
                foreach ($d in @(Get-ChildItem -LiteralPath $proot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
                    $null = $list.Add([pscustomobject][ordered]@{ source = ('plugin:' + $d.Name); dir = (Join-Path $d.FullName 'driver-profiles') })
                }
            }
        }
    }
    return @($list)
}

function Get-LctPrfProfileFiles {
    # 只读扫描三个来源；坏 JSON 不丢，带 parseError 报出来（禁止静默跳过）
    param([AllowEmptyString()][string]$Source = '')
    $files = New-Object System.Collections.ArrayList
    foreach ($sd in @(Get-LctPrfSourceDirs -Source $Source)) {
        if (-not (Test-Path -LiteralPath $sd.dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $sd.dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $raw = ''
            $parseError = ''
            $prof = $null
            try { $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) } catch { $parseError = $_.Exception.Message }
            if ($parseError -eq '') {
                # BOM 容错：profile 是 JSON 数据，允许带/不带 BOM（本项目的 .reg.absent / 编码事故都是 BOM 读回不一致）
                $rawBody = $raw.TrimStart([char]0xFEFF)
                if ($rawBody.Trim() -eq '') { $parseError = '文件为空' }
                else { try { $prof = ConvertTo-LctPrfPlain -Value ($rawBody | ConvertFrom-Json) } catch { $parseError = $_.Exception.Message } }
            }
            $itemId = ''
            if ($null -ne $prof) { $itemId = [string](Get-LctPrfProp -Bag $prof -Name 'id' -Default '') }
            if ($itemId -eq '') { $itemId = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $null = $files.Add([pscustomobject][ordered]@{
                    id = $itemId; source = $sd.source; path = $f.FullName; fileName = $f.Name
                    raw = $raw; profile = $prof; parseError = $parseError
                })
        }
    }
    return @($files)
}

function Find-LctPrfProfile {
    param([string]$Id)
    $want = ([string]$Id).Trim()
    if ($want -eq '') { return [pscustomobject][ordered]@{ ok = $false; error = '缺少 profile id'; profile = $null; source = ''; path = ''; parseError = ''; id = '' } }
    $notFoundResult = [pscustomobject][ordered]@{ ok = $false; error = ''; profile = $null; source = ''; path = ''; parseError = ''; id = $want }
    $files = Get-LctPrfProfileFiles -Source ''
    $broken = $null
    foreach ($f in @($files)) {
        if ([IO.Path]::GetFileNameWithoutExtension($f.fileName) -ieq $want -and $f.parseError -ne '') { $broken = $f; continue }
        if ($f.parseError -ne '' -or $null -eq $f.profile) { continue }
        if ([string]$f.profile['id'] -ieq $want -or [IO.Path]::GetFileNameWithoutExtension($f.fileName) -ieq $want) {
            return [pscustomobject][ordered]@{ ok = $true; error = ''; profile = $f.profile; source = $f.source; path = $f.path; parseError = ''; id = [string]$f.profile['id'] }
        }
    }
    if ($null -ne $broken) {
        $notFoundResult.error = ('profile 文件存在但 JSON 解析失败: ' + $broken.path + ' -> ' + $broken.parseError)
        return $notFoundResult
    }
    $where = @()
    foreach ($sd in @(Get-LctPrfSourceDirs -Source '')) { $where += ($sd.source + '=' + $sd.dir) }
    $notFoundResult.error = ('profile 不存在: ' + $want + '（搜索范围: ' + ($where -join ' ; ') + '）')
    return $notFoundResult
}

function Get-LctPrfProfileSearchInfo {
    param()
    $rows = New-Object System.Collections.ArrayList
    foreach ($sd in @(Get-LctPrfSourceDirs -Source '')) {
        $n = -1
        if (Test-Path -LiteralPath $sd.dir) { $n = @(Get-ChildItem -LiteralPath $sd.dir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count }
        $null = $rows.Add([pscustomobject][ordered]@{ source = $sd.source; dir = $sd.dir; exists = [bool](Test-Path -LiteralPath $sd.dir); jsonCount = $n })
    }
    return @($rows)
}
#endregion

#region 私有：.sys 路径解析（注册表权威 → 回退 → DriverStore 反查；全部只读）
function ConvertTo-LctPrfLocalImagePath {
    # 注册表 ImagePath 的常见形态：'\??\C:\...'、'\SystemRoot\System32\...'、'System32\...'、'"C:\... x\y.sys"'
    param([AllowEmptyString()][string]$ImagePath = '')
    $p = ([string]$ImagePath).Trim()
    if ($p.Length -gt 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { $p = $p.Substring(1, $p.Length - 2) }
    $p = $p -replace '^\\\?\?\\', ''
    if ($p -match '(?i)^\\SystemRoot\\') { $p = (Join-Path $env:SystemRoot $p.Substring(12)) }
    elseif ($p -match '(?i)^System32\\') { $p = (Join-Path $env:SystemRoot $p) }
    return $p.Trim()
}

function Get-LctPrfServiceImagePath {
    param([string]$Name)
    $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $o = [ordered]@{ keyPath = $keyPath; exists = $false; imagePath = ''; start = -1; type = -1; error = '' }
    try {
        if (-not (Test-Path -LiteralPath $keyPath)) { return [pscustomobject]$o }
        $o.exists = $true
        $k = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
        if ($null -ne $k) {
            if ($null -ne $k.PSObject.Properties['ImagePath']) { $o.imagePath = [string]$k.ImagePath }
            if ($null -ne $k.PSObject.Properties['Start']) { try { $o.start = [int]$k.Start } catch { $o.start = -1 } }
            if ($null -ne $k.PSObject.Properties['Type']) { try { $o.type = [int]$k.Type } catch { $o.type = -1 } }
        }
    } catch { $o.error = $_.Exception.Message }
    return [pscustomobject]$o
}

function Get-LctPrfDriverStoreBySha256 {
    # 只读反查：DriverStore\FileRepository 里按 SHA256 找 .sys。开销大 ⇒ 默认按文件名预过滤、有上限、可截断。
    param([string]$Sha256, [string]$FileName = '', [int]$Limit = 1500, [int]$MaxSeconds = 25)
    $o = [ordered]@{ ok = $false; found = $false; path = ''; scanned = 0; truncated = $false; note = ''; error = ''; elapsedSec = 0; candidates = @() }
    $want = ([string]$Sha256).Trim().ToLower()
    if ($want -notmatch '^[0-9a-f]{64}$') { $o.error = '按 SHA256 反查需要 64 位十六进制指纹'; return [pscustomobject]$o }
    $dsRoot = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $dsRoot)) { $o.error = '本机没有 DriverStore\FileRepository 目录'; return [pscustomobject]$o }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $filter = '*.sys'
    if (-not [string]::IsNullOrWhiteSpace($FileName)) { $filter = '*' + [IO.Path]::GetFileNameWithoutExtension($FileName) + '*.sys'; $o.note = '已按文件名预过滤：' + $filter }
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $dsRoot -Filter $filter -File -Recurse -ErrorAction SilentlyContinue) } catch { $o.error = $_.Exception.Message; return [pscustomobject]$o }
    if ($files.Count -gt $Limit) { $o.truncated = $true; $files = @($files[0..($Limit - 1)]) }
    foreach ($f in $files) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { $o.truncated = $true; $o.note = ($o.note + ' 达到时间上限 ' + $MaxSeconds + 's，已停止枚举').Trim(); break }
        $o.scanned++
        $h = Get-LctPrfSha256 -Path $f.FullName
        if ($h -ne '' -and $h.ToLower() -eq $want) {
            $o.ok = $true; $o.found = $true; $o.path = $f.FullName
            $o.candidates = @($f.FullName)
            break
        }
    }
    $sw.Stop()
    $o.elapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    if (-not $o.found -and $o.error -eq '') { $o.note = ($o.note + ' 已扫描 ' + $o.scanned + ' 个 .sys，未命中指纹').Trim() }
    return [pscustomobject]$o
}

function Resolve-LctPrfSysPath {
    # 定位 .sys：显式 -Path → profile 的 fileName（绝对/相对 profile 目录）→ 注册表 ImagePath →
    # System32\drivers\<name>.sys → 按 SHA256 去 DriverStore 反查（只读）。找不到就如实报「找不到」，不猜。
    param(
        [string]$ServiceName = '', [string]$FileName = '', [string]$ExplicitPath = '',
        [string]$ProfileDir = '', [string]$Sha256 = '', [switch]$AllowDriveStoreScan, [int]$DriveStoreLimit = 1500
    )
    $attempts = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $sysDrivers = Join-Path $env:SystemRoot 'System32\drivers'
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) { $null = $cands.Add([pscustomobject]@{ source = 'explicit'; path = $ExplicitPath }) }
    if (-not [string]::IsNullOrWhiteSpace($FileName)) {
        if ([IO.Path]::IsPathRooted($FileName)) { $null = $cands.Add([pscustomobject]@{ source = 'targetFileName(absolute)'; path = $FileName }) }
        if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) { $null = $cands.Add([pscustomobject]@{ source = 'targetFileName(next to profile)'; path = (Join-Path $ProfileDir $FileName) }) }
    }
    $reg = $null
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        $reg = Get-LctPrfServiceImagePath -Name $ServiceName
        if ($reg.exists) {
            if (-not [string]::IsNullOrWhiteSpace($reg.imagePath)) {
                $null = $cands.Add([pscustomobject]@{ source = 'registryImagePath'; path = (ConvertTo-LctPrfLocalImagePath -ImagePath $reg.imagePath) })
            } else { $null = $notes.Add(('服务 ' + $ServiceName + ' 的 ImagePath 为空 ⇒ 按约定回退到 System32\drivers\<name>.sys')) }
        } else { $null = $notes.Add(('注册表里没有服务 ' + $ServiceName + '（HKLM\SYSTEM\CurrentControlSet\Services\' + $ServiceName + '）')) }
        $null = $cands.Add([pscustomobject]@{ source = 'driversDirByServiceName'; path = (Join-Path $sysDrivers ($ServiceName + '.sys')) })
    }
    if (-not [string]::IsNullOrWhiteSpace($FileName)) { $null = $cands.Add([pscustomobject]@{ source = 'driversDirByFileName'; path = (Join-Path $sysDrivers ([IO.Path]::GetFileName($FileName))) }) }
    # 样本库候选：var\samples\<FileName> 与 var\samples\*.sys（按 SHA256 精确匹配）
    # 这样「samples.get 拿到文件」之后，ctl.send 不用再让人手动指路。
    $sampleDir = ''
    try { $sampleDir = Join-Path (Get-LctVarDir) 'samples' } catch { $sampleDir = '' }
    if ($sampleDir -ne '' -and (Test-Path -LiteralPath $sampleDir)) {
        if (-not [string]::IsNullOrWhiteSpace($FileName)) {
            $null = $cands.Add([pscustomobject]@{ source = 'sampleStoreByFileName'; path = (Join-Path $sampleDir ([IO.Path]::GetFileName($FileName))) })
        }
        if ($Sha256 -match '^[0-9a-fA-F]{64}$') {
            foreach ($sf in @(Get-ChildItem -LiteralPath $sampleDir -Filter '*.sys' -File -ErrorAction SilentlyContinue)) {
                $sh = ''
                try { $sh = Get-LctPrfSha256 -Path $sf.FullName } catch { $sh = '' }
                if ($sh -ieq $Sha256) {
                    $null = $cands.Add([pscustomobject]@{ source = 'sampleStoreBySha256'; path = $sf.FullName })
                    break
                }
            }
        }
    }
    foreach ($c in @($cands)) {
        $p = [string]$c.path
        $exists = $false
        if (-not [string]::IsNullOrWhiteSpace($p)) { try { $exists = [bool](Test-Path -LiteralPath $p -PathType Leaf) } catch { $exists = $false } }
        $null = $attempts.Add([pscustomobject][ordered]@{ source = $c.source; path = $p; exists = $exists })
        if ($exists) {
            return [pscustomobject][ordered]@{
                ok = $true; path = $p; exists = $true; resolution = $c.source; attempts = @($attempts); notes = @($notes); sha256 = (Get-LctPrfSha256 -Path $p)
                service = $reg; error = ''
            }
        }
    }
    $ds = $null
    if ($AllowDriveStoreScan -and $Sha256 -match '^[0-9a-fA-F]{64}$') {
        $ds = Get-LctPrfDriverStoreBySha256 -Sha256 $Sha256 -FileName $FileName -Limit $DriveStoreLimit
        $null = $attempts.Add([pscustomobject][ordered]@{ source = 'driverStoreBySha256'; path = $ds.path; exists = [bool]$ds.found })
        if ($ds.found) {
            return [pscustomobject][ordered]@{
                ok = $true; path = $ds.path; exists = $true; resolution = 'driverStoreBySha256'; attempts = @($attempts); notes = @($notes); sha256 = (Get-LctPrfSha256 -Path $ds.path)
                service = $reg; error = ''; driverStore = $ds
            }
        }
        if ($ds.note -ne '') { $null = $notes.Add('DriverStore 反查: ' + $ds.note) }
        if ($ds.error -ne '') { $null = $notes.Add('DriverStore 反查失败: ' + $ds.error) }
    }
    return [pscustomobject][ordered]@{
        ok = $false; path = ''; exists = $false; resolution = 'none'; attempts = @($attempts); notes = @($notes); sha256 = ''
        service = $reg; driverStore = $ds
        error = ('无法定位 .sys：' + [string]$ServiceName + [string]$FileName + ' 的所有候选路径都不存在（注册表 ImagePath 与回退路径都试过）。可用 -Path 显式指定，或先用 driver.devices -Name <service> 确认服务名')
    }
}
#endregion

#region 私有：PE 静态解析（自己读 DOS/NT/节表/导入表，不依赖外部工具；全部只读）
function Get-LctPrfLatin1Encoding {
    param()
    if ($null -eq $script:LctPrfLatin1) { $script:LctPrfLatin1 = [Text.Encoding]::GetEncoding(28591) }
    return $script:LctPrfLatin1
}

function Get-LctPrfLatin1 {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return (Get-LctPrfLatin1Encoding).GetString($Bytes)
}

function Read-LctPrfU16 {
    param([byte[]]$Image, [int]$Offset)
    if ($null -eq $Image -or $Offset -lt 0 -or ($Offset + 2) -gt $Image.Length) { return $null }
    return [uint16][BitConverter]::ToUInt16($Image, $Offset)
}

function Read-LctPrfU32 {
    param([byte[]]$Image, [int]$Offset)
    if ($null -eq $Image -or $Offset -lt 0 -or ($Offset + 4) -gt $Image.Length) { return $null }
    return [uint32][BitConverter]::ToUInt32($Image, $Offset)
}

function Read-LctPrfU64 {
    param([byte[]]$Image, [int]$Offset)
    if ($null -eq $Image -or $Offset -lt 0 -or ($Offset + 8) -gt $Image.Length) { return $null }
    return [uint64][BitConverter]::ToUInt64($Image, $Offset)
}

function Read-LctPrfAsciiZ {
    param([byte[]]$Image, [int]$Offset, [int]$Max = 512)
    if ($null -eq $Image -or $Offset -lt 0 -or $Offset -ge $Image.Length) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $i = $Offset
    $n = 0
    while ($i -lt $Image.Length -and $n -lt $Max) {
        $b = [int]$Image[$i]
        if ($b -eq 0) { break }
        if ($b -ge 32 -and $b -le 126) { $null = $sb.Append([char]$b) } else { $null = $sb.Append('.') }
        $i++
        $n++
    }
    return [string]$sb.ToString()
}

function ConvertFrom-LctPrfRvaToOffset {
    param($Sections, [uint32]$Rva)
    if ($null -eq $Sections) { return -1 }
    foreach ($s in @($Sections)) {
        if ($Rva -ge [uint32]$s.va -and $Rva -lt ([uint32]$s.va + [uint32]$s.vsize)) { return ([int]$s.raw + ([int]$Rva - [int]$s.va)) }
    }
    return -1
}

function ConvertFrom-LctPrfOffsetToRva {
    param($Sections, [int]$Offset)
    if ($null -eq $Sections -or $Offset -lt 0) { return -1 }
    foreach ($s in @($Sections)) {
        if ([int]$s.rawsize -le 0) { continue }
        if ($Offset -ge [int]$s.raw -and $Offset -lt ([int]$s.raw + [int]$s.rawsize)) { return ([int]$s.va + ($Offset - [int]$s.raw)) }
    }
    return -1
}

function Get-LctPrfMachineName {
    param([uint16]$Machine)
    if ($Machine -eq 0x014C) { return 'x86' }
    if ($Machine -eq 0x8664) { return 'x64' }
    if ($Machine -eq 0xAA64) { return 'arm64' }
    if ($Machine -eq 0x01C0) { return 'arm' }
    return ('unknown(0x' + ('{0:X}' -f $Machine) + ')')
}

function Get-LctPrfImportWatchList {
    param()
    return @('IoCreateDevice', 'IoCreateDeviceSecure', 'IoCreateSymbolicLink', 'IoCreateSymbolicLink2', 'IoDeleteSymbolicLink',
        'IoDeleteDevice', 'IofCompleteRequest', 'RtlInitUnicodeString', 'ExAllocatePoolWithTag', 'ExFreePoolWithTag',
        'MmCopyVirtualMemory', 'MmCopyMemory', 'MmMapIoSpace', 'MmUnmapIoSpace', 'MmMapLockedPagesSpecifyCache',
        'MmProbeAndLockPages', 'ZwOpenProcess', 'ZwOpenProcessTokenEx', 'ZwQuerySystemInformation', 'ZwProtectVirtualMemory',
        'ZwReadVirtualMemory', 'ZwWriteVirtualMemory', 'PsLookupProcessByProcessId', 'PsGetCurrentProcess',
        'ObReferenceObjectByHandle', 'KeStackAttachProcess', 'KeUnstackDetachProcess', 'KeBugCheckEx', 'DbgPrint',
        '__C_specific_handler', 'KiAttachProcess')
}

function Get-LctPrfPeImage {
    # 静态 PE 解析 + 证据抽取（设备名候选 / IOCTL 候选 / 输入大小提示）。全部只读，不执行任何代码。
    param([string]$Path, [int]$MaxBytes = 67108864)
    $o = [ordered]@{
        ok = $false; error = ''; path = $Path; sizeBytes = 0; sha256 = ''
        machine = 0; machineName = ''; peKind = ''; numberOfSections = 0; timestamp = 0; subsystem = 0
        imageBase = [uint64]0; entryPoint = 0; sections = @(); imports = @(); importedNames = @(); importsOfInterest = @()
        asciiStringCount = 0; wideStringCount = 0; deviceNameCandidates = @(); candidatesFound = 0
        ioctlCandidates = @(); ioctlCandidateCount = 0; ioctlScanTruncated = $false; inputSizeHints = @()
        scanMethods = @(); notes = (New-Object System.Collections.ArrayList)
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $o.error = '缺少路径'; return [pscustomobject]$o }
    $img = $null
    try {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($fi.PSIsContainer) { $o.error = '这是一个目录，不是文件'; return [pscustomobject]$o }
        if ($fi.Length -le 0) { $o.error = '文件长度为 0'; return [pscustomobject]$o }
        if ($fi.Length -gt $MaxBytes) { $o.error = ('文件太大（' + $fi.Length + ' 字节 > 上限 ' + $MaxBytes + '），拒绝静态解析'); return [pscustomobject]$o }
        $o.sizeBytes = [long]$fi.Length
        $o.sha256 = Get-LctPrfSha256 -Path $Path
        $img = [IO.File]::ReadAllBytes($fi.FullName)
    } catch { $o.error = '读文件失败: ' + $_.Exception.Message; return [pscustomobject]$o }
    if ($img.Length -lt 64) { $o.error = '文件太小，不是 PE 映像'; return [pscustomobject]$o }
    if ([int]$img[0] -ne 0x4D -or [int]$img[1] -ne 0x5A) { $o.error = '不是 PE 映像：DOS 头缺 MZ'; return [pscustomobject]$o }
    $eLfanew = Read-LctPrfU32 -Image $img -Offset 0x3C
    if ($null -eq $eLfanew -or $eLfanew -le 0 -or ($eLfanew + 24) -gt $img.Length) { $o.error = 'PE 头偏移非法（e_lfanew 越界）'; return [pscustomobject]$o }
    $peOff = [int]$eLfanew
    if ([int]$img[$peOff] -ne 0x50 -or [int]$img[$peOff + 1] -ne 0x45 -or [int]$img[$peOff + 2] -ne 0 -or [int]$img[$peOff + 3] -ne 0) { $o.error = '不是 PE 映像：PE\0\0 签名不匹配'; return [pscustomobject]$o }
    # COFF 头
    $machine = Read-LctPrfU16 -Image $img -Offset ($peOff + 4)
    $nsec = Read-LctPrfU16 -Image $img -Offset ($peOff + 6)
    $tstamp = Read-LctPrfU32 -Image $img -Offset ($peOff + 8)
    $optSize = Read-LctPrfU16 -Image $img -Offset ($peOff + 20)
    $o.machine = [int]$machine
    $o.machineName = Get-LctPrfMachineName -Machine $machine
    $o.numberOfSections = [int]$nsec
    $o.timestamp = [uint32]$tstamp
    $optOff = $peOff + 24
    if ($optSize -lt 2 -or ($optOff + $optSize) -gt $img.Length) { $o.error = '可选头越界'; return [pscustomobject]$o }
    $magic = Read-LctPrfU16 -Image $img -Offset $optOff
    $is64 = ($magic -eq 0x20B)
    if ($magic -eq 0x10B) { $o.peKind = 'PE32' } elseif ($is64) { $o.peKind = 'PE32+' } else { $o.error = ('可选头 magic 未知: 0x' + ('{0:X}' -f $magic)); return [pscustomobject]$o }
    $o.entryPoint = [uint32](Read-LctPrfU32 -Image $img -Offset ($optOff + 16))
    $o.imageBase = [uint64](Read-LctPrfU32 -Image $img -Offset ($optOff + 28))
    if ($is64) { $o.imageBase = [uint64](Read-LctPrfU64 -Image $img -Offset ($optOff + 24)) }
    $o.subsystem = [int](Read-LctPrfU16 -Image $img -Offset ($optOff + 68))
    # 数据目录
    $ddCount = 0
    $ddOff = 0
    if ($is64) { $ddCount = [int](Read-LctPrfU32 -Image $img -Offset ($optOff + 108)); $ddOff = $optOff + 112 }
    else { $ddCount = [int](Read-LctPrfU32 -Image $img -Offset ($optOff + 92)); $ddOff = $optOff + 96 }
    $importRva = [uint32]0
    if ($ddCount -ge 2) { $importRva = [uint32](Read-LctPrfU32 -Image $img -Offset ($ddOff + 8)) }
    # 节表
    $secOff = $optOff + $optSize
    $sections = New-Object System.Collections.ArrayList
    for ($si = 0; $si -lt [int]$nsec; $si++) {
        $so = $secOff + ($si * 40)
        if (($so + 40) -gt $img.Length) { break }
        $nm = Read-LctPrfAsciiZ -Image $img -Offset $so -Max 8
        $vsize = [uint32](Read-LctPrfU32 -Image $img -Offset ($so + 8))
        $va = [uint32](Read-LctPrfU32 -Image $img -Offset ($so + 12))
        $rsize = [uint32](Read-LctPrfU32 -Image $img -Offset ($so + 16))
        $raw = [uint32](Read-LctPrfU32 -Image $img -Offset ($so + 20))
        $chars = [uint32](Read-LctPrfU32 -Image $img -Offset ($so + 36))
        $null = $sections.Add([pscustomobject][ordered]@{ name = $nm; va = $va; vsize = $vsize; raw = $raw; rawsize = $rsize; chars = $chars })
    }
    $o.sections = @($sections)
    # 导入表
    $imports = New-Object System.Collections.ArrayList
    $impNames = New-Object System.Collections.ArrayList
    if ($importRva -gt 0) {
        $descOff = ConvertFrom-LctPrfRvaToOffset -Sections $sections -Rva $importRva
        if ($descOff -ge 0) {
            for ($di = 0; $di -lt 256; $di++) {
                $do = $descOff + ($di * 20)
                if (($do + 20) -gt $img.Length) { break }
                $oft = [uint32](Read-LctPrfU32 -Image $img -Offset $do)
                $nameRva = [uint32](Read-LctPrfU32 -Image $img -Offset ($do + 12))
                $ft = [uint32](Read-LctPrfU32 -Image $img -Offset ($do + 16))
                if ($oft -eq 0 -and $nameRva -eq 0 -and $ft -eq 0) { break }
                $dll = ''
                if ($nameRva -gt 0) {
                    $no = ConvertFrom-LctPrfRvaToOffset -Sections $sections -Rva $nameRva
                    if ($no -ge 0) { $dll = Read-LctPrfAsciiZ -Image $img -Offset $no -Max 260 }
                }
                if ($dll -eq '') { $dll = '(name?)' }
                $thunkRva = $oft
                if ($thunkRva -eq 0) { $thunkRva = $ft }
                $fnNames = New-Object System.Collections.ArrayList
                $to = ConvertFrom-LctPrfRvaToOffset -Sections $sections -Rva $thunkRva
                if ($to -ge 0) {
                    $step = 4
                    if ($is64) { $step = 8 }
                    for ($ti = 0; $ti -lt 4096; $ti++) {
                        $tv = [uint64]0
                        if ($is64) { $tv = [uint64](Read-LctPrfU64 -Image $img -Offset ($to + $ti * 8)) }
                        else { $tv = [uint64](Read-LctPrfU32 -Image $img -Offset ($to + $ti * 4)) }
                        if ($tv -eq 0) { break }
                        $isOrd = $false
                        if ($is64) { if (($tv -band [uint64]'0x8000000000000000') -ne 0) { $isOrd = $true } }
                        else { if (($tv -band 0x80000000) -ne 0) { $isOrd = $true } }
                        if ($isOrd) {
                            $null = $fnNames.Add('#ord' + [string]($tv -band 0xFFFF))
                            continue
                        }
                        $nn = ConvertFrom-LctPrfRvaToOffset -Sections $sections -Rva ([uint32]$tv)
                        if ($nn -ge 0) {
                            $fname = Read-LctPrfAsciiZ -Image $img -Offset ($nn + 2) -Max 260
                            $null = $fnNames.Add($fname)
                            $null = $impNames.Add($fname)
                        }
                    }
                }
                $null = $imports.Add([pscustomobject][ordered]@{ dll = $dll; functionCount = $fnNames.Count; functions = @($fnNames) })
            }
        }
    }
    $o.imports = @($imports)
    $o.importedNames = @($impNames)
    $watch = Get-LctPrfImportWatchList
    $interest = New-Object System.Collections.ArrayList
    foreach ($n in @($impNames)) {
        if ($watch -contains $n) { $null = $interest.Add($n) }
        elseif ($n -match '^(MmCopy|MmMap|Zw(Read|Write)VirtualMemory|KiAttach|KeStackAttach)' ) { $null = $interest.Add($n) }
    }
    $o.importsOfInterest = @($interest | Sort-Object -Unique)
    # ---- 字符串扫描（ASCII + UTF-16LE），只留与设备名相关的 ----
    $hay = Get-LctPrfLatin1 -Bytes $img
    $devs = New-Object System.Collections.ArrayList
    $asciiSeen = 0
    $rxAscii = [regex]'[ -~]{4,}'
    foreach ($m in $rxAscii.Matches($hay)) {
        $asciiSeen++
        if ($asciiSeen -gt 20000) { break }
        $t = [string]$m.Value
        if ($t.Length -gt 512) { continue }
        $hit = $false
        foreach ($pfx in $script:LctPrfDevPrefixes) { if ($t.Contains($pfx)) { $hit = $true; break } }
        if (-not $hit) { continue }
        $rva = ConvertFrom-LctPrfOffsetToRva -Sections $sections -Offset $m.Index
        $null = $devs.Add([pscustomobject][ordered]@{ text = $t; width = 'ascii'; fileOffset = $m.Index; rva = $rva; xrefs = 0 })
        if (@($devs).Count -ge $script:LctPrfMaxStrings) { break }
    }
    $wideSeen = 0
    $rxWide = [regex]'(?:[\x20-\x7E]\x00){4,}'
    foreach ($m in $rxWide.Matches($hay)) {
        $wideSeen++
        if ($wideSeen -gt 20000) { break }
        $rawText = $m.Value
        $chars = New-Object System.Text.StringBuilder
        for ($k = 0; $k -lt $rawText.Length; $k += 2) { $null = $chars.Append($rawText[$k]) }
        $t = [string]$chars.ToString()
        if ($t.Length -gt 512) { continue }
        $hit = $false
        foreach ($pfx in $script:LctPrfDevPrefixes) { if ($t.Contains($pfx)) { $hit = $true; break } }
        if (-not $hit) { continue }
        $rva = ConvertFrom-LctPrfOffsetToRva -Sections $sections -Offset $m.Index
        $null = $devs.Add([pscustomobject][ordered]@{ text = $t; width = 'utf16le'; fileOffset = $m.Index; rva = $rva; xrefs = 0 })
        if (@($devs).Count -ge $script:LctPrfMaxStrings) { break }
    }
    $o.asciiStringCount = $asciiSeen
    $o.wideStringCount = $wideSeen
    # ---- xref 证据：rip-relative lea/mov + 文件内 4/8 字节指针值 ----
    $ripTargets = @{}
    $rxRip = [regex]'[\x48\x4C][\x8D\x8B][\x05\x0D\x15\x1D\x25\x2D\x35\x3D][\s\S]{4}'
    $ripCount = 0
    foreach ($m in $rxRip.Matches($hay)) {
        if ($ripCount -gt 200000) { break }
        $ripCount++
        $disp = [BitConverter]::ToInt32($img, $m.Index + 3)
        $rvaHere = ConvertFrom-LctPrfOffsetToRva -Sections $sections -Offset $m.Index
        if ($rvaHere -lt 0) { continue }
        $target = [int64]$rvaHere + 7 + [int64]$disp
        if ($target -gt 0 -and $target -lt 2147483647) {
            $k2 = [int]$target
            if ($ripTargets.ContainsKey($k2)) { continue }
            $ripTargets[$k2] = $true
        }
    }
    $o.scanMethods = @('regex-latin1-window(u32 cmp imm32)', 'regex-rip-relative-lea+mov', 'regex-printable-strings(ascii+utf16le)')
    foreach ($d in @($devs)) {
        $c = 0
        if ([int]$d.rva -gt 0) {
            if ($ripTargets.ContainsKey([int]$d.rva)) { $c++ }
            $pat = [BitConverter]::GetBytes([uint32]$d.rva)
            $needle = Get-LctPrfLatin1 -Bytes $pat
            $idx = 0
            $hits = 0
            while ($hits -lt 16) {
                $idx = $hay.IndexOf($needle, $idx, [StringComparison]::Ordinal)
                if ($idx -lt 0) { break }
                $hits++
                $idx++
            }
            $c += $hits
            try {
                $vaBytes = [BitConverter]::GetBytes([uint64]([uint64]$o.imageBase + [uint64]$d.rva))
                $needleVa = Get-LctPrfLatin1 -Bytes $vaBytes
                $idx2 = 0
                $hits2 = 0
                while ($hits2 -lt 16) {
                    $idx2 = $hay.IndexOf($needleVa, $idx2, [StringComparison]::Ordinal)
                    if ($idx2 -lt 0) { break }
                    $hits2++
                    $idx2++
                }
                $c += $hits2
            } catch { }
        }
        $d.xrefs = $c
    }
    $o.deviceNameCandidates = @($devs)
    $o.candidatesFound = @($devs).Count
    if ($o.candidatesFound -eq 0) {
        $null = $o.notes.Add('candidatesFound=0：静态字符串扫描没找到任何 \Device\ / \??\ / \DosDevices\ / \GLOBALROOT\ 形态的设备名——这很常见（设备名可能是运行时拼接或加密的）。**不编造候选**，请人工逆向或直接问驱动作者。')
    }
    # ---- IOCTL 候选：CMP reg, imm32（Method 位与 DeviceType 位做可信度分层）----
    $rxCmp = [regex]'\x3D[\s\S]{4}|\x81[\xF8-\xFF][\s\S]{4}|\x41\x3D[\s\S]{4}|\x41\x81[\xF8-\xFF][\s\S]{4}'
    $byVal = @{}
    $totalCmp = 0
    $kept = 0
    foreach ($m in $rxCmp.Matches($hay)) {
        $totalCmp++
        $immOff = $m.Index + $m.Length - 4
        if (($immOff + 4) -gt $img.Length) { continue }
        $imm = [uint32][BitConverter]::ToUInt32($img, $immOff)
        $imm64 = [int64]$imm
        $high = $imm64 -band 0xF0000000
        $dtype = ($imm64 -shr 16) -band 0xFFFF
        $func = ($imm64 -shr 2) -band 0xFFF
        $meth = $imm64 -band 3
        $tier = ''
        if (@(0x80000000, 0x90000000, 0xA0000000, 0xC0000000) -contains $high) { $tier = 'likely' }
        elseif ((($dtype -ge 0x8000 -and $dtype -le 0xFFFF) -or ($dtype -ge 1 -and $dtype -le 0x27)) -and $func -ne 0 -and $meth -ne 3) { $tier = 'possible' }
        if ($tier -eq '') { continue }
        $key = [string]$imm
        if ($byVal.ContainsKey($key)) {
            $byVal[$key].count = $byVal[$key].count + 1
            if (@($byVal[$key].fileOffsets).Count -lt 6) { $byVal[$key].fileOffsets = @($byVal[$key].fileOffsets) + $immOff }
        } else {
            if ($kept -ge $script:LctPrfMaxIoctl) { $o.ioctlScanTruncated = $true; continue }
            $kept++
            $byVal[$key] = [pscustomobject][ordered]@{
                value = $imm; hex = ('0x' + ('{0:X8}' -f $imm)); tier = $tier; count = 1; method = $meth
                methodName = @('buffered', 'in-direct', 'out-direct', 'neither')[([int]$meth)]
                methodRisky = ($meth -eq 3); deviceType = ('0x' + ('{0:X4}' -f $dtype)); function = ('0x' + ('{0:X3}' -f $func))
                fileOffsets = @($immOff); xrefHint = 'heuristic'
            }
        }
    }
    $cands = New-Object System.Collections.ArrayList
    foreach ($k in @($byVal.Keys | Sort-Object)) { $null = $cands.Add($byVal[$k]) }
    $o.ioctlCandidates = @($cands)
    $o.ioctlCandidateCount = @($cands).Count
    if (@($cands).Count -eq 0) { $null = $o.notes.Add('ioctlCandidates=0：没有扫到像 IOCTL 的 CMP 立即数（可能是跳转表分派或先做位运算）。不编造。') }
    else { $null = $o.notes.Add('IOCTL 候选来自 CMP reg,imm32 的启发式筛选（DeviceType/Method 位分层），**必须人工确认后才可写入 actions**。') }
    # ---- 输入大小提示：IOCTL 判断点附近的小立即数比较 ----
    $hints = New-Object System.Collections.ArrayList
    foreach ($c in @($cands)) {
        $list = New-Object System.Collections.ArrayList
        foreach ($fo in @($c.fileOffsets)) {
            $lo = [Math]::Max(0, [int]$fo - 96)
            $hi = [Math]::Min($hay.Length, [int]$fo + 96)
            if ($hi -le $lo) { continue }
            $win = $hay.Substring($lo, $hi - $lo)
            foreach ($mm in $rxCmp.Matches($win)) {
                $io = $lo + $mm.Index + $mm.Length - 4
                if (($io + 4) -gt $img.Length) { continue }
                $iv = [int64][BitConverter]::ToUInt32($img, $io)
                if ($iv -lt 1 -or $iv -gt 65536) { continue }
                if ($iv -eq [int64]$c.value) { continue }
                $add = $true
                foreach ($x in @($list)) { if ([int64]$x -eq $iv) { $add = $false; break } }
                if ($add -and @($list).Count -lt 6) { $null = $list.Add($iv) }
            }
        }
        $null = $hints.Add([pscustomobject][ordered]@{ ioctl = $c.hex; inputSizeHints = @($list); note = '启发式：IOCTL 判断点 ±96 字节内的小立即数比较，可能是 InputBufferLength 门槛；需人工确认' })
    }
    $o.inputSizeHints = @($hints)
    $o.ok = $true
    return [pscustomobject]$o
}
#endregion

#region 私有：原生互操作（Add-Type 有类型存在守卫；不可用就如实退化，绝不假装成功）
function Ensure-LctPrfNative {
    param()
    if ('LctPrfNative' -as [type]) { $script:LctPrfNativeReady = $true; return $true }
    if ($script:LctPrfNativeTried) { return [bool]$script:LctPrfNativeReady }
    $script:LctPrfNativeTried = $true
    $src = @'
using System;
using System.Runtime.InteropServices;

public static class LctPrfNative {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
        IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Device_Interface_List_SizeW(out uint pulLen, ref Guid pInterfaceClassGuid, string pDeviceID, uint ulFlags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Device_Interface_ListW(ref Guid pInterfaceClassGuid, string pDeviceID, char[] Buffer, uint BufferLen, uint ulFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)]
    public struct OBJECT_DIRECTORY_INFORMATION { public UNICODE_STRING Name; public UNICODE_STRING TypeName; }

    [DllImport("ntdll.dll")]
    public static extern int NtOpenDirectoryObject(out IntPtr h, uint access, ref OBJECT_ATTRIBUTES oa);
    [DllImport("ntdll.dll")]
    public static extern int NtQueryDirectoryObject(IntPtr h, IntPtr buffer, uint len, bool single, bool restart, out uint ctx, out uint retLen);
    [DllImport("ntdll.dll")]
    public static extern int NtOpenSymbolicLinkObject(out IntPtr h, uint access, ref OBJECT_ATTRIBUTES oa);
    [DllImport("ntdll.dll")]
    public static extern int NtQuerySymbolicLinkObject(IntPtr h, ref UNICODE_STRING target, out uint retLen);
    [DllImport("ntdll.dll")]
    public static extern uint RtlNtStatusToDosError(int status);
}
'@
    try {
        Add-Type -TypeDefinition $src -ErrorAction Stop
        $script:LctPrfNativeReady = $true
        $script:LctPrfNativeError = ''
    } catch {
        $script:LctPrfNativeReady = $false
        $script:LctPrfNativeError = $_.Exception.Message
    }
    return [bool]$script:LctPrfNativeReady
}

function Get-LctPrfWin32Class {
    param([int]$Code = 0)
    if ($Code -eq 0) { return 'ok' }
    if ($Code -eq 2 -or $Code -eq 3) { return 'not-found' }
    if ($Code -eq 5) { return 'access-denied' }
    if ($Code -eq 32) { return 'in-use' }
    if ($Code -eq 1) { return 'unsupported' }
    if ($Code -eq 87) { return 'invalid-parameter' }
    if ($Code -eq 122 -or $Code -eq 234) { return 'buffer-too-small' }
    if ($Code -eq 1058) { return 'service-disabled' }
    if ($Code -eq 433) { return 'no-such-device' }
    return 'error'
}

function Get-LctPrfWin32Text {
    param([int]$Code = 0)
    $hint = ''
    if ($script:LctPrfWin32Hint.ContainsKey([string]$Code)) { $hint = [string]$script:LctPrfWin32Hint[[string]$Code] }
    if ($hint -eq '') { $hint = '未收录的 Win32 错误（参考 GetLastError=' + $Code + '）' }
    return $hint
}

function Get-LctPrfNtText {
    param([int]$Status = 0)
    $hex = '0x' + ('{0:X8}' -f [uint32]$Status)
    $hint = ''
    if ($script:LctPrfNtHint.ContainsKey($hex)) { $hint = [string]$script:LctPrfNtHint[$hex] }
    return ($hex + ' ' + $hint).Trim()
}

function New-LctPrfUniStr {
    # 在非托管内存里造 UNICODE_STRING（返回结构体；调用方负责 FreeHGlobal Buffer）
    param([string]$Text = '')
    $bytes = [Text.Encoding]::Unicode.GetBytes($Text)
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length + 2)
    if ($bytes.Length -gt 0) { [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length) }
    $us = New-Object LctPrfNative+UNICODE_STRING
    $us.Length = [uint16]$bytes.Length
    $us.MaximumLength = [uint16]($bytes.Length + 2)
    $us.Buffer = $ptr
    return $us
}

function New-LctPrfObjAttr {
    # 造 OBJECT_ATTRIBUTES（ObjectName 指向非托管 UNICODE_STRING；调用方负责 FreeHGlobal）
    param($UniStr)
    $oa = New-Object LctPrfNative+OBJECT_ATTRIBUTES
    $oa.Length = [Runtime.InteropServices.Marshal]::SizeOf([type]([LctPrfNative+OBJECT_ATTRIBUTES]))
    $so = [Runtime.InteropServices.Marshal]::SizeOf([type]([LctPrfNative+UNICODE_STRING]))
    $oa.ObjectName = [Runtime.InteropServices.Marshal]::AllocHGlobal($so)
    [Runtime.InteropServices.Marshal]::StructureToPtr($UniStr, $oa.ObjectName, $false)
    $oa.Attributes = 0x40   # OBJ_CASE_INSENSITIVE
    return $oa
}

function Invoke-LctPrfCreateFile {
    # 唯一的设备可用性实测入口（**只 CreateFile，绝不发 IOCTL**）
    param([string]$Path, [uint32]$Access = 0, [uint32]$Share = 3, [uint32]$Disposition = 3)
    $r = [ordered]@{
        path = $Path; access = $Access; share = $Share; attempted = $false; ok = $false; handle = [IntPtr]::Zero
        win32Error = 0; classification = 'unknown'; message = ''
    }
    if (-not (Ensure-LctPrfNative)) { $r.classification = 'native-unavailable'; $r.message = ('原生互操作不可用（Add-Type 失败）：' + [string]$script:LctPrfNativeError); return [pscustomobject]$r }
    $r.attempted = $true
    $h = [LctPrfNative]::CreateFileW($Path, $Access, $Share, [IntPtr]::Zero, $Disposition, 0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) {
        $r.win32Error = [int][Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $r.classification = Get-LctPrfWin32Class -Code $r.win32Error
        $r.message = ('CreateFileW(' + $Path + ') 失败 Win32=' + $r.win32Error + '：' + (Get-LctPrfWin32Text -Code $r.win32Error))
    } else {
        $r.ok = $true
        $r.handle = $h
        $r.classification = 'openable'
        $r.message = ('CreateFileW(' + $Path + ') 成功（句柄已取得；本步骤未发送任何 IOCTL）')
    }
    return [pscustomobject]$r
}

function Get-LctPrfInterfaceList {
    # 设备接口 GUID → CM_Get_Device_Interface_ListW（最通用的定位法：客户端不需要知道设备名）
    param([string]$InterfaceGuid = '', [uint32]$Flags = 1)
    $o = [ordered]@{ attempted = $false; supported = $false; ok = $false; error = ''; count = 0; items = @(); guid = $InterfaceGuid; flags = $Flags }
    if ([string]::IsNullOrWhiteSpace($InterfaceGuid)) { $o.error = '未提供 interfaceGuid'; return [pscustomobject]$o }
    $g = $null
    try { $g = [guid]::Parse($InterfaceGuid.Trim('{', '}')) } catch { $o.error = ('interfaceGuid 无法解析: ' + $InterfaceGuid); return [pscustomobject]$o }
    if (-not (Ensure-LctPrfNative)) { $o.attempted = $true; $o.error = ('原生互操作不可用：' + [string]$script:LctPrfNativeError); return [pscustomobject]$o }
    $o.attempted = $true
    $o.supported = $true
    try {
        $len = [uint32]0
        $rc = [LctPrfNative]::CM_Get_Device_Interface_List_SizeW([ref]$len, [ref]$g, $null, $Flags)
        if ($rc -ne 0) { $o.error = ('CM_Get_Device_Interface_List_SizeW 返回 CR=' + $rc); return [pscustomobject]$o }
        if ($len -le 1) { $o.ok = $true; $o.error = ''; return [pscustomobject]$o }
        $buf = New-Object char[] $len
        $rc2 = [LctPrfNative]::CM_Get_Device_Interface_ListW([ref]$g, $null, $buf, $len, $Flags)
        if ($rc2 -ne 0) { $o.error = ('CM_Get_Device_Interface_ListW 返回 CR=' + $rc2); return [pscustomobject]$o }
        $s = [string]::new($buf)
        $items = New-Object System.Collections.ArrayList
        foreach ($part in @($s -split [char]0)) { if ($part -ne '') { $null = $items.Add([string]$part) } }
        $o.items = @($items)
        $o.count = @($items).Count
        $o.ok = $true
    } catch { $o.error = ('设备接口枚举异常: ' + $_.Exception.Message) }
    return [pscustomobject]$o
}

function Invoke-LctPrfNtQuerySymlinkTarget {
    param([string]$LinkPath)
    $o = [ordered]@{ ok = $false; link = $LinkPath; target = ''; status = 0; statusText = ''; win32Error = 0; message = '' }
    if (-not (Ensure-LctPrfNative)) { $o.message = '原生互操作不可用'; return [pscustomobject]$o }
    $usPtr = [IntPtr]::Zero
    $oaPtr = [IntPtr]::Zero
    $h = [IntPtr]::Zero
    try {
        $us = New-LctPrfUniStr -Text $LinkPath
        $usPtr = $us.Buffer
        $oa = New-LctPrfObjAttr -UniStr $us
        $oaPtr = $oa.ObjectName
        # SYMBOLIC_LINK_QUERY = 0x0001
        $st = [LctPrfNative]::NtOpenSymbolicLinkObject([ref]$h, 1, [ref]$oa)
        $o.status = $st
        $o.statusText = Get-LctPrfNtText -Status $st
        if ($st -ne 0) {
            $o.win32Error = [int][LctPrfNative]::RtlNtStatusToDosError($st)
            $o.message = ('打开符号链接失败：' + $o.statusText + '（DOS=' + $o.win32Error + '）')
            return [pscustomobject]$o
        }
        $tbuf = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
        try {
            $target = New-Object LctPrfNative+UNICODE_STRING
            $target.Length = 0
            $target.MaximumLength = 16
            $target.Buffer = $tbuf
            $need = [uint32]0
            $st2 = [LctPrfNative]::NtQuerySymbolicLinkObject($h, [ref]$target, [ref]$need)
            $sz = [int]$need
            if ($st2 -eq 0) { $sz = [int]$target.Length }
            if ($sz -le 0) { $sz = 1024 }
            $tbuf2 = [Runtime.InteropServices.Marshal]::AllocHGlobal($sz + 2)
            try {
                $target2 = New-Object LctPrfNative+UNICODE_STRING
                $target2.Length = 0
                $target2.MaximumLength = [uint16]($sz + 2)
                $target2.Buffer = $tbuf2
                $need2 = [uint32]0
                $st3 = [LctPrfNative]::NtQuerySymbolicLinkObject($h, [ref]$target2, [ref]$need2)
                $o.status = $st3
                $o.statusText = Get-LctPrfNtText -Status $st3
                if ($st3 -ne 0 -and $st2 -ne 0) {
                    $o.win32Error = [int][LctPrfNative]::RtlNtStatusToDosError($st3)
                    $o.message = ('查询符号链接目标失败：' + $o.statusText + '（DOS=' + $o.win32Error + '）')
                    return [pscustomobject]$o
                }
                $take = [int]$need2
                if ($take -le 0) { $take = [int]$target2.Length }
                if ($take -gt 0) {
                    $bb = New-Object byte[] $take
                    [Runtime.InteropServices.Marshal]::Copy($tbuf2, $bb, 0, $take)
                    $o.target = [Text.Encoding]::Unicode.GetString($bb).TrimEnd([char]0)
                }
                $o.ok = ($o.target -ne '')
                $o.message = ('符号链接 ' + $LinkPath + ' -> ' + $o.target)
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($tbuf2) | Out-Null }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($tbuf) | Out-Null }
    } catch { $o.message = '符号链接查询异常: ' + $_.Exception.Message }
    finally {
        if ($h -ne [IntPtr]::Zero) { [LctPrfNative]::CloseHandle($h) | Out-Null }
        if ($usPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($usPtr) | Out-Null }
        if ($oaPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($oaPtr) | Out-Null }
    }
    return [pscustomobject]$o
}

function Test-LctPrfNameMatch {
    param([string]$Name, [string[]]$Patterns)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $pp = ([string]$p).Trim()
        if ($pp.Contains('*')) { if ($Name -like $pp) { return $true } }
        elseif ($Name -ieq $pp) { return $true }
        elseif ($Name -ieq ($pp.TrimStart('\'))) { return $true }
    }
    return $false
}

function Invoke-LctPrfNtEnumerate {
    # 用 NT API 枚举对象目录（\GLOBAL?? / \Device）。**失败就如实报 supported=false**，不假装成功。
    param([string]$Root = '\GLOBAL??', [string[]]$MatchNames = @(), [int]$MaxEntries = 4096, [switch]$ResolveMatchedTargets)
    $o = [ordered]@{
        attempted = $false; supported = $false; ok = $false; root = $Root; error = ''
        count = 0; total = 0; typeCounts = [ordered]@{}; items = @(); matched = @(); matchCount = 0
        targetResolved = 0; notes = (New-Object System.Collections.ArrayList); nativeAvailable = $false
    }
    if (-not (Ensure-LctPrfNative)) {
        $o.attempted = $true
        $o.error = ('原生互操作不可用（Add-Type 失败）：' + [string]$script:LctPrfNativeError)
        $null = $o.notes.Add('NT 枚举退化：只用 profile / 派生候选集，不假装枚举成功')
        return [pscustomobject]$o
    }
    $o.nativeAvailable = $true
    $o.attempted = $true
    $usPtr = [IntPtr]::Zero
    $oaPtr = [IntPtr]::Zero
    $h = [IntPtr]::Zero
    $nbuf = [IntPtr]::Zero
    try {
        $us = New-LctPrfUniStr -Text $Root
        $usPtr = $us.Buffer
        $oa = New-LctPrfObjAttr -UniStr $us
        $oaPtr = $oa.ObjectName
        # DIRECTORY_QUERY = 0x0001
        $st = [LctPrfNative]::NtOpenDirectoryObject([ref]$h, 1, [ref]$oa)
        if ($st -ne 0) {
            $dos = [int][LctPrfNative]::RtlNtStatusToDosError($st)
            $o.error = ('NtOpenDirectoryObject(' + $Root + ') 失败: ' + (Get-LctPrfNtText -Status $st) + '（DOS=' + $dos + '）')
            $null = $o.notes.Add('NT 枚举退化：只用 profile / 派生候选集，不假装枚举成功')
            return [pscustomobject]$o
        }
        $o.supported = $true
        $bufSize = 65536
        $nbuf = [Runtime.InteropServices.Marshal]::AllocHGlobal($bufSize)
        $structSize = [Runtime.InteropServices.Marshal]::SizeOf([type]([LctPrfNative+OBJECT_DIRECTORY_INFORMATION]))
        $ctx = [uint32]0
        $ret = [uint32]0
        $restart = $true
        $items = New-Object System.Collections.ArrayList
        $typeCounts = @{}
        $loops = 0
        while ($loops -lt 200) {
            $loops++
            $st2 = [LctPrfNative]::NtQueryDirectoryObject($h, $nbuf, [uint32]$bufSize, $false, $restart, [ref]$ctx, [ref]$ret)
            $restart = $false
            if ($st2 -ne 0) {
                if ($st2 -eq 0x8000001A) { break }   # STATUS_NO_MORE_ENTRIES = 正常结束
                $dos2 = [int][LctPrfNative]::RtlNtStatusToDosError($st2)
                $o.error = ('NtQueryDirectoryObject 在循环 ' + $loops + ' 结束: ' + (Get-LctPrfNtText -Status $st2) + '（DOS=' + $dos2 + '）；已取到 ' + @($items).Count + ' 条')
                break
            }
            $off = 0
            while (($off + $structSize) -le $ret) {
                $info = [Runtime.InteropServices.Marshal]::PtrToStructure([IntPtr]($nbuf.ToInt64() + $off), [type]([LctPrfNative+OBJECT_DIRECTORY_INFORMATION]))
                $name = ''
                $type = ''
                if ([int]$info.Name.Length -gt 0 -and $info.Name.Buffer -ne [IntPtr]::Zero) {
                    $bb = New-Object byte[] ([int]$info.Name.Length)
                    [Runtime.InteropServices.Marshal]::Copy($info.Name.Buffer, $bb, 0, $bb.Length)
                    $name = [Text.Encoding]::Unicode.GetString($bb)
                }
                if ([int]$info.TypeName.Length -gt 0 -and $info.TypeName.Buffer -ne [IntPtr]::Zero) {
                    $bb2 = New-Object byte[] ([int]$info.TypeName.Length)
                    [Runtime.InteropServices.Marshal]::Copy($info.TypeName.Buffer, $bb2, 0, $bb2.Length)
                    $type = [Text.Encoding]::Unicode.GetString($bb2)
                }
                if ($name -eq '' -and $type -eq '') { break }
                if ($type -ne '') { if ($typeCounts.ContainsKey($type)) { $typeCounts[$type] = $typeCounts[$type] + 1 } else { $typeCounts[$type] = 1 } }
                if (@($items).Count -lt $MaxEntries) { $null = $items.Add([pscustomobject][ordered]@{ name = $name; type = $type; target = '' }) }
                $off += $structSize
            }
        }
        $o.total = @($items).Count
        $o.typeCounts = [pscustomobject]$typeCounts
        # 只对匹配项解析符号链接目标（313 个链接全解析太慢，且没必要）
        $matched = New-Object System.Collections.ArrayList
        foreach ($it in @($items)) {
            if (@($MatchNames).Count -gt 0) {
                if (-not (Test-LctPrfNameMatch -Name ([string]$it.name) -Patterns $MatchNames)) { continue }
            }
            $row = [pscustomobject][ordered]@{ name = $it.name; type = $it.type; ntPath = ($Root.TrimEnd('\') + '\' + [string]$it.name); target = '' }
            if ($ResolveMatchedTargets -and [string]$it.type -eq 'SymbolicLink') {
                $r = Invoke-LctPrfNtQuerySymlinkTarget -LinkPath ([string]$row.ntPath)
                if ($r.ok) { $row.target = [string]$r.target; $o.targetResolved = $o.targetResolved + 1 }
            }
            $null = $matched.Add($row)
        }
        $o.matched = @($matched)
        $o.matchCount = @($matched).Count
        $o.count = @($items).Count
        $o.items = @($items)
        $o.ok = $true
        if (@($MatchNames).Count -gt 0 -and @($matched).Count -eq 0) {
            $null = $o.notes.Add('NT 枚举成功，但没有名字匹配到候选（设备名与驱动服务名没有权威映射；本模块不猜测对应关系）')
        }
    } catch {
        $o.error = 'NT 枚举异常: ' + $_.Exception.Message
        $null = $o.notes.Add('NT 枚举退化：只用 profile / 派生候选集')
    } finally {
        if ($h -ne [IntPtr]::Zero) { [LctPrfNative]::CloseHandle($h) | Out-Null }
        if ($nbuf -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($nbuf) | Out-Null }
        if ($usPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($usPtr) | Out-Null }
        if ($oaPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($oaPtr) | Out-Null }
    }
    return [pscustomobject]$o
}

function ConvertTo-LctPrfOpenPath {
    # 候选写法 → CreateFileW 能吃的 Win32 路径（实测三种写法都能开：\\.\X / \??\X / \\?\GLOBALROOT\Device\X）
    param([string]$Candidate = '')
    $c = ([string]$Candidate).Trim()
    $o = [ordered]@{ input = $c; ok = $false; wildcard = $false; path = ''; note = '' }
    if ($c -eq '') { $o.note = '空候选'; return [pscustomobject]$o }
    if ($c.Contains('*')) { $o.wildcard = $true; $o.note = '通配候选：无法直接 CreateFile，需要先用 NT 枚举展开成真实名字'; return [pscustomobject]$o }
    if ($c.StartsWith('\\.\') -or $c.StartsWith('\\?\')) { $o.path = $c }
    elseif ($c.StartsWith('\??\')) { $o.path = $c }
    elseif ($c.StartsWith('\GLOBALROOT\') -or $c.StartsWith('\Device\') -or $c.StartsWith('Device\')) {
        $rest = $c
        if ($rest.StartsWith('\GLOBALROOT\')) { $rest = $rest.Substring(12) }
        elseif ($rest.StartsWith('\')) { $rest = $rest.Substring(1) }
        $o.path = ('\\?\GLOBALROOT\' + $rest)
    } else {
        $o.path = ('\\.\' + $c)
        $o.note = '未加前缀的裸名字按 \\.\<name> 处理'
    }
    $o.ok = $true
    return [pscustomobject]$o
}

function Get-LctPrfDerivedCandidates {
    # 从服务名 / .sys 文件名派生的符号链接候选（**明确标 source=derived**，能不能打开由 CreateFile 实测决定）
    param([string]$ServiceName = '', [string]$FileName = '')
    $names = New-Object System.Collections.ArrayList
    foreach ($n in @($ServiceName, ([IO.Path]::GetFileNameWithoutExtension($FileName)))) {
        $t = ([string]$n).Trim()
        if ($t -eq '' -or $t -eq $FileName) { continue }
        if (-not ($names -contains $t)) { $null = $names.Add($t) }
    }
    $tmp = @($names)
    foreach ($n in $tmp) {
        foreach ($suf in @('64', 'Device', 'Drv')) {
            $x = $n + $suf
            if (-not ($names -contains $x)) { $null = $names.Add($x) }
        }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($n in @($names)) {
        $null = $out.Add([pscustomobject][ordered]@{ kind = 'symlink'; name = $n; candidate = ('\\.\' + $n); source = 'derived'; wildcard = $false })
        $null = $out.Add([pscustomobject][ordered]@{ kind = 'symlink'; name = $n; candidate = ('\??\' + $n); source = 'derived'; wildcard = $false })
    }
    return @($out)
}

function Invoke-LctPrfProbeCandidates {
    # 候选入口 → CreateFile 可用性实测（只做错误分类，**绝不发未知 IOCTL**）
    param($Candidates, [uint32]$Access = 0, [switch]$NoOpen)
    $tries = New-Object System.Collections.ArrayList
    $o = [ordered]@{ attempted = $false; tryCount = 0; okCount = 0; openPath = ''; handle = [IntPtr]::Zero; wildcardCount = 0; verdict = 'no-candidate'; classifications = [ordered]@{}; tries = @(); notes = (New-Object System.Collections.ArrayList) }
    $classCounts = @{}
    foreach ($c in @($Candidates)) {
        $cand = ''
        $src = ''
        if ($c -is [string]) { $cand = [string]$c } else { $cand = [string](Get-LctPrfProp -Bag $c -Name 'candidate' -Default ''); $src = [string](Get-LctPrfProp -Bag $c -Name 'source' -Default '') }
        $op = ConvertTo-LctPrfOpenPath -Candidate $cand
        if (-not $op.ok -or $op.wildcard) {
            if ($op.wildcard) { $o.wildcardCount = $o.wildcardCount + 1 }
            $null = $tries.Add([pscustomobject][ordered]@{ candidate = $cand; source = $src; openPath = ''; wildcard = [bool]$op.wildcard; attempted = $false; ok = $false; win32Error = 0; classification = 'skipped'; message = $op.note })
            continue
        }
        if ($NoOpen) {
            $null = $tries.Add([pscustomobject][ordered]@{ candidate = $cand; source = $src; openPath = $op.path; wildcard = $false; attempted = $false; ok = $false; win32Error = 0; classification = 'not-attempted'; message = '按调用方要求跳过 CreateFile 实测（-NoCreateFileTest）' })
            continue
        }
        $r = Invoke-LctPrfCreateFile -Path $op.path -Access $Access
        $o.attempted = $true
        $o.tryCount = $o.tryCount + 1
        $cf = $r.classification
        if ($classCounts.ContainsKey($cf)) { $classCounts[$cf] = $classCounts[$cf] + 1 } else { $classCounts[$cf] = 1 }
        $null = $tries.Add([pscustomobject][ordered]@{ candidate = $cand; source = $src; openPath = $op.path; wildcard = $false; attempted = $true; ok = [bool]$r.ok; win32Error = [int]$r.win32Error; classification = $cf; message = [string]$r.message })
        if ($r.ok -and $o.openPath -eq '') {
            $o.openPath = $op.path
            $o.handle = $r.handle
            $o.okCount = $o.okCount + 1
        } elseif ($r.ok) {
            [LctPrfNative]::CloseHandle($r.handle) | Out-Null
            $o.okCount = $o.okCount + 1
        }
    }
    $o.classifications = [pscustomobject]$classCounts
    if (@($tries).Count -eq 0) { $o.verdict = 'no-candidate' }
    elseif (-not $o.attempted) { $o.verdict = 'not-attempted' }
    elseif ($o.okCount -gt 0) { $o.verdict = 'openable' }
    elseif ($classCounts.ContainsKey('in-use') -or $classCounts.ContainsKey('access-denied')) { $o.verdict = 'exists-but-restricted' }
    elseif ($classCounts.ContainsKey('not-found') -and @($tries).Count -eq $classCounts['not-found']) { $o.verdict = 'not-found' }
    elseif ($classCounts.ContainsKey('native-unavailable')) { $o.verdict = 'native-unavailable' }
    else { $o.verdict = 'unknown' }
    $o.tries = @($tries)
    if ($o.verdict -eq 'not-found') { $null = $o.notes.Add('所有候选都返回「设备不存在」：驱动可能没加载，或设备名与候选不符（本模块不猜名字）') }
    if ($o.verdict -eq 'exists-but-restricted') { $null = $o.notes.Add('候选返回「拒绝访问/被占用」⇒ 通常说明**设备确实存在**，只是当前权限或打开方式不合适') }
    return [pscustomobject]$o
}

function Invoke-LctPrfSendIoctl {
    # 真正发 IOCTL 的唯一入口（只在 -Apply 路径下被调用）
    param([IntPtr]$Handle, [uint32]$Ioctl = 0, [byte[]]$InBytes = $null, [int]$OutSize = 0, [string]$Method = 'buffered')
    $o = [ordered]@{ sent = $false; ok = $false; win32Error = 0; bytesReturned = 0; outBuffer = $null; classification = 'unknown'; message = '' }
    if (-not (Ensure-LctPrfNative)) { $o.classification = 'native-unavailable'; $o.message = '原生互操作不可用'; return [pscustomobject]$o }
    $inSize = 0
    if ($null -ne $InBytes) { $inSize = $InBytes.Length }
    $needOut = [Math]::Max($OutSize, 0)
    $allocIn = [IntPtr]::Zero
    $allocOut = [IntPtr]::Zero
    try {
        if ($Method -eq 'inout') {
            $total = [Math]::Max([Math]::Max($inSize, $needOut), 1)
            $allocIn = [Runtime.InteropServices.Marshal]::AllocHGlobal($total)
            if ($inSize -gt 0) { [Runtime.InteropServices.Marshal]::Copy($InBytes, 0, $allocIn, $inSize) }
            $allocOut = $allocIn
        } else {
            $allocIn = [Runtime.InteropServices.Marshal]::AllocHGlobal([Math]::Max($inSize, 1))
            if ($inSize -gt 0) { [Runtime.InteropServices.Marshal]::Copy($InBytes, 0, $allocIn, $inSize) }
            $allocOut = [Runtime.InteropServices.Marshal]::AllocHGlobal([Math]::Max($needOut, 1))
        }
        $returned = [uint32]0
        $outPtr = $allocOut
        if ($Method -eq 'inout' -or $needOut -eq 0) { $outPtr = $allocOut }
        $okCall = [LctPrfNative]::DeviceIoControl($Handle, $Ioctl, $allocIn, [uint32]$inSize, $outPtr, [uint32]$needOut, [ref]$returned, [IntPtr]::Zero)
        $o.sent = $true
        $o.bytesReturned = [int]$returned
        if ($okCall) {
            $o.ok = $true
            $o.classification = 'ok'
            $o.message = ('DeviceIoControl 成功，返回 ' + $returned + ' 字节')
            if ($needOut -gt 0) {
                $buf = New-Object byte[] $needOut
                [Runtime.InteropServices.Marshal]::Copy($allocOut, $buf, 0, $needOut)
                $o.outBuffer = $buf
            }
        } else {
            $o.win32Error = [int][Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $o.classification = Get-LctPrfWin32Class -Code $o.win32Error
            $o.message = ('DeviceIoControl 失败 Win32=' + $o.win32Error + '：' + (Get-LctPrfWin32Text -Code $o.win32Error))
            if ($o.win32Error -eq 234 -and $needOut -gt 0) { $o.outBuffer = $null }
        }
    } catch {
        $o.message = 'DeviceIoControl 调用异常: ' + $_.Exception.Message
    } finally {
        if ($allocIn -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($allocIn) | Out-Null }
        if ($allocOut -ne [IntPtr]::Zero -and $allocOut -ne $allocIn) { [Runtime.InteropServices.Marshal]::FreeHGlobal($allocOut) | Out-Null }
    }
    return [pscustomobject]$o
}
#endregion

#region 导出 1：Get-LctDriverProfileList（只读；返回包装对象 {items,count,...}）
function Get-LctDriverProfileList {
    param([AllowEmptyString()][string]$Source = '')
    $verb = 'driver.profile.list'
    $sv = ([string]$Source).Trim().ToLower()
    if ($sv -ne '' -and ($script:LctPrfSources -notcontains $sv)) {
        return New-LctResult -Verb $verb -Errors @("不支持的 -Source 取值 '$Source'；可用: builtin | user | plugin | ''（全部）")
    }
    $files = Get-LctPrfProfileFiles -Source $sv
    $items = New-Object System.Collections.ArrayList
    foreach ($f in @($files)) {
        $it = [ordered]@{
            id = $f.id; source = $f.source; path = $f.path; fileName = $f.fileName
            kind = ''; engineApi = 0; targetFileName = ''; sha256 = ''; riskLevel = ''; method = ''; align = 0
            strategy = ''; actionCount = 0; actions = @(); valid = $false; isDraft = $false; problem = ''; parseError = $f.parseError
        }
        if ($f.parseError -ne '') { $it.problem = ('JSON 解析失败: ' + $f.parseError) }
        elseif ($null -eq $f.profile) { $it.problem = 'profile 为空' }
        else {
            $sch = Test-LctPrfProfileSchema -Profile $f.profile -ProfilePath $f.path
            $it.kind = [string](Get-LctPrfProp -Bag $f.profile -Name 'kind' -Default '')
            $it.engineApi = $sch.info.engineApi
            $it.targetFileName = $sch.info.fileName
            $it.sha256 = $sch.info.sha256
            $it.riskLevel = $sch.info.riskLevel
            $it.method = $sch.info.method
            $it.align = $sch.info.align
            $it.strategy = $sch.info.strategy
            $it.actionCount = $sch.info.actionCount
            $it.actions = @($sch.info.actions)
            $it.valid = [bool]$sch.ok
            if (-not $sch.ok) { $it.problem = (@($sch.errors) -join ' | ') }
            $dr = Get-LctPrfProp -Bag $f.profile -Name 'draft'
            if ($null -ne $dr) {
                $it.isDraft = $true
                if ($it.problem -eq '') { $it.problem = '这是静态草案（needsReview=true），不能直接执行' }
            }
        }
        $null = $items.Add([pscustomobject]$it)
    }
    $data = [ordered]@{
        source = $(if ($sv -eq '') { 'all' } else { $sv })
        items = @($items)
        count = @($items).Count
        validCount = @($items | Where-Object { $_.valid }).Count
        dirs = @(Get-LctPrfProfileSearchInfo)
        notes = @(
            'profile 是纯数据：只描述「怎么调用这个驱动」，不含任何可执行代码（引擎永不 eval profile 内容）。'
            'valid 只代表通过 schema，**不含** .sys 指纹比对；指纹/沙盒校验请用 driver.profile.validate。'
            '内置目录 core\driver-profiles 允许为空（本版不预置任何未经人工确认的真实驱动 profile）。'
        )
    }
    $null = Write-LctPrfLog -Verb $verb -Level 'info' -Message ('列出 profile: ' + $data.count) -Data ([ordered]@{ source = $data.source; count = $data.count; valid = $data.validCount })
    return [pscustomobject]$data
}
#endregion

#region 导出 2：Get-LctDriverProfileShow（只读；返回包装对象）
function Get-LctDriverProfileShow {
    param([Parameter(Mandatory)][string]$Id)
    $verb = 'driver.profile.show'
    $found = Find-LctPrfProfile -Id $Id
    if (-not $found.ok) {
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message $found.error -Data ([ordered]@{ id = $Id })
        return New-LctResult -Verb $verb -Errors @($found.error)
    }
    $sch = Test-LctPrfProfileSchema -Profile $found.profile -ProfilePath $found.path -ExpectedId $found.id
    $data = [ordered]@{
        id = $found.id; source = $found.source; path = $found.path
        count = 1; items = @($found.profile); profile = $found.profile
        schemaOk = [bool]$sch.ok; schemaErrors = @($sch.errors); schemaWarnings = @($sch.warnings); info = $sch.info
        notes = @('profile 为纯数据；schemaOk 只代表字段/类型/ioctl/risk/layout 合法，不含 .sys 指纹比对。')
    }
    $null = Write-LctPrfLog -Verb $verb -Level 'info' -Message ('查看 profile: ' + $found.id) -Data ([ordered]@{ id = $found.id; source = $found.source; schemaOk = $sch.ok })
    return [pscustomobject]$data
}
#endregion

#region 导出 3：Test-LctDriverProfile（schema + .sys 指纹 + 内存沙盒；不碰内核、不发 IOCTL）
function Test-LctDriverProfile {
    param([string]$Id = '', [string]$Path = '')
    $verb = 'driver.profile.validate'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $checks = New-Object System.Collections.ArrayList
    $prof = $null
    $profPath = ''
    $profDir = ''
    $source = ''
    $sysFromPath = ''
    $haveId = (-not [string]::IsNullOrWhiteSpace($Id))
    $havePath = (-not [string]::IsNullOrWhiteSpace($Path))
    if (-not $haveId -and -not $havePath) {
        return New-LctResult -Verb $verb -Errors @('必须给 -Id <profile id> 或 -Path <profile.json | .sys>；两者可同时给（-Id 选 profile，-Path 指定用来比对指纹的 .sys）')
    }
    if ($havePath) {
        $ext = [IO.Path]::GetExtension($Path).ToLower()
        if ($ext -eq '.sys') { $sysFromPath = $Path }
        else {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return New-LctResult -Verb $verb -Errors @('profile 文件不存在: ' + $Path) }
            $raw = ''
            try { $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) } catch { return New-LctResult -Verb $verb -Errors @('读取 profile 失败: ' + $_.Exception.Message) }
            $raw = $raw.TrimStart([char]0xFEFF)
            try { $prof = ConvertTo-LctPrfPlain -Value ($raw | ConvertFrom-Json) } catch { return New-LctResult -Verb $verb -Errors @('profile JSON 解析失败: ' + $_.Exception.Message) }
            $profPath = $Path
            $profDir = Split-Path -Parent $Path
            $source = 'path'
        }
    }
    if ($null -eq $prof -and $haveId) {
        $found = Find-LctPrfProfile -Id $Id
        if (-not $found.ok) { return New-LctResult -Verb $verb -Errors @($found.error) }
        $prof = $found.profile
        $profPath = $found.path
        $profDir = Split-Path -Parent $found.path
        $source = $found.source
    }
    if ($null -eq $prof) { return New-LctResult -Verb $verb -Errors @('没能取到 profile：-Path 指向 .sys 时必须同时给 -Id 选定 profile') }
    # 1) schema
    $sch = Test-LctPrfProfileSchema -Profile $prof -ProfilePath $profPath -ExpectedId $(if ($haveId) { $Id } else { '' })
    foreach ($e in @($sch.errors)) { $null = $errors.Add([string]$e) }
    foreach ($w in @($sch.warnings)) { $null = $warnings.Add([string]$w) }
    $null = $checks.Add([pscustomobject][ordered]@{ name = 'schema'; passed = [bool]$sch.ok; detail = $(if ($sch.ok) { '字段/类型/ioctl/risk/layout 全部合法' } else { (@($sch.errors) -join ' | ') }) })
    # 2) 指纹门
    $declared = New-Object System.Collections.ArrayList
    if ($sch.info.sha256 -ne '') { $null = $declared.Add($sch.info.sha256) }
    foreach ($x in @($sch.info.sha256AnyOf)) { $null = $declared.Add($x) }
    $fpSys = $null
    $actual = ''
    $fpMatch = $false
    if (@($declared).Count -eq 0) {
        $null = $checks.Add([pscustomobject][ordered]@{ name = 'fingerprint'; passed = $false; detail = '没有可用的 target.sha256 / sha256AnyOf，无法比对指纹' })
    } else {
        $svcForFile = ''
        # .sys 的定位与「设备入口策略」无关：只要 profile 给了 serviceNameHint 就用它查注册表 ImagePath
        # （strategy 只决定「设备怎么找」，不决定「.sys 在哪」）。实测：strategy=symlink 时旧逻辑漏掉注册表
        # 候选，导致指纹门误报「无法定位 .sys」，只能把样本手工放进 System32\drivers 才过。
        if ([string]$sch.info.serviceNameHint -ne '') { $svcForFile = [string]$sch.info.serviceNameHint }
        $fpSys = Resolve-LctPrfSysPath -ServiceName $svcForFile -FileName ([string]$sch.info.fileName) -ExplicitPath $sysFromPath -ProfileDir $profDir -Sha256 ([string]$declared[0])
        if (-not $fpSys.ok) {
            $null = $errors.Add('指纹校验失败：' + $fpSys.error)
            $null = $checks.Add([pscustomobject][ordered]@{ name = 'fingerprint'; passed = $false; detail = $fpSys.error })
        } else {
            $actual = (Get-LctPrfSha256 -Path $fpSys.path).ToLower()
            $fpMatch = ($declared -contains $actual)
            if (-not $fpMatch) {
                $null = $errors.Add('指纹不符：文件 ' + $fpSys.path + ' 的实际 SHA256=' + $actual + '，profile 声明 ' + (@($declared) -join ' / ') + '（布局错版本必蓝屏）⇒ 拒绝（契约 §13.6 第 2 条）')
            }
            $null = $checks.Add([pscustomobject][ordered]@{ name = 'fingerprint'; passed = [bool]$fpMatch; detail = ('file=' + $fpSys.path + ' actual=' + $actual + ' declared=' + (@($declared) -join ',') + ' resolution=' + $fpSys.resolution) })
        }
    }
    # 3) 内存沙盒自检（打包/解包往返，不碰设备）
    $sandbox = $null
    try { $sandbox = Invoke-LctPrfSandbox -Profile $prof } catch { $sandbox = [pscustomobject][ordered]@{ passed = $false; checks = @([pscustomobject][ordered]@{ name = 'sandbox'; passed = $false; detail = ('沙盒自检异常: ' + $_.Exception.Message) }); actionCount = 0 } }
    foreach ($c in @($sandbox.checks)) {
        $null = $checks.Add($c)
        if (-not $c.passed) { $null = $errors.Add('内存沙盒自检失败: ' + $c.name + ' -> ' + [string]$c.detail) }
    }
    $data = [ordered]@{
        id = $sch.info.id; source = $source; profilePath = $profPath
        sysFile = $fpSys; declaredSha256 = @($declared); actualSha256 = $actual; fingerprintMatch = [bool]$fpMatch
        schemaOk = [bool]$sch.ok; checks = @($checks); info = $sch.info
        sandbox = [ordered]@{ passed = [bool]$sandbox.passed; actionCount = [int]$sandbox.actionCount }
        limits = @('validate 不碰内核：只做 schema + .sys 指纹比对 + 内存沙盒（打包/解包往返），不发任何 IOCTL、不 CreateFile 设备')
    }
    $ok = (@($errors).Count -eq 0)
    $null = Write-LctPrfValidationLog -Verb $verb -Id ([string]$sch.info.id) -Path $profPath -Ok $ok -Errors @($errors) -Warnings @($warnings)
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$data)
}
#endregion

#region 导出 4：New-LctDriverProfileDraft（静态草案，只读；产出必须带 confidence + needsReview=true）
function New-LctDriverProfileDraft {
    param([Parameter(Mandatory)][string]$Path)
    $verb = 'driver.profile.draft'
    $notes = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-LctResult -Verb $verb -Errors @('找不到 .sys 文件: ' + $Path)
    }
    $pe = $null
    try { $pe = Get-LctPrfPeImage -Path $Path } catch { return New-LctResult -Verb $verb -Errors @('静态解析异常: ' + $_.Exception.Message) }
    if (-not $pe.ok) {
        return New-LctResult -Verb $verb -Errors @('不是可解析的 PE 映像: ' + $pe.error) -Data ([ordered]@{ path = $Path; peError = $pe.error })
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $sha = [string]$pe.sha256
    $sha8 = '????????'
    if ($sha.Length -ge 8) { $sha8 = $sha.Substring(0, 8).ToLower() }
    $cands = New-Object System.Collections.ArrayList
    foreach ($d in @($pe.deviceNameCandidates)) { $null = $cands.Add([string]$d.text) }
    $ioctlCand = New-Object System.Collections.ArrayList
    foreach ($c in @($pe.ioctlCandidates)) {
        $null = $ioctlCand.Add([pscustomobject][ordered]@{
                hex = $c.hex; tier = $c.tier; method = $c.methodName; methodRisky = [bool]$c.methodRisky
                deviceType = $c.deviceType; function = $c.function; hits = [int]$c.count; fileOffsets = @($c.fileOffsets)
            })
    }
    $tierA = @($pe.ioctlCandidates | Where-Object { $_.tier -eq 'likely' }).Count
    $devWithXref = @($pe.deviceNameCandidates | Where-Object { [int]$_.xrefs -gt 0 }).Count
    $hintCount = 0
    foreach ($h in @($pe.inputSizeHints)) { $hintCount += @($h.inputSizeHints).Count }
    $conf = 0.10
    $why = New-Object System.Collections.ArrayList
    $null = $why.Add('0.10 基础分：文件存在且已算 SHA256')
    $conf += 0.15
    $null = $why.Add('+0.15 PE 头/节表解析成功')
    if (@($pe.imports).Count -gt 0) { $conf += 0.10; $null = $why.Add('+0.10 解析到导入表（' + @($pe.imports).Count + ' 个 DLL）') }
    if (@($pe.importsOfInterest).Count -gt 0) { $conf += 0.05; $null = $why.Add('+0.05 导入了驱动常用内核 API（' + @($pe.importsOfInterest).Count + ' 个）') }
    if (@($pe.deviceNameCandidates).Count -gt 0) { $conf += 0.08; $null = $why.Add('+0.08 找到设备名字符串（' + @($pe.deviceNameCandidates).Count + ' 条）') }
    if ($devWithXref -gt 0) { $conf += 0.15; $null = $why.Add('+0.15 其中 ' + $devWithXref + ' 条设备名有 xref 证据（rip-relative 或指针值）') }
    if ($tierA -gt 0) { $conf += 0.20; $null = $why.Add('+0.20 有 ' + $tierA + ' 个高可信 IOCTL 候选（DeviceType/Method 位分层）') }
    if ($tierA -ge 3) { $conf += 0.05; $null = $why.Add('+0.05 IOCTL 高可信候选 >= 3') }
    if ($hintCount -gt 0) { $conf += 0.05; $null = $why.Add('+0.05 有 ' + $hintCount + ' 个输入大小提示') }
    $conf = [Math]::Round($conf, 2)
    if ($conf -gt 0.95) { $conf = 0.95 }
    $null = $why.Add('上限 0.95：静态草案永不等于可用 profile（actions 为空，必须人工确认）')
    foreach ($n in @($pe.notes)) { $null = $notes.Add([string]$n) }
    $null = $notes.Add('草案的 actions 故意为空：没有人工确认过 IOCTL 语义与输入结构之前，任何自动生成的 actions 都可能直接蓝屏（契约 §13.6 第 6 条）。')
    $draft = [ordered]@{
        id = ($stem + '-draft-' + $sha8)
        kind = 'driver-profile'
        engineApi = 2
        target = [ordered]@{ sha256 = $sha; fileName = [IO.Path]::GetFileName($Path) }
        locate = [ordered]@{
            strategy = 'symlink'
            candidates = @($cands)
            serviceNameHint = ''
            notes = '候选为静态字符串扫描的原文（未加工）；符号链接是否存在必须用 driver.devices 实测。'
        }
        handshake = $null
        actions = [ordered]@{}
        layout = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
        risk = [ordered]@{
            level = $(if (@($pe.ioctlCandidates).Count -gt 0 -or @($pe.deviceNameCandidates).Count -gt 0) { 'bsod' } else { 'medium' })
            notes = '静态草案：未确认语义的 IOCTL 一旦发出可能立刻蓝屏；补全 actions 时必须人工设定 risk.level 与还原方式。'
        }
        requires = [ordered]@{ restart = $false; admin = $true; elevation = 'admin' }
        source = [ordered]@{ generatedBy = 'LocalConfigTool driver.profile.draft（静态只读）'; draftFrom = [IO.Path]::GetFullPath($Path) }
        draft = [ordered]@{
            needsReview = $true
            confidence = $conf
            confidenceReason = @($why)
            evidence = [ordered]@{
                machine = $pe.machineName; peKind = $pe.peKind; numberOfSections = $pe.numberOfSections
                entryPoint = ('0x' + ('{0:X}' -f [uint32]$pe.entryPoint)); imageBase = ('0x' + ('{0:X}' -f [uint64]$pe.imageBase))
                subsystem = $pe.subsystem; timestamp = ('0x' + ('{0:X}' -f [uint32]$pe.timestamp))
                sections = @($pe.sections); imports = @($pe.imports); importsOfInterest = @($pe.importsOfInterest)
                asciiStringCount = $pe.asciiStringCount; wideStringCount = $pe.wideStringCount
                candidatesFound = $pe.candidatesFound
                deviceNameCandidates = @($pe.deviceNameCandidates)
                ioctlCandidates = @($ioctlCand)
                ioctlScanTruncated = [bool]$pe.ioctlScanTruncated
                inputSizeHints = @($pe.inputSizeHints)
                scanMethods = @($pe.scanMethods)
                limits = @(
                    'IOCTL 候选是 CMP reg,imm32 的启发式筛选，不是反汇编器；跳转表分派、位运算判定的驱动会扫不到。'
                    '设备名候选只收 Device 前缀形态的可打印字符串（ASCII+UTF-16LE）；运行时拼接的名字扫不到，此时 candidatesFound=0 并如实标注。'
                    '本模块不做内核操作、不加载驱动、不执行被解析文件里的任何代码。'
                )
            }
            notes = @($notes)
        }
    }
    $json = ConvertTo-LctPrfJson -Object $draft -Depth 14
    $null = Write-LctPrfLog -Verb $verb -Level 'info' -Message ('静态起草: ' + $Path) -Data ([ordered]@{ path = $Path; confidence = $conf; candidatesFound = $pe.candidatesFound; ioctlCandidates = @($pe.ioctlCandidates).Count; needsReview = $true })
    $data = [ordered]@{
        path = [IO.Path]::GetFullPath($Path); needsReview = $true; confidence = $conf
        candidatesFound = $pe.candidatesFound; ioctlCandidateCount = @($pe.ioctlCandidates).Count
        devNameXrefCount = $devWithXref
        draft = $draft
        draftJson = $json
        hint = '把 data.draft 人工补全（确认设备名 → 填 actions → 设 risk.level）后另存到 var\driver-profiles\<id>.json，再用 driver.profile.validate 过指纹门才可执行。'
    }
    return New-LctResult -Verb $verb -Warnings @('静态草案（needsReview=true）只供人工确认用；不得直接当 profile 执行。') -Data ([pscustomobject]$data)
}
#endregion

#region 导出 5：Get-LctDriverDevices（注册表解 .sys 路径 + 候选入口 + CreateFile 可用性；绝不发 IOCTL）
function Get-LctDriverDevices {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Profile = '',
        [string]$Sha256 = '',
        [string]$FileName = '',
        [switch]$DeepScan,
        [switch]$NoCreateFileTest
    )
    $verb = 'driver.devices'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $svcName = ([string]$Name).Trim()
    if ($svcName -notmatch '^[A-Za-z0-9_.\-]{1,128}$') {
        return New-LctResult -Verb $verb -Errors @("服务名非法: '$Name'（只允许字母/数字/下划线/点/连字符，长度 1..128；避免把不可信字符串拼进注册表路径）")
    }
    $profInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $found = Find-LctPrfProfile -Id $Profile
        if (-not $found.ok) { return New-LctResult -Verb $verb -Errors @($found.error) }
        $profInfo = Test-LctPrfProfileSchema -Profile $found.profile -ProfilePath $found.path
        if (-not [string]::IsNullOrWhiteSpace($Sha256) -and $profInfo.info.sha256 -ne '' -and $Sha256.ToLower() -ne $profInfo.info.sha256) {
            $null = $warnings.Add('传入的 -Sha256 与 profile 声明的 target.sha256 不同：文件路径以注册表/显式路径为准，指纹反查用传入值')
        }
    }
    $fn = [string]$FileName
    if ($fn -eq '' -and $null -ne $profInfo) { $fn = [string]$profInfo.info.fileName }
    $svcHint = $svcName
    if ($null -ne $profInfo -and [string]$profInfo.info.strategy -eq 'serviceImagePath' -and [string]$profInfo.info.serviceNameHint -ne '') { $svcHint = [string]$profInfo.info.serviceNameHint }
    $sys = Resolve-LctPrfSysPath -ServiceName $svcHint -FileName $fn -Sha256 $Sha256 -AllowDriveStoreScan:$DeepScan
    $fileBlock = [pscustomobject][ordered]@{
        path = $sys.path; exists = [bool]$sys.exists; resolution = $sys.resolution; sha256 = $sys.sha256
        attempts = @($sys.attempts); notes = @($sys.notes); driverStore = $sys.driverStore; error = $sys.error
        service = [pscustomobject][ordered]@{
            name = $svcHint; keyPath = $sys.service.keyPath; exists = [bool]$sys.service.exists
            imagePath = [string]$sys.service.imagePath; start = [int]$sys.service.start; type = [int]$sys.service.type
        }
    }
    $cands = New-Object System.Collections.ArrayList
    $ig = ''
    if ($null -ne $profInfo) {
        foreach ($c in @($profInfo.info.candidates)) { $null = $cands.Add([pscustomobject][ordered]@{ kind = 'symlink'; name = ''; candidate = [string]$c; source = ('profile:' + $Profile); wildcard = ([string]$c).Contains('*') }) }
        $ig = [string]$profInfo.info.interfaceGuid
        if ($ig -ne '') { $null = $cands.Add([pscustomobject][ordered]@{ kind = 'interfaceGuid'; name = ''; candidate = $ig; source = ('profile:' + $Profile); wildcard = $false }) }
    }
    foreach ($d in @(Get-LctPrfDerivedCandidates -ServiceName $svcName -FileName $fn)) { $null = $cands.Add($d) }
    $iface = $null
    $ifacePaths = New-Object System.Collections.ArrayList
    if ($ig -ne '') {
        $iface = Get-LctPrfInterfaceList -InterfaceGuid $ig
        if ($iface.ok) { foreach ($p in @($iface.items)) { $null = $ifacePaths.Add([pscustomobject][ordered]@{ kind = 'interface'; name = ''; candidate = [string]$p; source = 'interfaceGuid'; wildcard = $false }) } }
        elseif ($iface.error -ne '') { $null = $warnings.Add('设备接口枚举失败: ' + $iface.error) }
    }
    $matchPatterns = New-Object System.Collections.ArrayList
    foreach ($c in @($cands)) {
        $t = ([string]$c.candidate).Trim()
        if ($t -eq '') { continue }
        $leaf = $t
        if ($leaf -match '^\\\?\?\\') { $leaf = $leaf.Substring(4) }
        elseif ($leaf -match '^\\\.\\') { $leaf = $leaf.Substring(4) }
        elseif ($leaf -match '^\\Device\\') { $leaf = $leaf.Substring(8) }
        if ($leaf -ne '' -and -not ($matchPatterns -contains $leaf)) { $null = $matchPatterns.Add($leaf) }
    }
    if (-not [string]::IsNullOrWhiteSpace($svcHint)) { if (-not ($matchPatterns -contains $svcHint)) { $null = $matchPatterns.Add($svcHint) } }
    $nt = Invoke-LctPrfNtEnumerate -Root '\GLOBAL??' -MatchNames @($matchPatterns) -ResolveMatchedTargets
    if ($nt.attempted -and -not $nt.supported) { $null = $warnings.Add('NT 枚举不可用（' + $nt.error + '）⇒ 只用 profile/派生候选集，**不假装枚举成功**；如需枚举 \Device/\GLOBAL?? 请确认 ntdll P/Invoke 可用') }
    $ntPaths = New-Object System.Collections.ArrayList
    foreach ($m in @($nt.matched)) {
        $null = $ntPaths.Add([pscustomobject][ordered]@{ kind = 'symlink'; name = [string]$m.name; candidate = ('\??\' + [string]$m.name); source = 'ntEnum'; wildcard = $false; ntTarget = [string]$m.target })
    }
    $merged = New-Object System.Collections.ArrayList
    $seen = New-Object System.Collections.ArrayList
    foreach ($group in @($ntPaths, $ifacePaths, $cands)) {
        foreach ($c in @($group)) {
            $key = ([string]$c.candidate).ToLower()
            if ($key -eq '' -or ($seen -contains $key)) { continue }
            $null = $seen.Add($key)
            $null = $merged.Add($c)
        }
    }
    $probe = Invoke-LctPrfProbeCandidates -Candidates $merged -Access 0 -NoOpen:$NoCreateFileTest
    if ($probe.handle -ne [IntPtr]::Zero) {
        try { [LctPrfNative]::CloseHandle($probe.handle) | Out-Null } catch { }
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($t in @($probe.tries)) {
        $srcRow = $null
        foreach ($c in @($merged)) { if (([string]$c.candidate).ToLower() -eq ([string]$t.candidate).ToLower()) { $srcRow = $c; break } }
        $ntTarget = ''
        if ($null -ne $srcRow -and $srcRow.PSObject.Properties['ntTarget']) { $ntTarget = [string]$srcRow.ntTarget }
        $null = $items.Add([pscustomobject][ordered]@{
                candidate = $t.candidate; kind = $(if ($null -ne $srcRow) { [string]$srcRow.kind } else { 'unknown' })
                name = $(if ($null -ne $srcRow) { [string]$srcRow.name } else { '' })
                source = $t.source; ntTarget = $ntTarget
                openPath = $t.openPath; wildcard = [bool]$t.wildcard; attempted = [bool]$t.attempted; openable = [bool]$t.ok
                win32Error = [int]$t.win32Error; classification = $t.classification; message = $t.message
            })
    }
    $isFatal = $false
    if (-not $sys.service.exists -and -not $sys.exists) {
        $null = $errors.Add('服务不存在且 .sys 也定位不到：注册表里没有 HKLM\SYSTEM\CurrentControlSet\Services\' + $svcHint + '，回退路径 System32\drivers\' + $svcHint + '.sys 也不存在。可用 driver.list 查看本机驱动服务名（例如 disk / tcpip）。')
        $isFatal = $true
    } elseif (-not $sys.exists) {
        $null = $warnings.Add('服务存在但 .sys 文件定位失败：' + $sys.error)
    }
    if ($probe.verdict -eq 'not-found') { $null = $warnings.Add('所有候选 CreateFile 都返回「设备不存在」：驱动可能未加载，或设备名与候选不符（本模块不猜设备名）') }
    $data = [ordered]@{
        name = $svcName
        file = $fileBlock
        items = @($items)
        count = @($items).Count
        entryCandidates = [pscustomobject][ordered]@{ count = @($items).Count; candidates = @($items) }
        interfaceEnumeration = $iface
        ntEnumeration = [pscustomobject][ordered]@{
            attempted = [bool]$nt.attempted; supported = [bool]$nt.supported; ok = [bool]$nt.ok; root = $nt.root
            error = $nt.error; total = [int]$nt.total; typeCounts = $nt.typeCounts
            matchCount = [int]$nt.matchCount; matched = @($nt.matched); targetResolved = [int]$nt.targetResolved; notes = @($nt.notes)
        }
        openability = [pscustomobject][ordered]@{
            tryCount = [int]$probe.tryCount; okCount = [int]$probe.okCount; wildcardCount = [int]$probe.wildcardCount
            verdict = $probe.verdict; classifications = $probe.classifications; skipped = [bool]$NoCreateFileTest
        }
        notes = @(
            '本次只做 CreateFile 可用性实测（access=0 查询式打开）与错误分类，**没有发送任何 IOCTL**（未知 IOCTL 会蓝屏）。'
            '文件路径解析只用注册表 ImagePath → System32\drivers 回退 → DriverStore 按 SHA256 反查（全部只读）；不写注册表、不改文件。'
            '设备对象名 ↔ 驱动服务名在用户态没有权威映射：NT 枚举只按名字匹配，匹配不上就是 matchCount=0，不做猜测。'
        )
        warnings = @($warnings)
    }
    $null = Write-LctPrfLog -Verb $verb -Level $(if ($isFatal) { 'warn' } else { 'info' }) -Message ('解析 driver.devices: ' + $svcHint + ' file=' + $sys.path + ' verdict=' + $probe.verdict) -Data ([ordered]@{ name = $svcName; file = $sys.path; resolution = $sys.resolution; verdict = $probe.verdict; tryCount = $probe.tryCount })
    if ($isFatal) { return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$data) }
    return [pscustomobject]$data
}
#endregion

#region 导出 6：Invoke-LctDriverCtl（通用原语执行器：默认只预览，-Apply 才 CreateFile + DeviceIoControl）
function Get-LctPrfReadBackPlan {
    # 为写类动作找「读回原值」的动作与写入值字段（拿不到原值 ⇒ 拒绝写，契约 §13.6 第 3 条）
    param($Profile, [string]$ActionName, $WriteAct)
    $o = [ordered]@{ ok = $false; actionName = ''; error = ''; valueFieldName = ''; inFields = @(); outFields = @(); source = '' }
    $actions = Get-LctPrfProp -Bag $Profile -Name 'actions'
    if ($null -eq $actions -or $actions -isnot [System.Collections.IDictionary]) { $o.error = 'profile 没有 actions'; return [pscustomobject]$o }
    $wIn = @(Get-LctPrfProp -Bag $WriteAct -Name 'in' -Default @())
    $writeNames = New-Object System.Collections.ArrayList
    foreach ($f in $wIn) { $null = $writeNames.Add([string](Get-LctPrfProp -Bag $f -Name 'name' -Default '')) }
    $rbName = [string](Get-LctPrfProp -Bag $WriteAct -Name 'readBack' -Default '')
    $o.source = 'action.readBack'
    if ($rbName -eq '') {
        $rbName = [string](Get-LctPrfProp -Bag $Profile -Name 'readBackAction' -Default '')
        $o.source = 'profile.readBackAction'
    }
    if ($rbName -eq '') {
        foreach ($an in @($actions.Keys | Sort-Object)) {
            if ([string]$an -ieq $ActionName) { continue }
            $a = $actions[$an]
            $k = [string](Get-LctPrfProp -Bag $a -Name 'kind' -Default '')
            if ($k -ne 'read' -and ([string]$an) -notmatch '^(?i)k?read') { continue }
            $inNames = New-Object System.Collections.ArrayList
            foreach ($f in @(Get-LctPrfProp -Bag $a -Name 'in' -Default @())) { $null = $inNames.Add([string](Get-LctPrfProp -Bag $f -Name 'name' -Default '')) }
            $shared = 0
            foreach ($n in @($inNames)) { if ($writeNames -contains $n) { $shared++ } }
            if ($shared -gt 0) { $rbName = [string]$an; $o.source = 'auto(kind=read + 共享输入字段)'; break }
        }
    }
    if ($rbName -eq '' -or -not $actions.Contains($rbName)) {
        $o.error = 'profile 没有可用的读回动作（readBack / readBackAction / kind=read 都没有）⇒ 写类原语拒绝执行'
        return [pscustomobject]$o
    }
    $rb = $actions[$rbName]
    $o.actionName = $rbName
    $o.inFields = @(Get-LctPrfProp -Bag $rb -Name 'in' -Default @())
    $o.outFields = @(Get-LctPrfProp -Bag $rb -Name 'out' -Default @())
    if (@($o.outFields).Count -eq 0) { $o.error = ('读回动作 ' + $rbName + ' 没有 out 字段，读不到原值'); return [pscustomobject]$o }
    $outValName = ''
    foreach ($f in @($o.outFields)) {
        if ([string](Get-LctPrfProp -Bag $f -Name 'type' -Default '') -eq 'bytes') { $outValName = [string](Get-LctPrfProp -Bag $f -Name 'name' -Default ''); break }
    }
    if ($outValName -eq '') { $outValName = [string](Get-LctPrfProp -Bag $o.outFields[0] -Name 'name' -Default '') }
    $valName = ''
    foreach ($f in $wIn) {
        if ([string](Get-LctPrfProp -Bag $f -Name 'type' -Default '') -eq 'bytes' -and [string](Get-LctPrfProp -Bag $f -Name 'name' -Default '') -ieq $outValName) { $valName = $outValName; break }
    }
    if ($valName -eq '') {
        foreach ($f in $wIn) {
            if ([string](Get-LctPrfProp -Bag $f -Name 'type' -Default '') -eq 'bytes') { $valName = [string](Get-LctPrfProp -Bag $f -Name 'name' -Default '') }
        }
    }
    if ($valName -eq '') { $o.error = '写动作里找不到 bytes 字段，无法把原值写回去 ⇒ 拒绝执行写'; return [pscustomobject]$o }
    $o.valueFieldName = $valName
    $o.ok = $true
    return [pscustomobject]$o
}

function Write-LctPrfRestoreScript {
    # 生成还原脚本（.ps1 带 BOM + .cmd 纯 ASCII + .json 精确参数）：复刻「把原值写回去」这一步
    param(
        [string]$ProfileId = '', [string]$ActionName = '', [string]$DevicePath = '', [string]$ValueField = '',
        [string]$BeforeHex = '', [string]$AfterHex = '', [string]$Sha256 = '', [bool]$Bsod = $false, $PayloadValues = $null
    )
    $o = [ordered]@{ ok = $false; dir = ''; ps1 = ''; cmd = ''; argsJson = ''; note = ''; error = '' }
    $base = Join-Path (Get-LctPrfVarBase) 'driver-profiles\restore'
    try { $null = Ensure-LctPrfDir -Path $base } catch { $o.error = '创建还原目录失败: ' + $_.Exception.Message; return [pscustomobject]$o }
    $o.dir = $base
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $tag = (ConvertTo-LctPrfSafeName -Text ($ProfileId + '-' + $ActionName)) + '-' + $stamp
    $payload = [ordered]@{}
    if ($null -ne $PayloadValues -and $PayloadValues -is [System.Collections.IDictionary]) {
        foreach ($k in @($PayloadValues.Keys)) { $payload[[string]$k] = $PayloadValues[$k] }
    }
    $payload[$ValueField] = $BeforeHex
    $argsObj = [ordered]@{ profile = $ProfileId; action = $ActionName; payload = $payload; overrideBsod = $true }
    $argsFile = Join-Path $base ($tag + '.json')
    $ps1File = Join-Path $base ($tag + '.ps1')
    $cmdFile = Join-Path $base ($tag + '.cmd')
    try {
        Write-LctPrfTextBom -Path $argsFile -Text (ConvertTo-LctPrfJson -Object $argsObj -Depth 10) | Out-Null
        $engine = Join-Path (Get-LctPrfToolRoot) 'core\Engine.ps1'
        $q = [char]39
        $ls = New-Object System.Collections.ArrayList
        $null = $ls.Add('# LocalConfigTool kwrite 还原脚本（自动生成，只做「把原值写回去」这一步）')
        $null = $ls.Add('#   profile   : ' + (ConvertTo-LctPrfAsciiText -Text $ProfileId))
        $null = $ls.Add('#   action    : ' + (ConvertTo-LctPrfAsciiText -Text $ActionName))
        $null = $ls.Add('#   设备      : ' + (ConvertTo-LctPrfAsciiText -Text $DevicePath))
        $null = $ls.Add('#   原值      : ' + (ConvertTo-LctPrfAsciiText -Text $BeforeHex))
        $null = $ls.Add('#   写入值    : ' + (ConvertTo-LctPrfAsciiText -Text $AfterHex))
        $null = $ls.Add('#   .sys 指纹 : ' + (ConvertTo-LctPrfAsciiText -Text $Sha256))
        $null = $ls.Add('#   bsod 动作 : ' + [string]$Bsod)
        $null = $ls.Add('# 适用条件与写入时一致（同一驱动版本、同一设备）；驱动已换版本先跑 driver.profile.validate。')
        $null = $ls.Add('$ErrorActionPreference = ''Continue''')
        $null = $ls.Add('$engine = ' + $q + ($engine -replace "'", "''") + $q)
        $null = $ls.Add('$argsFile = Join-Path $PSScriptRoot ' + $q + ($tag + '.json') + $q)
        $null = $ls.Add('$pwshExe = Join-Path $env:SystemRoot ' + $q + 'System32\WindowsPowerShell\v1.0\powershell.exe' + $q)
        $null = $ls.Add('$out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $engine -Verb ''driver.ctl.send'' -ArgsFile $argsFile -Apply 2>&1')
        $null = $ls.Add('[Console]::Out.WriteLine($out)')
        $null = $ls.Add('[Console]::Out.WriteLine(''还原脚本结束，退出码 = '' + $LASTEXITCODE)')
        Write-LctPrfTextBom -Path $ps1File -Text (($ls) -join "`r`n") | Out-Null
        $cs = New-Object System.Collections.ArrayList
        $null = $cs.Add('@echo off')
        $null = $cs.Add('setlocal')
        $null = $cs.Add('REM LocalConfigTool kwrite restore (generated, ASCII-safe wrapper)')
        $null = $cs.Add('REM profile=' + (ConvertTo-LctPrfAsciiText -Text $ProfileId) + ' action=' + (ConvertTo-LctPrfAsciiText -Text $ActionName))
        $null = $cs.Add('REM If any character shows as ?, run the .ps1 in this folder for the exact values.')
        $null = $cs.Add('powershell -NoProfile -ExecutionPolicy Bypass -File "core\Engine.ps1" -Verb driver.ctl.send -ArgsFile "' + $tag + '.json" -Apply')
        $null = $cs.Add('echo restore finished, last exit code = %ERRORLEVEL%')
        $null = $cs.Add('endlocal')
        Write-LctPrfTextAsciiCrlf -Path $cmdFile -Text (($cs) -join "`r`n") | Out-Null
        $o.ok = $true
        $o.ps1 = $ps1File
        $o.cmd = $cmdFile
        $o.argsJson = $argsFile
        $o.note = ('还原脚本已写在 ' + $base + '（.ps1 精确版 / .cmd 备用）；原值 ' + $BeforeHex)
    } catch { $o.error = '写还原脚本失败: ' + $_.Exception.Message }
    return [pscustomobject]$o
}

function Invoke-LctDriverCtl {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Action,
        [AllowEmptyString()][string]$Payload = '',
        [switch]$OverrideBsod,
        [switch]$IUnderstand,
        [switch]$SkipFingerprint,
        [switch]$Apply
    )
    $verb = 'driver.ctl.send'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $changes = New-Object System.Collections.ArrayList
    $refused = ''
    $model = [ordered]@{
        mode = $(if ($Apply) { 'apply' } else { 'preview' })
        profile = [ordered]@{ id = [string]$Profile; source = ''; path = ''; schemaOk = $false; engineApi = 0; riskLevel = '' }
        sysFile = $null
        action = [ordered]@{ name = [string]$Action; kind = ''; ioctl = 0; ioctlHex = ''; riskLevel = ''; riskSource = ''; method = 'buffered'; requiresOverrideBsod = $false; requiresUnderstand = $false; openAccess = 'readwrite' }
        request = [ordered]@{ size = 0; hex = ''; hexDump = @(); fields = @(); outFields = @(); outSize = 0; outNote = ''; payloadKeys = @(); method = 'buffered' }
        device = [ordered]@{ strategy = ''; interfaceGuid = ''; candidates = @(); openAttempts = @(); opened = $false; openPath = ''; verdict = 'preview' }
        gate = [ordered]@{ bsodOverride = [bool]$OverrideBsod; understand = [bool]$IUnderstand; skipFingerprint = [bool]$SkipFingerprint; refused = '' }
        result = $null; rawOutHex = ''; bytesReturned = 0; before = $null; after = $null; restore = $null; ioctlSent = $false
        notes = (New-Object System.Collections.ArrayList)
    }
    $found = Find-LctPrfProfile -Id $Profile
    if (-not $found.ok) {
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message $found.error -Data ([ordered]@{ profile = $Profile; action = $Action })
        $model.gate.refused = 'profile-not-found'
        return New-LctResult -Verb $verb -Errors @($found.error) -Data ([pscustomobject]$model)
    }
    $model.profile.id = $found.id
    $model.profile.source = $found.source
    $model.profile.path = $found.path
    $prof = $found.profile
    $profDir = Split-Path -Parent $found.path
    $sch = Test-LctPrfProfileSchema -Profile $prof -ProfilePath $found.path -ExpectedId $found.id
    $model.profile.schemaOk = [bool]$sch.ok
    $model.profile.engineApi = [int]$sch.info.engineApi
    $model.profile.riskLevel = [string]$sch.info.riskLevel
    if (-not $sch.ok) {
        foreach ($e in @($sch.errors)) { $null = $errors.Add('schema: ' + [string]$e) }
        $refused = 'schema'
        $null = $errors.Add('profile 未通过 schema 校验 ⇒ 拒绝执行（契约 §13.6 第 2 条：profile 必须过 validate 才允许执行）')
        $model.gate.refused = $refused
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(schema): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ errors = @($errors) })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # 指纹门
    $declared = New-Object System.Collections.ArrayList
    if ($sch.info.sha256 -ne '') { $null = $declared.Add($sch.info.sha256) }
    foreach ($x in @($sch.info.sha256AnyOf)) { $null = $declared.Add($x) }
    $svcForFile = ''
    # .sys 定位与设备入口策略无关：有 serviceNameHint 就用它查注册表 ImagePath（strategy 只管设备怎么找）。
    if ([string]$sch.info.serviceNameHint -ne '') { $svcForFile = [string]$sch.info.serviceNameHint }
    $sys = Resolve-LctPrfSysPath -ServiceName $svcForFile -FileName ([string]$sch.info.fileName) -ProfileDir $profDir -Sha256 ([string]$declared[0])
    $fpBlock = [ordered]@{
        path = $sys.path; exists = [bool]$sys.exists; resolution = $sys.resolution; declared = @($declared)
        actual = ''; match = $false; skipped = $false; attempts = @($sys.attempts); service = $sys.service; error = $sys.error
    }
    $fpBlocked = ''
    if (@($declared).Count -eq 0) {
        $fpBlocked = 'profile 没有 target.sha256 ⇒ 无法确认布局版本，拒绝执行'
    } elseif (-not $sys.ok) {
        if ($SkipFingerprint) {
            $fpBlock.skipped = $true
            $null = $warnings.Add('[高危] 无法定位 .sys 比对指纹，已按 -SkipFingerprint 跳过：' + $sys.error)
        } else {
            $fpBlocked = '无法定位 .sys 比对指纹（' + $sys.error + '）⇒ 拒绝执行；确认要跳过请显式加 -SkipFingerprint（会写审计日志）'
        }
    } else {
        $fpBlock.actual = (Get-LctPrfSha256 -Path $sys.path).ToLower()
        $fpBlock.match = ($declared -contains $fpBlock.actual)
        if (-not $fpBlock.match) {
            $fpBlocked = '指纹不符：实际 ' + $fpBlock.actual + ' 不在 ' + (@($declared) -join ' / ') + ' 里（布局错版本必蓝屏）⇒ 拒绝执行；即使加 -SkipFingerprint 也不放行'
        }
    }
    $model.sysFile = [pscustomobject]$fpBlock
    if ($fpBlocked -ne '') {
        $refused = 'fingerprint'
        $null = $errors.Add($fpBlocked)
        $model.gate.refused = $refused
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(fingerprint): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ reason = $fpBlocked })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # 动作与布局
    $actions = $prof['actions']
    if (-not $actions.Contains($Action)) {
        $refused = 'action-not-found'
        $null = $errors.Add('动作不存在: ' + $Action + '（该 profile 可用动作: ' + ((@($actions.Keys | Sort-Object)) -join ', ') + '）')
        $model.gate.refused = $refused
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    $act = $actions[$Action]
    $layoutRaw = Get-LctPrfProp -Bag $prof -Name 'layout'
    $layout = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
    if ($null -ne $layoutRaw -and $layoutRaw -is [System.Collections.IDictionary]) {
        $layout.method = [string](Get-LctPrfProp -Bag $layoutRaw -Name 'method' -Default 'buffered')
        $layout.align = [int](Get-LctPrfProp -Bag $layoutRaw -Name 'align' -Default 8)
        $layout.endian = [string](Get-LctPrfProp -Bag $layoutRaw -Name 'endian' -Default 'little')
    }
    $kind = [string](Get-LctPrfProp -Bag $act -Name 'kind' -Default '')
    if ($kind -eq '') {
        if ($Action -match '(?i)write') { $kind = 'write' }
        elseif ($Action -match '(?i)read') { $kind = 'read' }
        else { $kind = 'control' }
        $null = $model.notes.Add("动作 '" + $Action + "' 未声明 kind，按名字推断为 '" + $kind + "'（建议在 profile 里显式声明）")
    }
    $ioctlHex = [string](Get-LctPrfProp -Bag $act -Name 'ioctl' -Default '')
    $ioctl = [uint32]0
    if ($ioctlHex -ne '') { $ioctl = [uint32](ConvertTo-LctPrfUInt64 -Value $ioctlHex) }
    $actRisk = ''
    $actRiskSrc = ''
    $ra = Get-LctPrfProp -Bag $act -Name 'risk'
    if ($null -ne $ra) {
        if ($ra -is [System.Collections.IDictionary]) { $actRisk = [string](Get-LctPrfProp -Bag $ra -Name 'level' -Default '') }
        else { $actRisk = [string]$ra }
        $actRiskSrc = 'action.risk'
    }
    if ($actRisk -eq '') { $actRisk = [string]$sch.info.riskLevel; $actRiskSrc = 'profile.risk' }
    $bsodByMethod = ($layout.method -eq 'neither')
    $needsBsod = (($actRisk -eq 'bsod') -or $bsodByMethod)
    $needUnderstand = ($kind -eq 'blindscan')
    $openAccess = [string](Get-LctPrfProp -Bag $act -Name 'openAccess' -Default '')
    if ($openAccess -eq '') {
        $loc0 = Get-LctPrfProp -Bag $prof -Name 'locate'
        if ($null -ne $loc0) { $openAccess = [string](Get-LctPrfProp -Bag $loc0 -Name 'openAccess' -Default '') }
    }
    if ($openAccess -eq '') { $openAccess = 'readwrite' }
    $model.action = [pscustomobject][ordered]@{
        name = $Action; kind = $kind; ioctl = $ioctl; ioctlHex = $ioctlHex; riskLevel = $actRisk; riskSource = $actRiskSrc
        method = $layout.method; requiresOverrideBsod = [bool]$needsBsod; requiresUnderstand = [bool]$needUnderstand; openAccess = $openAccess
    }
    if ($needsBsod -and -not $OverrideBsod) {
        $refused = 'bsod-gate'
        $null = $errors.Add('该动作被标为疑似蓝屏风险（risk.level=' + $actRisk + $(if ($bsodByMethod) { '；layout.method=neither：驱动会直接解引用用户指针，稍有不慎立刻蓝屏' } else { '' }) + '）⇒ 默认禁用。确认已建还原点、清楚后果后加 -OverrideBsod 才放行（契约 §13.6 第 4 条）')
        $null = $warnings.Add('[高危][BSOD] 动作 ' + $Action + ' 是蓝屏风险动作（' + $actRiskSrc + '=' + $actRisk + '），本次已按默认策略拒绝执行')
        $model.gate.refused = $refused
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(bsod-gate): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ risk = $actRisk; riskSource = $actRiskSrc; method = $layout.method })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    if ($needsBsod) { $null = $warnings.Add('[高危][BSOD] 已按 -OverrideBsod 放行蓝屏风险动作 ' + $Action + '（' + $actRiskSrc + '=' + $actRisk + '）：写坏地址/结构会直接蓝屏；本工具已记录原值并生成还原脚本。') }
    if ($needUnderstand -and -not $IUnderstand) {
        $refused = 'blindscan-gate'
        $null = $errors.Add("动作 '" + $Action + "' 是盲扫类（kind=blindscan），可能命中 METHOD_NEITHER 驱动并立刻蓝屏 ⇒ 默认禁用；确认要盲扫必须显式加 -IUnderstand（契约 §13.6 第 4 条）")
        $model.gate.refused = $refused
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(blindscan-gate): ' + $found.id + ' / ' + $Action)
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    if ($needUnderstand) { $null = $warnings.Add('[高危] 盲扫类动作 ' + $Action + ' 已按 -IUnderstand 放行；METHOD_NEITHER 驱动一碰可能立刻蓝屏。') }
      # payload：三种写法都收
      #   ① JSON 对象：{"addr":"0xFFFFF80142A00000","readSize":4}
      #   ② 简写：addr=0xFFFFF80142A00000,readSize=4
      #   ③ 省略：用 action.presets（profile 里预置的默认值）
      # 值里支持 @ntoskrnl：自动取内核基址（省掉"自己去查地址"）
      $values = @{}
      $payloadText = ([string]$Payload).Trim()
      $presetsBag = $null
      try { $presetsBag = Get-LctPrfProp -Bag $act -Name 'presets' } catch { $presetsBag = $null }
      $presetCount = 0
      if ($null -ne $presetsBag) {
          try {
              $pv = ConvertTo-LctPrfPlain -Value $presetsBag
              if ($pv -is [System.Collections.IDictionary]) { foreach ($k in $pv.Keys) { $values[$k] = $pv[$k]; $presetCount++ } }
          } catch { $null = $warnings.Add('action.presets 解析失败（已忽略）：' + $_.Exception.Message) }
      }
      if ($payloadText -ne '') {
          $parsed = $null
          if ($payloadText -match '^\{') {
              $parsedOk = $false
              try { $parsed = ConvertTo-LctPrfPlain -Value ($payloadText | ConvertFrom-Json); $parsedOk = $true } catch { $parsedOk = $false }
              if ((-not $parsedOk) -or ($parsed -isnot [System.Collections.IDictionary])) {
                  $refused = 'payload'
                  $null = $errors.Add('Payload 看起来是 JSON，但解析失败或不是对象：' + $payloadText)
                  $model.gate.refused = $refused
                  $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(payload): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ payload = $payloadText })
                  return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
              }
          } else {
              # 简写：addr=0x...,readSize=4（也接受分号/换行分隔）
              $parsed = @{}
              foreach ($pair in @($payloadText -split '[,;\r\n]+')) {
                  $one = ([string]$pair).Trim()
                  if ($one -eq '') { continue }
                  $eq = $one.IndexOf('=')
                  if ($eq -lt 1) {
                      $refused = 'payload'
                      $null = $errors.Add('简写 payload 每一项必须是 key=value（例如 addr=0xFFFFF80142A00000,readSize=4）；这一项不合格：' + $one)
                      $model.gate.refused = $refused
                      return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
                  }
                  $k = $one.Substring(0, $eq).Trim()
                  $v = $one.Substring($eq + 1).Trim()
                  if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                      $refused = 'payload'
                      $null = $errors.Add('简写 payload 的字段名不合法：' + $k)
                      $model.gate.refused = $refused
                      return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
                  }
                  $parsed[$k] = $v
              }
              $null = $warnings.Add('payload 用了简写形式（key=value）：等价于 JSON 对象 ' + (($parsed | ConvertTo-Json -Compress -Depth 4)))
          }
          foreach ($k in $parsed.Keys) { $values[$k] = $parsed[$k] }
      }
      # @ntoskrnl 之类的占位：自动解析成内核基址（只读）
      foreach ($k in @($values.Keys)) {
          $vv = [string]$values[$k]
          if ($vv -match '^@?(ntoskrnl|ntkrnlmp|kernel)$') {
              $kb = $null
              try { $kb = Get-LctKernelBaseAddress } catch { $kb = $null }
              if ($null -ne $kb -and [int64]$kb.address -ne 0) {
                  $values[$k] = ('0x' + ([int64]$kb.address).ToString('X'))
                  $null = $warnings.Add('payload 字段 ' + $k + ' 用了 @' + $vv.TrimStart('@') + '，已自动解析为内核基址 ' + $values[$k] + '（模块 ' + [string]$kb.name + '）')
              } else {
                  $refused = 'payload'
                  $null = $errors.Add('payload 字段 ' + $k + ' 用了 @' + $vv + '，但取内核基址失败（可能未提权或 psapi 不可用）；请显式给地址')
                  $model.gate.refused = $refused
                  return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
              }
          }
      }
      # 安全闸：既没有 presets 也没给 payload，而动作确实需要输入 ⇒ 拒绝
      # （否则字段会按 0 填充，等于向 0 地址发 IOCTL，极可能立刻蓝屏）
      if ($values.Count -eq 0) {
          $insGuard = @(Get-LctPrfProp -Bag $act -Name 'in' -Default @())
          if (@($insGuard).Count -gt 0) {
              $refused = 'no-payload'
              $null = $errors.Add('这个动作没有预置参数（profile 里可加 "presets"），你也没给 payload ⇒ 拒绝执行：否则会向 0 地址发 IOCTL，极可能立刻蓝屏。请至少给关键字段，支持简写，例如：addr=0xFFFFF80142A00000,readSize=4（也可写 addr=@ntoskrnl 自动取内核基址）')
              $model.gate.refused = $refused
              $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(no-payload): ' + $found.id + ' / ' + $Action)
              return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
          }
      }
      # 动作可声明 require：这些字段必须由人显式给（防止预设默认值掩盖危险输入）
      $reqList = @()
      try { $reqList = @(Get-LctPrfProp -Bag $act -Name 'require' -Default @()) } catch { $reqList = @() }
      if (@($reqList).Count -gt 0) {
          $missingReq = @($reqList | Where-Object { -not $values.ContainsKey([string]$_) })
          if (@($missingReq).Count -gt 0) {
              $refused = 'require'
              $null = $errors.Add('该动作必须显式提供这些字段（不能靠预设/默认值）：' + (@($missingReq) -join ', ') + '。简写示例：addr=@ntoskrnl,readSize=4')
              $model.gate.refused = $refused
              return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
          }
      }
      if ($presetCount -gt 0) { $null = $warnings.Add('已使用 action.presets 预置了 ' + $presetCount + ' 个字段（payload 里的同名值会覆盖它们）') }
    $inFields = @(Get-LctPrfProp -Bag $act -Name 'in' -Default @())
    $outFields = @(Get-LctPrfProp -Bag $act -Name 'out' -Default @())
    $pack = ConvertTo-LctPrfBuffer -Fields $inFields -Layout $layout -Values $values
    if (@($inFields).Count -eq 0) { $pack = [pscustomobject][ordered]@{ ok = $true; error = ''; bytes = (New-Object byte[] 0); size = 0; plan = @() } }
    if (-not $pack.ok) {
        $refused = 'pack'
        $null = $errors.Add('payload 打包失败（' + $Action + '）: ' + [string]$pack.error)
        $model.request.fields = @($pack.plan)
        $model.gate.refused = $refused
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    if (@($pack.defaulted).Count -gt 0) { $null = $warnings.Add('payload 未提供以下字段，已按 0 填充（padding 类字段可省略；若字段名写错也会落在这里）：' + (@($pack.defaulted) -join ', ')) }
    $outSize = 0
    $outPlan = @()
    $outNote = ''
    if (@($outFields).Count -gt 0) {
        $outSet = Get-LctPrfSyntheticSet -Fields $outFields
        $outPack = ConvertTo-LctPrfBuffer -Fields $outFields -Layout $layout -Values $outSet
        if ($outPack.ok) { $outSize = [int]$outPack.size; $outPlan = @($outPack.plan) }
        else { $outNote = '输出布局含无法静态预判长度的字段（如无 len 的 cstr）: ' + [string]$outPack.error }
    }
    $model.request = [pscustomobject][ordered]@{
        size = [int]$pack.size; hex = (ConvertTo-LctPrfHex -Bytes $pack.bytes); hexDump = @(Format-LctPrfHexDump -Bytes $pack.bytes -Max 256)
        fields = @($pack.plan); outFields = @($outPlan); outSize = $outSize; outNote = $outNote; payloadKeys = @($values.Keys); method = $layout.method
    }
    # 设备候选（执行路径只用 profile 声明的候选）
    $candList = New-Object System.Collections.ArrayList
    $ig = ''
    $locate = Get-LctPrfProp -Bag $prof -Name 'locate'
    if ($null -ne $locate -and $locate -is [System.Collections.IDictionary]) {
        foreach ($c in @(Get-LctPrfProp -Bag $locate -Name 'candidates' -Default @())) { $null = $candList.Add([string]$c) }
        $ig = [string](Get-LctPrfProp -Bag $locate -Name 'interfaceGuid' -Default '')
    }
    $model.device.strategy = [string]$sch.info.strategy
    $model.device.interfaceGuid = $ig
    if ($ig -ne '') {
        $ifc = Get-LctPrfInterfaceList -InterfaceGuid $ig
        if ($ifc.ok) { foreach ($p in @($ifc.items)) { $null = $candList.Add([string]$p) } }
        else { $null = $warnings.Add('设备接口枚举失败（' + $ifc.error + '）：退回 profile 声明的符号链接候选') }
    }
    $model.device.candidates = @($candList)
    if (-not $Apply) {
        $model.gate.refused = ''
        if ($kind -eq 'write') {
            $rbPlan0 = Get-LctPrfReadBackPlan -Profile $prof -ActionName $Action -WriteAct $act
            $null = $changes.Add((New-LctPrfChange -Target ('driver-ctl://' + $found.id + '/' + $Action) -Name ([string]$pack.size + ' 字节输入') -Before '(未读取：预览不发任何 IOCTL)' -After (ConvertTo-LctPrfHex -Bytes $pack.bytes) -Note $(if ($rbPlan0.ok) { '写类动作：-Apply 时会先用 ' + $rbPlan0.actionName + ' 读回原值，再写，并生成还原脚本' } else { '写类动作：profile 没有可用读回动作 ⇒ -Apply 会被拒绝（无原值不写）' })))
        } else {
            $null = $changes.Add((New-LctPrfChange -Target ('driver-ctl://' + $found.id + '/' + $Action) -Name ([string]$pack.size + ' 字节输入') -Before '' -After '(由驱动返回，见 data.result)' -Note '只读/控制类动作：预览不发 IOCTL'))
        }
        $null = $model.notes.Add('预览模式：没有 CreateFile 任何设备、没有发送任何 IOCTL（契约 §13.6 第 1 条）。加 -Apply 才真发。')
        $null = Write-LctPrfLog -Verb $verb -Level 'info' -Message ('预览: ' + $found.id + '/' + $Action + ' ioctl=' + $ioctlHex) -Data ([ordered]@{ profile = $found.id; action = $Action; ioctl = $ioctlHex; inSize = $pack.size; inHex = (ConvertTo-LctPrfHex -Bytes $pack.bytes -Max 64); deviceCandidates = @($candList); applied = $false })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Changes @($changes) -Data ([pscustomobject]$model)
    }
    # -Apply
    if ($kind -eq 'blindscan') {
        $refused = 'blindscan-unsupported'
        $null = $errors.Add('kind=blindscan 的盲扫动作在首版不实现自动扫描（盲扫 METHOD_NEITHER 驱动会立刻蓝屏）；请先在 profile 里写明确切 ioctl 与 risk.level。')
        $model.gate.refused = $refused
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    if ($ioctlHex -eq '') {
        $refused = 'no-ioctl'
        $null = $errors.Add('动作 ' + $Action + ' 没有声明 ioctl，无法执行（盲扫请显式写出 ioctl 并用 -IUnderstand）')
        $model.gate.refused = $refused
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    $rbPlan = $null
    if ($kind -eq 'write') {
        $rbPlan = Get-LctPrfReadBackPlan -Profile $prof -ActionName $Action -WriteAct $act
        if (-not $rbPlan.ok) {
            $refused = 'no-before'
            $null = $errors.Add('无原值不写：' + $rbPlan.error + '（契约 §13.6 第 3 条：原语层不得提供「不带还原的写」）')
            $model.gate.refused = $refused
            $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(no-before): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ reason = $rbPlan.error })
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
        }
    }
    $accessMap = @{ 'none' = 0; 'query' = 0; 'read' = 2147483648; 'write' = 1073741824; 'readwrite' = 3221225472 }
    $accessVal = [uint32]3221225472
    if ($accessMap.ContainsKey($openAccess.ToLower())) { $accessVal = [uint32]$accessMap[$openAccess.ToLower()] }
    $openCands = New-Object System.Collections.ArrayList
    foreach ($c in @($candList)) {
        $op = ConvertTo-LctPrfOpenPath -Candidate ([string]$c)
        if ($op.ok -and -not $op.wildcard) { $null = $openCands.Add([pscustomobject][ordered]@{ candidate = $op.path; source = 'profile' }) }
    }
    $probe = Invoke-LctPrfProbeCandidates -Candidates @($openCands) -Access $accessVal
    $model.device.openAttempts = @($probe.tries)
    $model.device.opened = [bool]($probe.openPath -ne '')
    $model.device.openPath = [string]$probe.openPath
    $model.device.verdict = [string]$probe.verdict
    if (-not $model.device.opened) {
        $refused = 'device-unavailable'
        $null = $errors.Add('无法打开设备（分类=' + $probe.verdict + '）：候选 ' + ((@($candList)) -join ' , ') + ' 全部失败。请先用 driver.devices -Name <service> -Profile ' + $found.id + ' 核对候选入口；本模块不会拿猜的设备名去写。')
        foreach ($t in @($probe.tries)) { if (-not $t.ok -and $t.attempted) { $null = $warnings.Add('CreateFile ' + $t.openPath + ' -> Win32=' + $t.win32Error + ' (' + $t.classification + ')') } }
        $model.gate.refused = $refused
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('拒绝执行(device-unavailable): ' + $found.id + ' / ' + $Action) -Data ([ordered]@{ verdict = $probe.verdict; tries = @($probe.tries) })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    $handle = $probe.handle
    try {
        $beforeHex = ''
        if ($kind -eq 'write') {
            $rbValues = @{}
            foreach ($f in @($rbPlan.inFields)) {
                $fn2 = [string](Get-LctPrfProp -Bag $f -Name 'name' -Default '')
                if ($values.ContainsKey($fn2)) { $rbValues[$fn2] = $values[$fn2] }
            }
            $rbPack = ConvertTo-LctPrfBuffer -Fields @($rbPlan.inFields) -Layout $layout -Values $rbValues
            if (-not $rbPack.ok) {
                $refused = 'no-before'
                $null = $errors.Add('无原值不写：读回动作 ' + $rbPlan.actionName + ' 的输入无法用当前 payload 构造（' + $rbPack.error + '）⇒ 拒绝执行写')
                $model.gate.refused = $refused
                return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
            }
            $rbIoctlHex = [string](Get-LctPrfProp -Bag $prof['actions'][$rbPlan.actionName] -Name 'ioctl' -Default '')
            $rbIoctl = [uint32](ConvertTo-LctPrfUInt64 -Value $rbIoctlHex)
            $rbOutSize = 0
            $rbOutPack = ConvertTo-LctPrfBuffer -Fields @($rbPlan.outFields) -Layout $layout -Values (Get-LctPrfSyntheticSet -Fields @($rbPlan.outFields))
            if ($rbOutPack.ok) { $rbOutSize = [int]$rbOutPack.size }
            $rbSend = Invoke-LctPrfSendIoctl -Handle $handle -Ioctl $rbIoctl -InBytes $rbPack.bytes -OutSize $rbOutSize -Method $layout.method
            $model.ioctlSent = $true
            $null = $model.notes.Add('读回原值: ioctl=' + $rbIoctlHex + ' -> ' + [string]$rbSend.message)
            if (-not $rbSend.ok) {
                $refused = 'no-before'
                $null = $errors.Add('无原值不写：读回动作 ' + $rbPlan.actionName + ' 发送失败（' + [string]$rbSend.message + '）⇒ 拒绝执行写（契约 §13.6 第 3 条）')
                $model.gate.refused = $refused
                return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
            }
            $beforeHex = ConvertTo-LctPrfHex -Bytes ([byte[]]$rbSend.outBuffer)
            $un = ConvertFrom-LctPrfBuffer -Fields @($rbPlan.outFields) -Layout $layout -Buffer ([byte[]]$rbSend.outBuffer) -Length ([byte[]]$rbSend.outBuffer).Length
            $model.before = [pscustomobject][ordered]@{ action = $rbPlan.actionName; rawHex = $beforeHex; fields = $un.values; ioctl = $rbIoctlHex; bytesReturned = [int]$rbSend.bytesReturned; unpackOk = [bool]$un.ok; unpackError = $un.error; valueField = $rbPlan.valueFieldName; source = $rbPlan.source }
        }
        if ($kind -eq 'write') {
            $rst = Write-LctPrfRestoreScript -ProfileId $found.id -ActionName $Action -DevicePath $model.device.openPath -ValueField $rbPlan.valueFieldName -BeforeHex $beforeHex -AfterHex (ConvertTo-LctPrfHex -Bytes $pack.bytes) -Sha256 ([string]$fpBlock.actual) -Bsod $needsBsod -PayloadValues $values
            $model.restore = $rst
            if (-not $rst.ok) {
                $refused = 'restore-script-failed'
                $null = $errors.Add('还原脚本生成失败 ⇒ 拒绝执行写（不允许「不带还原的写」）：' + $rst.error)
                $model.gate.refused = $refused
                return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
            }
        }
        $send = Invoke-LctPrfSendIoctl -Handle $handle -Ioctl $ioctl -InBytes $pack.bytes -OutSize $outSize -Method $layout.method
        $model.ioctlSent = $true
        $model.bytesReturned = [int]$send.bytesReturned
        if (-not $send.ok) {
            $null = $errors.Add('DeviceIoControl 失败（ioctl=' + $ioctlHex + '）：' + [string]$send.message)
            $null = $model.notes.Add('动作失败，但**没有**写入内核内存（设备未接受该请求）' + $(if ($kind -eq 'write') { '；还原脚本仍已生成，可直接执行' } else { '' }))
            $model.gate.refused = 'ioctl-failed'
            $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('执行失败(ioctl): ' + $found.id + ' / ' + $Action + ' -> ' + [string]$send.message) -Data ([ordered]@{ ioctl = $ioctlHex; win32 = [int]$send.win32Error })
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
        }
        if ($null -ne $send.outBuffer -and ([byte[]]$send.outBuffer).Length -gt 0) {
            $model.rawOutHex = ConvertTo-LctPrfHex -Bytes ([byte[]]$send.outBuffer) -Max $script:LctPrfMaxHexDump
        }
        if (@($outFields).Count -gt 0 -and $null -ne $send.outBuffer) {
            $un2 = ConvertFrom-LctPrfBuffer -Fields $outFields -Layout $layout -Buffer ([byte[]]$send.outBuffer) -Length ([byte[]]$send.outBuffer).Length
            if ($un2.ok) { $model.result = [pscustomobject]$un2.values }
            else {
                $model.result = [pscustomobject][ordered]@{ truncated = [bool]$un2.truncated; error = [string]$un2.error; partial = [pscustomobject]$un2.values }
                $null = $warnings.Add('输出解包不完整: ' + [string]$un2.error)
            }
        }
        if ($kind -eq 'write') {
            $rbValues2 = @{}
            foreach ($f in @($rbPlan.inFields)) {
                $fn3 = [string](Get-LctPrfProp -Bag $f -Name 'name' -Default '')
                if ($values.ContainsKey($fn3)) { $rbValues2[$fn3] = $values[$fn3] }
            }
            $rbPack2 = ConvertTo-LctPrfBuffer -Fields @($rbPlan.inFields) -Layout $layout -Values $rbValues2
            if ($rbPack2.ok) {
                $rbIoctl2 = [uint32](ConvertTo-LctPrfUInt64 -Value ([string](Get-LctPrfProp -Bag $prof['actions'][$rbPlan.actionName] -Name 'ioctl' -Default '')))
                $rbOutSize2 = 0
                $op2 = ConvertTo-LctPrfBuffer -Fields @($rbPlan.outFields) -Layout $layout -Values (Get-LctPrfSyntheticSet -Fields @($rbPlan.outFields))
                if ($op2.ok) { $rbOutSize2 = [int]$op2.size }
                $rbSend2 = Invoke-LctPrfSendIoctl -Handle $handle -Ioctl $rbIoctl2 -InBytes $rbPack2.bytes -OutSize $rbOutSize2 -Method $layout.method
                if ($rbSend2.ok) {
                    $afterHex = ConvertTo-LctPrfHex -Bytes ([byte[]]$rbSend2.outBuffer)
                    $un3 = ConvertFrom-LctPrfBuffer -Fields @($rbPlan.outFields) -Layout $layout -Buffer ([byte[]]$rbSend2.outBuffer) -Length ([byte[]]$rbSend2.outBuffer).Length
                    $model.after = [pscustomobject][ordered]@{ rawHex = $afterHex; fields = $un3.values; bytesReturned = [int]$rbSend2.bytesReturned }
                } else { $null = $warnings.Add('写入后复核读回失败（不影响已完成的写入）: ' + [string]$rbSend2.message) }
            }
            $null = $changes.Add((New-LctPrfChange -Target ('driver-ctl://' + $found.id + '/' + $Action) -Name ([string]$pack.size + ' 字节输入') -Before $beforeHex -After (ConvertTo-LctPrfHex -Bytes $pack.bytes) -Note ('写类原语已执行；还原脚本: ' + [string]$model.restore.ps1)))
        } else {
            $null = $changes.Add((New-LctPrfChange -Target ('driver-ctl://' + $found.id + '/' + $Action) -Name ('ioctl=' + $ioctlHex) -Before '' -After $(if ($model.rawOutHex -ne '') { $model.rawOutHex } else { '(无输出缓冲)' }) -Note '只读/控制类动作已执行'))
        }
        $null = $model.notes.Add('已真实执行：CreateFile ' + $model.device.openPath + ' + DeviceIoControl(ioctl=' + $ioctlHex + ')。applied=true 只代表我们执行了这次调用，设备/驱动的判定见 data.result 与 bytesReturned。')
        $null = Write-LctPrfLog -Verb $verb -Level 'change' -Message ('执行完成: ' + $found.id + '/' + $Action + ' ioctl=' + $ioctlHex) -Data ([ordered]@{
                profile = $found.id; action = $Action; ioctl = $ioctlHex; device = $model.device.openPath; inSize = $pack.size
                inHex = (ConvertTo-LctPrfHex -Bytes $pack.bytes -Max 128); bytesReturned = [int]$send.bytesReturned
                outHex = $model.rawOutHex; before = $beforeHex; risk = $actRisk; overrideBsod = [bool]$OverrideBsod
                understand = [bool]$IUnderstand; skipFingerprint = [bool]$SkipFingerprint; restore = $(if ($null -ne $model.restore) { [string]$model.restore.ps1 } else { '' })
            })
        $model.gate.refused = ''
        return New-LctResult -Verb $verb -Applied -Warnings @($warnings) -Changes @($changes) -Data ([pscustomobject]$model)
    } finally {
        if ($handle -ne [IntPtr]::Zero) {
            try { [LctPrfNative]::CloseHandle($handle) | Out-Null } catch { }
        }
    }
}
#endregion

#region 导出 7：Get-LctDriverCtlVerify（canary 握手；默认只做指纹 + 可打开性 + 计划，不发 IOCTL）
function Get-LctDriverCtlVerify {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [switch]$OverrideBsod,
        [switch]$IUnderstand,
        [switch]$SkipFingerprint,
        [switch]$Apply
    )
    $verb = 'driver.ctl.verify'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $found = Find-LctPrfProfile -Id $Profile
    if (-not $found.ok) { return New-LctResult -Verb $verb -Errors @($found.error) }
    $sch = Test-LctPrfProfileSchema -Profile $found.profile -ProfilePath $found.path -ExpectedId $found.id
    if (-not $sch.ok) {
        foreach ($e in @($sch.errors)) { $null = $errors.Add('schema: ' + [string]$e) }
        return New-LctResult -Verb $verb -Errors @($errors)
    }
    $prof = $found.profile
    $profDir = Split-Path -Parent $found.path
    $declared = New-Object System.Collections.ArrayList
    if ($sch.info.sha256 -ne '') { $null = $declared.Add($sch.info.sha256) }
    foreach ($x in @($sch.info.sha256AnyOf)) { $null = $declared.Add($x) }
    $svcForFile = ''
    # .sys 定位与设备入口策略无关：有 serviceNameHint 就用它查注册表 ImagePath（strategy 只管设备怎么找）。
    if ([string]$sch.info.serviceNameHint -ne '') { $svcForFile = [string]$sch.info.serviceNameHint }
    $sys = Resolve-LctPrfSysPath -ServiceName $svcForFile -FileName ([string]$sch.info.fileName) -ProfileDir $profDir -Sha256 ([string]$declared[0])
    $fpMatch = $false
    $actual = ''
    if ($sys.ok) {
        $actual = (Get-LctPrfSha256 -Path $sys.path).ToLower()
        if (@($declared).Count -gt 0) {
            $fpMatch = ($declared -contains $actual)
            if (-not $fpMatch) { $null = $errors.Add('指纹不符：实际 ' + $actual + ' 不在声明里 ⇒ 这个设备就算能打开，也不能证明它就是本 profile 描述的那个驱动版本') }
        } else { $null = $warnings.Add('profile 没有 target.sha256：无法做文件身份证明') }
    } elseif (-not $SkipFingerprint) {
        $null = $errors.Add('无法定位 .sys 比对指纹：' + $sys.error)
    } else { $null = $warnings.Add('按 -SkipFingerprint 跳过指纹（结果不足以证明设备身份）') }
    $locate = Get-LctPrfProp -Bag $prof -Name 'locate'
    $candList = New-Object System.Collections.ArrayList
    $ig = ''
    if ($null -ne $locate -and $locate -is [System.Collections.IDictionary]) {
        foreach ($c in @(Get-LctPrfProp -Bag $locate -Name 'candidates' -Default @())) { $null = $candList.Add([string]$c) }
        $ig = [string](Get-LctPrfProp -Bag $locate -Name 'interfaceGuid' -Default '')
    }
    if ($ig -ne '') {
        $ifc = Get-LctPrfInterfaceList -InterfaceGuid $ig
        if ($ifc.ok) { foreach ($p in @($ifc.items)) { $null = $candList.Add([string]$p) } }
        else { $null = $warnings.Add('设备接口枚举失败: ' + $ifc.error) }
    }
    $probe = Invoke-LctPrfProbeCandidates -Candidates @($candList) -Access 0
    if ($probe.handle -ne [IntPtr]::Zero) { try { [LctPrfNative]::CloseHandle($probe.handle) | Out-Null } catch { } }
    $hs = Get-LctPrfProp -Bag $prof -Name 'handshake'
    $canary = [ordered]@{ declared = [bool]($null -ne $hs); action = ''; ioctl = ''; minOutBytes = 0; sent = $false; ok = $false; message = '' }
    if ($null -ne $hs -and $hs -is [System.Collections.IDictionary]) {
        $canary.action = [string](Get-LctPrfProp -Bag $hs -Name 'action' -Default '')
        $ex = Get-LctPrfProp -Bag $hs -Name 'expect'
        if ($null -ne $ex -and $ex -is [System.Collections.IDictionary]) {
            $canary.ioctl = [string](Get-LctPrfProp -Bag $ex -Name 'ioctl' -Default '')
            $canary.minOutBytes = [int](ConvertTo-LctPrfUInt64 -Value (Get-LctPrfProp -Bag $ex -Name 'minOutBytes' -Default 0))
        }
    }
    $proofLevel = 'none'
    if ($fpMatch) { $proofLevel = 'file-fingerprint' }
    if ($probe.okCount -gt 0) { $proofLevel = 'openable' }
    if ($null -eq $hs) {
        $null = $warnings.Add('profile 未声明 handshake ⇒ 无法证明「这个设备确实是这个驱动」；只能给文件指纹与可打开性（proofLevel=' + $proofLevel + '）')
    } elseif ($Apply) {
        if ($probe.openPath -eq '') {
            $null = $errors.Add('canary 未发送：没有可打开的设备入口（分类=' + $probe.verdict + '）')
        } elseif ($canary.action -eq '' -or -not $prof['actions'].Contains($canary.action)) {
            $null = $errors.Add('canary 未发送：handshake.action 为空或不在 actions 里')
        } else {
            $act = $prof['actions'][$canary.action]
            $layout = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
            $lr = Get-LctPrfProp -Bag $prof -Name 'layout'
            if ($null -ne $lr -and $lr -is [System.Collections.IDictionary]) {
                $layout.method = [string](Get-LctPrfProp -Bag $lr -Name 'method' -Default 'buffered')
                $layout.align = [int](Get-LctPrfProp -Bag $lr -Name 'align' -Default 8)
            }
            $actRisk = [string]$sch.info.riskLevel
            $ra = Get-LctPrfProp -Bag $act -Name 'risk'
            if ($null -ne $ra) { $actRisk = [string](Get-LctPrfProp -Bag $ra -Name 'level' -Default $actRisk) }
            if (($actRisk -eq 'bsod' -or $layout.method -eq 'neither') -and -not $OverrideBsod) {
                $null = $errors.Add('canary 动作被标为 bsod 风险 ⇒ 需要 -OverrideBsod 才发送')
            } else {
                $h2 = Invoke-LctPrfCreateFile -Path $probe.openPath -Access 0
                if (-not $h2.ok) {
                    $null = $errors.Add('canary 打开设备失败: ' + [string]$h2.message)
                } else {
                    try {
                        $io2 = [uint32](ConvertTo-LctPrfUInt64 -Value ([string](Get-LctPrfProp -Bag $act -Name 'ioctl' -Default '')))
                        $in2 = @(Get-LctPrfProp -Bag $act -Name 'in' -Default @())
                        $out2 = @(Get-LctPrfProp -Bag $act -Name 'out' -Default @())
                        $p2 = ConvertTo-LctPrfBuffer -Fields $in2 -Layout $layout -Values (Get-LctPrfSyntheticSet -Fields $in2)
                        if (@($in2).Count -eq 0) { $p2 = [pscustomobject][ordered]@{ ok = $true; bytes = (New-Object byte[] 0); size = 0; error = '' } }
                        $osz = 0
                        $o2p = ConvertTo-LctPrfBuffer -Fields $out2 -Layout $layout -Values (Get-LctPrfSyntheticSet -Fields $out2)
                        if ($o2p.ok) { $osz = [int]$o2p.size }
                        if ($osz -lt $canary.minOutBytes) { $osz = $canary.minOutBytes }
                        if ($p2.ok) {
                            $s2 = Invoke-LctPrfSendIoctl -Handle $h2.handle -Ioctl $io2 -InBytes $p2.bytes -OutSize $osz -Method $layout.method
                            $canary.sent = [bool]$s2.sent
                            $canary.ok = [bool]$s2.ok
                            $canary.message = [string]$s2.message
                            if ($s2.ok) {
                                $proofLevel = 'handshake'
                                if ($canary.minOutBytes -gt 0 -and [int]$s2.bytesReturned -lt $canary.minOutBytes) {
                                    $canary.ok = $false
                                    $proofLevel = 'openable'
                                    $null = $warnings.Add('握手返回字节数 ' + [int]$s2.bytesReturned + ' 少于 expect.minOutBytes=' + $canary.minOutBytes)
                                }
                            } else { $null = $errors.Add('canary 握手失败：' + [string]$s2.message) }
                        } else { $null = $errors.Add('canary 输入打包失败: ' + [string]$p2.error) }
                    } finally { [LctPrfNative]::CloseHandle($h2.handle) | Out-Null }
                }
            }
        }
    } else {
        $null = $warnings.Add('未加 -Apply ⇒ 只报告指纹与可打开性，不发送 canary IOCTL（证明强度只到 ' + $proofLevel + '）')
    }
    $data = [ordered]@{
        id = $found.id; source = $found.source; path = $found.path
        proofLevel = $proofLevel
        fileFingerprint = [pscustomobject][ordered]@{ path = $sys.path; exists = [bool]$sys.exists; resolution = $sys.resolution; declared = @($declared); actual = $actual; match = [bool]$fpMatch; skipped = [bool]$SkipFingerprint }
        device = [pscustomobject][ordered]@{ candidates = @($candList); openAttempts = @($probe.tries); opened = [bool]($probe.openPath -ne ''); openPath = $probe.openPath; verdict = $probe.verdict; interfaceGuid = $ig }
        canary = [pscustomobject]$canary
        applied = [bool]$Apply
        limits = @(
            '默认（不加 -Apply）不发任何 IOCTL：只做文件指纹 + CreateFile 可打开性 + canary 计划。'
            'Engine 里 driver.ctl.verify 是 mutating=$false 的 verb，不会带 -Apply 进来；要真发 canary 需直接调用本函数并显式 -Apply。'
        )
    }
    $null = Write-LctPrfLog -Verb $verb -Level $(if ($proofLevel -eq 'handshake') { 'info' } else { 'warn' }) -Message ('canary 校验: ' + $found.id + ' proofLevel=' + $proofLevel) -Data ([ordered]@{ id = $found.id; proofLevel = $proofLevel; fpMatch = $fpMatch; verdict = $probe.verdict; canarySent = $canary.sent })
    return [pscustomobject]$data
}
#endregion

#region 导出 8：Save-LctDriverProfile（草案 → 审定 → 另存为 profile；默认只预览；只写 var\driver-profiles）
function Save-LctDriverProfile {
    param(
        [Parameter(Mandatory)][string]$Id,
        $Json = $null,
        [switch]$Override,
        [switch]$Apply
    )
    $verb = 'driver.profile.save'
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $changes = New-Object System.Collections.ArrayList
    $model = [ordered]@{
        id = ([string]$Id).Trim(); path = ''; source = 'user'; exists = $false; wouldOverwrite = $false; overwritten = $false
        validated = $null; bytes = 0; sha256 = ''; backup = ''; readBack = $null; preview = (-not $Apply); mode = $(if ($Apply) { 'apply' } else { 'preview' })
        notes = (New-Object System.Collections.ArrayList)
    }
    # ---- 1) Id 合法性（防路径穿越：'.' 在允许字符集里，所以必须显式拒绝 '..' 与分隔符）----
    $id = $model.id
    if ($id -eq '') {
        $null = $errors.Add('缺少 -Id（保存后的文件名与 profile.id 都取它）')
    } elseif ($id -notmatch '^[A-Za-z0-9._\-]{1,128}$') {
        $null = $errors.Add("Id '$id' 非法（只允许字母/数字/点/下划线/连字符，长度 1..128）")
    } elseif ($id -match '\.\.' -or $id.Contains('/') -or $id.Contains('\')) {
        $null = $errors.Add("Id '$id' 含路径穿越片段（.. / / / \）⇒ 拒绝：只能写 var\driver-profiles\<id>.json")
    }
    if (@($errors).Count -gt 0) {
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # ---- 2) 解析 profile（字符串或对象都接受；字符串走 BOM 容错）----
    $parsed = $null
    $jsonText = ''
    if ($Json -is [string]) {
        $rawIn = ([string]$Json).TrimStart([char]0xFEFF)
        if ($rawIn.Trim() -eq '') {
            $null = $errors.Add('缺少 profile JSON（-Json 为空）')
        } else {
            try { $parsed = ConvertTo-LctPrfPlain -Value ($rawIn | ConvertFrom-Json) } catch { $null = $errors.Add('JSON 解析失败: ' + $_.Exception.Message) }
        }
    } elseif ($null -eq $Json) {
        $null = $errors.Add('缺少 profile JSON（-Json 必须给字符串或对象）')
    } else {
        $parsed = ConvertTo-LctPrfPlain -Value $Json
    }
    if (@($errors).Count -eq 0 -and $null -eq $parsed) { $null = $errors.Add('profile JSON 解析后为空') }
    if (@($errors).Count -gt 0) {
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # ---- 3) schema 校验（不合法直接拒，且**不写盘**）----
    $sch = Test-LctPrfProfileSchema -Profile $parsed -ExpectedId $id
    $model.validated = [pscustomobject][ordered]@{ ok = [bool]$sch.ok; errors = @($sch.errors); warnings = @($sch.warnings); kind = [string]$sch.info.kind; engineApi = [int]$sch.info.engineApi; actionCount = [int]$sch.info.actionCount; riskLevel = [string]$sch.info.riskLevel }
    if (-not $sch.ok) {
        foreach ($e in @($sch.errors)) { $null = $errors.Add([string]$e) }
        $null = $errors.Add('schema 校验不通过 ⇒ 拒绝保存（落盘的 profile 必须能被 driver.profile.validate 直接校验）')
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('保存被拒(schema): ' + $id) -Data ([ordered]@{ id = $id; errors = @($sch.errors) })
        return New-LctResult -Verb $verb -Errors @($errors) -Data ([pscustomobject]$model)
    }
    foreach ($w in @($sch.warnings)) { $null = $warnings.Add([string]$w) }
    $jsonText = ConvertTo-LctPrfJson -Object $parsed -Depth 14
    $enc = New-Object System.Text.UTF8Encoding($false)
    $wantBytes = $enc.GetByteCount($jsonText)
    # ---- 4) 目标路径（只允许写用户来源目录）----
    $dir = Join-Path (Get-LctPrfVarBase) 'driver-profiles'
    $target = Join-Path $dir ($id + '.json')
    $model.path = $target
    $model.bytes = [int]$wantBytes
    $exists = $false
    try { $exists = [bool](Test-Path -LiteralPath $target -PathType Leaf) } catch { $exists = $false }
    $model.exists = $exists
    $model.wouldOverwrite = $exists
    # .sys 指纹提示（这里不做指纹门：执行时才拦；但要如实告诉操作者本机此刻比不了）
    $declared = New-Object System.Collections.ArrayList
    if ([string]$sch.info.sha256 -ne '') { $null = $declared.Add([string]$sch.info.sha256) }
    foreach ($x in @($sch.info.sha256AnyOf)) { $null = $declared.Add([string]$x) }
    if (@($declared).Count -gt 0) {
        $probe = Resolve-LctPrfSysPath -FileName ([string]$sch.info.fileName) -Sha256 ([string]$declared[0]) -ProfileDir $dir
        if (-not $probe.ok) {
            $null = $warnings.Add('已保存，但本机此刻定位不到 target.fileName 的 .sys ⇒ 指纹无法当场比对；执行前 driver.profile.validate / driver.ctl.send 会再拦一次。')
        }
    }
    # ---- 5) 预览：不落盘 ----
    if (-not $Apply) {
        $null = $changes.Add((New-LctPrfChange -Target $target -Name $id -Before $(if ($exists) { '(将被覆盖：预览未落盘)' } else { '(不存在)' }) -After ('将写入 ' + $wantBytes + ' 字节（UTF-8 无 BOM）') -Note '预览：未写盘；-Apply 才保存'))
        $null = $model.notes.Add('预览模式：只给出目标路径 / 校验结果 / 是否覆盖 / 将写入的字节数，**没有写盘**（契约：写类 verb 默认只预览）。')
        $null = Write-LctPrfLog -Verb $verb -Level 'info' -Message ('预览保存 profile: ' + $id) -Data ([ordered]@{ id = $id; path = $target; exists = $exists; bytes = $wantBytes; applied = $false })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Changes @($changes) -Data ([pscustomobject]$model)
    }
    # ---- 6) 覆盖保护 ----
    if ($exists -and -not $Override) {
        $null = $errors.Add('同名 profile 已存在: ' + $target + ' ⇒ 需显式 -Override 才覆盖（覆盖前会把原文件复制进 var\backups\）')
        $null = Write-LctPrfLog -Verb $verb -Level 'warn' -Message ('保存被拒(已存在): ' + $id) -Data ([ordered]@{ id = $id; path = $target })
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # ---- 7) 备份原文件（只复制，不删原文件）----
    $oldSha = ''
    if ($exists) {
        try {
            $oldSha = (Get-LctPrfSha256 -Path $target).ToLower()
            $bdir = Ensure-LctPrfDir -Path (Join-Path (Get-LctPrfVarBase) 'backups\driver-profiles')
            $bname = ($id + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            $bpath = Join-Path $bdir $bname
            [IO.File]::Copy($target, $bpath, $false)
            $newSha = (Get-LctPrfSha256 -Path $bpath).ToLower()
            if ($newSha -ne $oldSha) {
                $null = $errors.Add('备份校验失败：备份文件 ' + $bpath + ' 的 SHA256=' + $newSha + ' 与原文件 ' + $oldSha + ' 不一致 ⇒ 拒绝覆盖写入')
                $model.backup = $bpath
                return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
            }
            $model.backup = $bpath
            $null = $model.notes.Add('覆盖前已把原文件复制到备份: ' + $bpath + '（原文件未删、内容未改）')
        } catch {
            $null = $errors.Add('备份原文件失败 ⇒ 拒绝覆盖写入: ' + $_.Exception.Message)
            return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
        }
    }
    # ---- 8) 写盘（UTF-8 **不带 BOM**：JSON 是数据不是脚本）----
    try {
        $null = Ensure-LctPrfDir -Path $dir
        [IO.File]::WriteAllText($target, $jsonText, $enc)
    } catch {
        $null = $errors.Add('写盘失败: ' + $_.Exception.Message)
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    # ---- 9) 回读比对（逐字符 + 字节数 + 重新解析 + 重新跑 schema）----
    $rb = [ordered]@{ match = $false; textMatch = $false; bytes = 0; id = ''; schemaOk = $false; sha256 = ''; bomPresent = $false; error = '' }
    try {
        $b = [IO.File]::ReadAllBytes($target)
        $rb.bytes = $b.Length
        $rb.sha256 = (Get-LctPrfSha256 -Path $target).ToLower()
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $rb.bomPresent = $true }
        $readBack = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
        $rbBody = $readBack.TrimStart([char]0xFEFF)
        $rb.textMatch = ($rbBody -ceq $jsonText)
        $rbParsed = ConvertTo-LctPrfPlain -Value ($rbBody | ConvertFrom-Json)
        $rb.id = [string](Get-LctPrfProp -Bag $rbParsed -Name 'id' -Default '')
        $rbSch = Test-LctPrfProfileSchema -Profile $rbParsed -ExpectedId $id
        $rb.schemaOk = [bool]$rbSch.ok
        $rb.match = ([bool]$rb.textMatch -and $rb.bytes -eq [int]$wantBytes -and $rb.id -eq $id -and [bool]$rb.schemaOk -and -not $rb.bomPresent)
    } catch { $rb.error = '回读失败: ' + $_.Exception.Message }
    $model.sha256 = [string]$rb.sha256
    $model.readBack = [pscustomobject]$rb
    if (-not $rb.match) {
        $null = $errors.Add('回读比对不一致 ⇒ 不报成功（textMatch=' + $rb.textMatch + ' bytes=' + $rb.bytes + '/' + $wantBytes + ' id=' + $rb.id + ' schemaOk=' + $rb.schemaOk + ' bom=' + $rb.bomPresent + ' ' + $rb.error + '）')
        $null = Write-LctPrfLog -Verb $verb -Level 'error' -Message ('保存回读不一致: ' + $id) -Data ([pscustomobject]$rb)
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject]$model)
    }
    $model.overwritten = $exists
    $null = $changes.Add((New-LctPrfChange -Target $target -Name $id -Before $(if ($exists) { $oldSha } else { '(不存在)' }) -After ([string]$rb.sha256) -Note $(if ($exists) { '覆盖保存（原文件已备份，未删除）' } else { '新建保存（UTF-8 无 BOM）' })))
    $null = $model.notes.Add('已保存到用户来源目录 var\driver-profiles（内置来源 core\driver-profiles 不会被本 verb 写入）。')
    $null = Write-LctPrfLog -Verb $verb -Level 'change' -Message ('保存 profile: ' + $id) -Data ([ordered]@{ id = $id; path = $target; bytes = [int]$rb.bytes; sha256 = $rb.sha256; overwritten = $exists; backup = $model.backup; validated = $sch.ok })
    return New-LctResult -Verb $verb -Applied -Warnings @($warnings) -Changes @($changes) -Data ([pscustomobject]$model)
}
#endregion

# ---------------------------------------------------------------------
# 内核基址（给 payload 里的 @ntoskrnl 用；也让"我自己查地址"这一步消失）
# ---------------------------------------------------------------------
$script:LctKbNativeLoaded = $false

function Ensure-LctKbNative {
    if ($script:LctKbNativeLoaded) { return }
    $code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LctKbNative {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EnumDeviceDrivers(IntPtr[] lpImageBase, uint cb, out uint lpcbNeeded);
    [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetDeviceDriverFileName(IntPtr lpImageBase, StringBuilder lpFilename, int nSize);
    [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetDeviceDriverBaseName(IntPtr lpImageBase, StringBuilder lpBaseName, int nSize);
}
"@
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    $script:LctKbNativeLoaded = $true
}

function Get-LctKernelBaseAddress {
    # 取内核镜像（ntoskrnl/ntkrnlmp）加载基址；只读。非管理员时系统不会给出基址，这里如实报错。
    param([int]$Max = 1024)
    $out = [ordered]@{ ok = $false; address = 0; name = ''; path = ''; error = ''; count = 0 }
    try { Ensure-LctKbNative } catch { $out.error = '加载 psapi 失败：' + $_.Exception.Message; return [pscustomobject]$out }
    try {
        $arr = New-Object IntPtr[] $Max
        $needed = [uint32]0
        $okCall = [LctKbNative]::EnumDeviceDrivers($arr, [uint32]($Max * [IntPtr]::Size), [ref]$needed)
        if (-not $okCall) {
            $out.error = 'EnumDeviceDrivers 失败（非管理员时常见）：' + (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())).Message
            return [pscustomobject]$out
        }
        $n = [int]($needed / [IntPtr]::Size)
        if ($n -gt $Max) { $n = $Max }
        $out.count = $n
        $pick = $null
        for ($i = 0; $i -lt $n; $i++) {
            $base = $arr[$i]
            if ($base -eq [IntPtr]::Zero) { continue }
            $sbName = New-Object Text.StringBuilder 512
            $lenName = [LctKbNative]::GetDeviceDriverBaseName($base, $sbName, 512)
            $nm = ''
            if ($lenName -gt 0) { $nm = $sbName.ToString() }
            $addr = [int64]$base.ToInt64()
            if ($null -eq $pick -and $nm -match '^(ntoskrnl|ntkrnlmp|ntkrnlpa|ntoskrnl\.exe)$') {
                $sbPath = New-Object Text.StringBuilder 1024
                $lenPath = [LctKbNative]::GetDeviceDriverFileName($base, $sbPath, 1024)
                $pth = ''
                if ($lenPath -gt 0) { $pth = $sbPath.ToString() }
                $pick = [pscustomobject][ordered]@{ name = $nm; address = $addr; path = $pth }
            }
        }
        if ($null -ne $pick -and [int64]$pick.address -ne 0) {
            $out.ok = $true
            $out.address = [int64]$pick.address
            $out.name = [string]$pick.name
            $out.path = [string]$pick.path
        } else {
            $out.error = '没有枚举到内核镜像的基址（未提权时系统会隐藏基址）：请以管理员运行，或显式给出地址'
        }
    } catch { $out.error = '异常：' + $_.Exception.Message }
    return [pscustomobject]$out
}

Export-ModuleMember -Function Get-LctDriverProfileList, Get-LctDriverProfileShow, Test-LctDriverProfile,
    New-LctDriverProfileDraft, Get-LctDriverDevices, Invoke-LctDriverCtl, Get-LctDriverCtlVerify,
    Save-LctDriverProfile, Get-LctKernelBaseAddress