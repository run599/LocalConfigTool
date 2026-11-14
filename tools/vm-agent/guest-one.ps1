# 最小单发验证：只发一个 IOCTL（0x80002048），确认码转换修复生效
$ErrorActionPreference = 'Continue'
$dir = 'C:\lct'
$outPath = Join-Path $dir 'one.json'
$o = [ordered]@{ steps = @(); rc = -1; ret = 0; hex = ''; dev = ''; kb = ''; codeArg = ''; error = '' }

$cs = @'
using System;
using System.Runtime.InteropServices;
public class OneResult {
    public int rc;
    public int bytesReturned;
    public byte[] data;
    public string error;
}
public class LctOne {
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
    public static OneResult Call(IntPtr h, uint code, byte[] inBuf, int outSize) {
        var r = new OneResult();
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
            r.error = e.Message;
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

$kb = [Int64]0
try { $kb = [LctOne]::Kb() } catch { }
$o.kb = ('0x{0:X}' -f $kb)

$svc = 'lctone'
$null = & sc.exe stop $svc 2>&1
$null = & sc.exe delete $svc 2>&1
$null = & sc.exe create $svc type= kernel binPath= (Join-Path $dir 'target.sys') start= demand 2>&1
$st = & sc.exe start $svc 2>&1
$o.steps += ('start: ' + (($st | Where-Object { $_ -match 'STATE|失败|错误' }) -join ' '))
Start-Sleep -Milliseconds 800

$oe = 0
$h = [LctOne]::Open('\\.\RTCore64', [ref]$oe)
$o.dev = ('handle=' + $h.ToInt64() + ' openErr=' + $oe)

if ($h -ne [IntPtr]::Zero -and $kb -ne 0) {
    # 48 字节：pad0(8) addr(u64@8) pad1(u32) offset(u32) readSize(u32@24) value(u32) pad3(16)
    $inB = New-Object byte[] 48
    [BitConverter]::GetBytes([Int64]$kb).CopyTo($inB, 8)
    [BitConverter]::GetBytes([UInt32]4).CopyTo($inB, 24)
    # 关键：0x80002048 在 PowerShell 里是 Int32 负数，必须用 Convert
    $codeArg = [System.Convert]::ToUInt32('80002048', 16)
    $o.codeArg = ('0x{0:X8} (uint32={1})' -f $codeArg, $codeArg)
    $o.steps += ('code=' + $o.codeArg)
    try {
        $r = [LctOne]::Call($h, $codeArg, $inB, 48)
        $o.rc = [int]$r.rc
        $o.ret = [int]$r.bytesReturned
        $o.error = [string]$r.error
        if ($r.rc -eq 0 -and $r.bytesReturned -gt 0) {
            $o.hex = [BitConverter]::ToString($r.data, 0, [Math]::Min([int]$r.bytesReturned, 64))
        }
        $o.steps += ('call rc=' + $r.rc + ' ret=' + $r.bytesReturned + ' hex=' + $o.hex)
    } catch {
        $o.steps += ('call EXCEPTION: ' + $_.Exception.Message)
    }
} else {
    $o.steps += 'device or kb unavailable'
}

try {
    [LctOne]::Close($h)
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    $o.steps += 'cleanup done'
} catch { }

$o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output ('ONE rc=' + $o.rc + ' ret=' + $o.ret + ' hex=' + $o.hex)
