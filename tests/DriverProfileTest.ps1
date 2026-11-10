# =====================================================================
# LocalConfigTool - tests\DriverProfileTest.ps1
# 职责：task-3（驱动 profile 数据层 + 通用原语执行器）自测 ①~⑧
# 契约：docs\CONTRACT.md §13.6 铁律 + §3 Result 形状 + §11.6 包装对象
#
# 铁律（本文件的核心约束）：
#   * **绝不对任何真实设备发未知 IOCTL**（会蓝屏）。测试只允许：
#     (a) 对不存在的设备断言错误分类；(b) 用预览路径断言缓冲区打包；
#     (c) 用假设备名断言定位失败。每次调用后都断言 `data.ioctlSent=false`
#     与 `data.device.opened=false`（预览）或「CreateFile 未成功」。
#   * 全程用隔离的 LCT_VAR_DIR / LCT_PLUGIN_ROOT，不污染真实 var\ 与 plugins\。
#   * 唯一的写盘对象是隔离目录里的测试 profile；draft/validate/list 一律只读。
#
# 运行：powershell -NoProfile -ExecutionPolicy Bypass -File tests\DriverProfileTest.ps1
# 退出码 = 失败断言数（0 = 全绿）
# =====================================================================
param([switch]$Quiet)

$script:Pass = 0
$script:Fail = 0
$script:Lines = New-Object System.Collections.ArrayList

function Section([string]$Title) {
    if (-not $Quiet) { Write-Host ''; Write-Host ('== ' + $Title) }
}
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = '[FAIL] '
    if ($Ok) { $tag = '[PASS] '; $script:Pass++ } else { $script:Fail++ }
    $line = $tag + $Name
    if (-not [string]::IsNullOrEmpty($Detail)) { $line = $line + '  -> ' + $Detail }
    if (-not $Quiet) { Write-Host $line }
    $null = $script:Lines.Add($line)
}
function Skip([string]$Name, [string]$Why) {
    $line = '[SKIP] ' + $Name + '  -> ' + $Why
    if (-not $Quiet) { Write-Host $line }
    $null = $script:Lines.Add($line)
}
function Short([string]$Text, [int]$Max = 200) {
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '...' }
    return $t
}
function Joined($Items) { return (Short ((@($Items | ForEach-Object { [string]$_ }) -join ' / '))) }

$root = Split-Path -Parent $PSScriptRoot
$ErrorActionPreference = 'Continue'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$diskSys = Join-Path $env:SystemRoot 'System32\drivers\disk.sys'
$tcpipSys = Join-Path $env:SystemRoot 'System32\drivers\tcpip.sys'

# ---------- 隔离环境（先设环境变量，再装载任何模块）----------
$testId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$varDir = Join-Path $env:TEMP ('lct-drvprof-test-' + $testId)
$workDir = Join-Path $varDir 'work'
$plugRoot = Join-Path $workDir 'plugins'
$userProfDir = Join-Path $varDir 'driver-profiles'
$plugProfDir = Join-Path $plugRoot 'fx-plugin\driver-profiles'
foreach ($d in @($varDir, $workDir, $plugRoot, $userProfDir, $plugProfDir)) {
    if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
}
$env:LCT_VAR_DIR = $varDir
$env:LCT_PLUGIN_ROOT = $plugRoot

# ---------- fixture：合成 .sys（不是真 PE，只用来做指纹比对，永不加载）----------
$demoSys = Join-Path $userProfDir 'demo-target.sys'
$demoBytes = New-Object byte[] 4096
for ($i = 0; $i -lt $demoBytes.Length; $i++) { $demoBytes[$i] = [byte](($i * 31 + 7) % 251) }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllBytes($demoSys, $demoBytes)
$demoSha = (Get-FileHash -LiteralPath $demoSys -Algorithm SHA256).Hash.ToLower()
$diskSha = (Get-FileHash -LiteralPath $diskSys -Algorithm SHA256).Hash.ToLower()

function Write-JsonNoBom {
    param([string]$Path, [string]$Json)
    [IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}
function Write-JsonWithBom {
    param([string]$Path, [string]$Json)
    [IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding($true)))
    return $Path
}
function Test-HasBom {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $true }
    return $false
}
function Get-FileSha {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function New-LctTestBaseProfile {
    # 测试用 profile：全部动作都指向「不存在的假设备」，只读动作 + 一个 bsod 写动作
    param([string]$Id, [string]$Sha)
    $o = [ordered]@{}
    $o['id'] = $Id
    $o['kind'] = 'driver-profile'
    $o['engineApi'] = 2
    $o['target'] = [ordered]@{ sha256 = $Sha; fileName = 'demo-target.sys' }
    $o['locate'] = [ordered]@{
        strategy = 'symlink'
        candidates = @('\\.\LctNoSuchDevice-7f3a1b', '\??\LctNoSuchDevice-7f3a1b')
        serviceNameHint = 'lct-no-such-service-xyz'
    }
    $o['handshake'] = [ordered]@{ action = 'ping'; expect = [ordered]@{ ioctl = '0x80002008'; minOutBytes = 4 } }
    $actions = [ordered]@{}
    $actions['ping'] = [ordered]@{ ioctl = '0x80002008'; kind = 'read'; in = @(); out = @([ordered]@{ name = 'code'; type = 'u32' }) }
    $actions['kread'] = [ordered]@{ ioctl = '0x80002000'; kind = 'read'; in = @([ordered]@{ name = 'addr'; type = 'u64' }); out = @([ordered]@{ name = 'value'; type = 'bytes'; len = 8 }) }
    $actions['kwrite'] = [ordered]@{ ioctl = '0x80002004'; kind = 'write'; readBack = 'kread'; in = @([ordered]@{ name = 'addr'; type = 'u64' }, [ordered]@{ name = 'value'; type = 'bytes'; len = 8 }) }
    $actions['layoutdemo'] = [ordered]@{ ioctl = '0x80002010'; kind = 'read'; in = @([ordered]@{ name = 'a'; type = 'u32' }, [ordered]@{ name = 'b'; type = 'u64' }, [ordered]@{ name = 'c'; type = 'bytes'; len = 4 }); out = @([ordered]@{ name = 'oa'; type = 'u32' }, [ordered]@{ name = 'ob'; type = 'u64' }, [ordered]@{ name = 'oc'; type = 'bytes'; len = 4 }) }
    $actions['strdemo'] = [ordered]@{ ioctl = '0x80002014'; kind = 'read'; in = @([ordered]@{ name = 's'; type = 'cstr' }) }
    $actions['lendemo'] = [ordered]@{ ioctl = '0x80002018'; kind = 'read'; in = @([ordered]@{ name = 'n'; type = 'u32' }, [ordered]@{ name = 'buf'; type = 'bytes'; lenFrom = 'n' }) }
    $actions['offsetdemo'] = [ordered]@{ ioctl = '0x8000201C'; kind = 'read'; in = @([ordered]@{ name = 'p'; type = 'u64' }, [ordered]@{ name = 'blob'; type = 'bytes'; lenOf = 'p' }) }
    $actions['bsodwrite'] = [ordered]@{ ioctl = '0x80002020'; kind = 'write'; readBack = 'kread'; risk = [ordered]@{ level = 'bsod'; notes = '测试用：写坏地址立刻蓝屏' }; in = @([ordered]@{ name = 'addr'; type = 'u64' }, [ordered]@{ name = 'value'; type = 'bytes'; len = 8 }) }
    $actions['blind'] = [ordered]@{ ioctl = '0x80002024'; kind = 'blindscan'; in = @([ordered]@{ name = 'addr'; type = 'u64' }) }
    $o['actions'] = $actions
    $o['layout'] = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
    $o['risk'] = [ordered]@{ level = 'medium'; notes = '测试用 profile：候选全是假设备名，不会命中任何真实设备' }
    $o['requires'] = [ordered]@{ restart = $false; admin = $true; elevation = 'admin' }
    return $o
}

# ---------- 装载模块 ----------
$loadError = ''
try {
    Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $root 'core\DriverProfiles.psm1') -Force -Global -ErrorAction Stop
} catch { $loadError = $_.Exception.Message }
if ($loadError -ne '') {
    Write-Host ('FATAL: 模块装载失败: ' + $loadError)
    Write-Host ('  （先跑 tests\Fix-Encoding.ps1 与 tests\Lint-PowerShell.ps1：解析失败会让整个模块载不进来）')
    exit 99
}
$exported = @(Get-Command -Module DriverProfiles | Select-Object -ExpandProperty Name)
$needExport = @('Get-LctDriverProfileList', 'Get-LctDriverProfileShow', 'Test-LctDriverProfile', 'New-LctDriverProfileDraft',
    'Get-LctDriverDevices', 'Invoke-LctDriverCtl', 'Get-LctDriverCtlVerify', 'Save-LctDriverProfile')
$missing = @($needExport | Where-Object { $exported -notcontains $_ })
Write-Host ('DriverProfileTest: root=' + $root + ' var=' + $varDir)
Write-Host ('  模块导出 ' + $exported.Count + ' 个；契约要求的 8 个导出缺失: ' + $(if (@($missing).Count -eq 0) { '无' } else { ($missing -join ',') }))
Write-Host ('  demo-target.sys sha256=' + $demoSha)
Write-Host ('  disk.sys sha256=' + $diskSha)

# ---------- 写 fixture profile ----------
$validJson = ConvertTo-Json -InputObject (New-LctTestBaseProfile -Id 'lct-demo-ok' -Sha $demoSha) -Depth 14
$validPath = Write-JsonNoBom -Path (Join-Path $userProfDir 'lct-demo-ok.json') -Json $validJson

# 指纹门正例/反例（对真实 disk.sys）
$fpOk = New-LctTestBaseProfile -Id 'lct-fp-ok' -Sha $diskSha
$fpOk['target']['fileName'] = 'disk.sys'
$fpOk['locate']['candidates'] = @('\\.\LctNoSuchDevice-fp')
Write-JsonNoBom -Path (Join-Path $userProfDir 'lct-fp-ok.json') -Json (ConvertTo-Json -InputObject $fpOk -Depth 14)
$fpBad = New-LctTestBaseProfile -Id 'lct-fp-bad' -Sha ('0' * 64)
$fpBad['target']['fileName'] = 'disk.sys'
$fpBad['locate']['candidates'] = @('\\.\LctNoSuchDevice-fp')
Write-JsonNoBom -Path (Join-Path $userProfDir 'lct-fp-bad.json') -Json (ConvertTo-Json -InputObject $fpBad -Depth 14)

# 8 类非法 profile
function Get-LctInvalidCase {
    param([string]$Id)
    $p = New-LctTestBaseProfile -Id $Id -Sha $demoSha
    if ($Id -eq 'i1') { $p['target'].Remove('sha256') }
    if ($Id -eq 'i2') { $p['target']['sha256'] = ('0' * 64) }
    if ($Id -eq 'i3') { $p['actions']['kread']['ioctl'] = '80002000' }
    if ($Id -eq 'i4') { $p['risk']['level'] = 'fatal' }
    if ($Id -eq 'i5') { $p['actions']['kread']['in'][0]['type'] = 'u24' }
    if ($Id -eq 'i6') { $p.Remove('locate') }
    if ($Id -eq 'i7') { $p['actions'] = [ordered]@{} }
    if ($Id -eq 'i8') { $p['kind'] = 'plugin-profile' }
    return $p
}
$invalidIds = @('i1', 'i2', 'i3', 'i4', 'i5', 'i6', 'i7', 'i8')
foreach ($iid in $invalidIds) {
    Write-JsonNoBom -Path (Join-Path $userProfDir ($iid + '.json')) -Json (ConvertTo-Json -InputObject (Get-LctInvalidCase -Id $iid) -Depth 14)
}

# plugin 来源（只读扫描用）
$plugJson = ConvertTo-Json -InputObject (New-LctTestBaseProfile -Id 'lct-plugin-ok' -Sha $demoSha) -Depth 14
Write-JsonNoBom -Path (Join-Path $plugProfDir 'lct-plugin-ok.json') -Json $plugJson

# BOM 容错 fixture（读侧必须能吃带 BOM 的 JSON）
Write-JsonWithBom -Path (Join-Path $userProfDir 'lct-bom-ok.json') -Json (ConvertTo-Json -InputObject (New-LctTestBaseProfile -Id 'lct-bom-ok' -Sha $demoSha) -Depth 14)

# 设备接口 GUID fixture（读-only CM 枚举；不发 IOCTL）
$ifaceProf = New-LctTestBaseProfile -Id 'lct-iface-disk' -Sha $demoSha
$ifaceProf['locate'] = [ordered]@{ strategy = 'interfaceGuid'; candidates = @(); interfaceGuid = '{53f56307-b6bf-11d0-94f2-00a0c91efb8b}'; serviceNameHint = '' }
Write-JsonNoBom -Path (Join-Path $userProfDir 'lct-iface-disk.json') -Json (ConvertTo-Json -InputObject $ifaceProf -Depth 14)

# =====================================================================
Section '① schema 校验：合法 profile 通过 + 8 类非法逐条拒绝且文案不同'
$rOk = Test-LctDriverProfile -Id 'lct-demo-ok'
Check '①-a 合法 profile 通过 validate（schema+指纹+沙盒）' ([bool]$rOk.ok) ('ok=' + $rOk.ok + ' checks=' + @($rOk.data.checks).Count + ' fingerprintMatch=' + $rOk.data.fingerprintMatch + ' errors=' + (Joined $rOk.errors))
if (-not $rOk.ok) { Write-Host ('    validate 原始输出: ' + (Short ($rOk | ConvertTo-Json -Depth 6 -Compress) 500)) }
$expectKeys = @{
    'i1' = 'target.sha256'; 'i2' = '指纹不符'; 'i3' = 'ioctl'; 'i4' = 'risk.level'
    'i5' = '类型未知'; 'i6' = 'locate'; 'i7' = 'actions 为空'; 'i8' = 'driver-profile'
}
$firstErrors = New-Object System.Collections.ArrayList
foreach ($iid in $invalidIds) {
    $r = Test-LctDriverProfile -Id $iid
    $errText = (Joined $r.errors)
    $hit = $false
    if ($errText -like ('*' + $expectKeys[$iid] + '*')) { $hit = $true }
    $null = $firstErrors.Add($errText)
    Check ('①-b ' + $iid + ' 被拒且文案含「' + $expectKeys[$iid] + '」') ((-not $r.ok) -and $hit) ('ok=' + $r.ok + ' errors=' + (Short $errText 220))
}
$uniq = @($firstErrors | Sort-Object -Unique).Count
Check '①-c 8 类非法的错误文案互不相同' (($uniq -eq 8) -and (@($firstErrors) -notcontains '')) ('unique=' + $uniq + '/8')
$rBadSrc = Get-LctDriverProfileList -Source 'nonsense'
Check '①-d profile.list 非法 -Source 被拒（可读文案）' ((-not $rBadSrc.ok) -and ((Joined $rBadSrc.errors) -like '*不支持的 -Source*')) ('errors=' + (Joined $rBadSrc.errors))
$rList = Get-LctDriverProfileList -Source 'user'
$item = @($rList.items | Where-Object { $_.id -eq 'lct-demo-ok' })
Check '①-e user 来源可列出合法 profile 且 valid=true' (($rList.count -ge 4) -and (@($item).Count -eq 1) -and $item[0].valid) ('count=' + $rList.count + ' item.valid=' + $(if (@($item).Count -eq 1) { $item[0].valid } else { 'n/a' }) + ' actions=' + $(if (@($item).Count -eq 1) { (@($item[0].actions) -join ',') } else { '' }))
$rListPlug = Get-LctDriverProfileList -Source 'plugin'
Check '①-f plugin 来源可列出插件携带的 profile' (@($rListPlug.items | Where-Object { $_.id -eq 'lct-plugin-ok' }).Count -eq 1) ('count=' + $rListPlug.count + ' first=' + $(if ($rListPlug.count -gt 0) { $rListPlug.items[0].id } else { '' }))
$rListAll = Get-LctDriverProfileList
$badItems = @($rListAll.items | Where-Object { $_.id -in $invalidIds -and $_.id -ne 'i2' -and $_.valid })
$i2Item = @($rListAll.items | Where-Object { $_.id -eq 'i2' })
Check '①-g 7 个 schema 非法项在 list 里 valid=false（i2 是 schema 合法但指纹不符 ⇒ valid=true，list 的 valid 只报 schema）' ((@($badItems).Count -eq 0) -and (@($i2Item).Count -eq 1) -and $i2Item[0].valid) ('schema 非法却判 valid 的个数=' + @($badItems).Count + ' i2.valid=' + $(if (@($i2Item).Count -eq 1) { $i2Item[0].valid } else { 'n/a' }))
$rBom = Test-LctDriverProfile -Id 'lct-bom-ok'
Check '①-h 带 BOM 的 JSON 也能读（BOM 容错）' ([bool]$rBom.ok) ('ok=' + $rBom.ok + ' errors=' + (Joined $rBom.errors))
$rShow = Get-LctDriverProfileShow -Id 'lct-demo-ok'
Check '①-i profile.show 返回包装对象（items/count/profile/schemaOk）' (($rShow.count -eq 1) -and (@($rShow.items).Count -eq 1) -and ($null -ne $rShow.profile) -and $rShow.schemaOk) ('count=' + $rShow.count + ' schemaOk=' + $rShow.schemaOk)

# =====================================================================
Section '② 打包/解包：小端 + 对齐的字节断言（走预览路径，不发 IOCTL）'
$pLayout = ConvertTo-Json -InputObject @{ a = 0x11223344; b = [uint64]'0x1122334455667788'; c = 'DEADBEEF' } -Compress
$rPack = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'layoutdemo' -Payload $pLayout
$hexLayout = [string]$rPack.data.request.hex
$expectLayout = '44332211000000008877665544332211deadbeef'
Check '②-a u32+u64+bytes(4) 打包字节（小端 + align 8 补 4 字节 0）' ($hexLayout -eq $expectLayout) ('实际=' + $hexLayout + ' 期望=' + $expectLayout)
$plan = @($rPack.data.request.fields)
$offA = -1; $offB = -1; $offC = -1; $sizeTotal = -1
foreach ($f in $plan) {
    if ($f.name -eq 'a') { $offA = [int]$f.offset }
    if ($f.name -eq 'b') { $offB = [int]$f.offset }
    if ($f.name -eq 'c') { $offC = [int]$f.offset }
}
$sizeTotal = [int]$rPack.data.request.size
Check '②-b 字段偏移与总长符合「每个字段按 min(字段大小, align) 对齐」' (($offA -eq 0) -and ($offB -eq 8) -and ($offC -eq 16) -and ($sizeTotal -eq 20)) ('offsets a/b/c=' + $offA + '/' + $offB + '/' + $offC + ' size=' + $sizeTotal)
$pStr = ConvertTo-Json -InputObject @{ s = 'LCT' } -Compress
$rStr = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'strdemo' -Payload $pStr
Check '②-c cstr 打包（UTF-8 + NUL 结尾）' ([string]$rStr.data.request.hex -eq '4c435400') ('实际=' + $rStr.data.request.hex + ' 期望=4c435400')
$pLen = ConvertTo-Json -InputObject @{ n = 4; buf = '01020304' } -Compress
$rLen = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'lendemo' -Payload $pLen
Check '②-d bytes(lenFrom) 打包（长度取自前一个字段的值）' ([string]$rLen.data.request.hex -eq '0400000001020304') ('实际=' + $rLen.data.request.hex + ' 期望=0400000001020304')
$pOff = ConvertTo-Json -InputObject @{ p = [uint64]'0x1122334455667788'; blob = 'AABBCCDDEEFF0011' } -Compress
$rOff = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'offsetdemo' -Payload $pOff
Check '②-e bytes(lenOf) 打包（长度 = 被引用字段的字节大小 8）' ([string]$rOff.data.request.hex -eq '8877665544332211aabbccddeeff0011') ('实际=' + $rOff.data.request.hex + ' 期望=8877665544332211aabbccddeeff0011')
$hexLines = @($rPack.data.request.hexDump)
Check '②-f 预览给出缓冲区十六进制 dump（多行 offset|hex|ascii）' (@($hexLines).Count -ge 2) ('dump 行数=' + @($hexLines).Count + ' 首行=' + (Short $(if (@($hexLines).Count -gt 0) { $hexLines[0] } else { '' }) 120))
$sandboxChecks = @($rOk.data.checks | Where-Object { $_.name -like 'sandbox.*' })
$sandboxBad = @($sandboxChecks | Where-Object { -not $_.passed })
Check '②-g 内存沙盒：out 打包→解包往返一致（validate 自检）' ((@($sandboxChecks).Count -ge 2) -and (@($sandboxBad).Count -eq 0)) ('sandbox 检查项=' + @($sandboxChecks).Count + ' 失败=' + @($sandboxBad).Count + ' 例=' + (Joined (@($sandboxChecks | Where-Object { $_.name -like '*roundtrip.out[layoutdemo]*' } | ForEach-Object { $_.detail }))))

# =====================================================================
Section '③ 预览不落盘 / 不发 IOCTL（假设备名 + 不存在的 profile id）'
$beforeFiles = @(Get-ChildItem -LiteralPath $varDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } | Sort-Object)
$rNoProf = Invoke-LctDriverCtl -Profile 'lct-no-such-profile-xyz' -Action 'kread' -Payload (ConvertTo-Json -InputObject @{ addr = 4096 } -Compress)
Check '③-a 不存在的 profile id ⇒ ok=false 且文案可读' ((-not $rNoProf.ok) -and ((Joined $rNoProf.errors) -like '*profile 不存在*') -and (-not $rNoProf.applied)) ('errors=' + (Short (Joined $rNoProf.errors) 200) + ' applied=' + $rNoProf.applied + ' refused=' + $rNoProf.data.gate.refused)
$pWrite = ConvertTo-Json -InputObject @{ addr = [uint64]4096; value = 'AABBCCDD00112233' } -Compress
$rPrev = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'kwrite' -Payload $pWrite
$prevHexOk = ([string]$rPrev.data.request.hex -eq '0010000000000000aabbccdd00112233')
Check '③-b 预览：applied=false / ok=true / 有 hexdump' (($rPrev.ok) -and (-not $rPrev.applied) -and ($prevHexOk) -and ([string]$rPrev.data.request.hex.Length -gt 0)) ('ok=' + $rPrev.ok + ' applied=' + $rPrev.applied + ' inHex=' + $rPrev.data.request.hex)
Check '③-c 预览绝不 CreateFile 设备（opened=false、openAttempts 为空）' ((-not $rPrev.data.device.opened) -and (@($rPrev.data.device.openAttempts).Count -eq 0) -and ([string]$rPrev.data.device.openPath -eq '')) ('opened=' + $rPrev.data.device.opened + ' attempts=' + @($rPrev.data.device.openAttempts).Count + ' verdict=' + $rPrev.data.device.verdict)
Check '③-d 预览绝不发 IOCTL（ioctlSent=false、result=null）' ((-not $rPrev.data.ioctlSent) -and ($null -eq $rPrev.data.result) -and ([int]$rPrev.data.bytesReturned -eq 0)) ('ioctlSent=' + $rPrev.data.ioctlSent + ' result=' + $(if ($null -eq $rPrev.data.result) { 'null' } else { 'not-null' }))
$changed = @(Compare-Object -ReferenceObject $beforeFiles -DifferenceObject @(Get-ChildItem -LiteralPath $varDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } | Sort-Object))
$logOnly = @($changed | Where-Object { $_.InputObject -notlike '*\logs\*' -and $_.SideIndicator -eq '=>' })
Check '③-e 预览不落盘（除审计日志外零新增文件）' (@($logOnly).Count -eq 0) ('新增非日志文件=' + (Joined (@($logOnly | ForEach-Object { $_.InputObject }))))
$rApplyFake = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'kwrite' -Payload $pWrite -Apply
$tries = @($rApplyFake.data.device.openAttempts)
$attemptedCount = @($tries | Where-Object { $_.attempted }).Count
$classified = @($tries | Where-Object { $_.attempted -and $_.classification -eq 'not-found' }).Count
Check '③-f -Apply 对不存在的设备：错误分类为 not-found（Win32=2）且不发 IOCTL' ((-not $rApplyFake.ok) -and ($attemptedCount -ge 2) -and ($classified -eq $attemptedCount) -and (-not $rApplyFake.data.ioctlSent) -and ([string]$rApplyFake.data.gate.refused -eq 'device-unavailable')) ('ok=' + $rApplyFake.ok + ' refused=' + $rApplyFake.data.gate.refused + ' attempts=' + $attemptedCount + ' not-found=' + $classified + ' ioctlSent=' + $rApplyFake.data.ioctlSent + ' 首条=' + (Joined (@($tries | Select-Object -First 1 | ForEach-Object { $_.openPath + ' -> Win32=' + $_.win32Error + ' ' + $_.classification }))))

# =====================================================================
Section '④ 指纹门：真实 .sys 的 sha256 正反两向（不符即拒绝）'
$rFpBad = Test-LctDriverProfile -Id 'lct-fp-bad' -Path $diskSys
Check '④-a sha256 写错 ⇒ validate 拒绝且给出实际指纹' ((-not $rFpBad.ok) -and ((Joined $rFpBad.errors) -like '*指纹不符*') -and ([string]$rFpBad.data.actualSha256 -eq $diskSha) -and (-not $rFpBad.data.fingerprintMatch)) ('ok=' + $rFpBad.ok + ' actual=' + $rFpBad.data.actualSha256 + ' declared=' + (Joined $rFpBad.data.declaredSha256) + ' errors=' + (Short (Joined $rFpBad.errors) 200))
$rFpOk = Test-LctDriverProfile -Id 'lct-fp-ok' -Path $diskSys
Check '④-b sha256 写对 ⇒ validate 通过（同一真实文件）' ([bool]$rFpOk.ok) ('ok=' + $rFpOk.ok + ' fingerprintMatch=' + $rFpOk.data.fingerprintMatch + ' resolution=' + $rFpOk.data.sysFile.resolution + ' errors=' + (Joined $rFpOk.errors))
$rFpNoFile = Test-LctDriverProfile -Id 'lct-fp-ok'
Check '④-c 定位不到 .sys 时不含糊：要么指纹不符要么报定位失败' ((-not $rFpNoFile.ok) -or $rFpNoFile.data.fingerprintMatch) ('ok=' + $rFpNoFile.ok + ' match=' + $rFpNoFile.data.fingerprintMatch + ' resolution=' + $rFpNoFile.data.sysFile.resolution + ' errors=' + (Short (Joined $rFpNoFile.errors) 160))

# =====================================================================
Section '⑤ driver.devices：注册表解 .sys 路径 + 候选入口 CreateFile 实测（不发 IOCTL）'
$rDisk = Get-LctDriverDevices -Name 'disk'
$diskPathOk = ($rDisk.file.exists -and ([IO.File]::Exists([string]$rDisk.file.path)))
Check '⑤-a -Name disk 解出真实存在的 .sys 路径' ($diskPathOk -and ([string]$rDisk.file.resolution -eq 'registryImagePath')) ('path=' + $rDisk.file.path + ' resolution=' + $rDisk.file.resolution + ' exists=' + $rDisk.file.exists + ' sha=' + $rDisk.file.sha256)
$rTcp = Get-LctDriverDevices -Name 'tcpip'
Check '⑤-b -Name tcpip 解出真实存在的 .sys 路径' ($rTcp.file.exists -and ([IO.File]::Exists([string]$rTcp.file.path))) ('path=' + $rTcp.file.path + ' resolution=' + $rTcp.file.resolution + ' imagePath(raw)=' + $rTcp.file.service.imagePath)
Check '⑤-c 候选入口逐个做了 CreateFile 实测并给了错误分类' ((@($rDisk.items).Count -ge 2) -and (@($rDisk.items | Where-Object { $_.attempted }).Count -ge 2)) ('候选数=' + $rDisk.count + ' 实测数=' + @($rDisk.items | Where-Object { $_.attempted }).Count + ' verdict=' + $rDisk.openability.verdict + ' 分类=' + (Short ($rDisk.openability.classifications | ConvertTo-Json -Compress) 120))
Check '⑤-d NB：devices 只做 CreateFile，不发任何 IOCTL（如实记录在 notes）' ((Joined $rDisk.notes) -like '*没有发送任何 IOCTL*') ('notes=' + (Short (Joined $rDisk.notes) 200))
$rMissing = Get-LctDriverDevices -Name 'lct-no-such-driver-xyz'
Check '⑤-e 不存在的服务 ⇒ ok=false 且文案可读' ((-not $rMissing.ok) -and ((Joined $rMissing.errors) -like '*服务不存在*')) ('errors=' + (Short (Joined $rMissing.errors) 220))
$rBadName = Get-LctDriverDevices -Name '..\bad name'
Check '⑤-f 非法服务名被拒（防路径穿越）' ((-not $rBadName.ok) -and ((Joined $rBadName.errors) -like '*服务名非法*')) ('errors=' + (Short (Joined $rBadName.errors) 160))
$rIface = Get-LctDriverDevices -Name 'disk' -Profile 'lct-iface-disk'
if ($rIface.interfaceEnumeration.supported -and $rIface.interfaceEnumeration.ok) {
    Check '⑤-g 设备接口 GUID 枚举（CM_Get_Device_Interface_ListW）可用' ([int]$rIface.interfaceEnumeration.count -ge 1) ('iface count=' + $rIface.interfaceEnumeration.count + ' 例=' + (Short (Joined (@($rIface.interfaceEnumeration.items | Select-Object -First 1))) 120))
} else {
    Skip '⑤-g 设备接口 GUID 枚举' ('本机不支持/失败: ' + [string]$rIface.interfaceEnumeration.error)
}
$ntInfo = $rDisk.ntEnumeration
Check '⑤-h NT 枚举 \GLOBAL?? 真实可用（含符号链接目标解析能力）' (($ntInfo.attempted -and $ntInfo.supported -and [int]$ntInfo.total -gt 0) -or (-not $ntInfo.supported)) ('supported=' + $ntInfo.supported + ' total=' + $ntInfo.total + ' matchCount=' + $ntInfo.matchCount + ' error=' + [string]$ntInfo.error)
Check '⑤-i 匹配不到就不猜（matchCount=0 时 names 映射如实标注）' (($ntInfo.matchCount -gt 0) -or (($ntInfo.notes -join ' ') -notlike '*假装*')) ('matchCount=' + $ntInfo.matchCount + ' notes=' + (Short (Joined $ntInfo.notes) 160))

# =====================================================================
Section '⑥ driver.profile.draft：静态草案不得编造、不得可直接执行'
foreach ($pair in @(@{ n = 'disk.sys'; p = $diskSys }, @{ n = 'tcpip.sys'; p = $tcpipSys })) {
    $nm = [string]$pair.n
    $sysPath = [string]$pair.p
    $rDraft = New-LctDriverProfileDraft -Path $sysPath
    if (-not $rDraft.ok) {
        Check ('⑥-draft ' + $nm + ' 解析成功') $false ('errors=' + (Joined $rDraft.errors))
        continue
    }
    $d = $rDraft.data
    $candCount = @($d.draft.locate.candidates).Count
    Check ('⑥-a ' + $nm + ' needsReview=true 且 confidence 在 0..1') (($d.needsReview -eq $true) -and ([double]$d.confidence -gt 0) -and ([double]$d.confidence -le 1) -and ([double]$d.confidence -le 0.95)) ('confidence=' + $d.confidence + ' needsReview=' + $d.needsReview)
    Check ('⑥-b ' + $nm + ' candidatesFound 与实际候选数一致（不编造）') ([int]$d.candidatesFound -eq $candCount) ('candidatesFound=' + $d.candidatesFound + ' list.Count=' + $candCount + ' 例=' + (Short (Joined (@($d.draft.locate.candidates | Select-Object -First 2))) 120))
    if ([int]$d.candidatesFound -eq 0) {
        Check ('⑥-c ' + $nm + ' 候选为 0 时明确写明 candidatesFound=0') ((Joined $d.draft.draft.notes) -like '*candidatesFound=0*') ('notes=' + (Short (Joined $d.draft.draft.notes) 200))
    } else {
        Check ('⑥-c ' + $nm + ' 报出至少 1 个设备名候选') ([int]$d.candidatesFound -ge 1) ('candidatesFound=' + $d.candidatesFound)
    }
    Check ('⑥-d ' + $nm + ' 草案 actions 为空（不可直接执行）') (@($d.draft.actions.Keys).Count -eq 0) ('actions 键数=' + @($d.draft.actions.Keys).Count + ' riskLevel=' + $d.draft.risk.level)
    $draftFile = Join-Path $workDir ($nm + '.draft.json')
    Write-JsonNoBom -Path $draftFile -Json ([string]$d.draftJson)
    $rDraftValidate = Test-LctDriverProfile -Path $draftFile
    Check ('⑥-e ' + $nm + ' 草案喂给 validate 必须被拒') ((-not $rDraftValidate.ok) -and (((Joined $rDraftValidate.errors) -like '*needsReview*') -or ((Joined $rDraftValidate.errors) -like '*actions 为空*'))) ('ok=' + $rDraftValidate.ok + ' errors=' + (Short (Joined $rDraftValidate.errors) 200))
    Check ('⑥-f ' + $nm + ' 静态只读：解析过程未改文件（sha 不变）') ((Get-FileSha -Path $sysPath) -eq $(if ($nm -eq 'disk.sys') { $diskSha } else { (Get-FileSha -Path $tcpipSys) })) ('sha=' + (Get-FileSha -Path $sysPath))
    Check ('⑥-g ' + $nm + ' 报出 IOCTL 候选数与扫描方法（启发式，需人工确认）') ((@($d.draft.draft.evidence.ioctlCandidates).Count -eq [int]$d.ioctlCandidateCount) -and ((Joined $d.draft.draft.evidence.scanMethods) -like '*cmp*')) ('ioctlCandidates=' + $d.ioctlCandidateCount + ' trunc=' + $d.draft.draft.evidence.ioctlScanTruncated + ' methods=' + (Short (Joined $d.draft.draft.evidence.scanMethods) 140))
}
$rDraftBad = New-LctDriverProfileDraft -Path (Join-Path $workDir 'no-such.sys')
Check '⑥-h 不存在的文件 ⇒ ok=false（不编造 PE 信息）' ((-not $rDraftBad.ok) -and ((Joined $rDraftBad.errors) -like '*找不到*')) ('errors=' + (Joined $rDraftBad.errors))
$rDraftNoPe = New-LctDriverProfileDraft -Path $demoSys
Check '⑥-i 非 PE 文件 ⇒ ok=false 且说明不是 PE' ((-not $rDraftNoPe.ok) -and ((Joined $rDraftNoPe.errors) -like '*PE*')) ('errors=' + (Short (Joined $rDraftNoPe.errors) 160))

# =====================================================================
Section '⑦ 风险闸门：bsod 动作默认禁用、盲扫需 -IUnderstand'
$rBsod = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'bsodwrite' -Payload $pWrite
Check '⑦-a risk.level=bsod 的动作不带 -OverrideBsod ⇒ 被拒' ((-not $rBsod.ok) -and (-not $rBsod.applied) -and ([string]$rBsod.data.gate.refused -eq 'bsod-gate') -and ((Joined $rBsod.errors) -like '*蓝屏风险*')) ('ok=' + $rBsod.ok + ' refused=' + $rBsod.data.gate.refused + ' errors=' + (Short (Joined $rBsod.errors) 200))
Check '⑦-b 拒绝时给出 [高危] warning 且无 IOCTL 发出' (((Joined $rBsod.warnings) -like '*[高危]*') -and (-not $rBsod.data.ioctlSent)) ('warnings=' + (Short (Joined $rBsod.warnings) 160) + ' ioctlSent=' + $rBsod.data.ioctlSent)
$rBsodOk = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'bsodwrite' -Payload $pWrite -OverrideBsod
Check '⑦-c 带 -OverrideBsod ⇒ 预览放行（applied=false，仍不发 IOCTL）' (($rBsodOk.ok) -and (-not $rBsodOk.applied) -and (-not $rBsodOk.data.ioctlSent)) ('ok=' + $rBsodOk.ok + ' applied=' + $rBsodOk.applied + ' ioctlSent=' + $rBsodOk.data.ioctlSent + ' warnings=' + (Short (Joined $rBsodOk.warnings) 160))
$rBlind = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'blind' -Payload (ConvertTo-Json -InputObject @{ addr = 4096 } -Compress) -OverrideBsod
Check '⑦-d 盲扫动作（kind=blindscan）不带 -IUnderstand ⇒ 被拒' ((-not $rBlind.ok) -and ([string]$rBlind.data.gate.refused -eq 'blindscan-gate') -and ((Joined $rBlind.errors) -like '*IUnderstand*')) ('refused=' + $rBlind.data.gate.refused + ' errors=' + (Short (Joined $rBlind.errors) 200))
$rBlindOk = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'blind' -Payload (ConvertTo-Json -InputObject @{ addr = 4096 } -Compress) -OverrideBsod -IUnderstand
Check '⑦-e 带 -IUnderstand ⇒ 预览放行（盲扫在 -Apply 时另被明确拒绝）' (($rBlindOk.ok) -and (-not $rBlindOk.applied)) ('ok=' + $rBlindOk.ok + ' refused=' + $rBlindOk.data.gate.refused)
$rBlindApply = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'blind' -Payload (ConvertTo-Json -InputObject @{ addr = 4096 } -Compress) -OverrideBsod -IUnderstand -Apply
Check '⑦-f 盲扫 -Apply 明确拒绝（首版不实现自动盲扫）' ((-not $rBlindApply.ok) -and ([string]$rBlindApply.data.gate.refused -eq 'blindscan-unsupported') -and (-not $rBlindApply.data.ioctlSent)) ('refused=' + $rBlindApply.data.gate.refused + ' ioctlSent=' + $rBlindApply.data.ioctlSent + ' errors=' + (Short (Joined $rBlindApply.errors) 160))
$rWrongAction = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'no-such-action' -Payload '{}'
Check '⑦-g 不存在的动作 ⇒ 列出可用动作' ((-not $rWrongAction.ok) -and ([string]$rWrongAction.data.gate.refused -eq 'action-not-found') -and ((Joined $rWrongAction.errors) -like '*可用动作*')) ('errors=' + (Short (Joined $rWrongAction.errors) 200))
$rBadPayload = Invoke-LctDriverCtl -Profile 'lct-demo-ok' -Action 'kread' -Payload '{"addr":'
Check '⑦-h 非法 payload JSON ⇒ 拒绝且不执行' ((-not $rBadPayload.ok) -and ([string]$rBadPayload.data.gate.refused -eq 'payload')) ('refused=' + $rBadPayload.data.gate.refused + ' errors=' + (Short (Joined $rBadPayload.errors) 160))

# =====================================================================
Section '⑧ driver.profile.save（草案 → 审定 → 另存；只写 var\driver-profiles）'
$saveId = 'lct-saved-1'
$savedPath = Join-Path $userProfDir ($saveId + '.json')
if (Test-Path -LiteralPath $savedPath) { $null = Move-LctToRecycleBin -Path $savedPath }
# 保存用的 JSON：profile.id 必须与 -Id 一致（不一致应被拒绝，见 ⑧-m）
$saveJson = ConvertTo-Json -InputObject (New-LctTestBaseProfile -Id $saveId -Sha $demoSha) -Depth 14
$rSavePrev = Save-LctDriverProfile -Id $saveId -Json $saveJson
Check '⑧-a 预览：applied=false / 给出目标路径 / 不落盘' ((-not $rSavePrev.applied) -and ($rSavePrev.ok) -and ([string]$rSavePrev.data.path -eq $savedPath) -and (-not (Test-Path -LiteralPath $savedPath)) -and ([int]$rSavePrev.data.bytes -gt 0)) ('path=' + $rSavePrev.data.path + ' bytes=' + $rSavePrev.data.bytes + ' fileExists=' + (Test-Path -LiteralPath $savedPath))
$pBad1 = Get-LctInvalidCase -Id 'i1'
$pBad1['id'] = $saveId
$badJson1 = ConvertTo-Json -InputObject $pBad1 -Depth 14
$rSaveBad1 = Save-LctDriverProfile -Id $saveId -Json $badJson1 -Apply
Check '⑧-b 非法（缺 sha256）保存被拒且文件未创建' ((-not $rSaveBad1.ok) -and (-not (Test-Path -LiteralPath $savedPath)) -and ((Joined $rSaveBad1.errors) -like '*target.sha256*') -and (-not $rSaveBad1.applied)) ('errors=' + (Short (Joined $rSaveBad1.errors) 200) + ' fileExists=' + (Test-Path -LiteralPath $savedPath))
$pBad2 = Get-LctInvalidCase -Id 'i5'
$pBad2['id'] = $saveId
$badJson2 = ConvertTo-Json -InputObject $pBad2 -Depth 14
$rSaveBad2 = Save-LctDriverProfile -Id $saveId -Json $badJson2 -Apply
Check '⑧-c 非法（类型未知）保存被拒且文件未创建' ((-not $rSaveBad2.ok) -and (-not (Test-Path -LiteralPath $savedPath)) -and ((Joined $rSaveBad2.errors) -like '*类型未知*') -and (-not $rSaveBad2.applied)) ('errors=' + (Short (Joined $rSaveBad2.errors) 200) + ' fileExists=' + (Test-Path -LiteralPath $savedPath))
$rSave1 = Save-LctDriverProfile -Id $saveId -Json $saveJson -Apply
Check '⑧-d 合法 JSON -Apply ⇒ 文件出现且回读一致（无 BOM）' (($rSave1.ok) -and ($rSave1.applied) -and (Test-Path -LiteralPath $savedPath) -and $rSave1.data.readBack.match -and (-not $rSave1.data.readBack.bomPresent) -and (-not (Test-HasBom -Path $savedPath))) ('ok=' + $rSave1.ok + ' bytes=' + $rSave1.data.readBack.bytes + ' textMatch=' + $rSave1.data.readBack.textMatch + ' shaOk=' + $rSave1.data.readBack.schemaOk + ' bom=' + $rSave1.data.readBack.bomPresent + ' sha=' + $rSave1.data.sha256)
$shaV1 = Get-FileSha -Path $savedPath
$rListSaved = Get-LctDriverProfileList -Source 'user'
$savedItem = @($rListSaved.items | Where-Object { $_.id -eq $saveId })
Check '⑧-e 保存后能被 driver.profile.list -Source user 列出' ((@($savedItem).Count -eq 1) -and ($savedItem[0].source -eq 'user') -and $savedItem[0].valid) ('count=' + $rListSaved.count + ' source=' + $(if (@($savedItem).Count -eq 1) { $savedItem[0].source } else { 'n/a' }) + ' valid=' + $(if (@($savedItem).Count -eq 1) { $savedItem[0].valid } else { 'n/a' }))
$rValidateSaved = Test-LctDriverProfile -Id $saveId
Check '⑧-f 保存后 driver.profile.validate -Id 通过（指纹门在保存目录里解析到 .sys）' ([bool]$rValidateSaved.ok) ('ok=' + $rValidateSaved.ok + ' resolution=' + $rValidateSaved.data.sysFile.resolution + ' match=' + $rValidateSaved.data.fingerprintMatch + ' errors=' + (Short (Joined $rValidateSaved.errors) 160))
$rSaveDup = Save-LctDriverProfile -Id $saveId -Json $saveJson -Apply
Check '⑧-g 同名已存在且不带 -Override ⇒ 拒绝' ((-not $rSaveDup.ok) -and ((Joined $rSaveDup.errors) -like '*-Override*')) ('errors=' + (Short (Joined $rSaveDup.errors) 200))
$v2 = New-LctTestBaseProfile -Id $saveId -Sha $demoSha
$v2['risk']['notes'] = '第二版（用于覆盖与备份断言）'
$v2['actions']['extra'] = [ordered]@{ ioctl = '0x80002030'; kind = 'read'; in = @([ordered]@{ name = 'addr'; type = 'u64' }) }
$jsonV2 = ConvertTo-Json -InputObject $v2 -Depth 14
$backupDir = Join-Path $varDir 'backups\driver-profiles'
$bkBefore = @(Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue).Count
$rSave2 = Save-LctDriverProfile -Id $saveId -Json $jsonV2 -Override -Apply
$shaV2 = Get-FileSha -Path $savedPath
$bkAfter = @(Get-ChildItem -LiteralPath $backupDir -File -ErrorAction SilentlyContinue)
$bkMatch = $false
foreach ($bf in @($bkAfter)) { if ((Get-FileSha -Path $bf.FullName) -eq $shaV1) { $bkMatch = $true } }
Check '⑧-h 带 -Override 覆盖：overwritten=true 且原内容进 var\backups\ 备份' (($rSave2.ok) -and ($rSave2.data.overwritten) -and ($shaV2 -ne $shaV1) -and (@($bkAfter).Count -gt $bkBefore) -and $bkMatch) ('overwritten=' + $rSave2.data.overwritten + ' backup新增=' + (@($bkAfter).Count - $bkBefore) + ' 备份内容=旧版sha:' + $bkMatch + ' backup=' + $rSave2.data.backup)
Check '⑧-i 覆盖后原 .json 一直在（只复制，未删除）' (Test-Path -LiteralPath $savedPath) ('saved 仍在=' + (Test-Path -LiteralPath $savedPath))
$rSaveEsc = Save-LctDriverProfile -Id '..\escape' -Json $saveJson -Apply
Check '⑧-j1 Id 含分隔符（反斜杠）⇒ 拒绝' ((-not $rSaveEsc.ok) -and ((Joined $rSaveEsc.errors) -like '*Id*非法*')) ('errors=' + (Short (Joined $rSaveEsc.errors) 160))
$rSaveEsc2 = Save-LctDriverProfile -Id '..' -Json $saveJson -Apply
Check '⑧-j2 Id 含路径穿越片段（..）⇒ 拒绝' ((-not $rSaveEsc2.ok) -and ((Joined $rSaveEsc2.errors) -like '*路径穿越*')) ('errors=' + (Short (Joined $rSaveEsc2.errors) 160))
$coreId = 'lct-builtin-attempt'
$coreJson = ConvertTo-Json -InputObject (New-LctTestBaseProfile -Id $coreId -Sha $demoSha) -Depth 14
$corePath = Join-Path $root 'core\driver-profiles\lct-builtin-attempt.json'
$rSaveCore = Save-LctDriverProfile -Id $coreId -Json $coreJson -Apply
Check '⑧-k 保存 verb 不会写内置目录 core\driver-profiles' ((-not (Test-Path -LiteralPath $corePath)) -and ([string]$rSaveCore.data.path -like ($varDir + '*')) -and ($rSaveCore.ok)) ('data.path=' + $rSaveCore.data.path + ' coreFileExists=' + (Test-Path -LiteralPath $corePath))
$rSaveGet = Save-LctDriverProfile -Id $saveId -Json $saveJson
Check '⑧-l 第二次预览会如实报告将被覆盖（wouldOverwrite=true）' (($rSaveGet.data.wouldOverwrite -eq $true) -and (-not $rSaveGet.applied) -and ($rSaveGet.ok)) ('wouldOverwrite=' + $rSaveGet.data.wouldOverwrite + ' exists=' + $rSaveGet.data.exists)
$rSaveMismatch = Save-LctDriverProfile -Id 'lct-other-id' -Json $saveJson -Apply
Check '⑧-m profile.id 与 -Id 不一致 ⇒ 拒绝（文件名与 id 必须一致）' ((-not $rSaveMismatch.ok) -and ((Joined $rSaveMismatch.errors) -like '*不一致*') -and (-not (Test-Path -LiteralPath (Join-Path $userProfDir 'lct-other-id.json')))) ('errors=' + (Short (Joined $rSaveMismatch.errors) 160))

# =====================================================================
Section '⑨ 收尾：①~⑧ 全程的真实边界（只读 verb 未落盘 / 未发过 IOCTL）'
$allNewFiles = @(Get-ChildItem -LiteralPath $varDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($varDir.Length) } | Sort-Object)
$unexpected = @($allNewFiles | Where-Object { $_ -notlike '*\driver-profiles\*' -and $_ -notlike '*\backups\*' -and $_ -notlike '*\logs\*' -and $_ -notlike '*\work\*' })
Check '⑨-a 隔离目录里没有计划外的落盘（只有 driver-profiles/backups/logs/work）' (@($unexpected).Count -eq 0) ('意外文件=' + (Joined $unexpected) + ' 总文件数=' + @($allNewFiles).Count)
$coreProfiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'core\driver-profiles') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Check '⑨-b 内置目录 core\driver-profiles 未被测试写入' (@($coreProfiles | Where-Object { $_ -like 'lct-*' -or $_ -like 'i?.json' }).Count -eq 0) ('内容=' + (Joined $coreProfiles))
$rVerify = Get-LctDriverCtlVerify -Profile 'lct-demo-ok'
Check '⑨-c driver.ctl.verify 默认不发 IOCTL，只给 proofLevel' (($null -ne $rVerify) -and ([string]$rVerify.proofLevel -match '^(none|file-fingerprint|openable|handshake)$') -and (-not [bool]$rVerify.canary.sent) -and (-not [bool]$rVerify.applied)) ('proofLevel=' + $rVerify.proofLevel + ' canarySent=' + $rVerify.canary.sent + ' verdict=' + $rVerify.device.verdict + ' fingerprintMatch=' + $rVerify.fileFingerprint.match)

# =====================================================================
Write-Host ''
Write-Host ('DriverProfileTest summary: PASS=' + $script:Pass + ' FAIL=' + $script:Fail + ' (SKIP 不计入失败)')
if ($script:Fail -gt 0) {
    Write-Host '--- 失败明细 ---'
    foreach ($l in @($script:Lines | Where-Object { $_ -like '[FAIL]*' })) { Write-Host $l }
}
Write-Host ('临时目录（可自行删除）：' + $varDir)
exit $script:Fail