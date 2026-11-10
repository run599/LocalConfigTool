# LocalConfigTool - tests\CapabilityTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\CapabilityTest.ps1
#
# 守「两条能力路线的前置条件冲突」这件事：
#   路线 B「提权」从普通用户起步 → 管理员/SYSTEM（本身就是先提权这一步）
#   路线 A「加载驱动」起点就要求管理员 → 未提权时必须被拦住并给出**顺序**指引
#
#   CT-1 capability.status 可用且字段齐全
#   CT-2 完整性级别与 isAdmin 自洽（S-1-16-x 的十进制映射：4096 Low / 8192 Medium / 12288 High / 16384 System）
#   CT-3 两条路线都在，requiresElevation 分别 false / true，driver 的 available 跟 isAdmin 一致
#   CT-4 纯函数闸门：未提权 ⇒ allowed=false + code=need-elevation + 提示含「提权」「先」
#   CT-5 纯函数闸门：已提权 ⇒ allowed=true
#   CT-6 统一提示文案（driver.load 用的那个）含动作顺序说明
#   CT-7 只读：applied=false；没有创建任何 lct* 服务
#   CT-8 引擎 verb 表里有 capability.status 且 mutating=false
#
# 已知缺口（如实记录，不假装）：真正的「非管理员进程跑引擎撞闸门」端到端证据没有拿到——
# runas /trustlevel:0x20000 造出的受限令牌里 PowerShell 无法稳定执行引擎（无输出）。
# 因此本测试验证的是「判定逻辑 + 数据 + 管理员上下文」，纯函数部分覆盖了非提权分支。
#
# 退出码 = 失败数。不加载驱动、不发 IOCTL、不修改系统。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-cap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}

Write-Host '== CT-1: capability.status 可用 =='
$cap = Eng 'capability.status' $null
Check 'CT-1a ok=true' ($null -ne $cap -and $cap.ok -eq $true) ''
$d = $null
if ($null -ne $cap) { $d = $cap.data }
Check 'CT-1b 字段齐全（user/isAdmin/integrityLevel/canLoadDriver/routes/prerequisite）' (
    $null -ne $d -and $null -ne $d.PSObject.Properties['user'] -and $null -ne $d.PSObject.Properties['isAdmin'] -and
    $null -ne $d.PSObject.Properties['integrityLevel'] -and $null -ne $d.PSObject.Properties['canLoadDriver'] -and
    $null -ne $d.PSObject.Properties['routes'] -and $null -ne $d.PSObject.Properties['prerequisite']
) ''
Check 'CT-1c applied=false（只读）' ($null -ne $cap -and $cap.applied -eq $false) ''

Write-Host ''
Write-Host '== CT-2: 完整性级别与 isAdmin 自洽 =='
$integ = ''
if ($null -ne $d) { $integ = [string]$d.integrityLevel }
$rid = -1
if ($null -ne $d -and $null -ne $d.PSObject.Properties['integrityRid']) { $rid = [int]$d.integrityRid }
Check 'CT-2a 完整性级别是已知值' (@('Low', 'Medium', 'High', 'System', 'Protected', 'Unknown') -contains $integ) ('integrity=' + $integ + ' rid=' + $rid)
$expectRid = @{ 'Low' = 4096; 'Medium' = 8192; 'High' = 12288; 'System' = 16384; 'Protected' = 20480 }
if ($expectRid.ContainsKey($integ)) {
    Check 'CT-2b RID 与名称一致（十进制映射）' ($rid -eq [int]$expectRid[$integ]) ('rid=' + $rid + ' expect=' + $expectRid[$integ])
} else {
    Check 'CT-2b RID 与名称一致（SKIP：级别未知）' $true ('integrity=' + $integ)
}
$isAdmin = $false
if ($null -ne $d) { $isAdmin = [bool]$d.isAdmin }
Check 'CT-2c isAdmin 与 canLoadDriver 一致' ($null -ne $d -and ([bool]$d.canLoadDriver -eq $isAdmin)) ('isAdmin=' + $isAdmin + ' canLoadDriver=' + $(if ($null -ne $d) { $d.canLoadDriver } else { '?' }))

Write-Host ''
Write-Host '== CT-3: 两条路线与前置条件 =='
$routes = @()
if ($null -ne $d) { $routes = @($d.routes) }
$elev = @($routes | Where-Object { [string]$_.id -eq 'elevate' })
$drv = @($routes | Where-Object { [string]$_.id -eq 'driver' })
Check 'CT-3a 提权路线存在且不要求先提权' (@($elev).Count -eq 1 -and $elev[0].requiresElevation -eq $false) ''
Check 'CT-3b 驱动路线存在且要求先提权' (@($drv).Count -eq 1 -and $drv[0].requiresElevation -eq $true) ''
Check 'CT-3c 驱动路线可用性 = 当前是否提权' (@($drv).Count -eq 1 -and ([bool]$drv[0].available -eq $isAdmin)) ('available=' + $(if (@($drv).Count -eq 1) { $drv[0].available } else { '?' }))
$prq = $null
if ($null -ne $d) { $prq = $d.prerequisite }
Check 'CT-3d 顺序声明为 elevate → driver' ($null -ne $prq -and (@($prq.order) -join ',') -eq 'elevate,driver') ('order=' + $(if ($null -ne $prq) { (@($prq.order) -join ',') } else { '?' }))

Write-Host ''
Write-Host '== CT-4/5: 纯函数闸门（两个分支） =='
Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $root 'core\Capabilities.psm1') -Force -Global -ErrorAction SilentlyContinue
$blocked = $null
$allowed = $null
try {
    $blocked = Test-LctCapabilityDriverLoad -IsAdmin $false -Action '加载驱动' -IntegrityName 'Medium'
    $allowed = Test-LctCapabilityDriverLoad -IsAdmin $true -Action '加载驱动' -IntegrityName 'High'
} catch { }
Check 'CT-4a 未提权 ⇒ allowed=false' ($null -ne $blocked -and $blocked.allowed -eq $false) ''
Check 'CT-4b 未提权 ⇒ code=need-elevation' ($null -ne $blocked -and [string]$blocked.code -eq 'need-elevation') ('code=' + $(if ($null -ne $blocked) { $blocked.code } else { '?' }))
Check 'CT-4c 未提权 ⇒ 提示含「提权」与「先」' ($null -ne $blocked -and [string]$blocked.hint -match '提权' -and [string]$blocked.hint -match '先') ''
Check 'CT-5 已提权 ⇒ allowed=true 且 needElevation=false' ($null -ne $allowed -and $allowed.allowed -eq $true -and $allowed.needElevation -eq $false) ''

Write-Host ''
Write-Host '== CT-6: driver.load 用的统一提示文案 =='
$msg = ''
try {
    Import-Module (Join-Path $root 'core\Drivers.psm1') -Force -Global -ErrorAction SilentlyContinue
    $msg = [string](& (Get-Module Drivers) { param() Get-LctDrvElevationMessage -Action '注册 / 启动内核驱动服务' })
} catch { $msg = '' }
Check 'CT-6a 文案非空' ($msg.Length -gt 20) ('len=' + $msg.Length)
Check 'CT-6b 文案含「提权」' ($msg -match '提权') ''
Check 'CT-6c 文案含顺序说明（先…再…/顺序不能反）' (($msg -match '先' -and $msg -match '再') -or ($msg -match '顺序不能反')) ''

Write-Host ''
Write-Host '== CT-7: 只读，没有副作用 =='
Check 'CT-7a 没有 lct* 内核服务被创建' (@(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'lct*' }).Count -eq 0) ''

Write-Host ''
Write-Host '== CT-8: 引擎 verb 表 =='
$verbs = Eng 'engine.verbs' $null
$entry = @()
if ($null -ne $verbs) { $entry = @($verbs.data.verbs) | Where-Object { [string]$_.verb -eq 'capability.status' } }
Check 'CT-8a verb 表含 capability.status' (@($entry).Count -eq 1) ('hits=' + @($entry).Count)
Check 'CT-8b capability.status 是只读（mutating=false）' (@($entry).Count -eq 1 -and $entry[0].mutating -eq $false) ''
Check 'CT-8c availability.Capabilities=true' ($null -ne $verbs -and $verbs.data.availability.Capabilities -eq $true) ''

if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
Write-Host ''
Write-Host ('CapabilityTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
