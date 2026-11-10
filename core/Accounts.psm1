# =====================================================================
# LocalConfigTool - Accounts.psm1
# 职责：账户 / UAC / 自动登录 的读取、预览与（-Apply 后）写入
# 作者：task-1 (backend-accounts)
# 契约：docs\CONTRACT.md §3 Result / §4 公共函数 / §5 verb / §6 account.status 形状 / §7 铁律
# 导出：Get-LctAccountStatus / Set-LctAdminAccount / Set-LctUac / Set-LctAutologon / Restore-LctAccountState
# 铁律：
#   1) 写操作默认只预览（返回 changes 不落盘），只有 -Apply 才写；
#   2) 真实写入前必须先 New-LctBackup，并把 backupId 填进 Result；
#   3) 一次写多值的用 Invoke-LctRegBatch：任一失败按 before 逆序回滚，ok=false 且 errors 说明；
#   4) 自动登录口令只从 passwordFile 读，绝不接受命令行明文，绝不写入 日志 / 备份 meta / Result（备份只记 hasPassword）；
#   5) 只动：内置 Administrator 的 Enabled、UAC 四项、Winlogon 自动登录四项；不碰其它类别；
#   6) 禁止 Remove-Item；注册表键树删除只用 Remove-LctRegistryKeyTree。
# 说明：本模块自带一份「.NET 注册表原语」（Get/Set/Remove-LctRegRawValue 等），刻意不依赖
#       Registry.psm1 的私有函数，避免 import 顺序耦合与额外导出面。
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

#region 常量（契约 §6 指定的两个键）
$script:LctUacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:LctWinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$script:LctUacNames = @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'PromptOnSecureDesktop', 'EnableInstallerDetection')
#endregion

#region 私有辅助：通用
function New-LctChangeEntry {
    param([string]$Kind = 'account', [string]$Target = '', [string]$Name = '', [string]$Before = '', [string]$After = '', [string]$Note = '')
    return [pscustomobject][ordered]@{ kind = $Kind; target = $Target; name = $Name; before = $Before; after = $After; note = $Note }
}

function Write-LctQuiet {
    param([string]$Verb = 'engine', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}

function Get-LctArgFrom {
    param([Alias('Args')][object]$ArgBag = $null, [string]$Key, $Default = $null)
    if ($null -eq $ArgBag) { return $Default }
    if ($ArgBag -is [System.Collections.IDictionary]) {
        foreach ($k in @($ArgBag.Keys)) { if ([string]$k -ieq $Key) { return $ArgBag[$k] } }
        return $Default
    }
    try { foreach ($p in @($ArgBag.PSObject.Properties)) { if ([string]$p.Name -ieq $Key) { return $p.Value } } } catch { }
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

function ConvertTo-LctInt64 {
    param($Value)
    if ($Value -is [ValueType] -and ($Value -isnot [bool])) { return [int64]$Value }
    $s = ([string]$Value).Trim()
    if ($s -match '^[+-]?0[xX]') { return [Convert]::ToInt64($s, 16) }
    return [int64]$s
}

function Get-LctToolIsElevated {
    try { return [bool](Test-LctElevated) } catch { return $false }
}
#endregion

#region 私有辅助：.NET 注册表原语（只支持 HKCU: / HKLM:）
function ConvertTo-LctRegLocation {
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
    return [pscustomobject][ordered]@{ hive = $hive; hiveName = $hn; subKey = $sub; normalized = ($hn + ':\' + $sub) }
}

function New-LctRegMissing {
    param([string]$Name = '')
    return [pscustomobject][ordered]@{
        exists = $false; name = $Name; type = ''; value = $null; kind = [Microsoft.Win32.RegistryValueKind]::Unknown
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
        $shown = $Name
        $exists = $false
        if ([string]::IsNullOrEmpty($Name)) {
            $v0 = $null
            try { $v0 = $k.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $v0 = $null }
            if ($null -ne $v0) { $exists = $true }
        } else {
            foreach ($n in @($k.GetValueNames())) { if ([string]$n -ieq $Name) { $exists = $true; $shown = [string]$n; break } }
        }
        if (-not $exists) { return (New-LctRegMissing -Name $shown) }
        $kind = [Microsoft.Win32.RegistryValueKind]::Unknown
        try { $kind = $k.GetValueKind($shown) } catch { }
        $val = $k.GetValue($shown, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return [pscustomobject][ordered]@{ exists = $true; name = $shown; kind = $kind; type = [string]$kind; value = $val }
    } finally {
        if ($null -ne $k) { $k.Close() }
    }
}

function Set-LctRegRawValue {
    param($Loc, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    $k = $null
    try { $k = $Loc.hive.CreateSubKey($Loc.subKey) } catch { throw "无法创建/打开注册表键 $($Loc.normalized)：$($_.Exception.Message)" }
    if ($null -eq $k) { throw "无法创建/打开注册表键 $($Loc.normalized)" }
    try { $k.SetValue($Name, $Value, $Kind) } finally { $k.Close() }
}

function Remove-LctRegRawValue {
    param($Loc, [string]$Name = '')
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $true) } catch { $k = $null }
    if ($null -eq $k) { return $false }
    try { $k.DeleteValue($Name, $false); return $true } finally { $k.Close() }
}

function ConvertTo-LctRegDisplay {
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

function Undo-LctRegBatch {
    # 逆序用 before 回滚已写入的项；返回失败说明数组
    param($Loc, $DoneItems)
    $errs = New-Object System.Collections.ArrayList
    for ($i = $DoneItems.Count - 1; $i -ge 0; $i--) {
        $it = $DoneItems[$i]
        try {
            $bf = $it.before
            if ($null -ne $bf -and $bf.exists) {
                Set-LctRegRawValue -Loc $Loc -Name $bf.name -Value $bf.value -Kind $bf.kind
            } elseif ($it.op -eq 'set') {
                $null = Remove-LctRegRawValue -Loc $Loc -Name $it.name
            }
        } catch {
            $null = $errs.Add("回滚 $($it.name) 失败: $($_.Exception.Message)")
        }
    }
    return @($errs)
}

function Invoke-LctRegBatch {
    # 原子写入一批注册表项。Items 每项：@{ op='set'|'remove'; name; kind; value; before=<Get-LctRegRawValue 结果> }
    # 返回 @{ ok; error; rollbackErrors; applied }
    param([string]$Path, $Items)
    $res = @{ ok = $true; error = ''; rollbackErrors = @(); applied = $false }
    $loc = ConvertTo-LctRegLocation -Path $Path
    $list = @($Items)
    if ($list.Count -eq 0) { return $res }
    $done = New-Object System.Collections.ArrayList

    foreach ($it in $list) {
        try {
            if ($it.op -eq 'remove') { $null = Remove-LctRegRawValue -Loc $loc -Name $it.name }
            else { Set-LctRegRawValue -Loc $loc -Name $it.name -Value $it.value -Kind $it.kind }
            $null = $done.Add($it)
        } catch {
            $res.ok = $false
            $res.error = "写入 $($it.name) 失败: $($_.Exception.Message)"
            $res.rollbackErrors = @(Undo-LctRegBatch -Loc $loc -DoneItems $done)
            return $res
        }
    }

    # 写入后复核（防止「以为写了其实没写」）
    foreach ($it in $list) {
        $cur = Get-LctRegRawValue -Loc $loc -Name $it.name
        if ($it.op -eq 'remove') {
            if ($cur.exists) { $res.ok = $false; $res.error = "删除后校验仍存在: $($it.name)"; break }
        } else {
            if (-not ($cur.exists -and $cur.kind -eq $it.kind -and (Compare-LctRegValue -A $cur.value -B $it.value))) {
                $res.ok = $false; $res.error = "写入后校验不一致: $($it.name)"; break
            }
        }
    }
    if (-not $res.ok) {
        $res.rollbackErrors = @(Undo-LctRegBatch -Loc $loc -DoneItems $done)
        return $res
    }
    $res.applied = $true
    return $res
}

function New-LctSetPlan {
    param($Loc, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind, [switch]$Mask)
    $before = Get-LctRegRawValue -Loc $Loc -Name $Name
    $bt = '(不存在)'
    if ($before.exists) { $bt = ConvertTo-LctRegDisplay -Value $before.value -TypeLabel $before.type }
    $at = ConvertTo-LctRegDisplay -Value $Value -TypeLabel ([string]$Kind)
    $note = ''
    if ($before.exists -and $before.kind -eq $Kind -and (Compare-LctRegValue -A $before.value -B $Value)) { $note = '无变化（值已一致）' }
    if ($Mask) {
        if ($before.exists) { $bt = '(已存在，内容隐藏)' } else { $bt = '(不存在)' }
        if (([string]$Value).Length -gt 0) { $at = '(已设置，内容隐藏)' } else { $at = '(空值)' }
        $note = ''
    }
    return [pscustomobject][ordered]@{
        name = $Name; op = 'set'; kind = $Kind; value = $Value; before = $before
        beforeText = $bt; afterText = $at; note = $note
    }
}

function New-LctRemovePlan {
    param($Loc, [string]$Name, [switch]$Mask)
    $before = Get-LctRegRawValue -Loc $Loc -Name $Name
    $bt = '(不存在)'
    if ($before.exists) { $bt = ConvertTo-LctRegDisplay -Value $before.value -TypeLabel $before.type }
    $note = ''
    if (-not $before.exists) { $note = '无变化（值本不存在）' }
    if ($Mask -and $before.exists) { $bt = '(已存在，内容隐藏)' }
    return [pscustomobject][ordered]@{
        name = $Name; op = 'remove'; kind = $null; value = $null; before = $before
        beforeText = $bt; afterText = '(已删除)'; note = $note
    }
}

function ConvertTo-LctPlanChanges {
    param($Plans, [string]$Path, [string]$Kind = 'registry')
    $out = New-Object System.Collections.ArrayList
    foreach ($p in @($Plans)) {
        $null = $out.Add((New-LctChangeEntry -Kind $Kind -Target $Path -Name $p.name -Before $p.beforeText -After $p.afterText -Note $p.note))
    }
    return @($out)
}

function ConvertTo-LctBatchItems {
    param($Plans)
    $out = New-Object System.Collections.ArrayList
    foreach ($p in @($Plans)) {
        $null = $out.Add(@{ op = $p.op; name = $p.name; kind = $p.kind; value = $p.value; before = $p.before })
    }
    return @($out)
}
#endregion

#region 私有辅助：账户
function Get-LctAdminGroupMemberNames {
    # 返回 'DOMAIN\name' 形式；首选 Win10 自带 Get-LocalGroupMember，回退 ADSI
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { return @() }
    try {
        foreach ($m in @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)) {
            $n = [string]$m.Name
            if (-not [string]::IsNullOrWhiteSpace($n)) {
                if ($n -notlike '*\*') { $n = $env:COMPUTERNAME + '\' + $n }
                if (-not (@($out) -icontains $n)) { $null = $out.Add($n) }
            }
        }
        if ($out.Count -gt 0) { return @($out) }
    } catch { }
    try {
        $g = [ADSI]("WinNT://" + $env:COMPUTERNAME + "/Administrators,group")
        foreach ($m in @($g.Invoke('Members'))) {
            $n = [string]$m.GetType().InvokeMember('Name', 'GetProperty', $null, $m, $null)
            if (-not [string]::IsNullOrWhiteSpace($n)) {
                if ($n -notlike '*\*') { $n = $env:COMPUTERNAME + '\' + $n }
                if (-not (@($out) -icontains $n)) { $null = $out.Add($n) }
            }
        }
    } catch { }
    return @($out)
}

function Get-LctLocalAccountInfos {
    param([string[]]$AdminNames = @())
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($u in @(Get-LocalUser -ErrorAction Stop)) {
            $n = [string]$u.Name
            $null = $out.Add([pscustomobject][ordered]@{
                name = $n; enabled = [bool]$u.Enabled; isAdmin = (@($AdminNames) -icontains $n); description = [string]$u.Description
            })
        }
        if ($out.Count -gt 0) { return @($out | Sort-Object name) }
    } catch { }
    try {
        $dir = [ADSI]("WinNT://" + $env:COMPUTERNAME)
        foreach ($child in @($dir.Children)) {
            if ([string]$child.SchemaClassName -ne 'User') { continue }
            $n = ''; $dis = 1; $desc = ''
            try { $n = [string]$child.Properties['Name'].Value } catch { }
            try { $dis = [int]$child.Properties['Disabled'].Value } catch { }
            try { $desc = [string]$child.Properties['Description'].Value } catch { }
            $null = $out.Add([pscustomobject][ordered]@{
                name = $n; enabled = ($dis -eq 0); isAdmin = (@($AdminNames) -icontains $n); description = $desc
            })
        }
    } catch { }
    return @($out | Sort-Object name)
}

function Get-LctUacSnapshot {
    param($Warnings = $null)
    $path = $script:LctUacPath
    $loc = ConvertTo-LctRegLocation -Path $path
    $vals = @{}
    foreach ($n in @($script:LctUacNames)) {
        $r = Get-LctRegRawValue -Loc $loc -Name $n
        if ($r.exists) {
            $i = $null
            try { $i = [int](ConvertTo-LctInt64 -Value $r.value) } catch { $i = $null }
            $vals[$n] = $i
        } else {
            $vals[$n] = $null
            if ($null -ne $Warnings) { $null = $Warnings.Add("UAC 值缺失（按 null 返回）: $path::$n") }
        }
    }
    return [pscustomobject][ordered]@{
        enableLUA = $vals['EnableLUA']
        consentPromptBehaviorAdmin = $vals['ConsentPromptBehaviorAdmin']
        promptOnSecureDesktop = $vals['PromptOnSecureDesktop']
        enableInstallerDetection = $vals['EnableInstallerDetection']
        path = $path
    }
}

function Get-LctAutologonSnapshot {
    param($Warnings = $null)
    $path = $script:LctWinlogonPath
    $loc = ConvertTo-LctRegLocation -Path $path
    $flag = Get-LctRegRawValue -Loc $loc -Name 'AutoAdminLogon'
    $userV = Get-LctRegRawValue -Loc $loc -Name 'DefaultUserName'
    # 口令值只用于判断「是否已设置」，绝不离开本函数作用域（契约 §7.3）
    $pwV = Get-LctRegRawValue -Loc $loc -Name 'DefaultPassword'
    $enabled = $false
    if ($flag.exists) { $enabled = ConvertTo-LctBool -Value $flag.value -Default $false }
    $user = ''
    if ($userV.exists -and $null -ne $userV.value) { $user = [string]$userV.value }
    $hasPassword = ($pwV.exists -and $null -ne $pwV.value -and ([string]$pwV.value).Length -gt 0)
    return [pscustomobject][ordered]@{ enabled = $enabled; user = $user; hasPassword = $hasPassword; path = $path }
}

function Get-LctAccountRawData {
    # account.status 的 data（契约 §6）
    param($Warnings = $null)
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $full = [string]$id.Name
    $uname = $full
    $domain = [string]$env:USERDOMAIN
    if ($full -like '*\*') {
        $ix = $full.IndexOf('\')
        $domain = $full.Substring(0, $ix)
        $uname = $full.Substring($ix + 1)
    }
    $isAdminToken = Get-LctToolIsElevated
    $inAdminGroup = $false
    try {
        foreach ($g in @($id.Groups)) {
            $val = ''
            try { $val = [string]$g.Value } catch { $val = '' }
            if ($val -eq 'S-1-5-32-544') { $inAdminGroup = $true; break }
        }
    } catch { }
    if (-not $inAdminGroup) {
        try { $inAdminGroup = ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    }
    $user = [pscustomobject][ordered]@{ name = $uname; domain = $domain; isAdminToken = $isAdminToken; inAdminGroup = $inAdminGroup }
    $admins = @(Get-LctAdminGroupMemberNames)
    if ($admins.Count -eq 0 -and $null -ne $Warnings) { $null = $Warnings.Add('无法枚举 Administrators 组成员（Get-LocalGroupMember 与 ADSI 都失败）。') }
    $users = @(Get-LctLocalAccountInfos -AdminNames $admins)
    $groups = [pscustomobject][ordered]@{ Administrators = @($admins) }
    $uac = Get-LctUacSnapshot -Warnings $Warnings
    $auto = Get-LctAutologonSnapshot -Warnings $Warnings
    return [pscustomobject][ordered]@{ user = $user; users = $users; groups = $groups; uac = $uac; autologon = $auto }
}

function Get-LctLocalAccountEnabled {
    param([string]$Name = 'Administrator')
    try {
        $u = Get-LocalUser -Name $Name -ErrorAction Stop
        return [pscustomobject][ordered]@{ exists = $true; enabled = [bool]$u.Enabled; source = 'Get-LocalUser' }
    } catch { }
    try {
        $u = [ADSI]("WinNT://" + $env:COMPUTERNAME + "/" + $Name + ",user")
        $d = [int]$u.Properties['Disabled'].Value
        return [pscustomobject][ordered]@{ exists = $true; enabled = ($d -eq 0); source = 'ADSI' }
    } catch {
        return [pscustomobject][ordered]@{ exists = $false; enabled = $false; source = 'missing' }
    }
}

function Set-LctLocalAccountEnabled {
    param([string]$Name = 'Administrator', [bool]$Enabled = $true)
    $firstErr = ''
    try {
        $u = Get-LocalUser -Name $Name -ErrorAction Stop
        Set-LocalUser -Name $Name -Enabled $Enabled -ErrorAction Stop
        return
    } catch {
        $firstErr = $_.Exception.Message
    }
    try {
        $u = [ADSI]("WinNT://" + $env:COMPUTERNAME + "/" + $Name + ",user")
        $u.PSBase.InvokeSet('Disabled', [bool](-not $Enabled))
        $u.SetInfo()
        return
    } catch {
        throw "无法修改账户 $Name 的启用状态：$firstErr / $($_.Exception.Message)"
    }
}
#endregion

#region 导出函数

function Get-LctAccountStatus {
    <#
    .SYNOPSIS account.status：只读快照（user / users / groups / uac / autologon）。
    #>
    param([Alias('Args')][object]$ArgBag = $null, [switch]$Apply)
    $verb = 'account.status'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $data = $null
    try {
        $data = Get-LctAccountRawData -Warnings $warnings
    } catch {
        $null = $errors.Add("读取账户状态失败: $($_.Exception.Message)")
    }
    $log = Write-LctQuiet -Verb $verb -Level info -Message '读取账户状态'
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

function Set-LctAdminAccount {
    <#
    .SYNOPSIS account.admin：启用/禁用内置 Administrator（默认预览，-Apply 才写）。
    #>
    param([object]$Enable = $null, [Alias('Args')][object]$ArgBag = $null, [switch]$Apply)
    $verb = 'account.admin'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $data = $null
    $targetName = 'Administrator'

    if ($null -ne $ArgBag) {
        if ($null -eq $Enable) { $Enable = Get-LctArgFrom -Args $ArgBag -Key 'enable' }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }
    if ($null -eq $Enable) {
        $null = $errors.Add('缺少 enable 参数：account.admin 需要 enable(true|false)')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.admin 缺少 enable 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    $target = ConvertTo-LctBool -Value $Enable
    $cur = Get-LctLocalAccountEnabled -Name $targetName
    if (-not $cur.exists) {
        $null = $errors.Add("本机不存在内置账户 $targetName（无法用 Set-LocalUser / ADSI 定位）")
        $log = Write-LctQuiet -Verb $verb -Level error -Message "account.admin 找不到 $targetName"
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    $before = [bool]$cur.enabled
    $note = ''
    if ($before -eq $target) { $note = '无变化（账户已是该状态）' }
    $null = $changes.Add((New-LctChangeEntry -Kind 'account' -Target $targetName -Name 'Enabled' -Before ([string]$before) -After ([string]$target) -Note $note))
    $data = [pscustomobject][ordered]@{ name = $targetName; enabledBefore = $before; enabledAfter = $target }

    if ($target -and -not $before) {
        $null = $warnings.Add('启用内置 Administrator 会多出一个高权限账户；请立即用 net user Administrator <强口令> 或「本地用户和组」设置口令。')
    }
    if ($target -and -not (Get-LctToolIsElevated)) {
        $null = $warnings.Add('当前进程未以管理员身份运行：修改账户启用状态会因权限不足失败。')
    }

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message "预览 account.admin enable=$target" -Data @{ name = $targetName; before = $before; after = $target }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ name = $targetName; enable = $target }) -AccountSnapshot (Get-LctAccountRawData -Warnings $warnings)
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add("创建备份失败，已取消写入: $($_.Exception.Message)")
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.admin 备份失败，未写入'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $done = $false
    try {
        Set-LctLocalAccountEnabled -Name $targetName -Enabled $target
        $chk = Get-LctLocalAccountEnabled -Name $targetName
        if (-not ($chk.exists -and ([bool]$chk.enabled -eq $target))) { throw "写入后校验不一致（期望 Enabled=$target）" }
        $done = $true
    } catch {
        $null = $errors.Add("写入失败: $($_.Exception.Message)")
        try {
            Set-LctLocalAccountEnabled -Name $targetName -Enabled $before
            $null = $warnings.Add("已用 before 值回滚 $targetName Enabled=$before")
        } catch {
            $null = $errors.Add("回滚失败: $($_.Exception.Message)")
        }
    }

    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message "已应用 account.admin enable=$target" -Data @{ name = $targetName; before = $before; after = $target; backupId = $backupId; done = $done }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $data -Log $log
}

function Set-LctUac {
    <#
    .SYNOPSIS account.uac：开关 UAC 四项（默认预览，-Apply 才写）；需重启生效。
    .DESCRIPTION enable=true → EnableLUA=1 / ConsentPromptBehaviorAdmin=5 / PromptOnSecureDesktop=1 / EnableInstallerDetection=1
                 enable=false → 四项全 0；可用可选参数逐项覆盖。
    #>
    param(
        [object]$Enable = $null,
        [object]$ConsentPromptBehaviorAdmin = $null,
        [object]$PromptOnSecureDesktop = $null,
        [object]$EnableInstallerDetection = $null,
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'account.uac'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $data = $null

    if ($null -ne $ArgBag) {
        if ($null -eq $Enable) { $Enable = Get-LctArgFrom -Args $ArgBag -Key 'enable' }
        if ($null -eq $ConsentPromptBehaviorAdmin) { $ConsentPromptBehaviorAdmin = Get-LctArgFrom -Args $ArgBag -Key 'consentPromptBehaviorAdmin' }
        if ($null -eq $PromptOnSecureDesktop) { $PromptOnSecureDesktop = Get-LctArgFrom -Args $ArgBag -Key 'promptOnSecureDesktop' }
        if ($null -eq $EnableInstallerDetection) { $EnableInstallerDetection = Get-LctArgFrom -Args $ArgBag -Key 'enableInstallerDetection' }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }
    if ($null -eq $Enable) {
        $null = $errors.Add('缺少 enable 参数：account.uac 需要 enable(true|false)')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.uac 缺少 enable 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    $on = ConvertTo-LctBool -Value $Enable
    $tEnableLUA = 0; $tConsent = 0; $tSecure = 0; $tInstaller = 0
    if ($on) { $tEnableLUA = 1; $tConsent = 5; $tSecure = 1; $tInstaller = 1 }
    if ($null -ne $ConsentPromptBehaviorAdmin) { try { $tConsent = [int](ConvertTo-LctInt64 -Value $ConsentPromptBehaviorAdmin) } catch { $null = $errors.Add("ConsentPromptBehaviorAdmin 非法: $ConsentPromptBehaviorAdmin") } }
    if ($null -ne $PromptOnSecureDesktop) { try { $tSecure = [int](ConvertTo-LctInt64 -Value $PromptOnSecureDesktop) } catch { $null = $errors.Add("PromptOnSecureDesktop 非法: $PromptOnSecureDesktop") } }
    if ($null -ne $EnableInstallerDetection) { try { $tInstaller = [int](ConvertTo-LctInt64 -Value $EnableInstallerDetection) } catch { $null = $errors.Add("EnableInstallerDetection 非法: $EnableInstallerDetection") } }

    $path = $script:LctUacPath
    $loc = $null
    try { $loc = ConvertTo-LctRegLocation -Path $path } catch { $null = $errors.Add($_.Exception.Message) }
    if ($null -eq $loc) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.uac 路径非法'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $plans = New-Object System.Collections.ArrayList
    $null = $plans.Add((New-LctSetPlan -Loc $loc -Name 'EnableLUA' -Value $tEnableLUA -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)))
    $null = $plans.Add((New-LctSetPlan -Loc $loc -Name 'ConsentPromptBehaviorAdmin' -Value $tConsent -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)))
    $null = $plans.Add((New-LctSetPlan -Loc $loc -Name 'PromptOnSecureDesktop' -Value $tSecure -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)))
    $null = $plans.Add((New-LctSetPlan -Loc $loc -Name 'EnableInstallerDetection' -Value $tInstaller -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)))
    foreach ($c in @(ConvertTo-LctPlanChanges -Plans $plans -Path $path)) { $null = $changes.Add($c) }

    $data = [pscustomobject][ordered]@{
        values = [pscustomobject][ordered]@{
            enableLUA = $tEnableLUA; consentPromptBehaviorAdmin = $tConsent; promptOnSecureDesktop = $tSecure; enableInstallerDetection = $tInstaller
        }
    }
    $null = $warnings.Add('UAC 注册表值修改后需要重启（或注销）才会完全生效。')
    if (-not $on) { $null = $warnings.Add('禁用 UAC 会显著降低系统防护（提权不再弹窗确认），部分依赖 UAC 的应用/商店组件可能异常。') }
    if (-not (Get-LctToolIsElevated)) { $null = $warnings.Add('当前进程未以管理员身份运行：写入 HKLM 会因权限不足失败。') }

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message "预览 account.uac enable=$on"
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    if ($errors.Count -gt 0) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.uac 参数非法，未写入'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ enable = $on }) -RegistryPaths @($path) -AccountSnapshot (Get-LctAccountRawData -Warnings $warnings)
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add("创建备份失败，已取消写入: $($_.Exception.Message)")
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.uac 备份失败，未写入'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $b = Invoke-LctRegBatch -Path $path -Items (ConvertTo-LctBatchItems -Plans $plans)
    if (-not $b.ok) {
        $null = $errors.Add("写入失败: $($b.error)")
        foreach ($e in @($b.rollbackErrors)) { $null = $errors.Add($e) }
        if (@($b.rollbackErrors).Count -eq 0) { $null = $warnings.Add('已用 before 值回滚本次全部改动。') }
    }

    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message "已应用 account.uac enable=$on" -Data @{ enable = $on; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $data -Log $log
}

function Set-LctAutologon {
    <#
    .SYNOPSIS account.autologon：开/关自动登录（默认预览，-Apply 才写）。
    .DESCRIPTION 口令只从 -PasswordFile 读；绝不接受命令行明文，绝不写入 日志/备份 meta/Result。
                 备份 meta 只记 hasPassword；Result 只返回 {enabled,user,hasPassword}。
    #>
    param(
        [object]$Enable = $null,
        [string]$User = '',
        [string]$PasswordFile = '',
        [string]$Domain = '',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'account.autologon'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $data = $null
    $path = $script:LctWinlogonPath

    if ($null -ne $ArgBag) {
        if ($null -eq $Enable) { $Enable = Get-LctArgFrom -Args $ArgBag -Key 'enable' }
        if ([string]::IsNullOrEmpty($User)) { $User = [string](Get-LctArgFrom -Args $ArgBag -Key 'user' -Default '') }
        if ([string]::IsNullOrEmpty($PasswordFile)) { $PasswordFile = [string](Get-LctArgFrom -Args $ArgBag -Key 'passwordFile' -Default '') }
        if ([string]::IsNullOrEmpty($Domain)) { $Domain = [string](Get-LctArgFrom -Args $ArgBag -Key 'domain' -Default '') }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }
    if ($null -eq $Enable) {
        $null = $errors.Add('缺少 enable 参数：account.autologon 需要 enable(true|false)')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.autologon 缺少 enable 参数'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }
    $on = ConvertTo-LctBool -Value $Enable
    $loc = $null
    try { $loc = ConvertTo-LctRegLocation -Path $path } catch { $null = $errors.Add($_.Exception.Message) }
    if ($null -eq $loc) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.autologon 路径非法'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $uName = ''
    $dName = ''
    $pw = ''
    $hasPw = $false

    if ($on) {
        if ([string]::IsNullOrWhiteSpace($User)) { $null = $errors.Add('启用自动登录必须提供 user（账号名）。') }
        if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
            $null = $errors.Add('启用自动登录必须提供 passwordFile：口令只从文件读取，不接受命令行明文（也可给一个空文件表示空口令）。')
        } elseif ($errors.Count -eq 0) {
            $pf = [string]$PasswordFile
            if (-not (Test-Path -LiteralPath $pf)) {
                $null = $errors.Add("口令文件不存在: $pf")
            } else {
                try {
                    $pw = [string](Get-Content -LiteralPath $pf -Raw -ErrorAction Stop)
                } catch {
                    $null = $errors.Add("读口令文件失败: $($_.Exception.Message)")
                }
                if ($errors.Count -eq 0) {
                    # 只去掉文件尾部的 CR/LF，其它字符（含空格）原样保留
                    $pw = $pw.TrimEnd([char[]]@([char]13, [char]10))
                    $hasPw = ($pw.Length -gt 0)
                    if (-not $hasPw) { $null = $warnings.Add('口令文件是空的：将写入空白口令，自动登录等同「无口令登入」，风险极高。') }
                }
            }
        }
        if ($errors.Count -eq 0) {
            $uName = $User.Trim()
            $dName = $Domain
            if ($uName -like '*\*') {
                $ix = $uName.IndexOf('\')
                if ([string]::IsNullOrEmpty($dName)) { $dName = $uName.Substring(0, $ix) }
                $uName = $uName.Substring($ix + 1)
            }
            if ([string]::IsNullOrWhiteSpace($dName)) { $dName = [string]$env:COMPUTERNAME }
        }
    }

    if ($errors.Count -gt 0) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.autologon 参数非法，未写入'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $plans = New-Object System.Collections.ArrayList
    if ($on) {
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'AutoAdminLogon' -Value '1' -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'DefaultUserName' -Value $uName -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'DefaultDomainName' -Value $dName -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
        # 口令项：before/after 一律遮罩，绝不把口令写进 Result
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'DefaultPassword' -Value $pw -Kind ([Microsoft.Win32.RegistryValueKind]::String) -Mask)) | Out-Null
    } else {
        if (-not [string]::IsNullOrWhiteSpace($User) -or -not [string]::IsNullOrWhiteSpace($PasswordFile)) {
            $null = $warnings.Add('禁用自动登录时忽略 user / passwordFile 参数。')
        }
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'AutoAdminLogon' -Value '0' -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
        $plans.Add((New-LctRemovePlan -Loc $loc -Name 'DefaultPassword' -Mask)) | Out-Null
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'DefaultUserName' -Value '' -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
        $plans.Add((New-LctSetPlan -Loc $loc -Name 'DefaultDomainName' -Value '' -Kind ([Microsoft.Win32.RegistryValueKind]::String))) | Out-Null
    }
    foreach ($c in @(ConvertTo-LctPlanChanges -Plans $plans -Path $path)) { $null = $changes.Add($c) }

    $data = [pscustomobject][ordered]@{ enabled = $on; user = $uName; hasPassword = $hasPw }

    # 契约 §7.3 必须说明的风险
    $null = $warnings.Add('AutoAdminLogon 会把口令以明文写入 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword；任何本地管理员或离线挂载系统盘都能读到。更安全的替代是 Sysinternals Autologon（把口令存进 LSA secret，注册表不留明文）。')
    if ($on) { $null = $warnings.Add('本次备份会导出 Winlogon 键，备份 .reg 里可能含「旧」口令明文（与原注册表同等级暴露），请保护 var\backups 目录。') }
    if (-not (Get-LctToolIsElevated)) { $null = $warnings.Add('当前进程未以管理员身份运行：写入 HKLM 会因权限不足失败。') }

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message "预览 account.autologon enable=$on user=$uName hasPassword=$hasPw"
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $bk = $null
    try {
        # 备份 meta 只记 hasPassword，绝不含口令
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ enable = $on; user = $uName; hasPassword = $hasPw }) -RegistryPaths @($path) -AccountSnapshot (Get-LctAccountRawData -Warnings $warnings)
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add("创建备份失败，已取消写入: $($_.Exception.Message)")
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.autologon 备份失败，未写入'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
    }

    $b = Invoke-LctRegBatch -Path $path -Items (ConvertTo-LctBatchItems -Plans $plans)
    if (-not $b.ok) {
        $null = $errors.Add("写入失败: $($b.error)")
        foreach ($e in @($b.rollbackErrors)) { $null = $errors.Add($e) }
        if (@($b.rollbackErrors).Count -eq 0) { $null = $warnings.Add('已用 before 值回滚本次全部改动。') }
    }
    $pw = ''  # 用完即清（降低内存驻留）

    # 如实回报落盘后的状态（hasPassword 由注册表反推，口令值不外露）
    try {
        $after = Get-LctAutologonSnapshot -Warnings $null
        $data = [pscustomobject][ordered]@{ enabled = [bool]$after.enabled; user = [string]$after.user; hasPassword = [bool]$after.hasPassword }
    } catch { }

    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message "已应用 account.autologon enable=$on user=$uName hasPassword=$hasPw" -Data @{ enable = $on; user = $uName; hasPassword = $hasPw; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $data -Log $log
}

function Restore-LctAccountState {
    <#
    .SYNOPSIS 从备份的 account-before.json 快照还原 Administrator 启用状态 / UAC 四项 / 自动登录开关。
    .DESCRIPTION 快照形状 = account.status 的 data（契约 §6）。口令无法还原（快照只记 hasPassword）：
                 若快照是「自动登录启用且存有口令」，为避免用空口令尝试登录，本函数把 AutoAdminLogon 置 0 并在 warnings 里说明。
                 -Apply 时才写入；写入前会再建一个备份（可反向回滚）。
    #>
    param([Parameter(Position = 0)]$Snapshot = $null, [Alias('Args')][object]$ArgBag = $null, [switch]$Apply, [string]$Verb = 'account.restore')
    $verb = $Verb
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''

    if ($null -eq $Snapshot -and $null -ne $ArgBag) {
        $Snapshot = Get-LctArgFrom -Args $ArgBag -Key 'snapshot'
        if ($null -eq $Snapshot) { $Snapshot = Get-LctArgFrom -Args $ArgBag -Key 'accountSnapshot' }
        if (-not $Apply) { $Apply = (ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') -Default $false) }
    }
    # 兼容：直接传 account-before.json 的路径
    if ($Snapshot -is [string]) {
        $sp = [string]$Snapshot
        if (Test-Path -LiteralPath $sp) {
            try { $Snapshot = (Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $null = $errors.Add("读取快照文件失败: $($_.Exception.Message)") }
        } else {
            $null = $errors.Add("快照文件不存在: $sp")
        }
    }
    if ($null -eq $Snapshot) {
        if ($errors.Count -eq 0) { $null = $errors.Add('缺少账户快照（account-before.json 的 data 对象）：无法还原。') }
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.restore 缺少快照'
        return New-LctResult -Verb $verb -Errors @($errors) -Warnings @($warnings) -Log $log
    }

    # ---- 从快照取目标值 ----
    $hasAdmin = $false; $adminTarget = $false
    foreach ($u in @(Get-LctArgFrom -Args $Snapshot -Key 'users' -Default @())) {
        if ([string](Get-LctArgFrom -Args $u -Key 'name') -ieq 'Administrator') {
            $hasAdmin = $true
            $adminTarget = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $u -Key 'enabled') -Default $false
        }
    }
    if (-not $hasAdmin) { $null = $warnings.Add('快照里没有 Administrator 账户记录：跳过 Administrator 启用状态还原。') }

    $uacVals = @{}
    $uacSnap = Get-LctArgFrom -Args $Snapshot -Key 'uac'
    if ($null -ne $uacSnap) {
        $pairs = @(@('EnableLUA', 'enableLUA'), @('ConsentPromptBehaviorAdmin', 'consentPromptBehaviorAdmin'), @('PromptOnSecureDesktop', 'promptOnSecureDesktop'), @('EnableInstallerDetection', 'enableInstallerDetection'))
        foreach ($pair in $pairs) {
            $v = Get-LctArgFrom -Args $uacSnap -Key $pair[1]
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
                try { $uacVals[$pair[0]] = [int](ConvertTo-LctInt64 -Value $v) } catch { $null = $warnings.Add("快照里的 $($pair[1]) 无法解析，跳过。") }
            }
        }
        foreach ($n in @($script:LctUacNames)) {
            if (-not $uacVals.ContainsKey($n)) { $null = $warnings.Add("快照缺少 UAC 值 $n：该值保持当前状态不还原。") }
        }
    } else {
        $null = $warnings.Add('快照里没有 uac 段：跳过 UAC 还原。')
    }

    $hasAuto = $false; $autoEnabled = $false; $autoUser = ''; $autoHasPw = $false; $autoDomainGiven = ''
    $autoSnap = Get-LctArgFrom -Args $Snapshot -Key 'autologon'
    if ($null -ne $autoSnap) {
        $hasAuto = $true
        $autoEnabled = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $autoSnap -Key 'enabled') -Default $false
        $autoUser = [string](Get-LctArgFrom -Args $autoSnap -Key 'user' -Default '')
        $autoHasPw = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $autoSnap -Key 'hasPassword') -Default $false
        $autoDomainGiven = [string](Get-LctArgFrom -Args $autoSnap -Key 'domain' -Default '')
    } else {
        $null = $warnings.Add('快照里没有 autologon 段：跳过自动登录还原。')
    }

    $wlLoc = ConvertTo-LctRegLocation -Path $script:LctWinlogonPath
    $uacLoc = ConvertTo-LctRegLocation -Path $script:LctUacPath

    # ---- 计划：Administrator ----
    $adminCur = Get-LctLocalAccountEnabled -Name 'Administrator'
    if ($hasAdmin -and $adminCur.exists) {
        $an = ''
        if ([bool]$adminCur.enabled -eq $adminTarget) { $an = '无变化（账户已是该状态）' }
        $null = $changes.Add((New-LctChangeEntry -Kind 'account' -Target 'Administrator' -Name 'Enabled' -Before ([string][bool]$adminCur.enabled) -After ([string]$adminTarget) -Note $an))
    } elseif ($hasAdmin -and -not $adminCur.exists) {
        $null = $errors.Add('快照要求还原 Administrator，但本机找不到该内置账户。')
    }

    # ---- 计划：UAC ----
    $uacPlans = New-Object System.Collections.ArrayList
    foreach ($n in @($script:LctUacNames)) {
        if ($uacVals.ContainsKey($n)) {
            $null = $uacPlans.Add((New-LctSetPlan -Loc $uacLoc -Name $n -Value $uacVals[$n] -Kind ([Microsoft.Win32.RegistryValueKind]::DWord)))
        }
    }
    foreach ($c in @(ConvertTo-LctPlanChanges -Plans $uacPlans -Path $script:LctUacPath)) { $null = $changes.Add($c) }

    # ---- 计划：自动登录 ----
    $wlPlans = New-Object System.Collections.ArrayList
    $autoActions = [ordered]@{}
    if ($hasAuto) {
        $dName = $autoDomainGiven
        $uOnly = $autoUser
        if ($uOnly -like '*\*') {
            $ix = $uOnly.IndexOf('\')
            if ([string]::IsNullOrEmpty($dName)) { $dName = $uOnly.Substring(0, $ix) }
            $uOnly = $uOnly.Substring($ix + 1)
        }
        if ([string]::IsNullOrWhiteSpace($dName)) { $dName = [string]$env:COMPUTERNAME }
        if ($autoEnabled -and -not $autoHasPw) {
            # 启用且快照无口令：可以完整还原（本来就没有存口令）
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'AutoAdminLogon' -Value '1' -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultUserName' -Value $uOnly -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultDomainName' -Value $dName -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctRemovePlan -Loc $wlLoc -Name 'DefaultPassword' -Mask))
            $autoActions['autologon'] = $false
        } elseif ($autoEnabled -and $autoHasPw) {
            # 口令无法还原 → 不能恢复成「启用」，否则会用空口令尝试登录
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'AutoAdminLogon' -Value '0' -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultUserName' -Value $uOnly -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultDomainName' -Value $dName -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $warnings.Add('快照显示「自动登录已启用且存有口令」，但口令无法从快照还原（备份只记 hasPassword）。为避免用空口令尝试登录，已把 AutoAdminLogon 置为 0；请手动写回口令，或用 Sysinternals Autologon 重新设置。')
            $autoActions['autologon'] = $false
        } else {
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'AutoAdminLogon' -Value '0' -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultUserName' -Value '' -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctSetPlan -Loc $wlLoc -Name 'DefaultDomainName' -Value '' -Kind ([Microsoft.Win32.RegistryValueKind]::String)))
            $null = $wlPlans.Add((New-LctRemovePlan -Loc $wlLoc -Name 'DefaultPassword' -Mask))
            $autoActions['autologon'] = $false
        }
        if ([string]::IsNullOrWhiteSpace($autoDomainGiven)) {
            $null = $warnings.Add("快照未记录 DefaultDomainName（契约 §6 形状限制），还原时按本机名 '$env:COMPUTERNAME' 写；若原来是域账户自动登录，请手动修正该值。")
        }
    }
    foreach ($c in @(ConvertTo-LctPlanChanges -Plans $wlPlans -Path $script:LctWinlogonPath)) { $null = $changes.Add($c) }

    # ---- 预览 ----
    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message '预览 account.restore（账户快照还原）'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            source = 'snapshot'; target = [pscustomobject][ordered]@{ administratorEnabled = $adminTarget; uac = $uacVals; autologon = [pscustomobject][ordered]@{ enabled = $autoEnabled; user = $autoUser; hasPassword = $autoHasPw } }
        }) -Log $log
    }

    # ---- 落盘（先备份当前状态，便于反向回滚）----
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ source = 'account-snapshot'; restoreAdmin = $hasAdmin; restoreUac = ($uacPlans.Count -gt 0); restoreAutologon = $hasAuto }) -RegistryPaths @($script:LctUacPath, $script:LctWinlogonPath) -AccountSnapshot (Get-LctAccountRawData -Warnings $null)
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add("创建备份失败，已取消还原: $($_.Exception.Message)")
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'account.restore 备份失败，未还原'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Log $log
    }

    $appliedAdmin = $false
    $appliedUac = $false
    $appliedAutologon = $false

    if ($hasAdmin -and $adminCur.exists) {
        try {
            Set-LctLocalAccountEnabled -Name 'Administrator' -Enabled $adminTarget
            $chk = Get-LctLocalAccountEnabled -Name 'Administrator'
            if (-not ($chk.exists -and ([bool]$chk.enabled -eq $adminTarget))) { throw "写入后校验不一致（期望 Enabled=$adminTarget）" }
            $appliedAdmin = $true
        } catch {
            $null = $errors.Add("还原 Administrator 启用状态失败: $($_.Exception.Message)")
            try {
                Set-LctLocalAccountEnabled -Name 'Administrator' -Enabled ([bool]$adminCur.enabled)
                $null = $warnings.Add('已把 Administrator 回滚到还原前的状态。')
            } catch { $null = $errors.Add("Administrator 回滚失败: $($_.Exception.Message)") }
        }
    }

    if ($uacPlans.Count -gt 0) {
        $b = Invoke-LctRegBatch -Path $script:LctUacPath -Items (ConvertTo-LctBatchItems -Plans $uacPlans)
        if ($b.ok) { $appliedUac = $true }
        else {
            $null = $errors.Add("还原 UAC 失败: $($b.error)")
            foreach ($e in @($b.rollbackErrors)) { $null = $errors.Add($e) }
        }
    }

    if ($wlPlans.Count -gt 0) {
        $b2 = Invoke-LctRegBatch -Path $script:LctWinlogonPath -Items (ConvertTo-LctBatchItems -Plans $wlPlans)
        if ($b2.ok) { $appliedAutologon = $true }
        else {
            $null = $errors.Add("还原自动登录失败: $($b2.error)")
            foreach ($e in @($b2.rollbackErrors)) { $null = $errors.Add($e) }
        }
    }

    if ($errors.Count -gt 0 -and ($appliedAdmin -or $appliedUac -or $appliedAutologon)) {
        $null = $warnings.Add('本次还原是「部分成功」：出错的分区已回滚，成功的分区保持已还原状态。')
    }

    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message '已应用 account.restore（账户快照还原）' -Data @{ backupId = $backupId; admin = $appliedAdmin; uac = $appliedUac; autologon = $appliedAutologon }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data ([pscustomobject][ordered]@{
        source = 'snapshot'
        applied = [pscustomobject][ordered]@{ administrator = $appliedAdmin; uac = $appliedUac; autologon = $appliedAutologon }
        target = [pscustomobject][ordered]@{ administratorEnabled = $adminTarget; uac = $uacVals; autologon = [pscustomobject][ordered]@{ enabled = $autoEnabled; user = $autoUser; hasPassword = $autoHasPw } }
    }) -Log $log
}

#endregion

Export-ModuleMember -Function Get-LctAccountStatus, Set-LctAdminAccount, Set-LctUac, Set-LctAutologon, Restore-LctAccountState