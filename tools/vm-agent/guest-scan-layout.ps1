# =====================================================================
# guest-scan-layout.ps1 —— 在 VM 里扫描 IOCTL 输入结构布局
#
# 目的：RTCore64 的 kread(0x80002048) 在不同来源的结构定义不一致。
#       本脚本穷举 (inSize, readSizeOffset) 组合，看哪个返回 87 以外的结果。
#
# 输出：C:\lct\layout-scan.json
# =====================================================================
$ErrorActionPreference = 'Continue'
$dir = 'C:\lct'
$outPath = Join-Path $dir 'layout-scan.json'
$log = New-Object System.Collections.ArrayList
function L([string]$m) { $null = $log.Add(((Get-Date).ToString('HH:mm:ss.fff') + '  ' + $m)) }

if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

$cs = @'
using System;
using System.Runtime.InteropServices;
public class LctK2 {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        byte[] lpInBuffer, uint nInBufferSize, byte[] lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("psapi.dll", SetLastError=true)]
    public static extern bool EnumDeviceDrivers(IntPtr[] lpImageBase, uint cb, out uint lpcbNeeded);
    [DllImport("psapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern int GetDeviceDriverBaseNameW(IntPtr ImageBase, System.Text.StringBuilder lpBaseName, int nSize);
}
'@
try { Add-Type -TypeDefinition $cs -ErrorAction Stop; L 'P/Invoke ok' } catch {
    L ('Add-Type failed: ' + $_.Exception.Message)
    $r = [ordered]@{ ok = $false; error = $_.Exception.Message; log = @($log) }
    $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outPath -Encoding UTF8
    return
}

# ntoskrnl 基址
$kernelBase = [Int64]0
try {
    $need = [uint32]0
    $null = [LctK2]::EnumDeviceDrivers($null, 0, [ref]$need)
    if ($need -gt 0) {
        $arr = New-Object IntPtr[] ([int]($need / [IntPtr]::Size))
        if ([LctK2]::EnumDeviceDrivers($arr, $need, [ref]$need)) {
            foreach ($h in $arr) {
                $sb = New-Object System.Text.StringBuilder 260
                $null = [LctK2]::GetDeviceDriverBaseNameW($h, $sb, 260)
                if ($sb.ToString() -match '(?i)^ntoskrnl|^ntkrnl') { $kernelBase = [Int64]$h; break }
            }
        }
    }
} catch { L ('enum err: ' + $_.Exception.Message) }
L ('ntoskrnl = 0x{0:X}' -f $kernelBase)

# 加载驱动
$svc = 'lctscan'
$sysPath = Join-Path $dir 'target.sys'
$null = & sc.exe stop $svc 2>&1
$null = & sc.exe delete $svc 2>&1
$c = & sc.exe create $svc type= kernel binPath= $sysPath start= demand 2>&1
L ('create: ' + (($c | ForEach-Object { [string]$_ }) -join ' '))
$s = & sc.exe start $svc 2>&1
L ('start: ' + (($s | ForEach-Object { [string]$_ }) -join ' '))
Start-Sleep -Milliseconds 600

# 打开设备
$access = [System.Convert]::ToUInt32('C0000000', 16)
$h = [IntPtr]::Zero
$usedDev = ''
foreach ($d in @('\\.\RTCore64', '\\.\RTCore64Device', '\\.\PhysicalMemory')) {
    $hh = [LctK2]::CreateFileW($d, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($hh.ToInt64() -ne -1 -and $hh.ToInt64() -ne 0) { $h = $hh; $usedDev = $d; break }
}
L ('device=' + $usedDev)

$results = New-Object System.Collections.ArrayList
if ($usedDev -ne '' -and $kernelBase -ne 0) {
    $code = [Convert]::ToUInt32('80002048', 16)
    L ('ioctl=0x{0:X8}' -f $code)
    # 穷举：in 大小 × readSize 偏移 × out 大小
    $inSizes = @(40, 48, 56, 64)
    $sizeOffsets = @(16, 20, 24, 28)
    $outSizes = @(48, 64)
    foreach ($inSize in $inSizes) {
        foreach ($sizeOff in $sizeOffsets) {
            foreach ($outSize in $outSizes) {
                if (($sizeOff + 4) -gt $inSize) { continue }
                $inBuf = New-Object byte[] $inSize
                # addr 固定放在 8（所有已知结构都在这）
                if ($inSize -ge 16) { [BitConverter]::GetBytes([Int64]$kernelBase).CopyTo($inBuf, 8) }
                [BitConverter]::GetBytes([UInt32]4).CopyTo($inBuf, $sizeOff)
                $outBuf = New-Object byte[] $outSize
                $ret = [uint32]0
                $ok = $false
                $err = 0
                try {
                    $ok = [LctK2]::DeviceIoControl($h, [uint32]$code, $inBuf, [uint32]$inSize, $outBuf, [uint32]$outSize, [ref]$ret, [IntPtr]::Zero)
                    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                } catch {
                    $err = -999
                }
                $hex = ''
                if ($ok -and $ret -gt 0) { $hex = [BitConverter]::ToString($outBuf, 0, [Math]::Min([int]$ret, 16)) }
                $null = $results.Add([pscustomobject][ordered]@{
                        inSize = $inSize; sizeOffset = $sizeOff; outSize = $outSize
                        ok = $ok; win32Error = $err; bytesReturned = [int]$ret; outHex = $hex
                    })
                L ('in={0} sizeOff={1} out={2} -> ok={3} err={4} ret={5} hex={6}' -f $inSize, $sizeOff, $outSize, $ok, $err, $ret, $hex)
            }
        }
    }
}

# 清理
try {
    if ($h.ToInt64() -ne -1 -and $h.ToInt64() -ne 0) { $null = [LctK2]::CloseHandle($h) }
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    L 'cleanup done'
} catch { }

$final = [ordered]@{
    ranAt        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    kernelBase   = ('0x{0:X}' -f $kernelBase)
    device       = $usedDev
    totalTried   = @($results).Count
    nonError87   = @($results | Where-Object { $_.win32Error -ne 87 })
    results      = @($results)
    log          = @($log)
}
$final | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Output ('SCAN DONE tried=' + @($results).Count + ' non87=' + @($final.nonError87).Count)
