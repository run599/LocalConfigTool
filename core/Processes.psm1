# =====================================================================
# LocalConfigTool - Processes.psm1
# 职责：进程快照 / 详情 / 终止 / 会话内看门狗 / IFEO 加载阻断
# 作者：backend-processes (task-4)
# 契约：docs\CONTRACT.md §3 Result / §5 verb / §10 编码与自动变量陷阱 / §11.1 §11.2 §11.4
# 导出：Get-LctProcessList / Get-LctProcessDetail / Stop-LctProcess
#       Start-LctProcessWatch / Get-LctProcessWatchStatus / Stop-LctProcessWatch / Get-LctProcessWatchLog
#       Set-LctProcessBlock / Remove-LctProcessBlock / Get-LctProcessBlockList
#
# 铁律：
#   1) 返回值一律用 New-LctResult 构造；动作类默认只预览，只有 -Apply 才真杀/真写；
#   2) **不自行创建 SYSTEM 身份**：以调用者当前权限运行，只如实上报当前身份，并把
#      OpenProcess(PROCESS_TERMINATE) 的真实 Win32 失败原因返回（5=拒绝访问/受保护，
#      87=pid 已不存在，31=无法取得映像路径）——「access denied」绝不冒充「进程不存在」；
#   3) 目标必须显式指定（pid 或唯一的 name），禁止通配与批量；关键/安全软件名单必须 -Override
#      才允许终止/监控，且写 warnings + 审计日志；
#   4) 看门狗只在当前进程内的 runspace 里循环：不装服务、不注册任务、不写自启动、不隐藏，
#      当前进程退出看门狗即停（引擎退出即停）；重杀前按 name + path 复核身份，防 pid 复用误杀；
#   5) Set-LctProcessBlock 写前 New-LctBackup（记录原值或「原本不存在」）；Remove 完整回滚；
#      删除注册表键只用 Remove-LctRegistryKeyTree，值删除用 .NET DeleteValue，全文件禁止 Remove-Item；
#   6) 兼容 Windows PowerShell 5.1；不使用 Set-StrictMode；
#      进程 id 一律用 $procId（$pid 是只读自动变量，本文件绝不赋值给它）。
#
# Engine 侧 verb 接线（Lead 负责，本模块不碰 Engine）：
#   process.list  -> Get-LctProcessList          process.detail -> Get-LctProcessDetail
#   process.kill  -> Stop-LctProcess             process.watch.start|status|stop|log
#   process.block.set -> Set-LctProcessBlock     process.block.remove -> Remove-LctProcessBlock
#   process.block.list -> Get-LctProcessBlockList
#
# data 形状（前端渲染依据；详见各函数注释）：
#   list   = @{ identity; items; count; total; truncated; limit; includeSystem; filters }
#   detail = @{ pid; name; path; commandLine; user; integrity; session; wsMB; cpu; startTime;
#               isCritical; suspectedProtected; terminate = @{ canTerminate; win32Error; win32Message; conclusion } }
#   kill   = @{ target; killed; applied; terminate = @{...}; backupId }
#   watch.*= @{ running; intervalSec; durationSec; startedAt; endsAt; endedAt; targets;
#               killCount; failureCount; skipCount; events; logPath; ... }
#   block  = @{ exeName; views = @(@{ hive; view; keyPath; debugger; ... }); ... } / list = @{ items; count; ... }
# =====================================================================

#region 依赖守卫（契约 §10.3：跨模块导入必须带 -Global；可用性以「模块是否装载成功」为准）
$script:LctCoreDir = $PSScriptRoot
$script:LctLoggingModule = Join-Path $script:LctCoreDir 'Logging.psm1'
$script:LctBackupModule = Join-Path $script:LctCoreDir 'Backup.psm1'
$script:LctLoaded = @{ Logging = $false; Backup = $false }
if (-not (Get-Module -Name Logging)) {
    if (Test-Path -LiteralPath $script:LctLoggingModule) {
        Import-Module $script:LctLoggingModule -Force -Global -ErrorAction Stop
    }
}
$script:LctLoaded.Logging = [bool](Get-Module -Name Logging)
if (-not (Get-Module -Name Backup)) {
    if (Test-Path -LiteralPath $script:LctBackupModule) {
        Import-Module $script:LctBackupModule -Force -Global -ErrorAction Stop
        # Backup 装载时可能重导 Logging：再确认一次全局可用（不递归）
        if (-not (Get-Module -Name Logging)) {
            Import-Module $script:LctLoggingModule -Force -Global -ErrorAction Stop
        }
    }
}
$script:LctLoaded.Backup = [bool](Get-Module -Name Backup)
#endregion

#region 原生互操作（错误码必须如实上报，不笼统说「失败」）
$script:LctProcSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LctProcNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr handle, uint flags, StringBuilder buffer, ref uint size);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr handle, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, uint len, out uint ret);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupAccountSid(string system, IntPtr sid, StringBuilder name, ref uint nameLen, StringBuilder domain, ref uint domainLen, out int use);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    public static string ImagePath(int processId, out int error)
    {
        error = 0;
        IntPtr h = OpenProcess(0x1000, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return null; }
        try {
            StringBuilder sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (!QueryFullProcessImageName(h, 0, sb, ref size)) { error = Marshal.GetLastWin32Error(); return null; }
            return sb.ToString();
        } finally { CloseHandle(h); }
    }

    public static bool CanTerminate(int processId, out int error)
    {
        error = 0;
        IntPtr h = OpenProcess(0x0001, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return false; }
        CloseHandle(h);
        return true;
    }

    public static bool Kill(int processId, uint exitCode, out int error)
    {
        error = 0;
        IntPtr h = OpenProcess(0x0001, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return false; }
        try {
            if (!TerminateProcess(h, exitCode)) { error = Marshal.GetLastWin32Error(); return false; }
            return true;
        } finally { CloseHandle(h); }
    }

    public static bool Identity(int processId, out string owner, out string integrity, out int error)
    {
        owner = null; integrity = null; error = 0;
        IntPtr h = OpenProcess(0x1000, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return false; }
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(h, 0x0008, out token)) { error = Marshal.GetLastWin32Error(); return false; }
            owner = SidToName(token, 1, out error);
            integrity = IntegrityName(token);
            return (owner != null);
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(h);
        }
    }

    private static string SidToName(IntPtr token, int infoClass, out int error)
    {
        error = 0;
        uint needed = 0;
        GetTokenInformation(token, infoClass, IntPtr.Zero, 0, out needed);
        if (needed == 0) { error = Marshal.GetLastWin32Error(); return null; }
        IntPtr buf = Marshal.AllocHGlobal((int)needed);
        try {
            uint got = 0;
            if (!GetTokenInformation(token, infoClass, buf, needed, out got)) { error = Marshal.GetLastWin32Error(); return null; }
            IntPtr sid = Marshal.ReadIntPtr(buf, 0);
            if (sid == IntPtr.Zero) return null;
            StringBuilder name = new StringBuilder(256); uint nl = (uint)name.Capacity;
            StringBuilder dom = new StringBuilder(256); uint dl = (uint)dom.Capacity;
            int use;
            if (!LookupAccountSid(null, sid, name, ref nl, dom, ref dl, out use)) { error = Marshal.GetLastWin32Error(); return null; }
            string d = dom.ToString(), n = name.ToString();
            return (d.Length == 0) ? n : (d + "\\" + n);
        } finally { Marshal.FreeHGlobal(buf); }
    }

    private static string IntegrityName(IntPtr token)
    {
        uint needed = 0;
        GetTokenInformation(token, 25, IntPtr.Zero, 0, out needed);
        if (needed == 0) return null;
        IntPtr buf = Marshal.AllocHGlobal((int)needed);
        try {
            uint got = 0;
            if (!GetTokenInformation(token, 25, buf, needed, out got)) return null;
            IntPtr sid = Marshal.ReadIntPtr(buf, 0);
            if (sid == IntPtr.Zero) return null;
            IntPtr pc = GetSidSubAuthorityCount(sid);
            byte count = Marshal.ReadByte(pc, 0);
            IntPtr pl = GetSidSubAuthority(sid, (uint)(count - 1));
            uint rid = (uint)Marshal.ReadInt32(pl, 0);
            switch (rid) {
                case 0x0000: return "Untrusted";
                case 0x1000: return "Low";
                case 0x2000: return "Medium";
                case 0x2100: return "MediumPlus";
                case 0x3000: return "High";
                case 0x4000: return "System";
                case 0x5000: return "Protected";
                default: return "0x" + rid.ToString("X");
            }
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

# 看门狗 runspace 专用的最小原生类（独立类名，避免与上面的类型冲突）
$script:LctWatchNativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LctWatchNative
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr handle, uint flags, StringBuilder buffer, ref uint size);

    public static string ImagePath(int processId, out int error)
    {
        error = 0;
        IntPtr h = OpenProcess(0x1000, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return null; }
        try {
            StringBuilder sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (!QueryFullProcessImageName(h, 0, sb, ref size)) { error = Marshal.GetLastWin32Error(); return null; }
            return sb.ToString();
        } finally { CloseHandle(h); }
    }

    public static bool Kill(int processId, out int error)
    {
        error = 0;
        IntPtr h = OpenProcess(0x0001, false, processId);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return false; }
        try {
            if (!TerminateProcess(h, 1)) { error = Marshal.GetLastWin32Error(); return false; }
            return true;
        } finally { CloseHandle(h); }
    }
}
'@

$script:LctNativeReady = $false
$script:LctNativeError = ''

function Initialize-LctProcNative {
    # 只编译一次；失败后不重试（把编译错误如实留下）
    if ($script:LctNativeReady) { return $true }
    if ($script:LctNativeError) { return $false }
    try {
        if (-not ([System.Management.Automation.PSTypeName]'LctProcNative').Type) {
            Add-Type -TypeDefinition $script:LctProcSource -ErrorAction Stop
        }
        $script:LctNativeReady = $true
    } catch {
        $script:LctNativeError = [string]$_.Exception.Message
        $script:LctNativeReady = $false
    }
    return [bool]$script:LctNativeReady
}
#endregion

#region 私有辅助
function New-LctProcChangeEntry {
    param(
        [string]$Kind = 'note',
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
    # 日志失败不得影响能力模块主流程；返回日志文件路径（可能为空串）
    param([string]$Verb = 'engine', [string]$Level = 'info', [string]$Message = '', $Data = $null)
    try { return [string](Write-LctLog -Verb $Verb -Level $Level -Message $Message -Data $Data) } catch { return '' }
}

function Get-LctArgFrom {
    # 兼容引擎把 Args 作为对象/hashtable 整体传入（简单函数禁止用 $Args 作参数名，契约 §10.8）
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
    if ($Value -is [ValueType]) {
        try { return ([double]$Value -ne 0) } catch { return $Default }
    }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if (@('1', 'true', 'yes', 'on', 'y', '是', '开', '启用') -contains $s) { return $true }
    if (@('0', 'false', 'no', 'off', 'n', '否', '关', '禁用', '') -contains $s) { return $false }
    return $Default
}

function ConvertTo-LctIntSafe {
    # [object] 形参 + 安全转换：JSON 里的 null / 字符串都不会把参数绑定炸掉
    param($Value, [int]$Default = 0)
    if ($null -eq $Value) { return $Default }
    $s = ([string]$Value).Trim()
    if ($s -eq '') { return $Default }
    $n = 0
    if ([int]::TryParse($s, [ref]$n)) { return $n }
    return $Default
}

function Get-LctWin32Text {
    # 如实翻译 Win32 错误码（不笼统说「失败」）
    param([int]$Code)
    if ($Code -eq 0) { return '' }
    $msg = ''
    try { $msg = [string](New-Object System.ComponentModel.Win32Exception -ArgumentList $Code).Message } catch { $msg = '' }
    $hint = ''
    switch ($Code) {
        5 { $hint = '拒绝访问：权限不足，或该进程受保护（PPL/系统关键进程）' }
        87 { $hint = '参数无效：该 pid 已不存在（进程已退出）' }
        6 { $hint = '句柄无效：进程可能已退出' }
        31 { $hint = '设备未就绪：无法读取该进程的映像/令牌（多为 System/Registry 等内核态进程）' }
        3 { $hint = '系统找不到指定的路径' }
        2 { $hint = '系统找不到指定的文件' }
    }
    if ($hint) { return ('Win32 ' + $Code + ' (' + $msg + ') —— ' + $hint) }
    return ('Win32 ' + $Code + ' (' + $msg + ')')
}

function Get-LctCriticalProcessPatterns {
    # 关键进程 / 安全软件名单（契约 §11.2 铁律 3 的落地清单）
    return @(
        'MsMpEng', 'MsMpEngCP', 'NisSrv', 'MsSense', 'Sense', 'MsSecFw', 'MpCmdRun', 'smartscreen',
        'SecurityHealthService', 'SecurityHealthSystray', 'WinDefend', 'WdNisSvc',
        'csrss', 'lsass', 'lsaiso', 'services', 'smss', 'wininit', 'winlogon', 'dwm',
        'svchost', 'system', 'registry', 'idle', 'secure system', 'memory compression',
        'sgrmbroker', 'audiodg', 'fontdrvhost', 'trustedinstaller', 'wsl', 'wslservice',
        'avira*', 'avgnt*', 'avguard*', 'avshadow*', 'avscan*', 'avcenter*', 'avp*', 'kav*'
    )
}

function Test-LctProcCritical {
    param([string]$ProcName)
    if ([string]::IsNullOrWhiteSpace($ProcName)) { return $false }
    $n = ([string]$ProcName -replace '(?i)\.exe$', '').Trim().ToLowerInvariant()
    foreach ($pat in @(Get-LctCriticalProcessPatterns)) {
        $p = ([string]$pat).Trim().ToLowerInvariant()
        if ($p.EndsWith('*')) {
            if ($n.StartsWith($p.TrimEnd('*'))) { return $true }
        } elseif ($n -eq $p) {
            return $true
        }
    }
    return $false
}

function Get-LctProcStartText {
    param($Proc)
    if ($null -eq $Proc) { return '' }
    try { return ([datetime]$Proc.StartTime).ToString('s') } catch { return '' }
}

function Get-LctProcLive {
    param([int]$ProcId)
    if ($ProcId -le 0) { return $null }
    try { return (Get-Process -Id $ProcId -ErrorAction Stop) } catch { return $null }
}

function Test-LctProcIsSelf {
    param([int]$ProcId)
    try { return ($ProcId -eq [System.Diagnostics.Process]::GetCurrentProcess().Id) } catch { return $false }
}

function Get-LctProcNativeFacts {
    # 实测：能否 OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)/PROCESS_TERMINATE，属主与完整性级别
    param([int]$ProcId)
    $path = ''; $pathErr = 0
    $owner = ''; $integrity = ''; $idErr = 0
    $canTerm = $false; $termErr = 0
    $nativeOk = [bool](Initialize-LctProcNative)
    if ($nativeOk) {
        try { $path = [string][LctProcNative]::ImagePath($ProcId, [ref]$pathErr) } catch { $path = ''; $pathErr = -1 }
        try { $null = [LctProcNative]::Identity($ProcId, [ref]$owner, [ref]$integrity, [ref]$idErr) } catch { $idErr = -1 }
        try { $canTerm = [bool][LctProcNative]::CanTerminate($ProcId, [ref]$termErr) } catch { $termErr = -1 }
    } else {
        # 退化路径（Add-Type 不可用时仍要能给出结论）
        $p = Get-LctProcLive -ProcId $ProcId
        if ($null -ne $p) { try { $path = [string]$p.Path } catch { $path = '' } }
        try {
            $wp = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $ProcId) -ErrorAction Stop
            if ($wp) {
                $o = Invoke-CimMethod -InputObject $wp -MethodName GetOwner -ErrorAction Stop
                if ($o.ReturnValue -eq 0) { $owner = ('{0}\{1}' -f $o.Domain, $o.User) }
            }
        } catch { }
        $termErr = -2
    }
    return [pscustomobject][ordered]@{
        nativeOk          = $nativeOk
        path              = $path
        pathError         = $pathErr
        pathErrorText     = (Get-LctWin32Text -Code $pathErr)
        owner             = $owner
        integrity         = $integrity
        identityError     = $idErr
        identityErrorText = (Get-LctWin32Text -Code $idErr)
        canTerminate      = $canTerm
        terminateError    = $termErr
        terminateErrorText = (Get-LctWin32Text -Code $termErr)
    }
}

function Get-LctIdentityReport {
    # 如实上报当前身份：不自行创建 SYSTEM；需要 SYSTEM 时由用户走已有的提权插件
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $userName = ''; $sid = ''; $isSystem = $false
    try {
        $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -ne $wi) {
            $userName = [string]$wi.Name
            $isSystem = [bool]$wi.IsSystem
            try { $sid = [string]$wi.User.Value } catch { $sid = '' }
        }
    } catch { }
    $elevated = $false
    try { $elevated = [bool](Test-LctElevated) } catch { $elevated = $false }
    $integrity = ''; $ownErr = 0; $ownerFromToken = ''
    if (Initialize-LctProcNative) {
        try { $null = [LctProcNative]::Identity($me.Id, [ref]$ownerFromToken, [ref]$integrity, [ref]$ownErr) } catch { }
    }
    $mode = '以调用者当前权限运行（本工具不自行创建 SYSTEM 身份）'
    if ($elevated) { $mode = $mode + '；当前为提权会话' } else { $mode = $mode + '；当前未提权' }
    $sess = -1
    try { $sess = [int]$me.SessionId } catch { }
    return [pscustomobject][ordered]@{
        user = $userName; sid = $sid; isSystem = $isSystem; elevated = $elevated
        integrity = $integrity; pid = $me.Id; sessionId = $sess; mode = $mode
    }
}

function Resolve-LctProcessTarget {
    # 目标解析：pid 或「唯一的」进程名；禁止通配；-Path 作为额外身份校验（读不到路径就拒绝）
    param([int]$ProcId = 0, [string]$Name = '', [string]$Path = '')
    $errors = New-Object System.Collections.ArrayList
    $matches = New-Object System.Collections.ArrayList
    $wanted = ''
    if ($ProcId -gt 0) {
        $live = Get-LctProcLive -ProcId $ProcId
        if ($null -eq $live) {
            $err = 0
            $probe = $false
            if (Initialize-LctProcNative) { try { $probe = [bool][LctProcNative]::CanTerminate($ProcId, [ref]$err) } catch { $err = -1 } }
            $null = $errors.Add('进程不存在或已退出: pid=' + $ProcId + '（Get-Process 找不到该 pid）')
        } else {
            $null = $matches.Add($live)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        if ([string]$Name -match '[\*\?]') {
            $null = $errors.Add('禁止通配符目标: ' + $Name + '（本工具只处理显式指定的目标，不做批量）')
        } else {
            $wanted = ([string]$Name -replace '(?i)\.exe$', '').Trim()
            if ($wanted -eq '') {
                $null = $errors.Add('name 参数为空')
            } else {
                $cands = @()
                try { $cands = @(Get-Process -Name $wanted -ErrorAction Stop) } catch { $cands = @() }
                if (@($cands).Count -eq 0) {
                    $null = $errors.Add('未找到名为 ' + $Name + ' 的进程')
                } elseif (@($cands).Count -gt 1 -and $ProcId -le 0) {
                    $ids = @($cands | ForEach-Object { [string]$_.Id }) -join ','
                    $null = $errors.Add('名称 ' + $Name + ' 匹配到 ' + @($cands).Count + ' 个进程（pid=' + $ids + '）：请用 -Id 显式指定单个目标，本工具不做批量终止')
                } elseif (@($cands).Count -eq 1) {
                    $null = $matches.Add($cands[0])
                }
            }
        }
    }
    if ($ProcId -le 0 -and [string]::IsNullOrWhiteSpace($Name)) {
        $null = $errors.Add('缺少目标：必须显式指定 -Id 或 -Name（禁止「全部」/通配）')
    }

    # 身份复核：给了 -Path 就必须一致
    $single = $null
    if (@($matches).Count -eq 1) { $single = $matches[0] }
    if (@($matches).Count -gt 1) {
        $null = $errors.Add('目标解析到 ' + @($matches).Count + ' 个进程：拒绝继续（需要唯一目标）')
        $single = $null
    }

    $facts = $null
    $pathOk = $false
    $actualPath = ''
    if ($null -ne $single) {
        $facts = Get-LctProcNativeFacts -ProcId ([int]$single.Id)
        $actualPath = [string]$facts.path
        if (-not [string]::IsNullOrWhiteSpace([string]$Path)) {
            if ([string]::IsNullOrEmpty($actualPath)) {
                $null = $errors.Add('无法读取 pid=' + $single.Id + ' 的映像路径（' + $facts.pathErrorText + '）：无法用 -Path 校验身份，拒绝继续')
            } elseif (-not ($actualPath -ieq [string]$Path)) {
                $null = $errors.Add('身份不符：pid=' + $single.Id + ' 的映像路径是 ' + $actualPath + '，而 -Path 指定 ' + $Path)
            } elseif (Test-LctProcIsSelf -ProcId ([int]$single.Id)) {
                $null = $errors.Add('拒绝对当前进程自身（pid=' + $single.Id + '）执行终止')
            } else {
                $pathOk = $true
            }
        } else {
            if (Test-LctProcIsSelf -ProcId ([int]$single.Id)) {
                $null = $errors.Add('拒绝对当前进程自身（pid=' + $single.Id + '）执行终止')
            } else {
                $pathOk = $true
            }
        }
    }

    return [pscustomobject][ordered]@{
        ok          = ((@($errors).Count -eq 0) -and ($null -ne $single) -and $pathOk)
        errors      = @($errors)
        proc        = $single
        count       = @($matches).Count
        wantedName  = $wanted
        actualPath  = $actualPath
        facts       = $facts
    }
}

function Invoke-LctProcessTerminate {
    # 真正终止；如实返回失败原因（OpenProcess 错误码 / WMI 返回码），绝不假成功
    param([int]$ProcId, [string]$ExpectedName = '', [string]$ExpectedPath = '')
    $r = [ordered]@{
        ok = $false; method = ''; win32Error = 0; win32Message = ''
        wmiReturn = $null; nameVerified = $false; pathVerified = $false
        stillRunning = $true; note = ''
    }
    $live = Get-LctProcLive -ProcId $ProcId
    if ($null -eq $live) {
        $r.stillRunning = $false
        $r.note = '进程已不存在（无需终止）'
        return [pscustomobject]$r
    }
    if (Test-LctProcIsSelf -ProcId $ProcId) {
        $r.note = '拒绝终止当前进程自身'
        return [pscustomobject]$r
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedName)) {
        $want = ([string]$ExpectedName -replace '(?i)\.exe$', '').Trim()
        $r.nameVerified = ([string]$live.ProcessName -ieq $want)
    } else {
        $r.nameVerified = $true
    }
    $actualPath = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPath)) {
        $actualPath = [string](Get-LctProcPathOnly -ProcId $ProcId)
        $r.pathVerified = ($actualPath -ne '' -and ($actualPath -ieq [string]$ExpectedPath))
    } else {
        $r.pathVerified = $true
    }
    # 防 pid 复用：调用方给了期望身份，就必须先复核通过
    if (-not $r.nameVerified) {
        $r.note = 'pid 复用：当前进程名「' + [string]$live.ProcessName + '」与期望「' + $ExpectedName + '」不符，已拒绝终止'
        return [pscustomobject]$r
    }
    if (-not $r.pathVerified) {
        $r.note = 'pid 复用：当前映像路径与期望不符（当前=' + $(if ($actualPath) { $actualPath } else { '(读取失败)' }) + '），已拒绝终止'
        return [pscustomobject]$r
    }

    $killed = $false
    $err = 0
    if (Initialize-LctProcNative) {
        try { $killed = [bool][LctProcNative]::Kill($ProcId, 1, [ref]$err) } catch { $err = -1 }
    } else {
        $err = -2
    }
    if ($killed) {
        $r.method = 'OpenProcess(PROCESS_TERMINATE)+TerminateProcess'
    } else {
        $r.win32Error = $err
        $r.win32Message = Get-LctWin32Text -Code $err
        # 第二通道：WMI Terminate（给出独立证据；同样不会假成功）
        try {
            $wp = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $ProcId) -ErrorAction Stop
            if ($wp) {
                $o = Invoke-CimMethod -InputObject $wp -MethodName Terminate -ErrorAction Stop
                $r.wmiReturn = [int]$o.ReturnValue
                if ([int]$o.ReturnValue -eq 0) {
                    $killed = $true
                    $r.method = 'WMI Win32_Process.Terminate'
                }
            }
        } catch { $r.wmiReturn = -1 }
    }

    for ($i = 0; $i -lt 20; $i++) {
        if ($null -eq (Get-LctProcLive -ProcId $ProcId)) { $r.stillRunning = $false; break }
        Start-Sleep -Milliseconds 150
    }
    $r.ok = (-not $r.stillRunning)
    if ($r.ok -and $r.method -eq '') { $r.method = '(进程在终止调用期间自行退出)' }
    if (-not $r.ok -and $r.note -eq '') { $r.note = '终止调用已返回但进程仍存在' }
    return [pscustomobject]$r
}

function Get-LctProcPathOnly {
    param([int]$ProcId)
    if (-not (Initialize-LctProcNative)) { return '' }
    $err = 0
    $p = ''
    try { $p = [string][LctProcNative]::ImagePath($ProcId, [ref]$err) } catch { $p = '' }
    return $p
}
#endregion

#region 看门狗日志与 runspace 循环源码
function Get-LctWatchLogDir {
    $logsDir = ''
    try { $logsDir = Join-Path (Get-LctVarDir) 'logs' } catch { $logsDir = '' }
    if ([string]::IsNullOrWhiteSpace($logsDir)) {
        $logsDir = Join-Path (Join-Path (Split-Path -Parent $script:LctCoreDir) 'var') 'logs'
    }
    if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }
    return $logsDir
}

function Get-LctWatchLogPath {
    param([string]$Date = '')
    if ([string]::IsNullOrWhiteSpace($Date)) { $Date = (Get-Date -Format 'yyyyMMdd') }
    return (Join-Path (Get-LctWatchLogDir) ('process-watch-' + $Date + '.log'))
}

$script:LctWatchLoopSource = @'
param($state)
$ErrorActionPreference = 'Continue'
$enc = New-Object System.Text.UTF8Encoding($false)
if (-not ([System.Management.Automation.PSTypeName]'LctWatchNative').Type) {
    Add-Type -TypeDefinition $state.nativeSource -ErrorAction SilentlyContinue
}
function ConvertTo-WatchJsonString {
    param([string]$Text)
    if ($null -eq $Text) { return '""' }
    $s = [string]$Text
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return ('"' + $s + '"')
}
function Write-WatchEvent {
    param([string]$Kind, [string]$Detail, [string]$TargetName = '', [int]$TargetPid = 0)
    $line = '{"ts":' + (ConvertTo-WatchJsonString ([DateTime]::Now.ToString('s'))) +
        ',"event":' + (ConvertTo-WatchJsonString $Kind) +
        ',"target":' + (ConvertTo-WatchJsonString $TargetName) +
        ',"pid":' + $TargetPid +
        ',"detail":' + (ConvertTo-WatchJsonString $Detail) + '}'
    try { [IO.File]::AppendAllText($state.logPath, $line + [Environment]::NewLine, $enc) } catch { }
    $state.events = [int]$state.events + 1
    $state.lastEvent = $Kind
    $state.lastDetail = $Detail
}
try {
    Write-WatchEvent -Kind 'watch.started' -Detail ('看门狗启动：interval=' + $state.intervalSec + 's duration=' + $state.durationSec + 's targets=' + @($state.targets).Count + ' override=' + $state.allowCritical)
    $ownPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $deadline = [DateTime]::Now.AddSeconds([int]$state.durationSec)
    $first = $true
    while (-not $state.stop) {
        if (-not $first) {
            $waited = 0.0
            while ($waited -lt ([int]$state.intervalSec) -and (-not $state.stop)) {
                [System.Threading.Thread]::Sleep(200)
                $waited = $waited + 0.2
            }
        }
        $first = $false
        if ($state.stop) { break }
        foreach ($t in @($state.targets)) {
            if ($state.stop) { break }
            if ((-not $state.allowCritical) -and ($t.isCritical -eq $true)) {
                Write-WatchEvent -Kind 'guard.critical' -Detail '目标在关键/安全软件名单内且未授权（-Override），看门狗跳过' -TargetName ([string]$t.name)
                continue
            }
            $procs = @()
            try { $procs = @([System.Diagnostics.Process]::GetProcessesByName([string]$t.name)) } catch { $procs = @() }
            foreach ($p in $procs) {
                try {
                    $curId = [int]$p.Id
                    if ($curId -eq $ownPid) { continue }
                    if ($t.path) {
                        $perr = 0
                        $actual = ''
                        try { $actual = [string][LctWatchNative]::ImagePath($curId, [ref]$perr) } catch { $actual = '' }
                        if (($actual -eq '') -or (-not ($actual -ieq [string]$t.path))) {
                            $state.skipped = [int]$state.skipped + 1
                            if ($actual -eq '') { $why = '路径读取失败（Win32 ' + $perr + '）' } else { $why = '路径不符：' + $actual }
                            Write-WatchEvent -Kind 'identity.skip' -Detail ('身份复核未通过，跳过（防 pid 复用误杀）：' + $why) -TargetName ([string]$t.name) -TargetPid $curId
                            continue
                        }
                    }
                    $kerr = 0
                    $ok = $false
                    try { $ok = [bool][LctWatchNative]::Kill($curId, [ref]$kerr) } catch { $kerr = -1 }
                    if ($ok) {
                        $state.kills = [int]$state.kills + 1
                        Write-WatchEvent -Kind 'kill.ok' -Detail ('已终止 pid=' + $curId) -TargetName ([string]$t.name) -TargetPid $curId
                    } else {
                        $state.failures = [int]$state.failures + 1
                        $state.lastError = 'Win32 ' + $kerr
                        $extra = ''
                        if ($kerr -eq 5) { $extra = '（拒绝访问：受保护/权限不足）' }
                        if ($kerr -eq 87) { $extra = '（进程已退出）' }
                        Write-WatchEvent -Kind 'kill.fail' -Detail ('终止失败：Win32 ' + $kerr + $extra) -TargetName ([string]$t.name) -TargetPid $curId
                    }
                } finally {
                    try { $p.Dispose() } catch { }
                }
            }
        }
        if ([DateTime]::Now -ge $deadline) { break }
    }
    if ($state.stop) { Write-WatchEvent -Kind 'watch.stopped' -Detail '收到停止请求，看门狗退出' }
    else { Write-WatchEvent -Kind 'watch.timeout' -Detail ('到达时长上限 ' + $state.durationSec + 's，看门狗自行结束') }
} catch {
    $state.lastError = [string]$_.Exception.Message
    try { Write-WatchEvent -Kind 'watch.error' -Detail ('看门狗异常：' + $_.Exception.Message) } catch { }
} finally {
    $state.running = $false
    $state.endedAt = [DateTime]::Now.ToString('s')
}
'@
#endregion

#region 注册表辅助（IFEO 用；键删除只用 Remove-LctRegistryKeyTree）
function ConvertTo-LctRegLoc {
    param([string]$Path)
    $m = [regex]::Match([string]$Path, '^\s*(HKCU|HKEY_CURRENT_USER|HKLM|HKEY_LOCAL_MACHINE)\s*[\\:]\s*(.*)$')
    if (-not $m.Success) { throw ('不支持的注册表路径（只支持 HKCU:/HKLM:）: ' + $Path) }
    $h = $m.Groups[1].Value.ToUpperInvariant()
    $sub = ($m.Groups[2].Value -replace '/', '\').Trim('\')
    if ([string]::IsNullOrEmpty($sub)) { throw ('拒绝操作配置单元根: ' + $Path) }
    if (($h -eq 'HKCU') -or ($h -eq 'HKEY_CURRENT_USER')) {
        $hive = [Microsoft.Win32.Registry]::CurrentUser; $hn = 'HKCU'
    } else {
        $hive = [Microsoft.Win32.Registry]::LocalMachine; $hn = 'HKLM'
    }
    return [pscustomobject][ordered]@{
        hive = $hive; hiveName = $hn; subKey = $sub; normalized = ($hn + ':\' + $sub)
    }
}

function Get-LctRegStringValue {
    param($Loc, [string]$Name)
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $false) } catch { $k = $null }
    if ($null -eq $k) { return [pscustomobject][ordered]@{ keyExists = $false; exists = $false; value = $null } }
    try {
        $found = $false; $shown = $Name
        foreach ($n in @($k.GetValueNames())) { if ([string]$n -ieq $Name) { $found = $true; $shown = [string]$n; break } }
        if (-not $found) { return [pscustomobject][ordered]@{ keyExists = $true; exists = $false; value = $null } }
        $v = $null
        try { $v = $k.GetValue($shown, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { $v = $null }
        return [pscustomobject][ordered]@{ keyExists = $true; exists = $true; value = $v }
    } finally { $k.Close() }
}

function Set-LctRegStringValue {
    param($Loc, [string]$Name, [string]$Value)
    $k = $null
    try { $k = $Loc.hive.CreateSubKey($Loc.subKey) } catch { throw ('无法创建/打开注册表键 ' + $Loc.normalized + '：' + $_.Exception.Message) }
    if ($null -eq $k) { throw ('无法创建/打开注册表键: ' + $Loc.normalized) }
    try { $k.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $k.Close() }
}

function Remove-LctRegValueOnly {
    # 只删值，不删键（键删除必须走 Remove-LctRegistryKeyTree）
    param($Loc, [string]$Name)
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $true) } catch { $k = $null }
    if ($null -eq $k) { return $false }
    try {
        $k.DeleteValue($Name, $false)
        return $true
    } finally { $k.Close() }
}

function Test-LctRegKeyEmpty {
    param($Loc)
    $k = $null
    try { $k = $Loc.hive.OpenSubKey($Loc.subKey, $false) } catch { $k = $null }
    if ($null -eq $k) { return $true }
    try {
        if (@($k.GetValueNames()).Count -gt 0) { return $false }
        if (@($k.GetSubKeyNames()).Count -gt 0) { return $false }
        return $true
    } finally { $k.Close() }
}

$script:LctIfeoSub = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:LctIfeoSub32 = 'SOFTWARE\Wow6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:LctBlockMarkers = @('LctBlockReason', 'LctBlockSetAt', 'LctBlockBy', 'LctBlockTargetPath')
$script:LctDefaultBlocker = 'C:\Windows\System32\LctBlocked.exe'
if ($env:SystemRoot) { $script:LctDefaultBlocker = Join-Path $env:SystemRoot 'System32\LctBlocked.exe' }

function Get-LctIfeoViews {
    # HKLM 必须同时覆盖原生视图与 Wow6432Node 视图；HKCU 只用于测试/演示（Windows 只认 HKLM 的 IFEO）
    param([string]$ExeName, [string]$Hive = 'HKLM')
    $views = New-Object System.Collections.ArrayList
    if ($Hive -eq 'HKCU') {
        $sub = $script:LctIfeoSub + '\' + $ExeName
        $null = $views.Add([pscustomobject][ordered]@{
            hive = 'HKCU'; view = 'native'; keyPath = ('HKCU:\' + $sub); honored = $false
        })
    } else {
        $sub = $script:LctIfeoSub + '\' + $ExeName
        $null = $views.Add([pscustomobject][ordered]@{
            hive = 'HKLM'; view = 'native'; keyPath = ('HKLM:\' + $sub); honored = $true
        })
        $sub32 = $script:LctIfeoSub32 + '\' + $ExeName
        $null = $views.Add([pscustomobject][ordered]@{
            hive = 'HKLM'; view = 'wow6432'; keyPath = ('HKLM:\' + $sub32); honored = $true
        })
    }
    return @($views)
}

function Get-LctIfeoViewState {
    param($View)
    $loc = ConvertTo-LctRegLoc -Path $View.keyPath
    $keyExists = (Test-Path -LiteralPath $View.keyPath)
    $d = Get-LctRegStringValue -Loc $loc -Name 'Debugger'
    $marker = Get-LctRegStringValue -Loc $loc -Name 'LctBlockReason'
    $setAt = Get-LctRegStringValue -Loc $loc -Name 'LctBlockSetAt'
    $setBy = Get-LctRegStringValue -Loc $loc -Name 'LctBlockBy'
    $tPath = Get-LctRegStringValue -Loc $loc -Name 'LctBlockTargetPath'
    return [pscustomobject][ordered]@{
        loc             = $loc
        keyPath         = $View.keyPath
        hive            = $View.hive
        view            = $View.view
        honored         = $View.honored
        keyExists       = $keyExists
        debuggerExists  = [bool]$d.exists
        debuggerValue   = [string]$d.value
        byUs            = [bool]$marker.exists
        markerReason    = [string]$marker.value
        markerSetAt     = [string]$setAt.value
        markerSetBy     = [string]$setBy.value
        markerTarget    = [string]$tPath.value
    }
}

function Restore-LctIfeoView {
    # 把某个 IFEO 视图回滚到写前状态
    param($Loc, [bool]$KeyExistedBefore, [bool]$DebuggerExistedBefore, [string]$DebuggerBeforeValue)
    try {
        if (-not $KeyExistedBefore) {
            $null = Remove-LctRegistryKeyTree -Path $Loc.normalized
            return $true
        }
        foreach ($mn in @($script:LctBlockMarkers)) { $null = Remove-LctRegValueOnly -Loc $Loc -Name $mn }
        if ($DebuggerExistedBefore) {
            Set-LctRegStringValue -Loc $Loc -Name 'Debugger' -Value $DebuggerBeforeValue
        } else {
            $null = Remove-LctRegValueOnly -Loc $Loc -Name 'Debugger'
        }
        return $true
    } catch { return $false }
}
#endregion

#region 导出：进程快照 / 详情 / 终止

function Get-LctProcessList {
    <#
    .SYNOPSIS process.list：进程快照（pid/name/user/session/path/wsMB/cpu/startTime/是否关键进程）。
    .DESCRIPTION -IncludeSystem 才包含会话 0（服务/系统）进程（默认隐藏）；-Name 支持 -like 通配（只读过滤）；
                 -User 按属主子串过滤；每行都带 terminateAccess 实测结论（能否 OpenProcess(PROCESS_TERMINATE)）。
                 该写操作会同时上报调用者身份（identity），不自行创建 SYSTEM。
    #>
    param(
        [string]$Name = '',
        [string]$User = '',
        [switch]$IncludeSystem,
        $Limit = 200,
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'process.list'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $limitN = ConvertTo-LctIntSafe -Value $Limit -Default 200

    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
        if ([string]::IsNullOrWhiteSpace($User)) { $User = [string](Get-LctArgFrom -Args $ArgBag -Key 'user' -Default '') }
        if (-not $IncludeSystem) { $IncludeSystem = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'includeSystem') }
        $lim = Get-LctArgFrom -Args $ArgBag -Key 'limit'
        if ($null -ne $lim) { $limitN = ConvertTo-LctIntSafe -Value $lim -Default $limitN }
    }
    if ($limitN -le 0) { $limitN = 200 }
    if ($limitN -gt 2000) { $limitN = 2000; $null = $warnings.Add('Limit 上限 2000，已按 2000 处理。') }

    $all = @(Get-Process -ErrorAction SilentlyContinue)
    $rows = New-Object System.Collections.ArrayList
    $skippedSession0 = 0
    foreach ($pr in $all) {
        $pName = [string]$pr.ProcessName
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            if (-not (($pName -like $Name) -or (($pName + '.exe') -like $Name))) { continue }
        }
        $sess = -1
        try { $sess = [int]$pr.SessionId } catch { $sess = -1 }
        if ((-not $IncludeSystem) -and ($sess -eq 0)) { $skippedSession0++; continue }
        $facts = Get-LctProcNativeFacts -ProcId ([int]$pr.Id)
        $owner = [string]$facts.owner
        if (-not [string]::IsNullOrWhiteSpace($User)) {
            if (-not ($owner -like ('*' + $User + '*'))) { continue }
        }
        $ws = 0.0
        try { $ws = [double]$pr.WorkingSet64 } catch { $ws = 0.0 }
        $cpu = $null
        try { $cpu = [double]$pr.CPU } catch { $cpu = $null }
        $null = $rows.Add([pscustomobject][ordered]@{
            pid              = [int]$pr.Id
            name             = $pName
            user             = $owner
            session          = $sess
            path             = [string]$facts.path
            wsMB             = [math]::Round(($ws / 1MB), 1)
            cpu              = $cpu
            startTime        = (Get-LctProcStartText -Proc $pr)
            isCritical       = (Test-LctProcCritical -ProcName $pName)
            integrity        = [string]$facts.integrity
            canTerminate     = [bool]$facts.canTerminate
            terminateError   = [int]$facts.terminateError
            pathError        = [int]$facts.pathError
        })
    }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { $_.wsMB }; Descending = $true })
    $truncated = (@($sorted).Count -gt $limitN)
    $items = @($sorted | Select-Object -First $limitN)

    $identity = Get-LctIdentityReport
    if (-not $IncludeSystem) { $null = $warnings.Add('默认隐藏会话 0（服务/系统）进程 ' + $skippedSession0 + ' 个；需要时加 -IncludeSystem。') }
    if (-not $identity.elevated) { $null = $warnings.Add('当前进程未提权：属主/映像路径/终止能力可能读取失败是预期现象。') }
    if (-not (Initialize-LctProcNative)) { $null = $warnings.Add('原生 API 不可用，已退化为托管读取：' + $script:LctNativeError) }
    if ($truncated) { $null = $warnings.Add('结果被 Limit=' + $limitN + ' 截断（匹配 ' + @($sorted).Count + ' 个）。') }

    $data = [pscustomobject][ordered]@{
        identity       = $identity
        items          = $items
        count          = @($items).Count
        matched        = @($sorted).Count
        truncated      = $truncated
        limit          = $limitN
        includeSystem  = [bool]$IncludeSystem
        filters        = [pscustomobject][ordered]@{ name = $Name; user = $User }
        processTotal   = @($all).Count
        session0Hidden = $skippedSession0
    }
    $log = Write-LctQuiet -Verb $verb -Level info -Message ('进程快照：返回 ' + @($items).Count + ' 个（匹配 ' + @($sorted).Count + '）') `
        -Data @{ user = $identity.user; elevated = $identity.elevated; name = $Name; includeSystem = [bool]$IncludeSystem }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

function Get-LctProcessDetail {
    <#
    .SYNOPSIS process.detail：单进程详情 + 能否取得 PROCESS_TERMINATE 的**实测**结论。
    .DESCRIPTION 结论字段 terminate.canTerminate / win32Error / win32Message / conclusion；
                 access denied(5) 与 pid 不存在(87) 严格区分；受保护进程会给出 suspectedProtected。
    #>
    param(
        $Id = $null,
        [string]$Name = '',
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'process.detail'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $procId = ConvertTo-LctIntSafe -Value $Id -Default 0
    if ($null -ne $ArgBag) {
        if ($procId -le 0) { $procId = ConvertTo-LctIntSafe -Value (Get-LctArgFrom -Args $ArgBag -Key 'id' -Default 0) -Default 0 }
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
    }
    if (($procId -le 0) -and [string]::IsNullOrWhiteSpace($Name)) {
        $null = $errors.Add('缺少目标：process.detail 需要 id（或唯一的 name）')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.detail 缺少目标'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }
    $res = Resolve-LctProcessTarget -ProcId $procId -Name $Name -Path ''
    if (-not $res.ok) {
        foreach ($e in @($res.errors)) { $null = $errors.Add($e) }
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.detail 目标解析失败' -Data @{ id = $procId; name = $Name }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }
    $pr = $res.proc
    $facts = $res.facts
    $pName = [string]$pr.ProcessName
    $isCritical = Test-LctProcCritical -ProcName $pName
    $suspectedProtected = $false
    if ($isCritical) { $suspectedProtected = $true }
    if (($facts.terminateError -eq 5) -or ($facts.pathError -eq 5) -or ($facts.identityError -eq 5)) { $suspectedProtected = $true }
    if ([string]$facts.integrity -match '^(System|Protected)$') { $suspectedProtected = $true }

    $conclusion = ''
    if ($facts.canTerminate) {
        $conclusion = 'PROCESS_TERMINATE 可用：OpenProcess 成功（实际 TerminateProcess 仍可能被执行体里的保护逻辑拒绝）'
    } else {
        $conclusion = 'PROCESS_TERMINATE 不可用：' + $facts.terminateErrorText
        if ($facts.terminateError -eq 5) { $conclusion = $conclusion + '；这是权限/保护问题，不是「进程不存在」' }
        if ($facts.terminateError -eq 87) { $conclusion = 'PROCESS_TERMINATE 不可用：该 pid 已不存在（进程已退出）' }
    }

    $cmdLine = ''
    try {
        $wp = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [int]$pr.Id) -ErrorAction Stop
        if ($wp) { $cmdLine = [string]$wp.CommandLine }
    } catch { $null = $warnings.Add('无法读取命令行（CIM 查询失败）：' + $_.Exception.Message) }

    $sess = -1
    try { $sess = [int]$pr.SessionId } catch { $sess = -1 }
    $ws = 0.0
    try { $ws = [double]$pr.WorkingSet64 } catch { $ws = 0.0 }
    $cpu = $null
    try { $cpu = [double]$pr.CPU } catch { $cpu = $null }

    $data = [pscustomobject][ordered]@{
        pid                = [int]$pr.Id
        name               = $pName
        path               = [string]$facts.path
        pathError          = [int]$facts.pathError
        pathErrorText      = [string]$facts.pathErrorText
        commandLine        = $cmdLine
        user               = [string]$facts.owner
        integrity          = [string]$facts.integrity
        session            = $sess
        wsMB               = [math]::Round(($ws / 1MB), 1)
        cpu                = $cpu
        startTime          = (Get-LctProcStartText -Proc $pr)
        isCritical         = $isCritical
        criticalList       = @(Get-LctCriticalProcessPatterns)
        suspectedProtected = $suspectedProtected
        identityError      = [int]$facts.identityError
        identityErrorText  = [string]$facts.identityErrorText
        terminate          = [pscustomobject][ordered]@{
            canTerminate = [bool]$facts.canTerminate
            win32Error   = [int]$facts.terminateError
            win32Message = [string]$facts.terminateErrorText
            conclusion   = $conclusion
        }
    }
    if ($isCritical) { $null = $warnings.Add('目标是关键/安全软件名单成员（' + $pName + '）：终止需要 -Override，且用户态可能永远无法终止（PPL/受保护进程）。') }
    if ((Initialize-LctProcNative) -eq $false) { $null = $warnings.Add('原生 API 不可用，终止结论为退化推断：' + $script:LctNativeError) }
    $log = Write-LctQuiet -Verb $verb -Level info -Message ('进程详情 pid=' + $pr.Id + ' ' + $pName) `
        -Data @{ canTerminate = [bool]$facts.canTerminate; win32Error = [int]$facts.terminateError; integrity = [string]$facts.integrity }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

function Stop-LctProcess {
    <#
    .SYNOPSIS process.kill：终止显式指定的单个进程（默认预览，-Apply 才真杀）。
    .DESCRIPTION 关键/安全软件名单必须 -Override；失败时如实返回 OpenProcess 的 Win32 原因。
                 一次只处理一个目标：-Name 必须唯一匹配，禁止通配与批量。
    #>
    param(
        $Id = $null,
        [string]$Name = '',
        [string]$Path = '',
        [switch]$Override,
        [switch]$Apply,
        [Alias('Args')][object]$ArgBag = $null
    )
    $verb = 'process.kill'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    $procId = ConvertTo-LctIntSafe -Value $Id -Default 0

    if ($null -ne $ArgBag) {
        if ($procId -le 0) { $procId = ConvertTo-LctIntSafe -Value (Get-LctArgFrom -Args $ArgBag -Key 'id' -Default 0) -Default 0 }
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = [string](Get-LctArgFrom -Args $ArgBag -Key 'name' -Default '') }
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        if (-not $Override) { $Override = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'override') }
        if (-not $Apply) { $Apply = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') }
    }

    $res = Resolve-LctProcessTarget -ProcId $procId -Name $Name -Path $Path
    if (-not $res.ok) {
        foreach ($e in @($res.errors)) { $null = $errors.Add($e) }
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.kill 目标解析失败' -Data @{ id = $procId; name = $Name; path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                target = [pscustomobject][ordered]@{ pid = $procId; name = $Name; path = $Path }; killed = $false; applied = $false
            }) -Log $log
    }
    $pr = $res.proc
    $facts = $res.facts
    $pName = [string]$pr.ProcessName
    $targetPath = [string]$facts.path
    $isCritical = Test-LctProcCritical -ProcName $pName

    # 注意：参数值里的字符串拼接必须整体加括号，否则简单函数会把多余实参吞进自动变量（契约 §10.8 同源陷阱）
    $change = New-LctProcChangeEntry -Kind 'note' -Target ('pid=' + [int]$pr.Id + ' ' + $pName) -Name '<process>' `
        -Before ('(运行中 pid=' + [int]$pr.Id + ')') -After '(预览：将终止)' -Note $(if ($Apply) { '' } else { '未加 -Apply，仅预览' })
    $null = $changes.Add($change)

    $criticalWarn = '目标是关键/安全软件名单成员（' + $pName + '）：默认拒绝终止，必须显式 -Override；用户态可能永远无法终止（PPL/受保护进程）。'
    if ($isCritical) {
        if (-not $Override) {
            $null = $errors.Add($criticalWarn)
            $null = $warnings.Add($criticalWarn)
            $log = Write-LctQuiet -Verb $verb -Level warn -Message ('process.kill 拒绝关键进程（未加 -Override）：' + $pName) `
                -Data @{ pid = [int]$pr.Id; name = $pName; user = (Get-LctIdentityReport).user }
            return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                    target = [pscustomobject][ordered]@{ pid = [int]$pr.Id; name = $pName; path = $targetPath; user = [string]$facts.owner; isCritical = $true }
                    killed = $false; refused = $true; reason = $criticalWarn
                }) -Log $log
        }
        $null = $warnings.Add($criticalWarn)
        $null = $warnings.Add('已使用 -Override 授权终止关键/安全软件目标；该决定已写入审计日志。')
        Write-LctQuiet -Verb $verb -Level warn -Message ('process.kill 使用 -Override 终止关键目标：' + $pName + ' pid=' + [int]$pr.Id) `
            -Data @{ user = (Get-LctIdentityReport).user; elevated = (Get-LctIdentityReport).elevated } | Out-Null
    }
    if (-not (Get-LctIdentityReport).elevated) {
        $null = $warnings.Add('当前进程未提权：对其它用户/服务进程的终止很可能失败（错误码 5）。')
    }

    $targetInfo = [pscustomobject][ordered]@{
        pid = [int]$pr.Id; name = $pName; path = $targetPath; user = [string]$facts.owner
        integrity = [string]$facts.integrity; startTime = (Get-LctProcStartText -Proc $pr); isCritical = $isCritical
    }
    $termTest = [pscustomobject][ordered]@{
        canTerminate = [bool]$facts.canTerminate
        win32Error   = [int]$facts.terminateError
        win32Message = [string]$facts.terminateErrorText
    }

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message ('预览 process.kill ' + $pName + ' pid=' + [int]$pr.Id) `
            -Data @{ pid = [int]$pr.Id; name = $pName; canTerminate = [bool]$facts.canTerminate; win32Error = [int]$facts.terminateError }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                target = $targetInfo; killed = $false; applied = $false; terminate = $termTest
            }) -Log $log
    }

    # ---- 先备份（契约 §7.2）----
    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{
                pid = [int]$pr.Id; name = $pName; path = $targetPath; override = [bool]$Override
            })
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add('创建备份失败，已取消终止: ' + $_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.kill 备份失败，未终止' -Data @{ pid = [int]$pr.Id; name = $pName }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) `
            -Data ([pscustomobject][ordered]@{ target = $targetInfo; killed = $false; terminate = $termTest }) -Log $log
    }

    $kill = Invoke-LctProcessTerminate -ProcId ([int]$pr.Id) -ExpectedName $pName -ExpectedPath $targetPath
    if ($kill.ok) {
        $change.after = '(已终止)'
        $change.note = '方式: ' + $kill.method
    } else {
        $change.after = '(仍运行：终止失败)'
        $change.note = '方式: ' + $kill.method + '；' + $kill.note
        $null = $errors.Add(('终止失败 pid=' + [int]$pr.Id + ' ' + $pName + '：' + $kill.win32Message +
                $(if ($null -ne $kill.wmiReturn) { '；WMI Terminate 返回码=' + $kill.wmiReturn } else { '' }) + '。' + $kill.note))
    }

    $appliedFlag = ($Apply -and $kill.ok -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message ('process.kill ' + $pName + ' pid=' + [int]$pr.Id + ' 结果=' + $kill.ok) `
        -Data @{ pid = [int]$pr.Id; name = $pName; ok = [bool]$kill.ok; method = $kill.method; win32Error = [int]$kill.win32Error; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId `
        -Data ([pscustomobject][ordered]@{
            target = $targetInfo; killed = [bool]$kill.ok; applied = $appliedFlag
            terminate = [pscustomobject][ordered]@{
                canTerminate = [bool]$facts.canTerminate; win32Error = [int]$kill.win32Error; win32Message = [string]$kill.win32Message
                wmiReturn = $kill.wmiReturn; method = $kill.method; stillRunning = [bool]$kill.stillRunning; note = $kill.note
            }
        }) -Log $log
}
#endregion

#region 导出：会话内看门狗（只在当前进程 runspace 内循环，不落地任何持久化）
function ConvertTo-LctWatchPlan {
    param($Targets = @(), [switch]$Override)
    $errors = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    $seen = @{}
    $list = @($Targets)
    if (@($list).Count -eq 0) { $null = $errors.Add('缺少 targets：必须显式指定目标（pid 或 name），禁止通配/全部') }
    foreach ($t in $list) {
        if ($null -eq $t) { continue }
        $wantId = 0; $wantName = ''; $wantPath = ''
        if (($t -is [int]) -or ($t -is [long])) { $wantId = [int]$t }
        elseif ($t -is [string]) {
            $s = [string]$t
            if ($s -match '^\d+$') { $wantId = [int]$s } else { $wantName = $s }
        } else {
            $wantId = ConvertTo-LctIntSafe -Value (Get-LctArgFrom -Args $t -Key 'pid' -Default 0) -Default 0
            $wantName = [string](Get-LctArgFrom -Args $t -Key 'name' -Default '')
            $wantPath = [string](Get-LctArgFrom -Args $t -Key 'path' -Default '')
        }
        if (($wantId -le 0) -and [string]::IsNullOrWhiteSpace($wantName)) {
            $null = $errors.Add('目标必须显式给出 pid 或 name')
            continue
        }
        $res = Resolve-LctProcessTarget -ProcId $wantId -Name $wantName -Path $wantPath
        if (-not $res.ok) {
            foreach ($e in @($res.errors)) { $null = $errors.Add($e) }
            continue
        }
        $pr = $res.proc
        $pName = [string]$pr.ProcessName
        $pPath = [string]$res.facts.path
        $key = $pName.ToLowerInvariant() + '|' + $pPath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $isCritical = Test-LctProcCritical -ProcName $pName
        if ($isCritical -and (-not $Override)) {
            $null = $errors.Add('目标 ' + $pName + '（pid=' + [int]$pr.Id + '）在关键/安全软件名单内：看门狗默认拒绝监控，如确需请加 -Override')
            continue
        }
        $null = $plan.Add([pscustomobject][ordered]@{
            name       = $pName
            pid        = [int]$pr.Id
            path       = $pPath
            user       = [string]$res.facts.owner
            isCritical = $isCritical
            startTime  = (Get-LctProcStartText -Proc $pr)
        })
    }
    return [pscustomobject][ordered]@{ errors = @($errors); targets = @($plan) }
}

function Start-LctProcessWatch {
    <#
    .SYNOPSIS process.watch.start：会话内看门狗（被杀后复活再杀）。
    .DESCRIPTION 默认只预览；-Apply 才真正启动。目标必须显式（pid 或唯一 name）。
                 只在当前进程的 runspace 内循环：不装服务/不注册任务/不写自启/不隐藏，当前进程退出即停。
                 重杀前按 name+path 复核身份（防 pid 复用误杀）。事件写 var\logs\process-watch-<日期>.log。
    #>
    param(
        [object[]]$Targets = @(),
        $IntervalSec = 2,
        $DurationSec = 300,
        [switch]$Override,
        [switch]$Apply,
        [Alias('Args')][object]$ArgBag = $null
    )
    $verb = 'process.watch.start'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $interval = ConvertTo-LctIntSafe -Value $IntervalSec -Default 2
    $duration = ConvertTo-LctIntSafe -Value $DurationSec -Default 300

    if ($null -ne $ArgBag) {
        if (@($Targets).Count -eq 0) { $Targets = @(Get-LctArgFrom -Args $ArgBag -Key 'targets' -Default @()) }
        $iv = Get-LctArgFrom -Args $ArgBag -Key 'intervalSec'
        if ($null -ne $iv) { $interval = ConvertTo-LctIntSafe -Value $iv -Default $interval }
        $dv = Get-LctArgFrom -Args $ArgBag -Key 'durationSec'
        if ($null -ne $dv) { $duration = ConvertTo-LctIntSafe -Value $dv -Default $duration }
        if (-not $Override) { $Override = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'override') }
        if (-not $Apply) { $Apply = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') }
    }
    $Targets = @($Targets | Where-Object { $null -ne $_ })

    if ($interval -lt 1) {
        $null = $errors.Add('IntervalSec 必须 >= 1 秒（收到 ' + $interval + '）')
    }
    if ($duration -lt 1) { $duration = 300 }
    if ($duration -gt 3600) {
        $duration = 3600
        $null = $warnings.Add('DurationSec 上限 3600 秒，已按 3600 处理。')
    }

    # 单实例
    $existing = $script:LctWatch
    $alreadyRunning = $false
    if ($null -ne $existing) {
        $st = $existing.State
        $inv = ''
        try { $inv = [string]$existing.PowerShell.InvocationStateInfo.State } catch { $inv = '' }
        if ((-not [bool]$st.stop) -and ([string]$st.endedAt -eq '') -and (@('Completed', 'Stopped', 'Failed') -notcontains $inv)) {
            $alreadyRunning = $true
        } else {
            $script:LctWatch = $null
        }
    }
    if ($alreadyRunning) { $null = $errors.Add('已有看门狗在运行：本模块只允许单实例，请先 Stop-LctProcessWatch。') }

    $wplan = ConvertTo-LctWatchPlan -Targets $Targets -Override:$Override
    foreach ($e in @($wplan.errors)) { $null = $errors.Add($e) }

    $logPath = Get-LctWatchLogPath
    $endsAt = ''
    if (@($wplan.targets).Count -gt 0) { $endsAt = (Get-Date).AddSeconds($duration).ToString('s') }

    foreach ($t in @($wplan.targets)) {
        $null = $changes.Add((New-LctProcChangeEntry -Kind 'note' -Target ('pid=' + $t.pid + ' ' + $t.name) -Name '<process-watch>' `
                    -Before '(当前运行中)' -After '(看门狗将反复终止其复活实例)' `
                    -Note $(if ($Apply) { '' } else { '未加 -Apply，仅预览' })))
    }
    if ($Override -and (@($wplan.targets | Where-Object { $_.isCritical }).Count -gt 0)) {
        $null = $warnings.Add('看门狗目标包含关键/安全软件（已 -Override 授权）；该决定已写入审计日志。')
        Write-LctQuiet -Verb $verb -Level warn -Message 'process.watch.start 使用 -Override 监控关键目标' `
            -Data @{ targets = @($wplan.targets | Where-Object { $_.isCritical }) } | Out-Null
    }
    foreach ($t in @($wplan.targets)) {
        if ([string]::IsNullOrEmpty([string]$t.path)) { $null = $warnings.Add('目标 ' + $t.name + ' 的映像路径读取失败：身份复核只能靠进程名，存在同名误杀风险。') }
    }

    $planData = [pscustomobject][ordered]@{
        running      = $false
        applied      = $false
        intervalSec  = $interval
        durationSec  = $duration
        endsAt       = $endsAt
        targets      = @($wplan.targets)
        override     = [bool]$Override
        logPath      = $logPath
        persistence  = '仅当前进程内 runspace 循环：不装服务/不注册任务/不写自启动/不隐藏，进程退出即停'
    }

    if ($errors.Count -gt 0) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.watch.start 被拒绝' -Data @{ errors = @($errors) }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }
    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message ('预览 process.watch.start targets=' + @($wplan.targets).Count)
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    # ---- 真正启动（当前进程内 runspace）----
    $state = [hashtable]::Synchronized(@{})
    $state.stop = $false
    $state.running = $true
    $state.kills = 0
    $state.failures = 0
    $state.skipped = 0
    $state.events = 0
    $state.startedAt = (Get-Date).ToString('s')
    $state.endedAt = ''
    $state.lastEvent = ''
    $state.lastDetail = ''
    $state.lastError = ''
    $state.intervalSec = $interval
    $state.durationSec = $duration
    $state.until = $endsAt
    $state.logPath = $logPath
    $state.allowCritical = [bool]$Override
    $state.nativeSource = $script:LctWatchNativeSource
    $state.targets = @($wplan.targets | ForEach-Object {
            @{ name = [string]$_.name; path = [string]$_.path; pid = [int]$_.pid; isCritical = [bool]$_.isCritical }
        })
    $state.owner = (Get-LctIdentityReport).user

    $rs = $null
    $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:LctWatchLoopSource).AddArgument($state)
        $handle = $ps.BeginInvoke()
    } catch {
        $null = $errors.Add('启动看门狗 runspace 失败: ' + $_.Exception.Message)
        try { if ($ps) { $ps.Dispose() } } catch { }
        try { if ($rs) { $rs.Dispose() } } catch { }
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.watch.start runspace 启动失败'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    $script:LctWatch = [pscustomobject][ordered]@{
        PowerShell = $ps; Runspace = $rs; Handle = $handle; State = $state
    }
    $planData.running = $true
    $planData.applied = $true
    $log = Write-LctQuiet -Verb $verb -Level change -Message ('已启动 process.watch.start targets=' + @($wplan.targets).Count + ' interval=' + $interval + 's duration=' + $duration + 's') `
        -Data @{ targets = @($wplan.targets); interval = $interval; duration = $duration; logPath = $logPath; override = [bool]$Override }
    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
}

function Get-LctProcessWatchStatus {
    <#
    .SYNOPSIS process.watch.status：看门狗状态（是否在跑、计数、目标、日志路径）。
    #>
    param([Alias('Args')][object]$ArgBag = $null, [switch]$Apply)
    $verb = 'process.watch.status'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $w = $script:LctWatch
    $running = $false
    $st = $null
    $inv = ''
    if ($null -ne $w) {
        $st = $w.State
        try { $inv = [string]$w.PowerShell.InvocationStateInfo.State } catch { $inv = '' }
        $running = ((-not [bool]$st.stop) -and ([string]$st.endedAt -eq '') -and (@('Completed', 'Stopped', 'Failed') -notcontains $inv))
    }
    $data = [pscustomobject][ordered]@{
        running        = $running
        hasInstance    = ($null -ne $w)
        invocationState = $inv
        startedAt      = $(if ($null -ne $st) { [string]$st.startedAt } else { '' })
        endsAt         = $(if ($null -ne $st) { [string]$st.until } else { '' })
        endedAt        = $(if ($null -ne $st) { [string]$st.endedAt } else { '' })
        intervalSec    = $(if ($null -ne $st) { [int]$st.intervalSec } else { 0 })
        durationSec    = $(if ($null -ne $st) { [int]$st.durationSec } else { 0 })
        killCount      = $(if ($null -ne $st) { [int]$st.kills } else { 0 })
        failureCount   = $(if ($null -ne $st) { [int]$st.failures } else { 0 })
        skipCount      = $(if ($null -ne $st) { [int]$st.skipped } else { 0 })
        eventCount     = $(if ($null -ne $st) { [int]$st.events } else { 0 })
        lastEvent      = $(if ($null -ne $st) { [string]$st.lastEvent } else { '' })
        lastDetail     = $(if ($null -ne $st) { [string]$st.lastDetail } else { '' })
        lastError      = $(if ($null -ne $st) { [string]$st.lastError } else { '' })
        targets        = $(if ($null -ne $st) { @($st.targets) } else { @() })
        override       = $(if ($null -ne $st) { [bool]$st.allowCritical } else { $false })
        logPath        = $(if ($null -ne $st) { [string]$st.logPath } else { (Get-LctWatchLogPath) })
        identity       = (Get-LctIdentityReport)
        persistence    = '仅当前进程内 runspace 循环；本进程退出即停（不装服务/不注册任务/不写自启动/不隐藏）'
    }
    if (-not $running) { $null = $warnings.Add('当前没有运行中的看门狗。') }
    $log = Write-LctQuiet -Verb $verb -Level info -Message ('process.watch.status running=' + $running)
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $data -Log $log
}

function Stop-LctProcessWatch {
    <#
    .SYNOPSIS process.watch.stop：停止会话内看门狗（默认预览，-Apply 才停）。
    #>
    param(
        $WaitSec = 5,
        [switch]$Apply,
        [Alias('Args')][object]$ArgBag = $null
    )
    $verb = 'process.watch.stop'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $wait = ConvertTo-LctIntSafe -Value $WaitSec -Default 5
    if ($wait -lt 1) { $wait = 1 }
    if ($wait -gt 30) { $wait = 30 }
    if ($null -ne $ArgBag) {
        $wv = Get-LctArgFrom -Args $ArgBag -Key 'waitSec'
        if ($null -ne $wv) { $wait = ConvertTo-LctIntSafe -Value $wv -Default $wait }
        if (-not $Apply) { $Apply = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') }
    }
    $w = $script:LctWatch
    if ($null -eq $w) {
        $null = $warnings.Add('当前没有运行中的看门狗（幂等：无操作）。')
        $log = Write-LctQuiet -Verb $verb -Level info -Message 'process.watch.stop 无实例'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                wasRunning = $false; stopped = $false; killCount = 0
            }) -Log $log
    }
    $st = $w.State
    $invNow = ''
    try { $invNow = [string]$w.PowerShell.InvocationStateInfo.State } catch { $invNow = '' }
    $runningNow = ((-not [bool]$st.stop) -and ([string]$st.endedAt -eq '') -and (@('Completed', 'Stopped', 'Failed') -notcontains $invNow))
    if (-not $runningNow) {
        # 已结束：幂等无操作；**保留**最后一次运行的计数，让 status 仍能如实上报（下一次 Start 会清掉它）
        $null = $warnings.Add('看门狗已不在运行（幂等：无操作）；上次运行的最终计数仍可从 process.watch.status 读到。')
        $log = Write-LctQuiet -Verb $verb -Level info -Message 'process.watch.stop 实例已结束（幂等）'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                wasRunning = $false; stopped = $false; running = $false; killCount = [int]$st.kills; failureCount = [int]$st.failures
                endedAt = [string]$st.endedAt; targets = @($st.targets); logPath = [string]$st.logPath
            }) -Log $log
    }
    $watchIds = ((@($st.targets | ForEach-Object { $_.pid })) -join ',')
    $null = $changes.Add((New-LctProcChangeEntry -Kind 'note' -Target ('watch pid=' + $watchIds) `
                -Name '<process-watch>' -Before '(运行中)' -After '(将停止，不再重杀)' -Note $(if ($Apply) { '' } else { '未加 -Apply，仅预览' })))

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message '预览 process.watch.stop'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                wasRunning = $true; stopped = $false; killCount = [int]$st.kills; failureCount = [int]$st.failures; targets = @($st.targets); logPath = [string]$st.logPath
            }) -Log $log
    }

    $st.stop = $true
    $ended = $false
    for ($i = 0; $i -lt ($wait * 10); $i++) {
        if ([string]$st.endedAt -ne '') { $ended = $true; break }
        Start-Sleep -Milliseconds 100
    }
    $inv = ''
    try { $inv = [string]$w.PowerShell.InvocationStateInfo.State } catch { $inv = '' }
    if ((-not $ended) -or ($inv -eq 'Running')) {
        try { $w.PowerShell.Stop() } catch { }
        for ($i = 0; $i -lt 30; $i++) {
            try { $inv = [string]$w.PowerShell.InvocationStateInfo.State } catch { $inv = '' }
            if ($inv -ne 'Running') { break }
            Start-Sleep -Milliseconds 100
        }
    }
    try { $w.Runspace.Dispose() } catch { }
    try { $w.PowerShell.Dispose() } catch { }
    if (-not $ended) { $null = $warnings.Add('看门狗未在等待时间内自行退出，已强制 Stop()（runspace 已释放）。') }
    # 刻意不置空 $script:LctWatch：让 status 仍能读到本次运行的最终计数（Start 会自动清掉已结束的实例）
    $null = $warnings.Add('看门狗已停止；最终计数保留在 process.watch.status 中，下次 start 会重置。')

    $log = Write-LctQuiet -Verb $verb -Level change -Message ('已停止 process.watch.stop，累计终止 ' + [int]$st.kills + ' 次') `
        -Data @{ kills = [int]$st.kills; failures = [int]$st.failures; ended = $ended; invocationState = $inv }
    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            wasRunning = $true; stopped = $true; running = $false; graceful = $ended; killCount = [int]$st.kills; failureCount = [int]$st.failures
            eventCount = [int]$st.events; targets = @($st.targets); logPath = [string]$st.logPath; endedAt = [string]$st.endedAt
        }) -Log $log
}

function Get-LctProcessWatchLog {
    <#
    .SYNOPSIS process.watch.log：读回看门狗事件日志（var\logs\process-watch-<日期>.log，JSON 行）。
    .DESCRIPTION 默认返回最近 100 行；-All（或 Limit<=0）返回全部；-Date yyyyMMdd 指定其它日期。
    #>
    param(
        [string]$Date = '',
        $Limit = 100,
        [switch]$All,
        [Alias('Args')][object]$ArgBag = $null,
        [switch]$Apply
    )
    $verb = 'process.watch.log'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $limitN = ConvertTo-LctIntSafe -Value $Limit -Default 100
    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Date)) { $Date = [string](Get-LctArgFrom -Args $ArgBag -Key 'date' -Default '') }
        $lv = Get-LctArgFrom -Args $ArgBag -Key 'limit'
        if ($null -ne $lv) { $limitN = ConvertTo-LctIntSafe -Value $lv -Default $limitN }
        if (-not $All) { $All = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'all') }
    }
    $path = Get-LctWatchLogPath -Date $Date
    $lines = New-Object System.Collections.ArrayList
    $badLines = 0
    $exists = Test-Path -LiteralPath $path
    if ($exists) {
        $raw = @()
        try { $raw = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop) } catch {
            $null = $errors.Add('读取监控日志失败: ' + $_.Exception.Message)
        }
        foreach ($ln in $raw) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try {
                $null = $lines.Add(($ln | ConvertFrom-Json))
            } catch { $badLines++ }
        }
    } else {
        $null = $warnings.Add('尚未生成监控日志（该日期没有看门狗事件）: ' + $path)
    }
    $kills = 0; $fails = 0; $skips = 0; $others = 0
    foreach ($o in @($lines)) {
        $ev = [string]$o.event
        if ($ev -eq 'kill.ok') { $kills++ }
        elseif ($ev -eq 'kill.fail') { $fails++ }
        elseif ($ev -eq 'identity.skip') { $skips++ }
        else { $others++ }
    }
    $total = @($lines).Count
    $out = @($lines)
    if ((-not $All) -and ($limitN -gt 0) -and ($total -gt $limitN)) {
        $out = @($lines[($total - $limitN) .. ($total - 1)])
    }
    if ($badLines -gt 0) { $null = $warnings.Add('有 ' + $badLines + ' 行无法解析为 JSON（已跳过，未丢弃文件）。') }
    $log = Write-LctQuiet -Verb $verb -Level info -Message ('读取监控日志 ' + $path + ' 共 ' + $total + ' 行')
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            path = $path; exists = [bool]$exists; total = $total; count = @($out).Count; returned = @($out)
            counts = [pscustomobject][ordered]@{ killOk = $kills; killFail = $fails; identitySkip = $skips; other = $others }
            badLines = $badLines
        }) -Log $log
}
#endregion

#region 导出：IFEO 加载阻断
function Set-LctProcessBlock {
    <#
    .SYNOPSIS process.block.set：用 IFEO Debugger 重定向让目标程序无法启动（默认预览）。
    .DESCRIPTION 写 HKLM 时同时处理原生视图与 Wow6432Node 视图；写前 New-LctBackup（记录原值或「原本不存在」）。
                 Debugger 默认指向一个刻意不存在的占位路径（<System32>\LctBlocked.exe）：目标创建即失败、不会有任何程序被运行。
                 已存在「第三方」Debugger（无本工具标记）时必须 -Override 才允许覆盖。-Hive HKCU 仅用于测试（Windows 只认 HKLM 的 IFEO）。
    #>
    param(
        [string]$Path = '',
        [string]$Reason = '',
        [Alias('Debugger')][string]$Blocker = '',
        [ValidateSet('HKLM', 'HKCU')][string]$Hive = 'HKLM',
        [switch]$Override,
        [switch]$Apply,
        [Alias('Args')][object]$ArgBag = $null
    )
    $verb = 'process.block.set'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = [string](Get-LctArgFrom -Args $ArgBag -Key 'reason' -Default '') }
        if ([string]::IsNullOrWhiteSpace($Blocker)) {
            $Blocker = [string](Get-LctArgFrom -Args $ArgBag -Key 'blocker' -Default '')
            if ([string]::IsNullOrWhiteSpace($Blocker)) { $Blocker = [string](Get-LctArgFrom -Args $ArgBag -Key 'debugger' -Default '') }
        }
        $hv = [string](Get-LctArgFrom -Args $ArgBag -Key 'hive' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($hv)) { if (@('HKLM', 'HKCU') -contains $hv.ToUpperInvariant()) { $Hive = $hv.ToUpperInvariant() } }
        if (-not $Override) { $Override = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'override') }
        if (-not $Apply) { $Apply = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 path 参数：process.block.set 需要要阻断的可执行文件路径')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.set 缺少 path'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }
    $exeName = ''
    try { $exeName = [string][IO.Path]::GetFileName($Path) } catch { $exeName = '' }
    if ([string]::IsNullOrWhiteSpace($exeName)) {
        $null = $errors.Add('无法从 path 解析出可执行文件名: ' + $Path)
    } elseif ($exeName -match '[\\/:*?"<>|]') {
        $null = $errors.Add('可执行文件名含非法字符: ' + $exeName)
    }
    if (-not [string]::IsNullOrWhiteSpace($Blocker) -and ($Blocker -match '[<>|]')) {
        $null = $errors.Add('Blocker 路径含非法字符: ' + $Blocker)
    }
    if ($errors.Count -gt 0) {
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.set 参数非法' -Data @{ path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }
    $blockerPath = $Blocker
    if ([string]::IsNullOrWhiteSpace($blockerPath)) { $blockerPath = $script:LctDefaultBlocker }
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = '未说明原因'; $null = $warnings.Add('未提供 -Reason：已记为「未说明原因」（后审计/回滚需要它）。') }
    $by = ''
    try { $by = [string](Get-LctIdentityReport).user } catch { $by = '' }
    if (-not ($exeName -match '(?i)\.exe$')) { $null = $warnings.Add('目标文件名不是 .exe（' + $exeName + '）：IFEO 只作用于可执行映像，请确认这是你要阻断的映像名。') }
    if ($Hive -eq 'HKCU') { $null = $warnings.Add('HKCU 视图不被 Windows 的 IFEO 机制读取，仅用于测试/演示；真正阻断必须用 HKLM。') }
    if (-not (Test-Path -LiteralPath $Path)) { $null = $warnings.Add('指定的可执行文件当前不存在（' + $Path + '）：仍按映像名 ' + $exeName + ' 写入 IFEO 项。') }
    $null = $warnings.Add('IFEO 会把 Debugger 指向刻意不存在的占位路径 ' + $blockerPath + '：目标程序将无法启动（启动方会看到错误），不会有任何程序被运行；已运行的实例不受影响，仅影响之后的新启动。')
    if (($Hive -eq 'HKLM') -and (-not (Get-LctIdentityReport).elevated)) {
        $null = $warnings.Add('写 HKLM 需要管理员权限：当前未提权，-Apply 时很可能失败（错误码 5）。')
    }

    $views = @(Get-LctIfeoViews -ExeName $exeName -Hive $Hive)
    $states = New-Object System.Collections.ArrayList
    $conflict = $false
    foreach ($v in $views) {
        $s = Get-LctIfeoViewState -View $v
        $null = $states.Add($s)
        if ($s.debuggerExists -and (-not ($s.debuggerValue -ieq $blockerPath)) -and (-not $s.byUs)) {
            $conflict = $true
            $null = $changes.Add((New-LctProcChangeEntry -Kind 'registry' -Target $s.keyPath -Name 'Debugger' `
                        -Before $s.debuggerValue -After '(拒绝：存在第三方 Debugger 值)' `
                        -Note '该 IFEO 项不是本工具设置的（无 LctBlockReason 标记）；覆盖会破坏原有的调试器配置，必须 -Override'))
        } else {
            $beforeText = '(不存在)'
            if ($s.debuggerExists) { $beforeText = $s.debuggerValue }
            $note = 'IFEO 重定向（' + $s.view + ' 视图）：目标将无法启动'
            if (-not $s.honored) { $note = $note + '；注意 HKCU 视图不被 Windows 读取' }
            $null = $changes.Add((New-LctProcChangeEntry -Kind 'registry' -Target $s.keyPath -Name 'Debugger' `
                        -Before $beforeText -After $blockerPath -Note $note))
        }
    }
    if ($conflict -and (-not $Override)) {
        $null = $errors.Add('目标映像的 IFEO 项已存在第三方 Debugger 值：默认拒绝覆盖（如确认要覆盖请加 -Override）。')
        $log = Write-LctQuiet -Verb $verb -Level warn -Message 'process.block.set 拒绝覆盖第三方 Debugger' -Data @{ exeName = $exeName }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
                exeName = $exeName; targetPath = $Path; blocker = $blockerPath; reason = $Reason; hive = $Hive; refused = $true
                views = @($states | ForEach-Object { [pscustomobject][ordered]@{ hive = $_.hive; view = $_.view; keyPath = $_.keyPath; debuggerBefore = $_.debuggerValue; byUs = $_.byUs } })
            }) -Log $log
    }
    if ($conflict -and $Override) { $null = $warnings.Add('已 -Override：正在覆盖第三方 Debugger 值（原值已写入备份，可用 backup.restore 还原）。') }

    $planData = [pscustomobject][ordered]@{
        exeName = $exeName; targetPath = $Path; blocker = $blockerPath; reason = $Reason; hive = $Hive
        setBy = $by; views = @($states | ForEach-Object {
                [pscustomobject][ordered]@{
                    hive = $_.hive; view = $_.view; keyPath = $_.keyPath; honored = $_.honored
                    debuggerBefore = $(if ($_.debuggerExists) { $_.debuggerValue } else { '(不存在)' }); byUs = $_.byUs
                }
            })
        markers = @($script:LctBlockMarkers)
        note = 'IFEO 只影响目标程序之后的新启动；已运行的实例不受影响。秒级回滚：process.block.remove'
    }

    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message ('预览 process.block.set ' + $exeName) -Data @{ exeName = $exeName; blocker = $blockerPath; view = @($views | ForEach-Object { $_.view }) }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    # ---- 先备份（契约 §7.2 / §11.2 铁律 5）----
    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ exeName = $exeName; path = $Path; blocker = $blockerPath; reason = $Reason; hive = $Hive }) `
            -RegistryPaths @($states | ForEach-Object { $_.keyPath })
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add('创建备份失败，已取消写入: ' + $_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.set 备份失败，未写入' -Data @{ exeName = $exeName }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    # ---- 写入（任一视图失败则整体回滚到 before）----
    $written = New-Object System.Collections.ArrayList
    $failMsg = ''
    foreach ($s in @($states)) {
        try {
            Set-LctRegStringValue -Loc $s.loc -Name 'Debugger' -Value $blockerPath
            Set-LctRegStringValue -Loc $s.loc -Name 'LctBlockReason' -Value $Reason
            Set-LctRegStringValue -Loc $s.loc -Name 'LctBlockSetAt' -Value ((Get-Date).ToString('s'))
            Set-LctRegStringValue -Loc $s.loc -Name 'LctBlockBy' -Value $by
            Set-LctRegStringValue -Loc $s.loc -Name 'LctBlockTargetPath' -Value $Path
            $null = $written.Add($s)
        } catch {
            $failMsg = ('写入 ' + $s.keyPath + ' 失败: ' + $_.Exception.Message)
            break
        }
    }
    if ([string]::IsNullOrEmpty($failMsg)) {
        foreach ($s in @($states)) {
            $chk = Get-LctRegStringValue -Loc $s.loc -Name 'Debugger'
            if ((-not $chk.exists) -or (-not ([string]$chk.value -ieq $blockerPath))) {
                $failMsg = ('写入后校验失败: ' + $s.keyPath + ' 的 Debugger 不是期望值')
                break
            }
        }
    }
    if (-not [string]::IsNullOrEmpty($failMsg)) {
        $null = $errors.Add($failMsg)
        foreach ($s in @($written)) {
            $okBack = Restore-LctIfeoView -Loc $s.loc -KeyExistedBefore ([bool]$s.keyExists) -DebuggerExistedBefore ([bool]$s.debuggerExists) -DebuggerBeforeValue ([string]$s.debuggerValue)
            if (-not $okBack) { $null = $errors.Add('回滚失败（视图 ' + $s.view + '）: ' + $s.keyPath) }
        }
        if (@($written).Count -gt 0) { $null = $warnings.Add('已把 ' + @($written).Count + ' 个视图回滚到写前状态。') }
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.set 写入失败并回滚' -Data @{ exeName = $exeName; error = $failMsg; backupId = $backupId }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $planData -Log $log
    }

    foreach ($s in @($states)) {
        $chk = Get-LctRegStringValue -Loc $s.loc -Name 'Debugger'
        $null = $warnings.Add('已复核 ' + $s.view + ' 视图：Debugger=' + [string]$chk.value + '（' + $s.keyPath + '）')
    }
    $log = Write-LctQuiet -Verb $verb -Level change -Message ('已应用 process.block.set ' + $exeName + ' -> ' + $blockerPath) `
        -Data @{ exeName = $exeName; blocker = $blockerPath; backupId = $backupId; by = $by }
    return New-LctResult -Verb $verb -Applied -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $planData -Log $log
}

function Remove-LctProcessBlock {
    <#
    .SYNOPSIS process.block.remove：撤销 IFEO 重定向并完整回滚（默认预览，-Apply 才真删）。
    .DESCRIPTION 只删除本工具设置的重定向（有 LctBlockReason 标记）；要删第三方 Debugger 必须 -Override。
                 删完若该 IFEO 子键已空，则用 Remove-LctRegistryKeyTree 删除该键（恢复到「原本不存在」）。
    #>
    param(
        [string]$Path = '',
        [ValidateSet('Auto', 'HKLM', 'HKCU')][string]$Hive = 'Auto',
        [switch]$Override,
        [switch]$Apply,
        [Alias('Args')][object]$ArgBag = $null
    )
    $verb = 'process.block.remove'
    $changes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $backupId = ''
    if ($null -ne $ArgBag) {
        if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string](Get-LctArgFrom -Args $ArgBag -Key 'path' -Default '') }
        $hv = [string](Get-LctArgFrom -Args $ArgBag -Key 'hive' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($hv)) { if (@('AUTO', 'HKLM', 'HKCU') -contains $hv.ToUpperInvariant()) { $Hive = $hv.ToUpperInvariant() } }
        if (-not $Override) { $Override = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'override') }
        if (-not $Apply) { $Apply = ConvertTo-LctBool -Value (Get-LctArgFrom -Args $ArgBag -Key 'apply') }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $null = $errors.Add('缺少 path 参数：process.block.remove 需要要解除阻断的可执行文件路径')
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.remove 缺少 path'
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }
    $exeName = ''
    try { $exeName = [string][IO.Path]::GetFileName($Path) } catch { $exeName = '' }
    if ([string]::IsNullOrWhiteSpace($exeName)) {
        $null = $errors.Add('无法从 path 解析出可执行文件名: ' + $Path)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.remove 路径非法' -Data @{ path = $Path }
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data $null -Log $log
    }

    $views = New-Object System.Collections.ArrayList
    if (($Hive -eq 'Auto') -or ($Hive -eq 'HKLM')) { foreach ($v in @(Get-LctIfeoViews -ExeName $exeName -Hive 'HKLM')) { $null = $views.Add($v) } }
    if (($Hive -eq 'Auto') -or ($Hive -eq 'HKCU')) { foreach ($v in @(Get-LctIfeoViews -ExeName $exeName -Hive 'HKCU')) { $null = $views.Add($v) } }

    $states = New-Object System.Collections.ArrayList
    $foreign = $false
    foreach ($v in $views) {
        $s = Get-LctIfeoViewState -View $v
        $null = $states.Add($s)
        if (-not $s.debuggerExists -and -not $s.byUs) { continue }
        if ($s.debuggerExists -and (-not $s.byUs)) { $foreign = $true }
        $null = $changes.Add((New-LctProcChangeEntry -Kind 'registry' -Target $s.keyPath -Name 'Debugger' `
                    -Before $(if ($s.debuggerExists) { $s.debuggerValue } else { '(不存在)' }) -After '(删除并回滚为原本状态)' `
                    -Note $(if ($s.byUs) { '本工具设置（LctBlockReason=' + $s.markerReason + '）' } else { '第三方 Debugger 值（需 -Override）' })))
    }
    if (@($changes).Count -eq 0) { $null = $warnings.Add('这两个视图都没有 IFEO 重定向：无需操作（幂等）。') }
    $planData = [pscustomobject][ordered]@{
        exeName = $exeName; targetPath = $Path; hive = $Hive; removed = $false
        views = @($states | ForEach-Object {
                [pscustomobject][ordered]@{
                    hive = $_.hive; view = $_.view; keyPath = $_.keyPath
                    debuggerBefore = $(if ($_.debuggerExists) { $_.debuggerValue } else { '(不存在)' }); byUs = $_.byUs
                }
            })
        foreign = $foreign
    }
    if ($foreign -and (-not $Override)) {
        $null = $errors.Add('存在不是本工具设置的 IFEO Debugger 值：默认拒绝删除（如确认要删除请加 -Override）。')
        $log = Write-LctQuiet -Verb $verb -Level warn -Message 'process.block.remove 拒绝删除第三方 Debugger' -Data @{ exeName = $exeName }
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }
    if (-not $Apply) {
        $log = Write-LctQuiet -Verb $verb -Level change -Message ('预览 process.block.remove ' + $exeName)
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    # ---- 先备份（回滚留痕）----
    $bk = $null
    try {
        $bk = New-LctBackup -Verb $verb -Args ([pscustomobject][ordered]@{ exeName = $exeName; path = $Path; hive = $Hive }) `
            -RegistryPaths @($states | ForEach-Object { $_.keyPath })
        $backupId = [string]$bk.id
    } catch {
        $null = $errors.Add('创建备份失败，已取消删除: ' + $_.Exception.Message)
        $log = Write-LctQuiet -Verb $verb -Level error -Message 'process.block.remove 备份失败，未删除'
        return New-LctResult -Verb $verb -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -Data $planData -Log $log
    }

    $removedAny = $false
    foreach ($s in @($states)) {
        if ((-not $s.debuggerExists) -and (-not $s.byUs)) { continue }
        try {
            if ($s.debuggerExists) {
                if ($s.byUs -or $Override) {
                    $null = Remove-LctRegValueOnly -Loc $s.loc -Name 'Debugger'
                } else {
                    throw '第三方 Debugger 值未授权删除'
                }
            }
            foreach ($mn in @($script:LctBlockMarkers)) { $null = Remove-LctRegValueOnly -Loc $s.loc -Name $mn }
            $removedAny = $true
            if (Test-LctRegKeyEmpty -Loc $s.loc) {
                $null = Remove-LctRegistryKeyTree -Path $s.loc.normalized
            }
        } catch {
            $null = $errors.Add('撤销 ' + $s.keyPath + ' 失败: ' + $_.Exception.Message)
        }
    }
    # 复核：Debugger 与标记都必须消失；空键必须已删
    foreach ($s in @($states)) {
        $d2 = Get-LctRegStringValue -Loc $s.loc -Name 'Debugger'
        $m2 = Get-LctRegStringValue -Loc $s.loc -Name 'LctBlockReason'
        if ($d2.exists -and ($s.byUs -or $Override)) { $null = $errors.Add('撤销后校验失败：Debugger 仍然存在 ' + $s.keyPath) }
        if ($m2.exists) { $null = $errors.Add('撤销后校验失败：标记值 LctBlockReason 仍然存在 ' + $s.keyPath) }
    }
    $planData.removed = $removedAny
    $appliedFlag = ($Apply -and ($errors.Count -eq 0))
    $log = Write-LctQuiet -Verb $verb -Level change -Message ('已应用 process.block.remove ' + $exeName) `
        -Data @{ exeName = $exeName; removed = $removedAny; backupId = $backupId }
    return New-LctResult -Verb $verb -Applied:$appliedFlag -Changes @($changes) -Warnings @($warnings) -Errors @($errors) -BackupId $backupId -Data $planData -Log $log
}

function Get-LctProcessBlockList {
    <#
    .SYNOPSIS process.block.list：当前 IFEO 重定向清单（本工具设置的置顶，并标出第三方项）。
    #>
    param([Alias('Args')][object]$ArgBag = $null, [switch]$Apply)
    $verb = 'process.block.list'
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $roots = @(
        ('HKLM:\' + $script:LctIfeoSub),
        ('HKLM:\' + $script:LctIfeoSub32),
        ('HKCU:\' + $script:LctIfeoSub)
    )
    $items = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop) } catch { $null = $warnings.Add('枚举失败: ' + $root + '（' + $_.Exception.Message + '）') }
        foreach ($c in $children) {
            $keyPath = [string]$c.Name
            $loc = $null
            try { $loc = ConvertTo-LctRegLoc -Path $keyPath } catch { continue }
            $d = Get-LctRegStringValue -Loc $loc -Name 'Debugger'
            $mk = Get-LctRegStringValue -Loc $loc -Name 'LctBlockReason'
            if ((-not $d.exists) -and (-not $mk.exists)) { continue }
            $setAt = Get-LctRegStringValue -Loc $loc -Name 'LctBlockSetAt'
            $setBy = Get-LctRegStringValue -Loc $loc -Name 'LctBlockBy'
            $tPath = Get-LctRegStringValue -Loc $loc -Name 'LctBlockTargetPath'
            $null = $items.Add([pscustomobject][ordered]@{
                exeName         = [string]$c.PSChildName
                keyPath         = $loc.normalized
                debugger        = [string]$d.value
                byUs            = [bool]$mk.exists
                reason          = $(if ($mk.exists) { [string]$mk.value } else { '' })
                setAt           = $(if ($setAt.exists) { [string]$setAt.value } else { '' })
                setBy           = $(if ($setBy.exists) { [string]$setBy.value } else { '' })
                targetPath      = $(if ($tPath.exists) { [string]$tPath.value } else { '' })
                view            = $(if ($loc.normalized -like '*Wow6432Node*') { 'wow6432' } else { 'native' })
                hive            = $loc.hiveName
                honored         = ($loc.hiveName -eq 'HKLM')
            })
        }
    }
    $sorted = @($items | Sort-Object -Property @{ Expression = { -not $_.byUs } }, @{ Expression = { $_.exeName } })
    $mine = @($sorted | Where-Object { $_.byUs })
    if (@($sorted).Count -gt @($mine).Count) { $null = $warnings.Add('清单含 ' + (@($sorted).Count - @($mine).Count) + ' 个**非本工具**设置的 IFEO Debugger 项（已标 byUs=false，删除需要 -Override）。') }
    $log = Write-LctQuiet -Verb $verb -Level info -Message ('IFEO 清单：本工具 ' + @($mine).Count + ' 项，合计 ' + @($sorted).Count + ' 项')
    return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @($errors) -Data ([pscustomobject][ordered]@{
            items = $sorted; count = @($sorted).Count; byUsCount = @($mine).Count
            foreignCount = (@($sorted).Count - @($mine).Count)
            ifeoPaths = $roots
            identity = (Get-LctIdentityReport)
        }) -Log $log
}
#endregion

Export-ModuleMember -Function Get-LctProcessList, Get-LctProcessDetail, Stop-LctProcess,
    Start-LctProcessWatch, Get-LctProcessWatchStatus, Stop-LctProcessWatch, Get-LctProcessWatchLog,
    Set-LctProcessBlock, Remove-LctProcessBlock, Get-LctProcessBlockList