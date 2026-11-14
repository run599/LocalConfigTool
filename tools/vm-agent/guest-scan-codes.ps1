# =====================================================================
# guest-scan-codes.ps1 —— 在 VM 里扫 IOCTL 码 + 结构（最终版）
#
# 关键教训（都是实测踩出来的）：
#   1. PowerShell 调 P/Invoke 的 `out uint` 参数（[ref]）会抛异常 → 封装进 C#
#   2. PowerShell 调 C# 的 `out byte[]` 且传 $null 也会抛 → C# 用**返回对象**
#   3. 内核地址是负数（0xFFFFF8...）→ 用 [Int64] 而不是 [UInt64]
#   4. 中文用户名在 vmrun 命令行会乱码 → 全部用 ASCII 路径 C:\lct\
#
# 输出：C:\lct\code-scan.json
# =====================================================================
$ErrorActionPreference = 'Continue'
$dir = 'C:\lct'
$outPath = Join-Path $dir 'code-scan.json'
$log = New-Object System.Collections.ArrayList
function L([string]$m) { $null = $log.Add(((Get-Date).ToString('HH:mm:ss.fff') + '  ' + $m)) }

if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

$cs = @'
using System;
using System.Runtime.InteropServices;

public class IoctlResult {
    public int rc;              // 0 = 成功；非 0 = Win32 错误码；-1001 = 托管异常
    public int bytesReturned;
    public byte[] data;
    public string error;
}

public class LctProbe {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        byte[] lpInBuffer, uint nInBufferSize, byte[] lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr hObject);
    [DllImport("psapi.dll", SetLastError=true)]
    static extern bool EnumDeviceDrivers(IntPtr[] lpImageBase, uint cb, out uint lpcbNeeded);
    [DllImport("psapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern int GetDeviceDriverBaseNameW(IntPtr ImageBase, System.Text.StringBuilder lpBaseName, int nSize);

    // 打开设备：成功返回 IntPtr；失败返回 IntPtr.Zero 并设置 errCode
    public static IntPtr OpenDevice(string path, out int errCode) {
        errCode = 0;
        try {
            IntPtr h = CreateFileW(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h.ToInt64() == -1) { errCode = Marshal.GetLastWin32Error(); return IntPtr.Zero; }
            return h;
        } catch (Exception) {
            errCode = -1001;
            return IntPtr.Zero;
        }
    }

    public static void CloseDevice(IntPtr h) {
        if (h != IntPtr.Zero) { try { CloseHandle(h); } catch { } }
    }

    // 返回结果对象（不用 out 参数 —— PowerShell 处理 out byte[] 会抛）
    public static IoctlResult Ioctl(IntPtr h, uint code, byte[] inBuf, int outSize) {
        var r = new IoctlResult();
        r.data = new byte[outSize];
        r.bytesReturned = 0;
        r.rc = 0;
        r.error = "";
        try {
            uint ret = 0;
            bool ok = DeviceIoControl(h, code, inBuf, (uint)inBuf.Length, r.data, (uint)outSize, out ret, IntPtr.Zero);
            r.bytesReturned = (int)ret;
            if (!ok) { r.rc = Marshal.GetLastWin32Error(); }
            return r;
        } catch (Exception ex) {
            r.rc = -1001;
            r.error = ex.Message;
            return r;
        }
    }

    public static long KernelBase() {
        try {
            uint need = 0;
            EnumDeviceDrivers(null, 0, out need);
            if (need == 0) { return 0; }
            int cnt = (int)(need / (uint)IntPtr.Size);
            IntPtr[] arr = new IntPtr[cnt];
            if (!EnumDeviceDrivers(arr, need, out need)) { return 0; }
            foreach (IntPtr h in arr) {
                var sb = new System.Text.StringBuilder(260);
                GetDeviceDriverBaseNameW(h, sb, 260);
                string n = sb.ToString();
                if (n.StartsWith("ntoskrnl", StringComparison.OrdinalIgnoreCase) ||
                    n.StartsWith("ntkrnl", StringComparison.OrdinalIgnoreCase)) {
                    return h.ToInt64();
                }
            }
        } catch { }
        return 0;
    }
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; L 'AddType ok' } catch {
    L ('AddType fail: ' + $_.Exception.Message)
    [ordered]@{ ok = $false; error = $_.Exception.Message; log = @($log) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outPath -Encoding UTF8
    return
}

$kb = [Int64]0
try { $kb = [LctProbe]::KernelBase() } catch { L ('kb err: ' + $_.Exception.Message) }
L ('ntoskrnl=0x{0:X}' -f $kb)

# 加载驱动
$svc = 'lctcode'
$null = & sc.exe stop $svc 2>&1
$null = & sc.exe delete $svc 2>&1
$null = & sc.exe create $svc type= kernel binPath= (Join-Path $dir 'target.sys') start= demand 2>&1
$null = & sc.exe start $svc 2>&1
Start-Sleep -Milliseconds 600

# 打开设备
$dev = ''
$h = [IntPtr]::Zero
foreach ($d in @('\\.\RTCore64', '\\.\RTCore64Device', '\\.\PhysicalMemory')) {
    $oe = 0
    $hh = [LctProbe]::OpenDevice($d, [ref]$oe)
    if ($hh -ne [IntPtr]::Zero) { $h = $hh; $dev = $d; break }
    L ('open ' + $d + ' fail err=' + $oe)
}
L ('device=' + $dev)

$res = New-Object System.Collections.ArrayList
if ($dev -ne '') {
    $codes = @(
        0x80002048, 0x8000204C, 0x80002008, 0x8000200C,
        0x80002000, 0x80002004, 0x80002010, 0x80002014,
        0x80002018, 0x8000201C, 0x80002020, 0x80002024,
        0x80002028, 0x8000202C, 0x80002030, 0x80002034,
        0x80002038, 0x8000203C, 0x80002040, 0x80002044,
        0x80002050, 0x80002054
    )
    $specs = @(
        @{ inSize = 40; sizeOff = 16 },
        @{ inSize = 48; sizeOff = 24 },
        @{ inSize = 40; sizeOff = 24 },
        @{ inSize = 48; sizeOff = 16 },
        @{ inSize = 56; sizeOff = 24 }
    )
    foreach ($codeNum in $codes) {
        foreach ($spec in $specs) {
            if (($spec.sizeOff + 4) -gt $spec.inSize) { continue }
            $inB = New-Object byte[] $spec.inSize
            if ($spec.inSize -ge 16) { [BitConverter]::GetBytes([Int64]$kb).CopyTo($inB, 8) }
            [BitConverter]::GetBytes([UInt32]4).CopyTo($inB, $spec.sizeOff)
            # 注意：0x80002048 在 PowerShell 里是 Int32 负数，[uint32] 直接转会抛异常。
            $codeU32 = [System.Convert]::ToUInt32(('{0:X8}' -f $codeNum), 16)
            $r = $null
            try { $r = [LctProbe]::Ioctl($h, $codeU32, $inB, 48) } catch { $r = $null }
            if ($null -eq $r) {
                $null = $res.Add([pscustomobject][ordered]@{
                        code = ('0x{0:X8}' -f $codeNum); inSize = $spec.inSize; sizeOff = $spec.sizeOff
                        ok = $false; err = -1002; ret = 0; hex = ''
                    })
                continue
            }
            $hex = ''
            if ($r.rc -eq 0 -and $r.bytesReturned -gt 0) {
                $n = [Math]::Min([int]$r.bytesReturned, 16)
                $hex = [BitConverter]::ToString($r.data, 0, $n)
            }
            $null = $res.Add([pscustomobject][ordered]@{
                    code = ('0x{0:X8}' -f $codeNum); inSize = $spec.inSize; sizeOff = $spec.sizeOff
                    ok = ($r.rc -eq 0); err = [int]$r.rc; ret = [int]$r.bytesReturned; hex = $hex
                })
            if ($r.rc -ne 87 -or $r.bytesReturned -gt 0) {
                L ('HIT code=0x{0:X8} in={1} off={2} rc={3} ret={4} hex={5}' -f $codeNum, $spec.inSize, $spec.sizeOff, $r.rc, $r.bytesReturned, $hex)
            }
        }
    }
}

# 清理
try {
    [LctProbe]::CloseDevice($h)
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    L 'cleanup done'
} catch { }

$hits = @($res | Where-Object { $_.err -ne 87 -or $_.ret -gt 0 })
$final = [ordered]@{
    ranAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    kernelBase = ('0x{0:X}' -f $kb)
    device     = $dev
    tried      = @($res).Count
    hits       = $hits
    all        = @($res)
    log        = @($log)
}
$final | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output ('CODE SCAN tried=' + @($res).Count + ' hits=' + @($hits).Count)
