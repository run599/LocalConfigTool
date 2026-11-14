# 最小诊断：拿 LctProbe::Ioctl 的真实异常消息
$ErrorActionPreference = 'Continue'
$dir = 'C:\lct'
$outPath = Join-Path $dir 'diag.json'
$o = [ordered]@{ steps = @(); error = ''; errType = ''; rc = 0; ret = 0; dev = ''; kb = '' }

$cs = @'
using System;
using System.Runtime.InteropServices;
public class IoctlResult2 {
    public int rc;
    public int bytesReturned;
    public byte[] data;
    public string error;
}
public class LctP2 {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inB, uint inS, byte[] outB, uint outS, out uint ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll", SetLastError=true)]
    static extern bool EnumDeviceDrivers(IntPtr[] b, uint cb, out uint needed);
    [DllImport("psapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern int GetDeviceDriverBaseNameW(IntPtr b, System.Text.StringBuilder sb, int n);

    public static IntPtr Open(string path, out int err) {
        err = 0;
        try {
            IntPtr h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h.ToInt64() == -1) { err = Marshal.GetLastWin32Error(); return IntPtr.Zero; }
            return h;
        } catch (Exception) { err = -1001; return IntPtr.Zero; }
    }
    public static void Close(IntPtr h) { if (h != IntPtr.Zero) { try { CloseHandle(h); } catch { } } }

    public static IoctlResult2 Call(IntPtr h, uint code, byte[] inBuf, int outSize) {
        var r = new IoctlResult2();
        r.data = new byte[outSize];
        r.rc = 0; r.bytesReturned = 0; r.error = "";
        try {
            uint ret = 0;
            bool ok = DeviceIoControl(h, code, inBuf, (uint)inBuf.Length, r.data, (uint)outSize, out ret, IntPtr.Zero);
            r.bytesReturned = (int)ret;
            if (!ok) { r.rc = Marshal.GetLastWin32Error(); }
            return r;
        } catch (Exception e) {
            r.rc = -2001;
            r.error = e.ToString();
            return r;
        }
    }
    public static long Kb() {
        try {
            uint need = 0;
            EnumDeviceDrivers(null, 0, out need);
            if (need == 0) return 0;
            IntPtr[] arr = new IntPtr[(int)(need / (uint)IntPtr.Size)];
            if (!EnumDeviceDrivers(arr, need, out need)) return 0;
            foreach (IntPtr h in arr) {
                var sb = new System.Text.StringBuilder(260);
                GetDeviceDriverBaseNameW(h, sb, 260);
                string n = sb.ToString();
                if (n.StartsWith("ntoskrnl", StringComparison.OrdinalIgnoreCase) || n.StartsWith("ntkrnl", StringComparison.OrdinalIgnoreCase)) return h.ToInt64();
            }
        } catch { }
        return 0;
    }
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; $o.steps += 'AddType ok' } catch {
    $o.steps += ('AddType FAIL: ' + $_.Exception.Message)
    $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding UTF8
    return
}

# 内核基址
try { $kb = [LctP2]::Kb(); $o.kb = ('0x{0:X}' -f $kb); $o.steps += ('kb=0x{0:X}' -f $kb) } catch {
    $o.steps += ('kb FAIL: ' + $_.Exception.Message)
}

# 加载
$null = & sc.exe stop lctdiag 2>&1
$null = & sc.exe delete lctdiag 2>&1
$null = & sc.exe create lctdiag type= kernel binPath= (Join-Path $dir 'target.sys') start= demand 2>&1
$null = & sc.exe start lctdiag 2>&1
Start-Sleep -Milliseconds 700

# 打开
$oe = 0
$h = [IntPtr]::Zero
try { $h = [LctP2]::Open('\\.\RTCore64', [ref]$oe); $o.dev = ('handle=' + $h.ToInt64() + ' openErr=' + $oe) } catch {
    $o.steps += ('open FAIL: ' + $_.Exception.Message)
}
$o.steps += ('dev: ' + $o.dev)

# 发 IOCTL（最小：全 0 的 48 字节）
if ($h -ne [IntPtr]::Zero) {
    $inB = New-Object byte[] 48
    try {
        $r = [LctP2]::Call($h, [uint32]0x80002048, $inB, 48)
        $o.rc = [int]$r.rc
        $o.ret = [int]$r.bytesReturned
        $o.error = [string]$r.error
        $o.steps += ('call ok rc=' + $r.rc + ' ret=' + $r.bytesReturned)
    } catch {
        $o.errType = $_.Exception.GetType().FullName
        $o.error = $_.Exception.Message
        $o.steps += ('call FAIL type=' + $o.errType + ' msg=' + $o.error)
    }
    [LctP2]::Close($h)
}
$null = & sc.exe stop lctdiag 2>&1
$null = & sc.exe delete lctdiag 2>&1
$o.steps += 'done'
$o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output ('DIAG rc=' + $o.rc + ' err=' + $o.error)
