# =====================================================================
# guest-probe.ps1 —— 在 VM（guest）里运行的 IOCTL 探测脚本
#
# 由主机通过 vmrun copyFileFromHostToGuest 推送进来，用 runProgramInGuest 执行。
# 不依赖任何第三方模块，只用 Windows PowerShell 5.1 自带能力。
#
# 职责：
#   1. 用 EnumDeviceDrivers 取 ntoskrnl 基址（作为 kread 的默认目标）
#   2. sc create/start 加载指定的 .sys
#   3. 尝试打开设备（多个候选符号链接）
#   4. 发一条 IOCTL（kread：读内核内存），如实记录返回
#   5. sc stop/delete 清理
#   6. 把全部结果写进 result.json（主机拉回去判定）
#
# 参数（用环境变量传入，避免 vmrun 参数转义的坑）：
#   LCT_SYS      要加载的 .sys 完整路径（默认 C:\lct\target.sys）
#   LCT_SVC      服务名（默认 lctprobe）
#   LCT_IOCTL    IOCTL 码（hex，默认 0x80002048）
#   LCT_DEVICES  设备候选（分号分隔）
#   LCT_READSIZE 读多少字节（默认 4）
#   LCT_ADDR     目标地址（hex；留空则用 ntoskrnl 基址）
#
# 崩溃语义：如果这个脚本让 VM 蓝屏，result.json 不会更新 —— 主机据此判定 crash。
# =====================================================================
$ErrorActionPreference = 'Continue'
$scriptDir = 'C:\lct'
$resultPath = Join-Path $scriptDir 'result.json'
$log = New-Object System.Collections.ArrayList
function L([string]$m) { $null = $log.Add(((Get-Date).ToString('HH:mm:ss.fff') + '  ' + $m)) }

if (-not (Test-Path -LiteralPath $scriptDir)) { $null = New-Item -ItemType Directory -Path $scriptDir -Force }

$out = [ordered]@{
    ranAt         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    hostName      = $env:COMPUTERNAME
    isAdmin       = $false
    sysPath       = ''
    service       = ''
    device        = ''
    ioctl         = ''
    payload       = ''
    bytesReturned = 0
    win32Error    = 0
    outHex        = ''
    ntoskrnlBase  = ''
    steps         = @()
    verdict       = ''
    error         = ''
    log           = @()
}

# ---------- 0) 环境 ----------
try {
    $out.isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
L ('admin=' + $out.isAdmin)
if (-not $out.isAdmin) {
    $out.verdict = 'not-admin'
    $out.log = @($log)
    $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Output 'VERDICT=not-admin'
    return
}

# ---------- 1) P/Invoke ----------
$cs = @'
using System;
using System.Runtime.InteropServices;
public class LctK {
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
    $out.error = 'Add-Type failed: ' + $_.Exception.Message
    $out.verdict = 'add-type-failed'
    $out.log = @($log)
    $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Output ('VERDICT=add-type-failed ' + $out.error)
    return
}

# ---------- 2) ntoskrnl 基址 ----------
$kernelBase = [Int64]0
try {
    $need = [uint32]0
    $null = [LctK]::EnumDeviceDrivers($null, 0, [ref]$need)
    if ($need -gt 0) {
        $cnt = [int]($need / [IntPtr]::Size)
        $arr = New-Object IntPtr[] $cnt
        if ([LctK]::EnumDeviceDrivers($arr, $need, [ref]$need)) {
            foreach ($h in $arr) {
                $sb = New-Object System.Text.StringBuilder 260
                $null = [LctK]::GetDeviceDriverBaseNameW($h, $sb, 260)
                if ($sb.ToString() -match '(?i)^ntoskrnl|^ntkrnl') { $kernelBase = [Int64]$h; break }
            }
        }
    }
} catch { L ('enumdrivers err: ' + $_.Exception.Message) }
$out.ntoskrnlBase = ('0x{0:X}' -f $kernelBase)
L ('ntoskrnl = ' + $out.ntoskrnlBase)

# ---------- 3) 参数 ----------
$sysPath = $env:LCT_SYS
if ([string]::IsNullOrWhiteSpace($sysPath)) { $sysPath = Join-Path $scriptDir 'target.sys' }
$svc = $env:LCT_SVC
if ([string]::IsNullOrWhiteSpace($svc)) { $svc = 'lctprobe' }
$ioctlText = $env:LCT_IOCTL
if ([string]::IsNullOrWhiteSpace($ioctlText)) { $ioctlText = '0x80002048' }
$devText = $env:LCT_DEVICES
if ([string]::IsNullOrWhiteSpace($devText)) { $devText = '\\.\RTCore64' }
$readSize = 4
try { if (-not [string]::IsNullOrWhiteSpace($env:LCT_READSIZE)) { $readSize = [int]$env:LCT_READSIZE } } catch { $readSize = 4 }
$addrText = $env:LCT_ADDR
$targetAddr = $kernelBase
if (-not [string]::IsNullOrWhiteSpace($addrText)) {
    try { $targetAddr = [Int64]($addrText -replace '0x', '') } catch { $targetAddr = $kernelBase }
}
$out.sysPath = $sysPath
$out.service = $svc
L ('sys=' + $sysPath + ' svc=' + $svc + ' ioctl=' + $ioctlText + ' readSize=' + $readSize)

if (-not (Test-Path -LiteralPath $sysPath)) {
    $out.verdict = 'sys-missing'
    $out.log = @($log)
    $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Output ('VERDICT=sys-missing ' + $sysPath)
    return
}

# ---------- 4) 加载驱动 ----------
try {
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    $c = & sc.exe create $svc type= kernel binPath= $sysPath start= demand 2>&1
    $out.steps += ('sc create -> ' + (($c | ForEach-Object { [string]$_ }) -join ' '))
    L ('create: ' + (($c | ForEach-Object { [string]$_ }) -join ' '))
    $s = & sc.exe start $svc 2>&1
    $out.steps += ('sc start -> ' + (($s | ForEach-Object { [string]$_ }) -join ' '))
    L ('start: ' + (($s | ForEach-Object { [string]$_ }) -join ' '))
} catch { $out.steps += ('load exception: ' + $_.Exception.Message) }

# 等 SCM 状态
Start-Sleep -Milliseconds 800

# ---------- 5) 打开设备 + 发 IOCTL ----------
$h = [IntPtr]::Zero
$usedDev = ''
foreach ($d in @($devText -split ';' | Where-Object { $_.Trim() -ne '' })) {
    $cand = $d.Trim()
    try {
        # GENERIC_READ|GENERIC_WRITE, share=3, OPEN_EXISTING
        # 注意：PowerShell 里 0xC0000000 会被当 int32 负数（-1073741824），传给 uint32 形参会溢出。
        # 用 Convert::ToUInt32 显式转成正数。
        $access = [System.Convert]::ToUInt32('C0000000', 16)
        $hh = [LctK]::CreateFileW($cand, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($hh.ToInt64() -ne -1 -and $hh.ToInt64() -ne 0) { $h = $hh; $usedDev = $cand; break }
        $errOpen = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        L ('open ' + $cand + ' failed err=' + $errOpen)
    } catch { L ('open ' + $cand + ' exception: ' + $_.Exception.Message) }
}
$out.device = $usedDev
L ('device=' + $usedDev)

if ($usedDev -ne '') {
    $code = 0
    try { $code = [Convert]::ToUInt32(($ioctlText -replace '^0x', ''), 16) } catch { $code = 0x80002048 }
    # 两种输入方式：
    #   A) LCT_INHEX：主机按 profile 布局预构造好的完整 buffer（十六进制）
    #      配合 LCT_PATCH="8:8;24:8" 表示这些偏移要写 guest 自己的内核基址
    #   B) 旧方式：只给 LCT_ADDR / LCT_READSIZE，按 48 字节 kread 结构构造
    $hexIn = [string]$env:LCT_INHEX
    if (-not [string]::IsNullOrWhiteSpace($hexIn)) {
        $hexIn = ($hexIn -replace '[^0-9A-Fa-f]', '')
        if (($hexIn.Length % 2) -ne 0) { $hexIn = $hexIn.Substring(0, $hexIn.Length - 1) }
        $inBuf = New-Object byte[] ([int]($hexIn.Length / 2))
        for ($bi = 0; $bi -lt $inBuf.Length; $bi++) {
            $inBuf[$bi] = [Convert]::ToByte($hexIn.Substring($bi * 2, 2), 16)
        }
        # 应用 patch：把占位 0 换成 guest 的内核基址
        $patchSpec = [string]$env:LCT_PATCH
        if (-not [string]::IsNullOrWhiteSpace($patchSpec)) {
            foreach ($pp in @($patchSpec -split ';')) {
                if ($pp.Trim() -eq '') { continue }
                $bits = $pp.Split(':')
                if ($bits.Count -lt 2) { continue }
                $poff = [int]$bits[0]; $psz = [int]$bits[1]
                if ($poff -lt 0 -or ($poff + $psz) -gt $inBuf.Length) { L ('patch 越界: ' + $pp); continue }
                if ($psz -eq 8) {
                    [BitConverter]::GetBytes([Int64]$kernelBase).CopyTo($inBuf, $poff)
                } elseif ($psz -eq 4) {
                    [BitConverter]::GetBytes([UInt32]($kernelBase -band 0xFFFFFFFF)).CopyTo($inBuf, $poff)
                }
                L ('patched kernel base at offset ' + $poff + ' size ' + $psz)
            }
        }
        L ('inHex 方式：' + $inBuf.Length + ' 字节')
    } else {
        # 48 字节：pad0(8) addr(u64) pad1(u32) offset(u32) readSize(u32) value(u32) pad3(16)
        $inBuf = New-Object byte[] 48
        [BitConverter]::GetBytes([Int64]$targetAddr).CopyTo($inBuf, 8)
        [BitConverter]::GetBytes([UInt32]$readSize).CopyTo($inBuf, 24)
    }
    $outBuf = New-Object byte[] 48
    $ret = [uint32]0
    $ok = [LctK]::DeviceIoControl($h, [uint32]$code, $inBuf, 48, $outBuf, 48, [ref]$ret, [IntPtr]::Zero)
    $werr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $out.ioctl = ('0x{0:X8}' -f $code)
    $out.payload = ('inSize={0} addr=0x{1:X} readSize={2}' -f $inBuf.Length, $targetAddr, $readSize)
    $out.bytesReturned = [int]$ret
    $out.win32Error = [int]$werr
    $take = [Math]::Min([int]$ret, 64)
    if ($take -gt 0) { $out.outHex = [BitConverter]::ToString($outBuf, 0, $take) }
    # 注意：DeviceIoControl 成功时 GetLastWin32Error 会返回上一次失败调用的残留值，
    # 不代表本次失败。只有 ok=False 时 win32Error 才有意义。
    if ($ok) {
        $out.win32Error = 0
        if ($ret -gt 0) { $out.verdict = 'ok-data' } else { $out.verdict = 'no-data' }
    } else {
        $out.verdict = 'error'
    }
    L ('ioctl ok=' + $ok + ' ret=' + $ret + ' err=' + $werr + ' out=' + $out.outHex)
} else {
    $out.verdict = 'no-device'
    L 'device not opened'
}

# ---------- 6) 清理 ----------
try {
    if ($h.ToInt64() -ne -1 -and $h.ToInt64() -ne 0) { $null = [LctK]::CloseHandle($h) }
    $null = & sc.exe stop $svc 2>&1
    $null = & sc.exe delete $svc 2>&1
    L 'cleanup done'
} catch { }

$out.log = @($log)
$out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
Write-Output ('VERDICT=' + $out.verdict + ' OUT=' + $out.outHex + ' BASE=' + $out.ntoskrnlBase + ' DEV=' + $out.device)
