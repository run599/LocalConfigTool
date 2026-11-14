# guest-anchor.ps1 - kread 读内核对象，拿 DRIVER_OBJECT / MajorFunction[]
#
# 环境变量：
$h = [IntPtr]::Zero
#   LCT_SYS      要加载的 .sys（可选；不给则认为是已加载）
#   LCT_SVC      服务名（默认 lctanchor）
#   LCT_DEVICES  设备候选，分号分隔（默认 \\.\RTCore64）
#   LCT_NOLOAD   1 = 不要加载/卸载驱动（默认 0）
#   LCT_IOCTL    kread 的 IOCTL 码（默认 0x80002048）
#   LCT_OUT      输出 JSON 路径（默认 C:\lct\anchor.json）
#
# 输出：{ ok, log[], ntoskrnl, psLoadedModuleList, fileObject, deviceObject,
#         driverObject, driverName, driverStart, driverSize, majorFunctions[],
#         capability{}, selfCheck{}, kreadCalls, elapsedMs }

$ErrorActionPreference = 'Continue'
$scriptDir = 'C:\lct'
if (-not (Test-Path -LiteralPath $scriptDir)) { $null = New-Item -ItemType Directory -Path $scriptDir -Force }
$log = New-Object System.Collections.ArrayList
function L($m) { $null = $log.Add([string]$m) }
$out = [ordered]@{ ok = $false; log = @(); error = '' }

function Get-EnvOr($name, $def) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $def }
    return $v
}

$sysPath   = Get-EnvOr 'LCT_SYS' ''
$svc       = Get-EnvOr 'LCT_SVC' 'lctanchor'
$devText   = Get-EnvOr 'LCT_DEVICES' '\\.\RTCore64'
$noLoad    = (Get-EnvOr 'LCT_NOLOAD' '0') -eq '1'
$ioctlText = Get-EnvOr 'LCT_IOCTL' '0x80002048'
$outPath   = Get-EnvOr 'LCT_OUT' (Join-Path $scriptDir 'anchor.json')

function Write-Result {
    $out.log = @($log)
    try {
        $txt = $out | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $outPath -Value $txt -Encoding UTF8
    } catch { }
    Write-Output 'ANCHOR_DONE'
}

# ---------- 1) C# ----------
$cs = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LctAnchor {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentProcessId();
    [DllImport("ntdll.dll")]
    public static extern uint NtQuerySystemInformation(uint cls, IntPtr buf, uint len, out uint ret);
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EnumDeviceDrivers(IntPtr[] arr, uint cb, out uint needed);
    [DllImport("psapi.dll", CharSet = CharSet.Unicode)]
    public static extern uint GetDeviceDriverBaseNameW(IntPtr imageBase, StringBuilder name, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint ret, IntPtr ov);

    public static uint IoctlCode = 0x80002048u;
    public static int Calls = 0;

    // ntoskrnl 基址：必须用 EnumDeviceDrivers 按名字匹配。
    // SystemModuleInformation(11) 的 ImageBase 不是可读地址（实测读出来全 0）。
    public static long KernelBase() {
        uint need = 0;
        EnumDeviceDrivers(null, 0, out need);
        if (need == 0) { return 0; }
        IntPtr[] arr = new IntPtr[(int)(need / IntPtr.Size)];
        uint got = 0;
        if (!EnumDeviceDrivers(arr, need, out got)) { return 0; }
        foreach (IntPtr d in arr) {
            StringBuilder sb = new StringBuilder(260);
            GetDeviceDriverBaseNameW(d, sb, 260);
            string nm = sb.ToString();
            if (nm.StartsWith("ntoskrnl", StringComparison.OrdinalIgnoreCase) ||
                nm.StartsWith("ntkrnl", StringComparison.OrdinalIgnoreCase)) { return d.ToInt64(); }
        }
        return 0;
    }

    // 单次 kread：RTCore64 只支持 1/2/4 字节，传 8 及以上会"成功但没读"（返回全 0）
    public static byte[] Read4(IntPtr h, long addr) {
        byte[] ib = new byte[48];
        Array.Copy(BitConverter.GetBytes(addr), 0, ib, 8, 8);
        Array.Copy(BitConverter.GetBytes((uint)4), 0, ib, 24, 4);
        byte[] ob = new byte[48];
        uint ret = 0;
        Calls++;
        if (!DeviceIoControl(h, IoctlCode, ib, 48, ob, 48, out ret, IntPtr.Zero)) { return null; }
        return new byte[] { ob[28], ob[29], ob[30], ob[31] };
    }

    // 任意长度：按 4 字节对齐循环读再切片
    public static byte[] Read(IntPtr h, long addr, int size) {
        if (size <= 0) { return null; }
        long start = addr & ~3L;
        int pre = (int)(addr - start);
        int chunks = (pre + size + 3) / 4;
        byte[] res = new byte[size];
        for (int i = 0; i < chunks; i++) {
            byte[] d = Read4(h, start + (long)i * 4);
            if (d == null) { return null; }
            for (int k = 0; k < 4; k++) {
                int idx = i * 4 + k - pre;
                if (idx >= 0 && idx < size) { res[idx] = d[k]; }
            }
        }
        return res;
    }

    public static long Ptr(IntPtr h, long addr) { byte[] b = Read(h, addr, 8); return b == null ? 0 : BitConverter.ToInt64(b, 0); }
    public static int I32(IntPtr h, long addr) { byte[] b = Read(h, addr, 4); return b == null ? 0 : BitConverter.ToInt32(b, 0); }
    public static ushort U16(IntPtr h, long addr) { byte[] b = Read(h, addr, 2); return b == null ? (ushort)0 : BitConverter.ToUInt16(b, 0); }

    public static string CStr(IntPtr h, long addr, int max) {
        byte[] b = Read(h, addr, max);
        if (b == null) { return null; }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < b.Length && b[i] != 0; i++) { sb.Append((char)b[i]); }
        return sb.ToString();
    }

    public static string WStr(IntPtr h, long addr) {
        ushort len = U16(h, addr);
        long buf = Ptr(h, addr + 8);
        if (len == 0 || len > 512 || buf == 0) { return null; }
        byte[] b = Read(h, buf, len);
        if (b == null) { return null; }
        return Encoding.Unicode.GetString(b);
    }

    // 有效内核地址：负 long 且高 16 位全 F
    public static bool IsKernel(long v) { return v < 0 && (((v >> 48) & 0xFFFF) == 0xFFFF); }

    // 句柄表 -> 该 handle 对应的对象体地址
    public static long FindObject(long wantHandle) {
        uint need = 0x400000;
        for (int a = 0; a < 14; a++) {
            IntPtr buf = Marshal.AllocHGlobal((int)need);
            try {
                uint got = 0;
                uint st = NtQuerySystemInformation(64, buf, need, out got);
                if (st == 0) {
                    long cnt = Marshal.ReadIntPtr(buf).ToInt64();
                    IntPtr p = new IntPtr(buf.ToInt64() + 16);
                    long pid = (long)GetCurrentProcessId();
                    for (long i = 0; i < cnt; i++) {
                        long obj = Marshal.ReadIntPtr(p).ToInt64();
                        if (Marshal.ReadIntPtr(p, 8).ToInt64() == pid &&
                            Marshal.ReadIntPtr(p, 16).ToInt64() == wantHandle) { return obj; }
                        p = new IntPtr(p.ToInt64() + 0x28);
                    }
                    return 0;
                }
                if (st != 0xC0000004u) { return 0; }
                need = got > need ? got + 0x10000 : need * 2;
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return 0;
    }

    // 导出表二分查找（导出名按字节序排列）
    public static long FindExport(IntPtr h, long ntBase, string target) {
        int lfanew = I32(h, ntBase + 0x3C);
        int expRva = I32(h, ntBase + lfanew + 0x88);
        if (expRva == 0) { return 0; }
        byte[] exp = Read(h, ntBase + expRva, 0x28);
        if (exp == null) { return 0; }
        int numNames = BitConverter.ToInt32(exp, 0x18);
        int addrFuncs = BitConverter.ToInt32(exp, 0x1C);
        int addrNames = BitConverter.ToInt32(exp, 0x20);
        int addrOrds = BitConverter.ToInt32(exp, 0x24);
        if (numNames <= 0 || numNames > 500000) { return 0; }
        int lo = 0, hi = numNames - 1;
        while (lo <= hi) {
            int mid = (lo + hi) / 2;
            int nameRva = I32(h, ntBase + addrNames + (long)mid * 4);
            if (nameRva == 0) { return 0; }
            string nm = CStr(h, ntBase + nameRva, 64);
            if (nm == null) { return 0; }
            int cmp = string.CompareOrdinal(nm, target);
            if (cmp == 0) {
                ushort ord = U16(h, ntBase + addrOrds + (long)mid * 2);
                return ntBase + I32(h, ntBase + addrFuncs + (long)ord * 4);
            }
            if (cmp < 0) { lo = mid + 1; } else { hi = mid - 1; }
        }
        return 0;
    }
}
"@

try {
    Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
    L 'C# 编译成功'
} catch {
    $out.error = 'C# 编译失败: ' + $_.Exception.Message
    L $out.error
    Write-Result
    return
}

# ---------- 2) 加载驱动 ----------
if (-not $noLoad -and -not [string]::IsNullOrWhiteSpace($sysPath)) {
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    Start-Sleep -Milliseconds 700
    $cr = & sc.exe create $svc type= kernel binPath= $sysPath start= demand 2>&1
    L ('sc create -> ' + (($cr | ForEach-Object { [string]$_ }) -join ' '))
    $sr = & sc.exe start $svc 2>&1
    $svcState = ($sr | Select-String 'STATE' | ForEach-Object { $_.Line.Trim() })
    L ('sc start -> ' + $svcState)
    Start-Sleep -Milliseconds 900
}

try {
    # ---------- 3) 打开设备 ----------
    $access = [System.Convert]::ToUInt32('C0000000', 16)
    $h = [IntPtr]::Zero
    $usedDev = ''
    foreach ($d in @($devText -split ';' | Where-Object { $_.Trim() -ne '' })) {
        $cand = $d.Trim()
        $hh = [LctAnchor]::CreateFileW($cand, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($hh.ToInt64() -ne -1 -and $hh.ToInt64() -ne 0) { $h = $hh; $usedDev = $cand; break }
        L ('open ' + $cand + ' failed err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    if ($h.ToInt64() -eq 0) { throw '所有设备候选都打不开' }
    $out.device = $usedDev
    L ('device = ' + $usedDev)

    # ---------- 4) ntoskrnl + PsLoadedModuleList ----------
    $ntBase = [LctAnchor]::KernelBase()
    $out.ntoskrnl = ('0x' + $ntBase.ToString('X'))
    L ('ntoskrnl = 0x' + $ntBase.ToString('X'))
    if ($ntBase -eq 0) { throw '取 ntoskrnl 基址失败' }
    $mz = [LctAnchor]::Read($h, $ntBase, 4)
    if ($mz -eq $null -or $mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) { throw 'kread 自检失败：读 ntoskrnl 得不到 MZ' }
    L 'kread 自检通过（读到 MZ）'

    # ---------- 5) 句柄 -> FILE_OBJECT -> DEVICE_OBJECT -> DRIVER_OBJECT ----------
    $fileObj = [LctAnchor]::FindObject($h.ToInt64())
    $out.fileObject = ('0x' + $fileObj.ToString('X'))
    L ('FILE_OBJECT = 0x' + $fileObj.ToString('X'))
    if (-not [LctAnchor]::IsKernel($fileObj)) { throw 'FILE_OBJECT 不是有效内核地址（句柄表可能没匹配到）' }

    $devObj = [LctAnchor]::Ptr($h, $fileObj + 0x08)
    $out.deviceObject = ('0x' + $devObj.ToString('X'))
    L ('DEVICE_OBJECT = 0x' + $devObj.ToString('X'))
    if (-not [LctAnchor]::IsKernel($devObj)) { throw 'DEVICE_OBJECT 不是有效内核地址' }

    $drvObj = [LctAnchor]::Ptr($h, $devObj + 0x08)
    $out.driverObject = ('0x' + $drvObj.ToString('X'))
    L ('DRIVER_OBJECT = 0x' + $drvObj.ToString('X'))
    if (-not [LctAnchor]::IsKernel($drvObj)) { throw 'DRIVER_OBJECT 不是有效内核地址' }

    # ---------- 6) DRIVER_OBJECT 字段 ----------
    $ty = [LctAnchor]::U16($h, $drvObj)
    $drvStart = [LctAnchor]::Ptr($h, $drvObj + 0x18)
    $drvSize = [LctAnchor]::I32($h, $drvObj + 0x20)
    $drvName = [LctAnchor]::WStr($h, $drvObj + 0x38)
    $out.driverStart = ('0x' + $drvStart.ToString('X'))
    $out.driverSize = ('0x' + $drvSize.ToString('X'))
    $out.driverName = $drvName
    L ('Type=0x' + $ty.ToString('X') + '  DriverStart=0x' + $drvStart.ToString('X') + '  DriverSize=0x' + $drvSize.ToString('X'))
    L ('DriverName = ' + $drvName)

    # ---------- 7) MajorFunction[0..27] ----------
    $irpNames = @(
        'IRP_MJ_CREATE', 'IRP_MJ_CREATE_NAMED_PIPE', 'IRP_MJ_CLOSE', 'IRP_MJ_READ'
        'IRP_MJ_WRITE', 'IRP_MJ_QUERY_INFORMATION', 'IRP_MJ_SET_INFORMATION', 'IRP_MJ_QUERY_EA'
        'IRP_MJ_SET_EA', 'IRP_MJ_FLUSH_BUFFERS', 'IRP_MJ_QUERY_VOLUME_INFORMATION', 'IRP_MJ_SET_VOLUME_INFORMATION'
        'IRP_MJ_DIRECTORY_CONTROL', 'IRP_MJ_FILE_SYSTEM_CONTROL', 'IRP_MJ_DEVICE_CONTROL', 'IRP_MJ_INTERNAL_DEVICE_CONTROL'
        'IRP_MJ_SHUTDOWN', 'IRP_MJ_LOCK_CONTROL', 'IRP_MJ_CLEANUP', 'IRP_MJ_CREATE_MAILSLOT'
        'IRP_MJ_QUERY_SECURITY', 'IRP_MJ_SET_SECURITY', 'IRP_MJ_POWER', 'IRP_MJ_SYSTEM_CONTROL'
        'IRP_MJ_DEVICE_CHANGE', 'IRP_MJ_QUERY_QUOTA', 'IRP_MJ_SET_QUOTA', 'IRP_MJ_PNP'
    )
    $mf = @()
    $inDriver = 0
    for ($i = 0; $i -lt 28; $i++) {
        $fp = [LctAnchor]::Ptr($h, $drvObj + 0x70 + $i * 8)
        $rva = -1
        if ([LctAnchor]::IsKernel($fp) -and [LctAnchor]::IsKernel($drvStart)) { $rva = $fp - $drvStart }
        $inside = ($rva -ge 0 -and $rva -lt $drvSize)
        if ($inside) { $inDriver++ }
        $mf += [ordered]@{
            irp      = $i
            name     = $irpNames[$i]
            address  = ('0x' + $fp.ToString('X'))
            rva      = $(if ($rva -ge 0) { '0x' + $rva.ToString('X') } else { '' })
            inDriver = $inside
        }
    }
    $out.majorFunctions = $mf
    L ('MajorFunction: 28 项中 ' + $inDriver + ' 个落在驱动内')

    # ---------- 8) 能力面 ----------
    $devCtl = $mf[14]
    $cap = [ordered]@{
        hasCreate        = $mf[0].inDriver
        hasClose         = $mf[2].inDriver
        hasRead          = $mf[3].inDriver
        hasWrite         = $mf[4].inDriver
        hasDeviceControl = $devCtl.inDriver
        hasInternalCtl   = $mf[15].inDriver
        hasShutdown      = $mf[16].inDriver
        hasPower         = $mf[22].inDriver
        hasPnp           = $mf[27].inDriver
        ioctlDispatchRva = $devCtl.rva
        handledIrpCount  = $inDriver
    }
    $out.capability = $cap
    L ('能力面: CREATE=' + $cap.hasCreate + ' READ=' + $cap.hasRead + ' WRITE=' + $cap.hasWrite + ' DEVICE_CONTROL=' + $cap.hasDeviceControl)
    if ($cap.hasDeviceControl) { L ('IOCTL 分派 RVA = ' + $cap.ioctlDispatchRva) }
    else { L '这个设备不处理 IRP_MJ_DEVICE_CONTROL（MajorFunction[14] 不在驱动内）' }

    # ---------- 9) 自校验 ----------
    $self = [ordered]@{
        typeIs4          = ($ty -eq 4)
        driverStartValid = [LctAnchor]::IsKernel($drvStart)
        driverSizeValid  = ($drvSize -gt 0)
        startHasMz       = $false
        dispatchInRange  = ($devCtl.inDriver -or -not $cap.hasDeviceControl)
    }
    $head = [LctAnchor]::Read($h, $drvStart, 2)
    if ($head -ne $null) { $self.startHasMz = ($head[0] -eq 0x4D -and $head[1] -eq 0x5A) }
    $out.selfCheck = $self
    L ('自校验: Type==4:' + $self.typeIs4 + ' Start有效:' + $self.driverStartValid + ' Size>0:' + $self.driverSizeValid + ' Start有MZ:' + $self.startHasMz)

    $fails = @()
    if (-not $self.typeIs4) { $fails += 'Type 不是 4（DRIVER_OBJECT 偏移可能不对）' }
    if (-not $self.driverStartValid) { $fails += 'DriverStart 不是内核地址' }
    if (-not $self.driverSizeValid) { $fails += 'DriverSize 为 0' }
    if (-not $self.startHasMz) { $fails += 'DriverStart 处没有 MZ（可能不是 PE 基址）' }
    $out.ok = (@($fails).Count -eq 0)
    if (@($fails).Count -gt 0) { $out.error = ($fails -join '; ') }

    # handle 在 finally 里关闭（避免异常泄漏，泄漏会拖住 DriverObject 引用）
} catch {
    $out.error = $_.Exception.Message
    L ('异常: ' + $_.Exception.Message)
} finally {
    if ($null -ne $h -and $h.ToInt64() -ne 0) { try { [LctAnchor]::CloseHandle($h) | Out-Null } catch { } }
    if (-not $noLoad -and -not [string]::IsNullOrWhiteSpace($sysPath)) {
        $null = & sc.exe stop $svc 2>&1
        $null = & sc.exe delete $svc 2>&1
        L '驱动已卸载'
    }
}

$out.kreadCalls = [LctAnchor]::Calls
L ('kread 调用次数 = ' + [LctAnchor]::Calls)
Write-Result