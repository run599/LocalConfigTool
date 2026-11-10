# =====================================================================
# LocalConfigTool - Registry.psm1
# 职责：通用注册表 读 / 写 / 删 / 快照（前端只经 Engine CLI 调用，本模块不弹窗、不交互）
# 作者：task-1 (backend-accounts)
# 契约：docs\CONTRACT.md §3 Result / §4 公共函数 / §5 verb / §7 铁律 / §8 编码
# 导出：Get-LctRegistryValue / Set-LctRegistryValue / Remove-LctRegistryValue / Get-LctRegistrySnapshot
# 铁律：
#   1) 写操作默认只预览（返回 changes 但不落盘），只有传 -Apply 才真正写；
#   2) 真实写入前必须先 New-LctBackup，并把 backupId 填进 Result；
#   3) 写入失败必须用 before 值回滚，ok=false 并在 errors 说明；
#   4) 禁止 Remove-Item：值删除用 .NET DeleteValue，键树删除用 Remove-LctRegistryKeyTree。
# 兼容：Windows PowerShell 5.1；不使用 Set-StrictMode；不依赖第三方模块。
# =====================================================================

#region 依赖守卫（契约 §10.3 / §10.4）
# 规则：跨模块导入一律带 -Global；可用性以「模块是否装载成功」为准，**不用 Get-Command 探测**（§10.4 实测会误报）。
# 原因：模块作用域里不带 -Global 的 `Import-Module -Force` 会把已全局加载的同名模块「抢」进本模块作用域，
#       导致全局注册被撤掉（New-LctResult / Remove-LctRegistryKeyTree 等集体消失）。
$script:LctLoggingModule = Join-Path $PSScriptRoot 'Logging.psm1'
$script:LctBackupModule = Join-Path $PSScriptRoot 'Backup.psm1'
$script:LctLoaded = @{ Logging = $false; Backup = $false }
if (-not (Get-Module -Name Logging)) {
    Import-Module $script:LctLoggingModule -Force -Global -ErrorAction Stop
}
$script:LctLoaded.Logging = [bool](Get-Module -Name Logging)
if (-not (Get-Module -Name Backup)) {
    Import-Module $script:LctBackupModule -Force -Global -ErrorAction Stop
    # Backup 装载时可能重导 Logging：再确认一次全局可用（只补一次，不递归）
    if (-not (Get-Module -Name Logging)) {
        Import-Module $script:LctLoggingModule -Force -Global -ErrorAction Stop
    }
}
$script:LctLoaded.Backup = [bool](Get-Module -Name Backup)
#endregion

#region 私有辅助
function New-LctChangeEntry {
    param(
        [string]$Kind = 'registry',
        [string]$Target = '',
        [string]$Name = '',
        [string]$Before = '',
        [string]$After = '',
        [string]$Note = ''
    )
    return [pscustomobject][ordered]@{
        kind = $Kind; target = $Target; name = $Name; before = $Before; after = $After; note = $Note
    }
}

function Write-LctQuiet {
    # 日志失败不应影响能力模块主流程；返回值是日志文件路径（可能为空串）
    param([string]$Verb = 'engine', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}

function Get-LctArgFrom {
    # 兼容引擎把 Args 作为对象/hashtable 整体传入
    param([Alias('Args')][object]$ArgBag = $null, [string]$Key, $Default = $null)
    if ($null -eq $ArgBag) { return $Default }
    if ($ArgBag -is [System.Collections.IDictionary]) {
        foreach ($k in @($ArgBag.Keys)) { if ([string]$k -ieq $Key) { return $ArgBag[$k] } }
        return $Default
    }
    try {
        foreach ($p in @($ArgBag.PSObject.Properties)) { if ([string]$p.Name -ieq $Key) { return $p.Value } }
    } catch { }
    return $Default
}

function ConvertTo-LctBool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [ValueType] -and ($Value -isnot [bool]) -and ($Value -isnot [datetime])) {
        try { return ([double]$Value -ne 0) } catch { return $Default }
    }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (@('1', 'true', 'yes', 'on', 'y', '是', '开', '启用') -contains $s) { return $true }
    if (@('0', 'false', 'no', 'off', 'n', '否', '关', '禁用', '') -contains $s) { return $false }
    return $Default
}

function ConvertTo-LctRegLocation {
    # 只支持 HKCU / HKLM（与 Logging.psm1 的 Remove-LctRegistryKeyTree 保持一致）
    param([string]$Path)
    $m = [regex]::Match([string]$Path, '^\s*(HKCU|HKEY_CURRENT_USER|HKLM|HKEY_LOCAL_MACHINE)\s*[\\:]\s*(.*)$')
    if (-not $m.Success) { throw "不支持的注册表路径（只支持 HKCU:/HKLM:）: $Path" }
    $h = $m.Groups[1].Value.ToUpperInvariant()
    $sub = $m.Groups[2].Value -replace '/', '\'
    $sub = $sub -replace '^\\+', ''
    $sub = $sub -replace '\\+$', ''
    if ([string]::IsNullOrEmpty($sub)) { throw "拒绝操作配置单元根: $Path" }
    if ($h -eq 'HKCU' -or $h -eq 'HKEY_CURRENT_USER') {
        $hive = [Microsoft.Win32.Registry]::CurrentUser; $hn = 'HKCU'
    } else {
        $hive = [Microsoft.Win32.Registry]::LocalMachine; $hn = 'HKLM'
    }
    return [pscustomobject][ordered]@{
        hive = $hive; hiveName = $hn; subKey = $sub; normalized = ($hn + ':\' + $sub)
    }
}

function ConvertTo-LctRegKind {
    param([string]$Type)
    $t = [string]$Type
    if ([string]::IsNullOrWhiteSpace($t)) { $t = 'String' }
    switch ($t.Trim().ToLowerInvariant()) {
        'string'       { return [Microsoft.Win32.RegistryValueKind]::String }
        'sz'           { return [Microsoft.Win32.RegistryValueKind]::String }
        'expandstring' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'expand'       { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        'dword'        { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'int'          { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'int32'        { return [Microsoft.Win32.RegistryValueKind]::DWord }
        'qword'        { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'int64'        { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'long'         { return [Microsoft.Win32.RegistryValueKind]::QWord }
        'multistring'  { return [Microsoft.Win32.RegistryValueKind]::MultiString }
        'binary'       { return [Microsoft.Win32.RegistryValueKind]::Binary }
        'byte[]'       { return [Microsoft.Win32.RegistryValueKind]::Binary }
        default        { throw "不支持的注册表值类型: $Type（可选 String|ExpandString|DWord|QWord|MultiString|Binary）" }
    }
}

function ConvertFrom-LctRegInput {
    # 把 JSON 传进来的标量/数组/十六进制串 归一化成注册表能写的 .NET 值
    param($Value, [Microsoft.Win32.RegistryValueKind]$Kind, [string]$TypeLabel = '')
    $k = [string]$Kind
    switch ($k) {
        'DWord' {
            $l = 0
            try { $l = ConvertTo-LctInt64 -Value $Value } catch { throw "DWord 的值必须是整数: $Value" }
            if ($l -lt -2147483648 -or $l -gt 4294967295) { throw "DWord 超出 32 位范围: $Value" }
            if ($l -gt 2147483647) { $l = $l - 4294967296 }
            return [int]$l
        }
        'QWord' {
            $l = 0
            try { $l = ConvertTo-LctInt64 -Value $Value } catch { throw "QWord 的值必须是整数: $Value" }
            return [int64]$l
        }
        'MultiString' {
            # 关键：函数返回数组会被 PowerShell 拆包成 object[]{...}，SetValue 就不认了；
            # 一元逗号包一层可保住 string[] 类型（调用侧还会再压一次，双保险）。
            if ($null -eq $Value) { return , ([string[]]@()) }
            if ($Value -is [array]) { return , ([string[]]@($Value | ForEach-Object { [string]$_ })) }
            return , ([string[]]@([string]$Value))
        }
        'Binary' {
            if ($null -eq $Value) { return , (New-Object byte[] 0) }
            if ($Value -is [byte[]]) { return , $Value }
            if ($Value -is [array]) {
                $arr = @($Value)
                $b = New-Object byte[] $arr.Count
                for ($i = 0; $i -lt $arr.Count; $i++) {
                    try { $b[$i] = [byte](ConvertTo-LctInt64 -Value $arr[$i]) } catch { throw "Binary 第 $i 个字节非法: $($arr[$i])" }
                }
                return , $b
            }
            $s = ([string]$Value) -replace '[^0-9A-Fa-f]', ''
            if ([string]::IsNullOrEmpty($s)) { return , (New-Object byte[] 0) }
            if ($s.Length % 2 -ne 0) { throw "Binary 十六进制串长度必须是偶数: $Value" }
            $b = New-Object byte[] ($s.Length / 2)
            for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($s.Substring($i * 2, 2), 16) }
            return , $b
        }
        default {
            if ($null -eq $Value) { return '' }
            return [string]$Value
        }
    }
}

function ConvertTo-LctInt64 {
    param($Value)
    if ($Value -is [ValueType] -and ($Value -isnot [bool])) { return [int64]$Value }
    $s = ([string]$Value).Trim()
    if ($s -match '^[+-]?0[xX]') { return [Convert]::ToInt64($s, 16) }
    return [int64]$s
}

function ConvertTo-LctRegDisplay {
    # changes 里的 before/after 用可读字符串（二进制转十六进制，多字符串用 ';' 连接）
    param($Value, [string]$TypeLabel = '')
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('x2') }) -join ' ') }
    if ($Value -is [array]) { return (@($Value | ForEach-Object { [string]$_ }) -join ';') }
    return [string]$Value
}

function Compare-LctRegValue {
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A -is [byte[]] -and $B -is [byte[]]) {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
        return $true
    }
    if ($A -is [array] -or $B -is [array]) {
        $aa = @($A); $bb = @($B)
        if ($aa.Count -ne $bb.Count) { return $false }
        for ($i = 0; $i -lt $aa.Count; $i++) { if ([string]$aa[$i] -cne [string]$bb[$i]) { return $false } }
        return $true
    }
    return ($A -eq $B)
}

function New-LctRegMissing {
    param([string]$Name = '')
    return [pscustomobject][ordered]@{
        exists = $false; name = $Name
        kind = [Microsoft.Win32.RegistryValueKind]::Unknown; type = ''; value = $null
    }
}

function Test-LctRegKeyExists {
    param($Loc)
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $false) } catch { $k = $null }
    if ($null -eq $k) { return $false }
    $k.Close()
    return $true
}

function Get-LctRegRawValue {
    param($Loc, [string]$Name = '')
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $false) } catch { $k = $null }
    if ($null -eq $k) { return (New-LctRegMissing -Name $Name) }
    try {
        $shownName = $Name
        $exists = $false
        if ([string]::IsNullOrEmpty($Name)) {
            $v0 = $null
            try { $v0 = $k.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $v0 = $null }
            if ($null -ne $v0) { $exists = $true }
        } else {
            foreach ($n in @($k.GetValueNames())) {
                if ([string]$n -ieq $Name) { $exists = $true; $shownName = [string]$n; break }
            }
        }
        if (-not $exists) { return (New-LctRegMissing -Name $shownName) }
        $kind = [Microsoft.Win32.RegistryValueKind]::Unknown
        try { $kind = $k.GetValueKind($shownName) } catch { }
        $val = $k.GetValue($shownName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject][ordered]@{
            exists = $true; name = $shownName; kind = $kind; type = [string]$kind; value = $val
        }
    } finally {
        if ($null -ne $k) { $k.Close() }
    }
}

function Set-LctRegRawValue {
    param($Loc, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    $k = $null
    try { $k = $Loc.hive.CreateSubKey($Loc.subKey) }
    catch { throw "无法创建/打开注册表键 $($Loc.normalized)：$($_.Exception.Message)" }
    if ($null -eq $k) { throw "无法创建/打开注册表键 $($Loc.normalized)" }
    try { $k.SetValue($Name, $Value, $Kind) } finally { $k.Close() }
}

function Remove-LctRegRawValue {
    param($Loc, [string]$Name = '')
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $true) } catch { $k = $null }
    if ($null -eq $k) { return $false }
    try {
        $k.DeleteValue($Name, $false)
        return $true
    } finally { $k.Close() }
}
#endregion

#region 导出函数

function Get-LctRegistryValue {
    <#
    .SYNOPSIS registry.get：读单个注册表值。
    .DESCRIPTION Name 省略时读该键的默认值；键或值不存在时 ok=false。
    #>
    param(
        [string]$Path = '',
        [string]$Name = '',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply   # 读操作忽略（引擎可能统一传 -Apply）
    )
    $verb = 'registry.get'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        if ([string]::IsNullOrEmpty($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 path 参数')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.get 缺少 path 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }

    $loc = $null
    try { $loc = ConvertTo-LctRegLocation -Path $Path }
    catch {
        $null = $errors.Add($_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.get 路径非法' -Data @{ path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }

    $keyExists = Test-LctRegKeyExists -Loc $loc
    $v = Get-LctRegRawValue -Loc $loc -Name $Name
    $data = [pscustomobject][ordered]@{
        path = $loc.normalized; name = $Name; type = $v.type; value = $v.value; exists = $v.exists
    }
    if (-not $v.exists) {
        if (-not $keyExists) { $null = $errors.Add("注册表键不存在: $($loc.normalized)") }
        else { $null = $errors.Add("注册表值不存在: $($loc.normalized)::$Name") }
    }
    $log = Write-LctQuiet -Verb $verb -Level info -Message "读取 $($loc.normalized)::$Name" -Data @{ exists = $v.exists; type = $v.type }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

function Set-LctRegistryValue {
    <#
    .SYNOPSIS registry.set：写单个注册表值（默认预览，-Apply 才落盘）。
    .DESCRIPTION 落盘前必先 New-LctBackup；写入后校验，失败用 before 回滚。
    #>
    param(
        [string]$Path = '',
        [string]$Name = '',
        $Value = $null,
        [string]$Type = 'String',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'registry.set'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $data = $null

    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        if ([string]::IsNullOrEmpty($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
        if ($null -eq $Value) { $Value = Get-LctArgFrom -Args $ArgBag -Key 'value' }
        $t = Get-LctArgFrom -Args $ArgBag -Key 'type' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$t)) { $Type = [string]$t }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 path 参数：registry.set 需要 path / name / value / type')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.set 缺少 path 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $loc = $null
    try { $loc = ConvertTo-LctRegLocation -Path $Path }
    catch {
        $null = $errors.Add($_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.set 路径非法' -Data @{ path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $kind = $null
    try { $kind = ConvertTo-LctRegKind -Type $Type }
    catch {
        $null = $errors.Add($_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.set 值类型非法' -Data @{ type = $Type }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    $kindName = [string]$kind

    $v = $null
    try {
        $v = ConvertFrom-LctRegInput -Value $Value -Kind $kind -TypeLabel $kindName
        # 双保险：即使返回值被拆包，这里也按类型压回注册表 API 需要的 .NET 类型
        if ($kindName -eq 'MultiString') { $v = [string[]]@($v) }
        elseif ($kindName -eq 'Binary') { $v = [byte[]]@($v) }
    }
    catch {
        $null = $errors.Add($_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.set 值非法' -Data @{ type = $kindName }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $keyExisted = Test-LctRegKeyExists -Loc $loc
    $before = Get-LctRegRawValue -Loc $loc -Name $Name
    $beforeText = '(不存在)'
    if ($before.exists) { $beforeText = ConvertTo-LctRegDisplay -Value $before.value -TypeLabel $before.type }
    $afterText = ConvertTo-LctRegDisplay -Value $v -TypeLabel $kindName

    $isSame = ($before.exists -and $before.kind -eq $kind -and (Compare-LctRegValue -A $before.value -B $v))
    $note = ''
    if ($isSame) { $note = '无变化（值已一致，重复应用安全）' }
    elseif (-not $keyExisted) { $note = '将新建键' }

    $null = $changes.Add((New-LctChangeEntry -Kind 'registry' -Target $loc.normalized -Name $Name `
        -Before $beforeText -After $afterText -Note $note))

    $data = [pscustomobject][ordered]@{ path = $loc.normalized; name = $Name; type = $kindName; value = $v }

    if (-not $Apply) {
        if ($loc.hiveName -eq 'HKLM' -and -not (Test-LctElevated)) {
            $null = $warnings.Add('当前进程未以管理员身份运行：应用该 HKLM 变更会因权限不足失败。')
        }
        $log = Write-LctQuiet -Verb $verb -Level change -Message "预览 registry.set $($loc.normalized)::$Name" `
            -Data @{ path = $loc.normalized; name = $Name; type = $kindName; before = $beforeText; after = $afterText }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    # ---- 先备份（契约 §7.2）----
    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ path = $loc.normalized; name = $Name; type = $kindName }) `
            -RegistryPaths @($loc.normalized)
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add("创建备份失败，已取消写入: $($_.Exception.Message)")
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.set 备份失败，未写入' -Data @{ path = $loc.normalized; name = $Name }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    # ---- 写入 + 校验 + 回滚 ----
    try {
        Set-LctRegRawValue -Loc $loc -Name $Name -Value $v -Kind $kind
        $chk = Get-LctRegRawValue -Loc $loc -Name $Name
        if (-not ($chk.exists -and $chk.kind -eq $kind -and (Compare-LctRegValue -A $chk.value -B $v))) {
            throw "写入后校验不一致（期望 $kindName = $afterText）"
        }
    } catch {
        $werr = $_.Exception.Message
        $null = $errors.Add("写入失败: $werr")
        try {
            if ($before.exists) {
                Set-LctRegRawValue -Loc $loc -Name $Name -Value $before.value -Kind $before.kind
                $null = $warnings.Add("已用 before 值回滚 $($loc.normalized)::$Name")
            } else {
                if ($keyExisted) { $null = Remove-LctRegRawValue -Loc $loc -Name $Name }
                else {
                    $null = Remove-LctRegistryKeyTree -Path $loc.normalized
                    if (Test-LctRegKeyExists -Loc $loc) {
                        $null = $errors.Add("回滚未完成：本次新建的键仍存在 $($loc.normalized)")
                    }
                }
                $null = $warnings.Add('已回滚（移除本次新增的值 / 键）')
            }
        } catch {
            $null = $errors.Add("回滚失败: $($_.Exception.Message)")
        }
    }

    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message "已应用 registry.set $($loc.normalized)::$Name" `
        -Data @{ path = $loc.normalized; name = $Name; type = $kindName; before = $beforeText; after = $afterText; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -BackupId $backupId -Data $data -Log $log
}

function Remove-LctRegistryValue {
    <#
    .SYNOPSIS registry.delete：删除注册表值；Name 为空时删除整个子键树。
    .DESCRIPTION 禁止 Remove-Item：值走 .NET DeleteValue，键树走 Remove-LctRegistryKeyTree。
    #>
    param(
        [string]$Path = '',
        [string]$Name = '',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'registry.delete'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $data = $null

    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        if ([string]::IsNullOrEmpty($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 path 参数：registry.delete 需要 path / name')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.delete 缺少 path 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $loc = $null
    try { $loc = ConvertTo-LctRegLocation -Path $Path }
    catch {
        $null = $errors.Add($_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.delete 路径非法' -Data @{ path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $keyExists = Test-LctRegKeyExists -Loc $loc
    $removeWholeKey = [string]::IsNullOrEmpty($Name)
    $before = Get-LctRegRawValue -Loc $loc -Name $Name
    $removed = $false

    if ($removeWholeKey) {
        $data = [pscustomobject][ordered]@{ path = $loc.normalized; name = ''; removed = $false }
        if (-not $keyExists) {
            $null = $changes.Add((New-LctChangeEntry -Kind 'registry' -Target $loc.normalized -Name '<key>' `
                -Before '(不存在)' -After '(不变)' -Note '无变化'))
        } else {
            $null = $changes.Add((New-LctChangeEntry -Kind 'registry' -Target $loc.normalized -Name '<key>' `
                -Before '(存在)' -After '(删除整棵子键)' -Note 'Remove-LctRegistryKeyTree'))
        }
    } else {
        $data = [pscustomobject][ordered]@{ path = $loc.normalized; name = $Name; removed = $false }
        $beforeText = '(不存在)'
        if ($before.exists) { $beforeText = ConvertTo-LctRegDisplay -Value $before.value -TypeLabel $before.type }
        $null = $changes.Add((New-LctChangeEntry -Kind 'registry' -Target $loc.normalized -Name $Name `
            -Before $beforeText -After '(已删除)' -Note $(if ($before.exists) { '' } else { '无变化（值本不存在）' })))
    }

    if (-not $Apply) {
        if ($loc.hiveName -eq 'HKLM' -and -not (Test-LctElevated)) {
            $null = $warnings.Add('当前进程未以管理员身份运行：应用该 HKLM 变更会因权限不足失败。')
        }
        $log = Write-LctQuiet -Verb $verb -Level change -Message "预览 registry.delete $($loc.normalized)::$Name"
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    if ($removeWholeKey) {
        if (-not $keyExists) {
            $log = Write-LctQuiet -Verb $verb -Level change -Message "registry.delete 无变化 $($loc.normalized)"
            return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
        }
        $bk = $null
        try {
            $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ path = $loc.normalized; name = '<key>' }) -RegistryPaths @($loc.normalized)
            $backupId = [string]$bk.id
        } catch {
            $null = $errors.Add("创建备份失败，已取消删除: $($_.Exception.Message)")
            $data.removed = $false
            $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.delete 备份失败，未删除' -Data @{ path = $loc.normalized }
            return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
        }
        try {
            $null = Remove-LctRegistryKeyTree -Path $loc.normalized
            # 复核：契约要求「注册表键删除只用 Remove-LctRegistryKeyTree」，故这里只验证不替代删除；
            # 删除没生效时如实报错，不做「假成功」（曾出现前导反斜杠导致的静默失败）。
            if (Test-LctRegKeyExists -Loc $loc) {
                throw "Remove-LctRegistryKeyTree 执行后该键仍存在（删除未生效）: $($loc.normalized)"
            }
            $removed = $true
        } catch {
            $null = $errors.Add("删除子键失败: $($_.Exception.Message)")
            # 回滚：把导出内容重新导入
            $regFile = @($bk.files | Where-Object { $_ -like '*.reg' } | Select-Object -First 1)
            if ($regFile.Count -gt 0) {
                # 注意：$ErrorActionPreference='Stop' 时 native 的 stderr+2>&1 会变成 NativeCommandError 终止错误，
                # 这里临时降级为 Continue 并在 finally 恢复（同 Lead 在 Backup.psm1 里的 Invoke-LctRegExe 写法）。
                $prevEap = $ErrorActionPreference
                $rc = -1
                try {
                    $ErrorActionPreference = 'Continue'
                    $null = & reg.exe import $regFile[0] 2>&1
                    $rc = $LASTEXITCODE
                } catch {
                    $rc = -1
                } finally {
                    $ErrorActionPreference = $prevEap
                }
                if ($rc -eq 0) { $null = $warnings.Add('已用备份 .reg 回滚该键') }
                else { $null = $errors.Add("回滚导入失败(rc=$rc): $($regFile[0])") }
            }
        }
    } else {
        if (-not $before.exists) {
            $log = Write-LctQuiet -Verb $verb -Level change -Message "registry.delete 无变化 $($loc.normalized)::$Name"
            return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
        }
        $bk = $null
        try {
            $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ path = $loc.normalized; name = $Name }) -RegistryPaths @($loc.normalized)
            $backupId = [string]$bk.id
        } catch {
            $null = $errors.Add("创建备份失败，已取消删除: $($_.Exception.Message)")
            $log = Write-LctQuiet -Verb $verb -Level error -Message 'registry.delete 备份失败，未删除' -Data @{ path = $loc.normalized; name = $Name }
            return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
        }
        try {
            $removed = [bool](Remove-LctRegRawValue -Loc $loc -Name $before.name)
            if ($removed) {
                $chk = Get-LctRegRawValue -Loc $loc -Name $Name
                if ($chk.exists) { throw '删除后校验仍然存在' }
            }
        } catch {
            $werr = $_.Exception.Message
            $null = $errors.Add("删除失败: $werr")
            try {
                Set-LctRegRawValue -Loc $loc -Name $before.name -Value $before.value -Kind $before.kind
                $null = $warnings.Add("已用 before 值回滚 $($loc.normalized)::$($before.name)")
            } catch { $null = $errors.Add("回滚失败: $($_.Exception.Message)") }
        }
    }

    $data.removed = $removed
    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message "已应用 registry.delete $($loc.normalized)::$Name" `
        -Data @{ path = $loc.normalized; name = $Name; removed = $removed; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
        -BackupId $backupId -Data $data -Log $log
}

function Get-LctRegistrySnapshot {
    <#
    .SYNOPSIS 采集若干注册表键的全部值，返回普通快照对象（供备份 / 原子回滚 / 差异比对使用）。
    .DESCRIPTION 注意：本函数不是 verb，返回的是快照对象本身（不是 Result）：
                 @{ capturedAt; keys = @(@{ path; exists; values = @(@{ name; type; value }) }) ; errors }
                 路径只支持 HKCU: / HKLM:。
    #>
    param(
        [string[]]$Paths = @(),
        [string]$Path = '',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply   # 读操作忽略
    )
    $keys = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    $all = New-Object System.Collections.ArrayList
    foreach ($p in @($Paths)) { if (-not [string]::IsNullOrWhiteSpace($p)) { $null = $all.Add([string]$p) } }
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $null = $all.Add([string]$Path) }
    if ($null -ne $ArgBag) {
        foreach ($p in @(Get-LctArgFrom -Args $ArgBag -Key 'paths' -Default @())) {
            if (-not [string]::IsNullOrWhiteSpace($p)) { $null = $all.Add([string]$p) }
        }
        $p1 = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($p1)) { $null = $all.Add($p1) }
    }

    foreach ($p in @($all)) {
        try {
            $loc = ConvertTo-LctRegLocation -Path $p
            $k = $loc.hive.OpenSubKey($loc.subKey, $false)
            if ($null -eq $k) {
                $null = $keys.Add([pscustomobject][ordered]@{ path = $loc.normalized; exists = $false; values = @() })
                continue
            }
            $vals = New-Object System.Collections.ArrayList
            try {
                $hasDefault = $false
                $dv = $null
                try { $dv = $k.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $dv = $null }
                if ($null -ne $dv) {
                    $hasDefault = $true
                    $dk = [Microsoft.Win32.RegistryValueKind]::Unknown
                    try { $dk = $k.GetValueKind('') } catch { }
                    $null = $vals.Add([pscustomobject][ordered]@{ name = ''; type = [string]$dk; value = $dv })
                }
                foreach ($n in @($k.GetValueNames())) {
                    $nk = [Microsoft.Win32.RegistryValueKind]::Unknown
                    try { $nk = $k.GetValueKind($n) } catch { }
                    $nv = $null
                    try { $nv = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $nv = $null }
                    $null = $vals.Add([pscustomobject][ordered]@{ name = [string]$n; type = [string]$nk; value = $nv })
                }
            } finally { $k.Close() }
            $null = $keys.Add([pscustomobject][ordered]@{ path = $loc.normalized; exists = $true; values = @($vals) })
        } catch {
            $null = $errors.Add("快照失败 $p : $($_.Exception.Message)")
        }
    }

    return [pscustomobject][ordered]@{
        capturedAt = (Get-Date).ToString('s')
        keys       = @($keys)
        errors     = @($errors)
    }
}

#endregion

Export-ModuleMember -Function Get-LctRegistryValue, Set-LctRegistryValue, Remove-LctRegistryValue, Get-LctRegistrySnapshot