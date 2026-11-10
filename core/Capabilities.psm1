# LocalConfigTool - core\Capabilities.psm1
#
# 能力路线与前置条件（只读判定）。
#
# 背景（这是本模块存在的理由）：
#   本工具承载两条互相依赖的「能力路线」，它们的前置条件不同，容易撞车：
#     路线 B「提权」：把漏洞组件当插件用，从**普通用户**起步，终点是管理员/SYSTEM。
#     路线 A「加载驱动」：注册并启动内核驱动，**起点就要求管理员**（sc create / sc start 需要）。
#   而工具默认以普通权限运行 ⇒ 直接点「加载驱动」必然失败，且旧的报错只说「需要管理员权限」，
#   不告诉用户「先去提权」，用户会以为是工具坏了。
#   所以：任何驱动写操作在未提权时都必须被拦住，并明确给出**先后顺序**的指引。
#
# 本模块只做三件事（全部只读，不加载驱动、不改系统）：
#   1) capability.status —— 当前权限画像 + 两条路线的可用性 + 前置条件提示
#   2) Test-LctCapabilityDriverLoad —— 纯函数判定（供引擎各驱动 verb 与测试共用）
#   3) 不改任何状态：连 sc.exe 都不调；权限只能"报告"，不能"伪造"

$script:LctCapNativeReady = $false
$script:LctCapNativeError = ''
$script:LctCapNativeSource = @'
using System;
using System.Runtime.InteropServices;

public class LctCapNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertSidToStringSidW(IntPtr Sid, out IntPtr StringSid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr hMem);

    const int TokenIntegrityLevel = 25;
    const uint TOKEN_QUERY = 0x0008;

    // 返回完整性级别的 SID 字符串（形如 S-1-16-12288）；失败返回 ""。
    // 用 ConvertSidToStringSid 而不是手算 GetSidSubAuthority：后者实测读出垃圾值（指针读错）。
    public static string GetIntegritySid(out string error)
    {
        error = "";
        IntPtr hToken = IntPtr.Zero;
        IntPtr buf = IntPtr.Zero;
        try
        {
            IntPtr proc = GetCurrentProcess();
            if (!OpenProcessToken(proc, TOKEN_QUERY, out hToken))
            {
                error = "OpenProcessToken 失败: " + Marshal.GetLastWin32Error();
                return "";
            }
            int len = 0;
            GetTokenInformation(hToken, TokenIntegrityLevel, IntPtr.Zero, 0, out len);
            if (len <= 0) { error = "GetTokenInformation 取长度失败"; return ""; }
            buf = Marshal.AllocHGlobal(len);
            if (!GetTokenInformation(hToken, TokenIntegrityLevel, buf, len, out len))
            {
                error = "GetTokenInformation 失败: " + Marshal.GetLastWin32Error();
                return "";
            }
            TOKEN_MANDATORY_LABEL tml = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(buf, typeof(TOKEN_MANDATORY_LABEL));
            IntPtr sid = tml.Label.Sid;
            if (sid == IntPtr.Zero) { error = "SID 为空"; return ""; }
            IntPtr strSid = IntPtr.Zero;
            if (!ConvertSidToStringSidW(sid, out strSid))
            {
                error = "ConvertSidToStringSid 失败: " + Marshal.GetLastWin32Error();
                return "";
            }
            try { return Marshal.PtrToStringUni(strSid); }
            finally { LocalFree(strSid); }
        }
        catch (Exception ex) { error = "异常: " + ex.Message; return ""; }
        finally
        {
            if (buf != IntPtr.Zero) { Marshal.FreeHGlobal(buf); }
            if (hToken != IntPtr.Zero) { CloseHandle(hToken); }
        }
    }
}
'@

function Ensure-LctCapNative {
    param()
    if ($script:LctCapNativeReady) { return $true }
    if ('' -ne $script:LctCapNativeError) { return $false }
    try {
        if (-not ('LctCapNative' -as [type])) {
            Add-Type -TypeDefinition $script:LctCapNativeSource -ErrorAction Stop
        }
        $script:LctCapNativeReady = $true
        return $true
    } catch {
        $script:LctCapNativeError = $_.Exception.Message
        return $false
    }
}

function Get-LctCapIntegrityLevel {
    # 返回 @{ sid='S-1-16-12288'; rid=12288; name='High|Medium|Low|System|Protected|Unknown' }，纯报告。
    # 注意：SID 字符串里的最后一节是**十进制**——4096=Low 8192=Medium 12288=High 16384=System 20480=Protected。
    param()
    if (-not (Ensure-LctCapNative)) {
        return [pscustomobject]@{ sid = ''; rid = -1; name = 'Unknown'; error = $script:LctCapNativeError }
    }
    $err = ''
    $sidText = ''
    try { $sidText = [string]([LctCapNative]::GetIntegritySid([ref]$err)) } catch { $sidText = ''; $err = $_.Exception.Message }
    $rid = -1
    if ($sidText -match '^S-1-16-(\d+)$') { $rid = [int]$Matches[1] }
    $name = 'Unknown'
    switch ($rid) {
        4096 { $name = 'Low' }
        8192 { $name = 'Medium' }
        12288 { $name = 'High' }
        16384 { $name = 'System' }
        20480 { $name = 'Protected' }
        -1 { $name = 'Unknown' }
        default { $name = ('RID:' + $rid) }
    }
    return [pscustomobject]@{ sid = $sidText; rid = $rid; name = $name; error = $err }
}
function Get-LctCapAbilityHint {
    # 未提权时给用户看的**动作顺序**提示（这是本模块的核心产出）
    param([AllowEmptyString()][string]$Action = '加载驱动', [string]$IntegrityName = 'Unknown')
    return ('需要管理员/SYSTEM 权限才能' + $Action + '：当前进程是' + $IntegrityName + '（未提权）。' +
        '本工具默认以普通权限运行，无法注册/启动内核驱动 —— ' +
        '请**先**用「提权」路线（把漏洞组件当插件加载，例如 plugins\cve-2026-49176）把自己提升到管理员/SYSTEM，' +
        '**再**回到本工具执行该操作。顺序不能反：没有高权限，前面这一步做不了。')
}

function Test-LctCapabilityDriverLoad {
    <#
    .SYNOPSIS
        纯函数：判断「能不能做驱动写操作」。供引擎各驱动 verb 与测试共用；不调用任何系统 API。
    .PARAMETER IsAdmin
        调用方传入的真实提权状态（引擎用 Test-LctElevated 的结果传进来，便于测试注入）。
    .PARAMETER Action
        动作名，用于提示文案（如「加载驱动」「卸载驱动服务」）。
    .PARAMETER IntegrityName
        完整性级别名，仅用于文案。
    #>
    param(
        [bool]$IsAdmin = $false,
        [AllowEmptyString()][string]$Action = '加载驱动',
        [AllowEmptyString()][string]$IntegrityName = 'Unknown'
    )
    $o = [ordered]@{
        allowed        = $false
        code           = 'need-elevation'
        needElevation  = $true
        action         = $Action
        isAdmin        = $IsAdmin
        integrityLevel = $IntegrityName
        message        = ''
        hint           = ''
        order          = @('elevate', 'driver')
    }
    if ($IsAdmin) {
        $o.allowed = $true
        $o.code = 'ok'
        $o.needElevation = $false
        $o.message = ('当前进程已提权（' + $IntegrityName + '），可以' + $Action)
        return [pscustomobject]$o
    }
    $o.message = ('未提权：当前进程是' + $IntegrityName + '，不能' + $Action)
    $o.hint = (Get-LctCapAbilityHint -Action $Action -IntegrityName $IntegrityName)
    return [pscustomobject]$o
}

function Get-LctCapabilities {
    # 只读：当前权限画像 + 两条能力路线的可用性 + 前置条件
    param()
    $verb = 'capability.status'
    $warnings = New-Object System.Collections.ArrayList
    $isAdmin = $false
    $user = ''
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $user = [string]$id.Name
        $isAdmin = [bool]([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $null = $warnings.Add('读取当前身份失败：' + $_.Exception.Message) }
    $integ = Get-LctCapIntegrityLevel
    if ($integ.error -ne '') { $null = $warnings.Add('读取完整性级别失败（按 Unknown 处理）：' + $integ.error) }

    # 驱动写操作判定（纯函数）
    $gate = Test-LctCapabilityDriverLoad -IsAdmin $isAdmin -Action '加载/卸载驱动' -IntegrityName $integ.name

    # 签名/测试签名状态（只读；调用 Drivers 模块的公开 verb，失败不致命）
    $testsigning = ''
    $secureBoot = $null
    try {
        $ds = Get-LctDriverStatus
        if ($null -ne $ds -and $ds.ok) {
            $testsigning = [string]$ds.data.testsigning
            $secureBoot = $ds.data.secureBoot
        }
    } catch { $null = $warnings.Add('读取驱动签名状态失败：' + $_.Exception.Message) }
    if ($testsigning -eq '') {
        try {
            $raw = (& bcdedit /enum '{current}' 2>$null | Out-String)
            $m = [regex]::Match($raw, '(?m)^\s*testsigning\s+(\S+)')
            if ($m.Success) { $testsigning = [string]$m.Groups[1].Value }
        } catch { }
    }

    $routes = @(
        [pscustomobject][ordered]@{
            id                = 'elevate'
            name              = '提权（漏洞组件当插件）'
            from              = '普通用户'
            to                = '管理员 / SYSTEM'
            requiresElevation = $false
            available         = $true
            blockedBy         = ''
            pluginHint        = 'plugins\cve-2026-49176'
            note              = '从普通权限起步，本身就是「先提权」这一步；提权成功后再执行驱动写操作'
        },
        [pscustomobject][ordered]@{
            id                = 'driver'
            name              = '加载驱动 / 内核原语'
            from              = '管理员 / SYSTEM'
            to                = '内核能力（任意读写 / 执行）'
            requiresElevation = $true
            available         = $isAdmin
            blockedBy         = $(if ($isAdmin) { '' } else { '未提权：sc create / sc start 需要管理员权限' })
            pluginHint        = ''
            note              = '本工具默认普通权限运行 ⇒ 必须先完成 elevate 路线'
        }
    )

    $data = [pscustomobject][ordered]@{
        user            = $user
        isAdmin         = $isAdmin
        integrityLevel  = $integ.name
        integrityRid    = $integ.rid
        elevated        = $isAdmin
        canLoadDriver   = [bool]$gate.allowed
        testsigning     = $testsigning
        secureBoot      = $secureBoot
        routes          = @($routes)
        prerequisite    = [pscustomobject][ordered]@{
            order  = @('elevate', 'driver')
            ok     = [bool]$gate.allowed
            hint   = [string]$gate.hint
            message = [string]$gate.message
        }
        capabilityMatrix = @(
            [pscustomobject][ordered]@{ capability = '加载/卸载驱动服务（driver.load/start/stop/unload）'; needsElevation = $true; available = $isAdmin; reason = $(if ($isAdmin) { '已提权' } else { '需要管理员权限' }) },
            [pscustomobject][ordered]@{ capability = '发 IOCTL 到驱动（driver.ctl.send -Apply）'; needsElevation = $true; available = $isAdmin; reason = $(if ($isAdmin) { '已提权（部分设备仍需 SE_LOAD_DRIVER/设备 ACL）' } else { '需要管理员权限' }) },
            [pscustomobject][ordered]@{ capability = '驱动 profile 起草/校验（只读）'; needsElevation = $false; available = $true; reason = '只读，不需要提权' },
            [pscustomobject][ordered]@{ capability = '设备/对象图枚举（driver.devices / driver.map）'; needsElevation = $false; available = $true; reason = '只读，不需要提权' },
            [pscustomobject][ordered]@{ capability = '测试签名开关（driver.testsigning）'; needsElevation = $true; available = $isAdmin; reason = $(if ($isAdmin) { '已提权' } else { '需要管理员权限' }) }
        )
        notes = @(
            '本模块只报告权限，不伪造权限、不做提权动作；提权由「提权」路线的插件负责（invoke 时明确 -Apply）。',
            '判断依据是有效令牌（IsInRole(Administrator)）；runas /trustlevel 这类受限令牌里 Administrators 是 deny-only，会被正确判为未提权。',
            '完整性级别（Medium/High/System）只是辅助信息：命令行工具被 UAC 提权后是 High，SYSTEM 服务里是 System。'
        )
    }
    return New-LctResult -Verb $verb -Warnings @($warnings) -Data $data
}

Export-ModuleMember -Function Get-LctCapabilities, Test-LctCapabilityDriverLoad, Get-LctCapIntegrityLevel, Get-LctCapAbilityHint