# LocalConfigTool - core\DriverMap.psm1
#
# 设备对象 ↔ 驱动对象 ↔ 服务名 的映射查询（只读；不打开设备、不发 IOCTL、不写注册表）。
#
# 为什么需要它：`driver.devices` 的候选是按「服务名」派生的（\\.\<service>），
# 当驱动自己创建的设备名与服务名不一致时，派生候选全部 not-found，用户态无计可施。
# 本模块改用对象管理器视角：
#   - 枚举 \Device（设备对象）与 \Driver（驱动对象）—— 文件系统 API 做不到，必须走 NT API；
#   - 枚举 \GLOBAL?? 的符号链接并用 NtQuerySymbolicLinkObject 解析出真实目标（\??\X → \Device\Y）；
#   - 用「名称一致 / 归一化一致」把设备对象对到驱动对象，再由驱动对象名推服务名，
#     并且**只在注册表里存在同名服务键时才标 serviceVerified=true**；
#   - 对不上的（例如 \Device\HarddiskVolume3 这种驱动自造名字）**明确列为 unresolved，不猜**。
#
# 已知边界（诚实声明，写在返回的 notes 里）：
#   1) 用户态没有「设备对象 → 驱动对象」的权威 API（那在 DEVICE_OBJECT->DriverObject 里，
#      属内核内存）。本模块只做名称层面的映射，命名不一致的一律 unresolved。
#   2) 若需要 100% 权威映射，唯一正路是用内核读原语读 DEVICE_OBJECT->DriverObject->DriverName，
#      那需要 profile + 已加载的漏洞驱动/自研驱动（属 driver.ctl.* 的职责，不在本模块）。

$script:LctDrvMapNativeReady = $false
$script:LctDrvMapNativeError = ''

$script:LctDrvMapNativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class LctDrvMapNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [DllImport("ntdll.dll")]
    public static extern uint NtOpenDirectoryObject(out IntPtr DirectoryHandle, uint DesiredAccess, ref OBJECT_ATTRIBUTES ObjectAttributes);

    [DllImport("ntdll.dll")]
    public static extern uint NtQueryDirectoryObject(IntPtr DirectoryHandle, IntPtr Buffer, uint Length, bool ReturnSingleEntry, bool RestartScan, out uint Context, out uint ReturnLength);

    [DllImport("ntdll.dll")]
    public static extern uint NtOpenSymbolicLinkObject(out IntPtr LinkHandle, uint DesiredAccess, ref OBJECT_ATTRIBUTES ObjectAttributes);

    [DllImport("ntdll.dll")]
    public static extern uint NtQuerySymbolicLinkObject(IntPtr LinkHandle, ref UNICODE_STRING LinkTarget, out uint ReturnedLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    const uint DIRECTORY_QUERY = 0x0001;
    const uint SYMBOLIC_LINK_QUERY = 0x0001;
    const uint OBJ_CASE_INSENSITIVE = 0x00000040;
    const uint STATUS_SUCCESS = 0x00000000;
    const uint STATUS_MORE_ENTRIES = 0x00000105;
    const uint STATUS_NO_MORE_ENTRIES = 0x8000001A;
    const uint STATUS_BUFFER_TOO_SMALL = 0xC0000023;

    static IntPtr BuildObjectAttributes(string name, out IntPtr nameBuffer, out IntPtr usBuffer)
    {
        nameBuffer = Marshal.StringToHGlobalUni(name);
        UNICODE_STRING us = new UNICODE_STRING();
        us.Length = (ushort)(name.Length * 2);
        us.MaximumLength = (ushort)(us.Length + 2);
        us.Buffer = nameBuffer;
        usBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
        Marshal.StructureToPtr(us, usBuffer, false);
        OBJECT_ATTRIBUTES oa = new OBJECT_ATTRIBUTES();
        oa.Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES));
        oa.RootDirectory = IntPtr.Zero;
        oa.ObjectName = usBuffer;
        oa.Attributes = OBJ_CASE_INSENSITIVE;
        oa.SecurityDescriptor = IntPtr.Zero;
        oa.SecurityQualityOfService = IntPtr.Zero;
        IntPtr oaBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)));
        Marshal.StructureToPtr(oa, oaBuffer, false);
        return oaBuffer;
    }

    static void FreeObjectAttributes(IntPtr oaBuffer, IntPtr nameBuffer, IntPtr usBuffer)
    {
        if (oaBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(oaBuffer); }
        if (usBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(usBuffer); }
        if (nameBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(nameBuffer); }
    }

    // 枚举目录对象，返回 "名字\t类型名" 数组。不做假：打不开就抛异常带上状态码。
    public static string[] EnumDirectory(string root, out string error)
    {
        error = "";
        List<string> results = new List<string>();
        IntPtr nameBuffer = IntPtr.Zero;
        IntPtr usBuffer = IntPtr.Zero;
        IntPtr oaBuffer = BuildObjectAttributes(root, out nameBuffer, out usBuffer);
        IntPtr dirHandle = IntPtr.Zero;
        try
        {
            OBJECT_ATTRIBUTES oa = (OBJECT_ATTRIBUTES)Marshal.PtrToStructure(oaBuffer, typeof(OBJECT_ATTRIBUTES));
            uint st = NtOpenDirectoryObject(out dirHandle, DIRECTORY_QUERY, ref oa);
            if (st != STATUS_SUCCESS)
            {
                error = string.Format("NtOpenDirectoryObject({0}) 失败 status=0x{1:X8}", root, st);
                return results.ToArray();
            }
            int bufferSize = 1 << 16;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                uint context = 0;
                bool restart = true;
                int guard = 0;
                while (guard++ < 20000)
                {
                    uint returned = 0;
                    uint st2 = NtQueryDirectoryObject(dirHandle, buffer, (uint)bufferSize, false, restart, out context, out returned);
                    restart = false;
                    if (st2 == STATUS_NO_MORE_ENTRIES) { break; }
                    if (st2 == STATUS_BUFFER_TOO_SMALL)
                    {
                        bufferSize *= 2;
                        Marshal.FreeHGlobal(buffer);
                        buffer = Marshal.AllocHGlobal(bufferSize);
                        continue;
                    }
                    if (st2 != STATUS_SUCCESS && st2 != STATUS_MORE_ENTRIES)
                    {
                        error = string.Format("NtQueryDirectoryObject({0}) 失败 status=0x{1:X8}", root, st2);
                        break;
                    }
                    int pos = 0;
                    while (true)
                    {
                        int nameLen = Marshal.ReadInt16(buffer, pos);
                        if (nameLen == 0) { break; }
                        IntPtr namePtr = Marshal.ReadIntPtr(buffer, pos + 8);
                        string entryName = namePtr == IntPtr.Zero ? "" : Marshal.PtrToStringUni(namePtr, nameLen / 2);
                        int typeLen = Marshal.ReadInt16(buffer, pos + 16);
                        IntPtr typePtr = Marshal.ReadIntPtr(buffer, pos + 24);
                        string entryType = typePtr == IntPtr.Zero ? "" : Marshal.PtrToStringUni(typePtr, typeLen / 2);
                        if (entryName.Length > 0) { results.Add(entryName + "\t" + entryType); }
                        pos += 32;
                        if ((pos + 32) > (int)returned) { break; }
                    }
                    if (st2 == STATUS_SUCCESS) { break; }
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        catch (Exception ex) { error = "枚举异常: " + ex.Message; }
        finally
        {
            if (dirHandle != IntPtr.Zero) { CloseHandle(dirHandle); }
            FreeObjectAttributes(oaBuffer, nameBuffer, usBuffer);
        }
        return results.ToArray();
    }

    // 解析符号链接对象的目标。失败返回 ""（不抛异常，调用方按空串处理）。
    public static string QuerySymlink(string linkPath, out string error)
    {
        error = "";
        IntPtr nameBuffer = IntPtr.Zero;
        IntPtr usBuffer = IntPtr.Zero;
        IntPtr oaBuffer = BuildObjectAttributes(linkPath, out nameBuffer, out usBuffer);
        IntPtr linkHandle = IntPtr.Zero;
        try
        {
            OBJECT_ATTRIBUTES oa = (OBJECT_ATTRIBUTES)Marshal.PtrToStructure(oaBuffer, typeof(OBJECT_ATTRIBUTES));
            uint st = NtOpenSymbolicLinkObject(out linkHandle, SYMBOLIC_LINK_QUERY, ref oa);
            if (st != STATUS_SUCCESS) { error = string.Format("NtOpenSymbolicLinkObject 失败 status=0x{0:X8}", st); return ""; }
            int cap = 2048;
            IntPtr buf = Marshal.AllocHGlobal(cap * 2);
            try
            {
                UNICODE_STRING target = new UNICODE_STRING();
                target.Length = 0;
                target.MaximumLength = (ushort)(cap * 2);
                target.Buffer = buf;
                uint returned = 0;
                uint st2 = NtQuerySymbolicLinkObject(linkHandle, ref target, out returned);
                if (st2 != STATUS_SUCCESS) { error = string.Format("NtQuerySymbolicLinkObject 失败 status=0x{0:X8}", st2); return ""; }
                int chars = (int)(target.Length / 2);
                if (chars <= 0) { return ""; }
                return Marshal.PtrToStringUni(target.Buffer, chars);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        catch (Exception ex) { error = "解析异常: " + ex.Message; return ""; }
        finally
        {
            if (linkHandle != IntPtr.Zero) { CloseHandle(linkHandle); }
            FreeObjectAttributes(oaBuffer, nameBuffer, usBuffer);
        }
    }
}
'@

function Ensure-LctDrvMapNative {
    param()
    if ($script:LctDrvMapNativeReady) { return $true }
    if ('' -ne $script:LctDrvMapNativeError) { return $false }
    try {
        if (-not ('LctDrvMapNative' -as [type])) {
            Add-Type -TypeDefinition $script:LctDrvMapNativeSource -ErrorAction Stop
        }
        $script:LctDrvMapNativeReady = $true
        return $true
    } catch {
        $script:LctDrvMapNativeError = $_.Exception.Message
        return $false
    }
}

function Split-LctDrvMapEntry {
    param([string]$Line)
    $i = $Line.IndexOf("`t")
    if ($i -lt 0) { return [pscustomobject]@{ name = $Line; type = '' } }
    return [pscustomobject]@{ name = $Line.Substring(0, $i); type = $Line.Substring($i + 1) }
}

function Get-LctDrvMapBaseName {
    # \Device\RTCore64 -> RTCore64；\Driver\KSecDD -> KSecDD；\GLOBAL??\C: -> C:
    param([AllowEmptyString()][string]$Name = '')
    $n = [string]$Name
    if ($n.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring(4) }
    foreach ($p in @('\Device\', '\Driver\', '\GLOBAL??\', '\BaseNamedObjects\')) {
        if ($n.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $n.Substring($p.Length) }
    }
    if ($n.StartsWith('\', [StringComparison]::Ordinal)) { return $n.TrimStart('\') }
    return $n
}

function Get-LctDrvMapAlnumKey {
    # 归一化键：去掉所有非字母数字、转小写（用于「命名略有差异」的兜底匹配）
    param([AllowEmptyString()][string]$Text = '')
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Text).ToCharArray()) {
        if ([char]::IsLetterOrDigit($ch)) { $null = $sb.Append([char]::ToLowerInvariant($ch)) }
    }
    return $sb.ToString()
}

function Get-LctDriverObjectMap {
    <#
    .SYNOPSIS
        枚举设备对象 / 驱动对象 / 全局符号链接，给出「设备 ↔ 驱动 ↔ 服务名」映射（只读）。
    .PARAMETER Service
        只看与该服务/驱动名相关的设备（按驱动对象名或注册表服务名匹配）。
    .PARAMETER MaxLinks
        最多解析多少个 \GLOBAL?? 符号链接（默认 3000；超出会如实标注截断）。
    .PARAMETER IncludeUnresolved
        结果里是否包含无法映射的设备对象（默认包含，方便看边界；想只看成功的加 -IncludeUnresolved:$false）。
    #>
    param(
        [AllowEmptyString()][string]$Service = '',
        [int]$MaxLinks = 3000,
        [bool]$IncludeUnresolved = $true
    )
    $verb = 'driver.map'
    $notes = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if (-not (Ensure-LctDrvMapNative)) {
        return New-LctResult -Verb $verb -Warnings @($warnings) -Errors @('原生互操作不可用（Add-Type 失败）：' + $script:LctDrvMapNativeError) -Data ([pscustomobject]@{ items = @(); count = 0 })
    }
    if ($MaxLinks -lt 1) { $MaxLinks = 1 }
    if ($MaxLinks -gt 20000) { $MaxLinks = 20000 }

    # ---- 1) 枚举三个目录 ----
    $devErr = ''
    $devLines = @([LctDrvMapNative]::EnumDirectory('\Device', [ref]$devErr))
    $drvErr = ''
    $drvLines = @([LctDrvMapNative]::EnumDirectory('\Driver', [ref]$drvErr))
    $lnkErr = ''
    $lnkLines = @([LctDrvMapNative]::EnumDirectory('\GLOBAL??', [ref]$lnkErr))
    if ($devErr -ne '') { $null = $warnings.Add('枚举 \Device 有问题：' + $devErr) }
    if ($drvErr -ne '') { $null = $warnings.Add('枚举 \Driver 有问题：' + $drvErr) }
    if ($lnkErr -ne '') { $null = $warnings.Add('枚举 \GLOBAL?? 有问题：' + $lnkErr) }

    $devices = New-Object System.Collections.ArrayList
    $dirQueue = New-Object System.Collections.ArrayList
    foreach ($l in $devLines) {
        $e = Split-LctDrvMapEntry $l
        if ($e.type -eq 'Directory') { $null = $dirQueue.Add($e.name); continue }
        $full = '\Device\' + $e.name
        $null = $devices.Add([pscustomobject]@{ name = $full; type = $e.type; base = (Get-LctDrvMapBaseName $full) })
    }
    # 递归一层：\Device\Harddisk0 这类目录下还有真正的设备对象（\Device\Harddisk0\DR0）
    $subDirs = 0
    foreach ($d in @($dirQueue)) {
        if ($subDirs -ge 400) { break }
        $subDirs++
        $subErr = ''
        foreach ($sl in @([LctDrvMapNative]::EnumDirectory(('\Device\' + $d), [ref]$subErr))) {
            $se = Split-LctDrvMapEntry $sl
            if ($se.type -eq 'Directory') { continue }
            $full = '\Device\' + $d + '\' + $se.name
            $null = $devices.Add([pscustomobject]@{ name = $full; type = $se.type; base = (Get-LctDrvMapBaseName $full) })
        }
    }
    $driverObjects = New-Object System.Collections.ArrayList
    foreach ($l in $drvLines) {
        $e = Split-LctDrvMapEntry $l
        if ($e.type -eq 'Directory') { continue }
        $null = $driverObjects.Add([pscustomobject]@{ name = ('\Driver\' + $e.name); type = $e.type; base = (Get-LctDrvMapBaseName $e.name) })
    }

    # ---- 2) 解析 \GLOBAL?? 链接（受 MaxLinks 限制） ----
    $linkEntries = @($lnkLines | ForEach-Object { Split-LctDrvMapEntry $_ } | Where-Object { $_.type -eq 'SymbolicLink' })
    $linkTotal = @($linkEntries).Count
    $linkTruncated = $false
    if ($linkTotal -gt $MaxLinks) { $linkEntries = @($linkEntries | Select-Object -First $MaxLinks); $linkTruncated = $true }
    $linksByDevice = @{}
    $linkResolved = 0
    $linkFailed = 0
    foreach ($le in @($linkEntries)) {
        $full = '\GLOBAL??\' + $le.name
        $err = ''
        $target = [string]([LctDrvMapNative]::QuerySymlink($full, [ref]$err))
        if ($target -eq '') { $linkFailed++; continue }
        $linkResolved++
        $tBase = Get-LctDrvMapBaseName $target
        $key = $tBase.ToLowerInvariant()
        if (-not $linksByDevice.ContainsKey($key)) { $linksByDevice[$key] = New-Object System.Collections.ArrayList }
        $null = $linksByDevice[$key].Add([pscustomobject][ordered]@{ link = ('\GLOBAL??\' + $le.name); target = $target })
    }
    if ($linkTruncated) { $null = $warnings.Add('符号链接共 ' + $linkTotal + ' 个，只解析了前 ' + $MaxLinks + ' 个（-MaxLinks 可调大）；截断意味着可能有链接未参与映射') }

    # ---- 2b) PnP 权威旁证：Win32_PnPEntity 的 Service 由 PnP 管理器维护，
    #          是「设备实例 → 驱动服务」的权威映射（与对象管理器那边的命名无关）。
    $pnpByService = @{}
    $pnpAll = @()
    $pnpErr = ''
    try {
        $pnpAll = @(Get-CimInstance Win32_PnPEntity -Property DeviceID, Name, Service, Status -ErrorAction Stop)
        foreach ($p in $pnpAll) {
            $s = [string]$p.Service
            if ($s -eq '') { continue }
            $k = $s.ToLowerInvariant()
            if (-not $pnpByService.ContainsKey($k)) { $pnpByService[$k] = New-Object System.Collections.ArrayList }
            $null = $pnpByService[$k].Add([pscustomobject][ordered]@{ deviceId = [string]$p.DeviceID; name = [string]$p.Name; service = $s; status = [string]$p.Status })
        }
    } catch { $pnpErr = $_.Exception.Message }
    if ($pnpErr -ne '') { $null = $warnings.Add('读取 Win32_PnPEntity 失败（PnP 旁证不可用）：' + $pnpErr) }

    # ---- 3) 建索引 ----
    $drvByExact = @{}
    $drvByAlnum = @{}
    foreach ($d in @($driverObjects)) {
        $k = ([string]$d.base).ToLowerInvariant()
        if (-not $drvByExact.ContainsKey($k)) { $drvByExact[$k] = $d }
        $a = Get-LctDrvMapAlnumKey $d.base
        if ($a -ne '' -and -not $drvByAlnum.ContainsKey($a)) { $drvByAlnum[$a] = $d }
    }

    # ---- 4) 映射 ----
    $items = New-Object System.Collections.ArrayList
    $mapped = 0
    $unresolved = 0
    $byConfidence = [ordered]@{ exact = 0; normalized = 0; unresolved = 0 }
    foreach ($dev in @($devices)) {
        $baseKey = ([string]$dev.base).ToLowerInvariant()
        $hit = $null
        $confidence = 'unresolved'
        $evidence = ''
        if ($drvByExact.ContainsKey($baseKey)) {
            $hit = $drvByExact[$baseKey]
            $confidence = 'exact'
            $evidence = '设备对象名与驱动对象名一致（忽略大小写）'
        } else {
            $a = Get-LctDrvMapAlnumKey $dev.base
            if ($a -ne '' -and $drvByAlnum.ContainsKey($a)) {
                $hit = $drvByAlnum[$a]
                $confidence = 'normalized'
                $evidence = '归一化后（去除非字母数字、转小写）与驱动对象名一致'
            }
        }
        $links = @()
        if ($linksByDevice.ContainsKey($baseKey)) { $links = @($linksByDevice[$baseKey]) }
        # 链接名也可能与服务名一致（例如 \GLOBAL??\RTCore64 -> \Device\RTCore64）
        if ($null -eq $hit -and @($links).Count -gt 0) {
            foreach ($lk in @($links)) {
                $lkBase = Get-LctDrvMapBaseName $lk.link
                $lkKey = ([string]$lkBase).ToLowerInvariant()
                if ($drvByExact.ContainsKey($lkKey)) {
                    $hit = $drvByExact[$lkKey]
                    $confidence = 'via-link-name'
                    $evidence = '通过符号链接名 ' + $lk.link + ' 与驱动对象名一致推导（非权威，仅命名层面）'
                    break
                }
            }
        }
        $serviceName = ''
        $serviceVerified = $false
        if ($null -ne $hit) {
            $serviceName = [string]$hit.base
            $svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $serviceName
            if (Test-Path -LiteralPath $svcKey) { $serviceVerified = $true }
            $mapped++
            $byConfidence[$confidence] = [int]$byConfidence[$confidence] + 1
        } else {
            $unresolved++
            $byConfidence.unresolved = [int]$byConfidence.unresolved + 1
        }
        if ($Service -ne '') {
            $svcKeyLower = ([string]$Service).ToLowerInvariant()
            $match = ($serviceName -ne '' -and $serviceName.ToLowerInvariant() -eq $svcKeyLower) -or
                     ($null -ne $hit -and ([string]$hit.base).ToLowerInvariant() -eq $svcKeyLower)
            if (-not $match) { continue }
        }
        if ($null -eq $hit -and -not $IncludeUnresolved) { continue }
        $null = $items.Add([pscustomobject][ordered]@{
            device         = [string]$dev.name
            deviceType     = [string]$dev.type
            links          = @($links)
            driverObject   = $(if ($null -ne $hit) { [string]$hit.name } else { '' })
            driverName     = $(if ($null -ne $hit) { [string]$hit.base } else { '' })
            serviceName    = $serviceName
            serviceVerified = $serviceVerified
            confidence     = $confidence
            evidence       = $evidence
            pnpDevices     = $(if ($serviceName -ne '' -and $pnpByService.ContainsKey($serviceName.ToLowerInvariant())) { @($pnpByService[$serviceName.ToLowerInvariant()]) } else { @() })
        })
    }

    $null = $notes.Add('设备对象名 ↔ 驱动对象名只在「命名一致」时可映射；命名不一致的设备（如驱动自造的 \Device\HarddiskVolume3）一律标 unresolved，不猜。')
    $null = $notes.Add('serviceName 由驱动对象名推出（\Driver\X ⇒ 服务 X）；只有注册表存在同名服务键才标 serviceVerified=true。')
    $null = $notes.Add('\Device 下只递归一层子目录（例如 \Device\Harddisk0\DR0）；更深的层级不展开，避免枚举失控。链接名（\GLOBAL??\*）可能与设备名或服务名相同，这类只在 via-link-name 置信度下使用，不当作权威。')
    $null = $notes.Add('用户态没有「设备对象 → 驱动对象」的权威 API（在 DEVICE_OBJECT->DriverObject，属内核内存）；需要 100% 权威映射只能用内核读原语（driver.ctl.* + 已加载驱动）。')
    $null = $notes.Add('items 是基于对象管理器名字的映射（可能 unresolved）；pnpDevices 来自 Win32_PnPEntity.Service，是 PnP 管理器维护的权威「设备实例 → 服务」映射，两者互补：-Service <name> 时即使 items 为空，pnpDevices 仍会给出该服务下的设备实例。')

    return New-LctResult -Verb $verb -Warnings @($warnings) -Data ([pscustomobject][ordered]@{
        items      = @($items)
        count      = @($items).Count
        service    = $Service
        stats      = [pscustomobject][ordered]@{
            deviceObjects  = @($devices).Count
            driverObjects  = @($driverObjects).Count
            linksTotal     = $linkTotal
            linksResolved  = $linkResolved
            linksFailed    = $linkFailed
            linksTruncated = $linkTruncated
            mapped         = $mapped
            unresolved     = $unresolved
            byConfidence   = $byConfidence
        }
        pnpDevices = $(if ($Service -ne '') { $sk = ([string]$Service).ToLowerInvariant(); if ($pnpByService.ContainsKey($sk)) { @($pnpByService[$sk]) } else { @() } } else { @() })
        notes      = @($notes)
    })
}

Export-ModuleMember -Function Get-LctDriverObjectMap
