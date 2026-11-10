# LocalConfigTool - 插件 SDK v2 自测（tests\PluginSdkTest.ps1）
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\PluginSdkTest.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\PluginSdkTest.ps1 -Quiet   # 只打印失败与汇总
#
# 退出码 = 失败断言数（0 = 全绿）。逐条打印 PASS/FAIL，末尾打印汇总。
#
# 覆盖（契约 docs\CONTRACT.md §12.1 / §12.2 与 task-7 的断言清单）：
#   1) 导出恰好 7 个（含 §12.2 第 5 条点名的 Get-LctPluginEngineApiVersion）；
#   2) 种类注册表初始只有 ps1/exe（且不含 driver）、字段齐全；能力表 9 项、写类 4 项 needsConfirm=true；
#   3) fixture：合法 v1（ok=true + degraded=true + 警告「按 v1 规则运行」）、合法 v2（degraded=false）、
#      未知能力、未知种类、entry.path 含 ..、lifecycle 命令含 .. 路径、sha256 不符、integrity 缺文件；
#   4) engineApi：区间被满足 / 不被满足（engineApiOk=false 但 **ok 仍为 true**）/ 无法解析；
#   5) Get-LctPluginChecksum：不存在路径、目录、被独占占用文件都 ok=false 且不抛；与 Get-FileHash 独立计算一致；
#   6) 敌对输入（$null / 字符串 / 数组 / 数字 / 各种字段形状写错）一律不抛异常，且仍返回冻结形状；
#   7) 真实样例 plugins\cve-2026-49176（v1 清单）⇒ ok=true + degraded=true + 0 错误；
#   8) 以子进程方式真跑 tests\Lint-Plugin.ps1，断言退出码：真实 plugins 树 = 0、合法 fixture 集 = 0、
#      非法 fixture 集 = 该目录下的用例数（每条非法清单恰好 1 个问题）。
#
# 边界：本测试只调用 SDK 的纯逻辑函数 + 读文件 + 算哈希；不启动任何插件进程、不装载任何载荷、
#       不写任何插件目录。唯一的运行时写入是系统临时目录里的一个"被独占占用的文件"（用于验证
#       checksum 的共享冲突分支），按项目删除铁律**不做删除**，交给系统临时目录自行清理。
#
# 编码：本文件含中文，必须 UTF-8 带 BOM（改完立刻跑 tests\Fix-Encoding.ps1）。
param([switch]$Quiet)

$toolRoot = Split-Path -Parent $PSScriptRoot
if (-not $toolRoot) { $toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$sdkPath = Join-Path $toolRoot 'core\PluginSdk.psm1'
$lintPath = Join-Path $PSScriptRoot 'Lint-Plugin.ps1'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures\PluginSdk'
$goodRoot = Join-Path $fixtureRoot 'good'
$badRoot = Join-Path $fixtureRoot 'bad'
$samplePluginsRoot = Join-Path $toolRoot 'plugins'

$script:passCount = 0
$script:failCount = 0
$script:failLines = New-Object System.Collections.ArrayList

function Write-Case([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        $script:passCount++
        if (-not $Quiet) { Write-Host ('  [PASS] ' + $Name) }
    } else {
        $script:failCount++
        $line = '  [FAIL] ' + $Name
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + '  -- ' + $Detail }
        $null = $script:failLines.Add($line)
        Write-Host $line
    }
}

function Assert-True([string]$Name, $Condition, [string]$Detail = '') {
    Write-Case -Name $Name -Ok ([bool]$Condition) -Detail $Detail
}

function Assert-Equal([string]$Name, $Expected, $Actual) {
    $e = [string]$Expected
    $a = [string]$Actual
    Write-Case -Name $Name -Ok ($e -eq $a) -Detail ('期望 [' + $e + '] 实际 [' + $a + ']')
}

function Test-CallNoThrow([string]$Name, [scriptblock]$Body) {
    # 只用于自包含的调用（脚本块不依赖外部循环变量）
    try {
        $null = & $Body
        Write-Case -Name $Name -Ok $true
    } catch {
        Write-Case -Name $Name -Ok $false -Detail ('抛出了异常: ' + $_.Exception.Message)
    }
}

function Read-LctFixtureObject([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($text | ConvertFrom-Json)
}

function Invoke-LctFixtureManifest([string]$Dir) {
    $obj = Read-LctFixtureObject (Join-Path $Dir 'plugin.json')
    return (Test-LctPluginManifestV2 -Obj $obj -Dir $Dir -Id (Split-Path -Leaf $Dir))
}

function Get-LctPowerShell51Path {
    # 本脚本可能被 PS 5.1 或 PS 7 宿主运行；子进程固定用 Windows PowerShell 5.1（项目目标解释器）
    try {
        $cur = (Get-Process -Id $PID).Path
        if ($cur -and (Test-Path -LiteralPath $cur -PathType Leaf) -and ([IO.Path]::GetFileName($cur) -ieq 'powershell.exe')) {
            return $cur
        }
    } catch { }
    $sysExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysExe -PathType Leaf) { return $sysExe }
    return 'powershell.exe'
}

function Invoke-LctLintChild([string]$Root) {
    # 必须走子进程：Lint-Plugin.ps1 以 exit 码报告问题数，同进程调用会把宿主一起退出
    $exe = Get-LctPowerShell51Path
    $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $lintPath -Quiet -PluginRoot $Root 2>&1
    return @{ code = $LASTEXITCODE; output = (@($out) -join "`n") }
}

Write-Host '=== PluginSdkTest：插件 SDK v2 纯逻辑层自测 ==='

# ---------------------------------------------------------------------------
# 0. 前置条件与模块装载
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 0. 前置条件 / 模块装载 --'
$pre = @(
    @{ path = $sdkPath; name = 'core\PluginSdk.psm1' },
    @{ path = $lintPath; name = 'tests\Lint-Plugin.ps1' },
    @{ path = $goodRoot; name = 'tests\fixtures\PluginSdk\good' },
    @{ path = $badRoot; name = 'tests\fixtures\PluginSdk\bad' }
)
foreach ($x in @($pre)) {
    Assert-True ('前置条件存在: ' + $x.name) (Test-Path -LiteralPath $x.path) ([string]$x.path)
}

$loadError = ''
try { $null = Import-Module -Name $sdkPath -Force -ErrorAction Stop } catch { $loadError = $_.Exception.Message }
Assert-True '装载 core\PluginSdk.psm1 成功' ([string]::IsNullOrEmpty($loadError)) $loadError
if ($loadError) {
    Write-Host ('PluginSdkTest: 无法装载 SDK，后续断言全部跳过。' + $loadError)
    Write-Host ('PluginSdkTest 汇总: PASS=' + $script:passCount + ' FAIL=' + $script:failCount)
    exit $script:failCount
}

$expectedExports = @(
    'Get-LctPluginKindRegistry',
    'Get-LctPluginCapabilityTable',
    'Get-LctPluginEngineApiVersion',
    'Test-LctPluginManifestV2',
    'Test-LctPluginIntegrity',
    'Test-LctPluginEngineApi',
    'Get-LctPluginChecksum'
)
$exported = @(Get-Command -Module PluginSdk -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
Assert-Equal '导出函数恰好 7 个' 7 (@($exported).Count)
foreach ($n in @($expectedExports)) {
    Assert-True ('导出包含 ' + $n) (@($exported) -contains $n)
}

# ---------------------------------------------------------------------------
# 1. 种类注册表
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 1. 种类注册表（初始只有 ps1/exe）--'
$kinds = Get-LctPluginKindRegistry
Assert-Equal '种类注册表恰好 2 项' 2 (@($kinds.Keys).Count)
Assert-True '种类注册表含 ps1' ($kinds.ContainsKey('ps1'))
Assert-True '种类注册表含 exe' ($kinds.ContainsKey('exe'))
Assert-True '种类注册表不含 driver（§12.2 第 7 条 P0 + §12.4 边界）' (-not $kinds.ContainsKey('driver'))
Assert-True '种类注册表不含 psm1（未在本任务范围）' (-not $kinds.ContainsKey('psm1'))
foreach ($k in @('ps1', 'exe')) {
    $entry = $kinds[$k]
    Assert-Equal ($k + '：name 字段') $k $entry.name
    Assert-Equal ($k + '：isolation=子进程') '子进程' $entry.isolation
    Assert-True ($k + '：needsApply=true') ([bool]$entry.needsApply)
    Assert-True ($k + '：entryRequired 含 path') (@($entry.entryRequired) -contains 'path')
    Assert-True ($k + '：summary 非空') (-not [string]::IsNullOrWhiteSpace([string]$entry.summary))
}

# ---------------------------------------------------------------------------
# 2. 能力表
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 2. 能力表（§12.2 第 8 条 9 项）--'
$caps = Get-LctPluginCapabilityTable
$expectedCaps = @('read.process', 'write.process', 'read.registry', 'write.registry', 'read.fs', 'write.fs', 'account.change', 'service.control', 'network.out')
$capNames = @($caps.Keys | Sort-Object)
Assert-Equal '能力表恰好 9 项' 9 (@($capNames).Count)
Assert-Equal '能力表名字集合与 §12.2 第 8 条一致' (@($expectedCaps | Sort-Object) -join ',') (@($capNames) -join ',')
foreach ($c in @($expectedCaps)) {
    Assert-True ('能力表含 ' + $c) ($caps.ContainsKey($c))
    $cdef = $caps[$c]
    Assert-Equal ($c + '：name 字段') $c $cdef.name
    Assert-True ($c + '：risk 合法(low|medium|high)') (@('low', 'medium', 'high') -contains [string]$cdef.risk)
    Assert-True ($c + '：summary 非空') (-not [string]::IsNullOrWhiteSpace([string]$cdef.summary))
}
foreach ($c in @('write.process', 'write.registry', 'account.change', 'service.control')) {
    Assert-True ($c + '：needsConfirm=true（§12.2 第 8 条硬要求）') ([bool]$caps[$c].needsConfirm)
}
$kernelCaps = @($capNames | Where-Object { ([string]$_).StartsWith('kernel.') })
Assert-Equal '能力表不含任何 kernel.*（§12.4 边界）' 0 (@($kernelCaps).Count)
Assert-Equal '能力表不含 policy.wdac（§12.2 第 8 条只列 9 项）' 0 (@($capNames | Where-Object { ([string]$_).StartsWith('policy.') }).Count)

# ---------------------------------------------------------------------------
# 3. 引擎版本常量 getter
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 3. 引擎 API 版本常量 --'
Assert-Equal 'Get-LctPluginEngineApiVersion 返回 1.0' '1.0' (Get-LctPluginEngineApiVersion)
Assert-True 'EngineApiVersion 返回类型是 string' ((Get-LctPluginEngineApiVersion) -is [string])
Test-CallNoThrow 'Get-LctPluginEngineApiVersion 无参调用不抛异常' { Get-LctPluginEngineApiVersion }
$apiCmd = Get-Command -Name Get-LctPluginEngineApiVersion -Module PluginSdk -ErrorAction SilentlyContinue
Assert-True 'EngineApiVersion 命令存在' ($null -ne $apiCmd)
if ($null -ne $apiCmd) {
    $mandatoryParams = @($apiCmd.Parameters.Values | Where-Object {
            $null -ne ($_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and [bool]$_.Mandatory })
        })
    Assert-Equal 'EngineApiVersion 无必填参数' 0 (@($mandatoryParams).Count)
}

# ---------------------------------------------------------------------------
# 4. fixture：合法 v1（v1 兼容硬要求）
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 4. 合法 v1 清单（不许拒绝老插件）--'
$v1Dir = Join-Path $goodRoot 'fx-v1-basic'
$r1 = Invoke-LctFixtureManifest $v1Dir
Assert-True 'v1：ok=true（不因缺 v2 字段被拒绝）' ($r1.ok -eq $true) (@($r1.errors) -join ' | ')
Assert-True 'v1：degraded=true' ($r1.degraded -eq $true)
Assert-Equal 'v1：manifestVersion=1' 1 $r1.manifestVersion
Assert-Equal 'v1：errors 为空' 0 (@($r1.errors).Count)
Assert-True 'v1：warnings 含「按 v1 规则运行」' ((@($r1.warnings) -join '|') -match '按 v1 规则运行')
Assert-True 'v1：engineApiOk=true（缺 engineApi 不算"不满足"）' ($r1.engineApiOk -eq $true)
Assert-True 'v1：kinds 自动补入 entry.kind=ps1' (@($r1.kinds) -contains 'ps1')
Assert-Equal 'v1：capabilities 为空数组' 0 (@($r1.capabilities).Count)

# ---------------------------------------------------------------------------
# 5. fixture：合法 v2
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 5. 合法 v2 清单 --'
$v2Dir = Join-Path $goodRoot 'fx-v2-full'
$r2 = Invoke-LctFixtureManifest $v2Dir
Assert-True 'v2：ok=true' ($r2.ok -eq $true) (@($r2.errors) -join ' | ')
Assert-True 'v2：degraded=false' ($r2.degraded -eq $false)
Assert-Equal 'v2：manifestVersion=2' 2 $r2.manifestVersion
Assert-True 'v2：engineApiOk=true' ($r2.engineApiOk -eq $true)
Assert-Equal 'v2：capabilities=read.fs,write.fs' 'read.fs,write.fs' (@($r2.capabilities) -join ',')
Assert-Equal 'v2：kinds=ps1' 'ps1' (@($r2.kinds) -join ',')
Assert-Equal 'v2：errors 为空' 0 (@($r2.errors).Count)
Assert-Equal 'v2：单元素 kinds 数组未被 PowerShell 解包' 1 (@($r2.kinds).Count)

# 反解包回归（实测 PS 5.1，SDK 曾在此处被自己的 return 解包坑过）：
# 清单里 "capabilities":["read.fs"] / "kinds":["ps1"] 是完全合法的写法，但 PowerShell 会把函数
# return 处的**单元素数组**解包成裸值 —— 没有护栏时这里会得到 ok=false +「必须是字符串数组」。
$rSingle = Test-LctPluginManifestV2 -Obj @{
    id           = 'x'
    engineApi    = '>=1.0 <2.0'
    capabilities = @('read.fs')
    kinds        = @('ps1')
    entry        = @{ kind = 'ps1'; path = 'a.ps1' }
} -Dir $v2Dir -Id 'x'
Assert-True '单元素数组字段：ok=true（不被误判成"字段写成了字符串"）' ($rSingle.ok -eq $true) (@($rSingle.errors) -join ' | ')
Assert-Equal '单元素数组字段：capabilities 恰好 1 项' 1 (@($rSingle.capabilities).Count)
Assert-Equal '单元素数组字段：kinds 恰好 1 项' 1 (@($rSingle.kinds).Count)
Assert-True '单元素数组字段：识别出 read.fs' (@($rSingle.capabilities) -contains 'read.fs')

# 完整性校验：与 Get-FileHash 的独立计算交叉验证（证明 SDK 真算了哈希，而不是"只数条数"）
$blobPath = Join-Path $v2Dir 'payload\blob.txt'
$independentHash = ''
if (Test-Path -LiteralPath $blobPath -PathType Leaf) {
    $independentHash = (Get-FileHash -LiteralPath $blobPath -Algorithm SHA256).Hash.ToLowerInvariant()
} 
Assert-True '完整性 fixture 文件存在（前置）' (Test-Path -LiteralPath $blobPath -PathType Leaf) $blobPath
$v2Obj = Read-LctFixtureObject (Join-Path $v2Dir 'plugin.json')
$intResult = Test-LctPluginIntegrity -Dir $v2Dir -Integrity $v2Obj.integrity
Assert-True 'integrity：ok=true' ($intResult.ok -eq $true) (@($intResult.errors) -join ' | ')
Assert-Equal 'integrity：checked 恰好 1 个文件' 1 (@($intResult.checked).Count)
if (@($intResult.checked).Count -eq 1) {
    $checkedItem = @($intResult.checked)[0]
    Assert-Equal 'integrity：期望值 = 独立计算的 SHA-256' $independentHash $checkedItem.expected
    Assert-Equal 'integrity：实际值 = 独立计算的 SHA-256' $independentHash $checkedItem.actual
    Assert-True 'integrity：matched=true' ([bool]$checkedItem.matched)
}

# ---------------------------------------------------------------------------
# 6. fixture：6 个非法清单（每个恰好 1 条错误，且点名）
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 6. 非法清单（未知能力/未知种类/.. 路径/sha256）--'
$badCases = @(
    @{ dir = 'fx-unknown-cap'; expect = '未知能力'; hint = 'kernel.dream.inject' },
    @{ dir = 'fx-unknown-kind'; expect = '未知入口种类'; hint = 'driver' },
    @{ dir = 'fx-dotdot-entry'; expect = 'entry.path'; hint = '..' },
    @{ dir = 'fx-dotdot-lifecycle'; expect = 'lifecycle'; hint = '..' },
    @{ dir = 'fx-sha-mismatch'; expect = 'sha256 不符'; hint = 'payload\blob.txt' },
    @{ dir = 'fx-sha-missing'; expect = '不可校验'; hint = 'absent.bin' }
)
foreach ($c in @($badCases)) {
    $dir = Join-Path $badRoot $c.dir
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'plugin.json'))) {
        Write-Case -Name ($c.dir + '：fixture 存在（前置）') -Ok $false -Detail $dir
        continue
    }
    $r = Invoke-LctFixtureManifest $dir
    $msg = @($r.errors) -join ' | '
    Assert-True ($c.dir + '：ok=false') ($r.ok -eq $false) ('errors= ' + $msg)
    Assert-Equal ($c.dir + '：恰好 1 条错误') 1 (@($r.errors).Count)
    Assert-True ($c.dir + '：点名「' + $c.expect + '」') ($msg -match [regex]::Escape($c.expect)) ('errors= ' + $msg)
    Assert-True ($c.dir + '：点名「' + $c.hint + '」') ($msg -match [regex]::Escape($c.hint)) ('errors= ' + $msg)
}

# ---------------------------------------------------------------------------
# 7. engineApi：区间满足 / 不满足 / 无法解析
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 7. engineApi 区间 --'
$apiCases = @(
    @{ req = '>=1.0 <2.0'; ok = $true },
    @{ req = '>=0.9 <2.0'; ok = $true },
    @{ req = '>=1.0'; ok = $true },
    @{ req = '<=1.0'; ok = $true },
    @{ req = '=1.0'; ok = $true },
    @{ req = '1.0'; ok = $true },
    @{ req = '>=1.0 <=1.0'; ok = $true },
    @{ req = '>=2.0'; ok = $false },
    @{ req = '<1.0'; ok = $false },
    @{ req = '>1.0'; ok = $false },
    @{ req = ''; ok = $false },
    @{ req = 'abc'; ok = $false },
    @{ req = '>=1.0 <'; ok = $false }
)
foreach ($c in @($apiCases)) {
    $api = $null
    $threw = ''
    try { $api = Test-LctPluginEngineApi -Requirement $c.req -EngineApi '1.0' } catch { $threw = $_.Exception.Message }
    $label = 'engineApi 要求「' + $c.req + '」'
    Assert-True ($label + '：不抛异常') ([string]::IsNullOrEmpty($threw)) $threw
    if ($null -eq $api) {
        Write-Case -Name ($label + '：返回结果非空') -Ok $false
        continue
    }
    Assert-True ($label + '：ok=' + [string]$c.ok) ([bool]$api.ok -eq [bool]$c.ok) ('reason= ' + [string]$api.reason)
    Assert-True ($label + '：reason 非空') (-not [string]::IsNullOrWhiteSpace([string]$api.reason))
    Assert-True ($label + '：返回 @{ok;errors;reason} 冻结形状') (($api -is [System.Collections.IDictionary]) -and $api.Contains('ok') -and $api.Contains('errors') -and $api.Contains('reason'))
}

# 清单级：engineApi 不满足 ⇒ engineApiOk=false，但 ok 仍为 true
$rApi = Invoke-LctFixtureManifest (Join-Path $goodRoot 'fx-engineapi-high')
Assert-True 'engineApi 不满足：engineApiOk=false' ($rApi.engineApiOk -eq $false)
Assert-True 'engineApi 不满足：仍 ok=true（不是 ok=false）' ($rApi.ok -eq $true) (@($rApi.errors) -join ' | ')
Assert-Equal 'engineApi 不满足：errors 为空（不构成清单错误）' 0 (@($rApi.errors).Count)
Assert-True 'engineApi 不满足：warnings 点出 engineApi' ((@($rApi.warnings) -join '|') -match 'engineApi')
Assert-True 'engineApi 不满足：v2 清单不属于 v1 降级' ($rApi.degraded -eq $false)

# ---------------------------------------------------------------------------
# 8. Get-LctPluginChecksum 的边界
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 8. 校验和边界（不存在 / 目录 / 被独占占用）--'
$ck = Get-LctPluginChecksum -Path $blobPath
Assert-True 'checksum：存在文件 ok=true' ($ck.ok -eq $true) ([string]$ck.error)
Assert-Equal 'checksum：sha256 与 Get-FileHash 一致' $independentHash $ck.sha256
Assert-Equal 'checksum：size 与文件长度一致' ((Get-Item -LiteralPath $blobPath).Length) $ck.size

$ckNo = Get-LctPluginChecksum -Path (Join-Path $fixtureRoot 'no-such-file.bin')
Assert-True 'checksum：不存在的路径 ok=false' ($ckNo.ok -eq $false)
Assert-True 'checksum：不存在的路径 error 非空' (-not [string]::IsNullOrWhiteSpace([string]$ckNo.error)) ([string]$ckNo.error)

$ckDir = Get-LctPluginChecksum -Path $fixtureRoot
Assert-True 'checksum：目录而不是文件 ok=false' ($ckDir.ok -eq $false)
Assert-True 'checksum：目录 error 点明是目录' ([string]$ckDir.error -match '目录') ([string]$ckDir.error)

# 被独占占用的文件：在系统临时目录创建（按删除铁律不删除）
$lockDir = Join-Path $env:TEMP ('lct-pluginsdk-lock-' + [guid]::NewGuid().ToString('N'))
$lockFile = Join-Path $lockDir 'locked.bin'
$lockOk = $true
$lockDetail = ''
$ckLock = $null
$handle = $null
try {
    $null = New-Item -ItemType Directory -Path $lockDir -Force -ErrorAction Stop
    [IO.File]::WriteAllText($lockFile, 'locked-fixture')
    $handle = [IO.File]::Open($lockFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $ckLock = Get-LctPluginChecksum -Path $lockFile
} catch {
    $lockOk = $false
    $lockDetail = $_.Exception.Message
} finally {
    if ($null -ne $handle) { try { $handle.Dispose() } catch { } }
}
Assert-True 'checksum：被独占占用文件的前置准备成功' $lockOk $lockDetail
if ($lockOk -and $null -ne $ckLock) {
    Assert-True 'checksum：被独占占用文件 ok=false（不抛）' ($ckLock.ok -eq $false)
    Assert-True 'checksum：被独占占用文件 error 非空' (-not [string]::IsNullOrWhiteSpace([string]$ckLock.error)) ([string]$ckLock.error)
}

# ---------------------------------------------------------------------------
# 9. Test-LctPluginIntegrity 的边界
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 9. 完整性校验边界 --'
$iNull = Test-LctPluginIntegrity -Dir $v2Dir -Integrity $null
Assert-True 'integrity：$null ⇒ ok=true' ($iNull.ok -eq $true)
Assert-Equal 'integrity：$null ⇒ checked 为空' 0 (@($iNull.checked).Count)
$iStr = Test-LctPluginIntegrity -Dir $v2Dir -Integrity 'garbage'
Assert-True 'integrity：字符串 ⇒ ok=false' ($iStr.ok -eq $false)
$iEmpty = Test-LctPluginIntegrity -Dir $v2Dir -Integrity @{ sha256 = @{} }
Assert-True 'integrity：空 sha256 映射 ⇒ ok=true' ($iEmpty.ok -eq $true)
$iDot = Test-LctPluginIntegrity -Dir $v2Dir -Integrity @{ sha256 = @{ '..\..\evil.bin' = ('0' * 64) } }
Assert-True 'integrity：键含 .. ⇒ ok=false' ($iDot.ok -eq $false)
Assert-True 'integrity：键含 .. ⇒ 点名' ((@($iDot.errors) -join '|') -match '\.\.') (@($iDot.errors) -join ' | ')
$iAbs = Test-LctPluginIntegrity -Dir $v2Dir -Integrity @{ sha256 = @{ 'C:\Windows\notepad.exe' = ('0' * 64) } }
Assert-True 'integrity：绝对路径键 ⇒ ok=false（有意收紧）' ($iAbs.ok -eq $false)
$iFmt = Test-LctPluginIntegrity -Dir $v2Dir -Integrity @{ sha256 = @{ 'payload\blob.txt' = 'xyz' } }
Assert-True 'integrity：期望值非 64 位十六进制 ⇒ ok=false（有意收紧）' ($iFmt.ok -eq $false)
$iNoDir = Test-LctPluginIntegrity -Dir (Join-Path $fixtureRoot 'no-such-dir') -Integrity @{ sha256 = @{ 'a.bin' = ('0' * 64) } }
Assert-True 'integrity：插件目录不存在 ⇒ ok=false' ($iNoDir.ok -eq $false)

# ---------------------------------------------------------------------------
# 10. 敌对输入：一律不 throw，且仍返回冻结形状
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 10. 敌对输入不抛异常 + 冻结形状 --'
$hostileDir = Join-Path $fixtureRoot 'no-such-dir'
$hostileManifests = @(
    @{ name = '$null'; obj = $null },
    @{ name = '字符串'; obj = 'not-an-object' },
    @{ name = '数组'; obj = @(1, 2, 3) },
    @{ name = '数字'; obj = 42 },
    @{ name = '空 hashtable'; obj = @{} },
    @{ name = 'capabilities 写成字符串'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; capabilities = 'read.fs' } },
    @{ name = 'capabilities 写成对象'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; capabilities = @{ a = 1 } } },
    @{ name = 'capabilities 含非字符串元素'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; capabilities = @($null, '', 7) } },
    @{ name = 'kinds 写成字符串'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; kinds = 'ps1' } },
    @{ name = 'entry 是字符串'; obj = @{ id = 'x'; entry = 'run.ps1' } },
    @{ name = 'lifecycle 是数组'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; lifecycle = @('a', 'b') } },
    @{ name = 'lifecycle 值是对象'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; lifecycle = @{ install = @{ a = 1 } } } },
    @{ name = 'integrity 是字符串'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; integrity = 'nope' } },
    @{ name = 'integrity.sha256 是数组'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 'a.ps1' }; integrity = @{ sha256 = @(1, 2) } } },
    @{ name = 'manifest 非数字'; obj = @{ id = 'x'; manifest = '二'; entry = @{ kind = 'ps1'; path = 'a.ps1' } } },
    @{ name = 'manifest=99'; obj = @{ id = 'x'; manifest = 99; entry = @{ kind = 'ps1'; path = 'a.ps1' } } },
    @{ name = 'engineApi 是数字'; obj = @{ id = 'x'; engineApi = 2; entry = @{ kind = 'ps1'; path = 'a.ps1' } } },
    @{ name = 'id 含路径穿越'; obj = @{ id = '../evil'; entry = @{ kind = 'ps1'; path = 'a.ps1' } } },
    @{ name = 'id 与目录名不一致'; obj = @{ id = 'other-id'; entry = @{ kind = 'ps1'; path = 'a.ps1' } } },
    @{ name = 'entry.path 是数字'; obj = @{ id = 'x'; entry = @{ kind = 'ps1'; path = 5 } } },
    @{ name = 'kinds 与 entry.kind 不一致'; obj = @{ id = 'x'; kinds = @('exe'); entry = @{ kind = 'ps1'; path = 'a.ps1' } } }
)
foreach ($c in @($hostileManifests)) {
    $res = $null
    $threw = ''
    try { $res = Test-LctPluginManifestV2 -Obj $c.obj -Dir $hostileDir -Id 'x' } catch { $threw = $_.Exception.Message }
    Assert-True ('敌对输入不抛异常: ' + $c.name) ([string]::IsNullOrEmpty($threw)) $threw

    $shapeOk = $false
    if ($null -ne $res) {
        $shapeOk = ($null -ne $res.PSObject.Properties['ok']) -and
                   ($null -ne $res.PSObject.Properties['errors']) -and
                   ($null -ne $res.PSObject.Properties['warnings']) -and
                   ($null -ne $res.PSObject.Properties['manifestVersion']) -and
                   ($null -ne $res.PSObject.Properties['engineApiOk']) -and
                   ($null -ne $res.PSObject.Properties['capabilities']) -and
                   ($null -ne $res.PSObject.Properties['kinds']) -and
                   ($null -ne $res.PSObject.Properties['degraded'])
    }
    $typeName = 'null'
    if ($null -ne $res) { $typeName = $res.GetType().Name }
    Assert-True ('敌对输入仍返回冻结形状: ' + $c.name) $shapeOk ('type=' + $typeName)
}

# 'kinds 与 entry.kind 不一致'：不是错误，而是警告 + 自动补入
$rMismatch = Test-LctPluginManifestV2 -Obj @{ id = 'x'; kinds = @('exe'); entry = @{ kind = 'ps1'; path = 'a.ps1' } } -Dir $hostileDir -Id 'x'
Assert-True 'kinds 与 entry.kind 不一致 ⇒ 仍 ok=true（只告警）' ($rMismatch.ok -eq $true) (@($rMismatch.errors) -join ' | ')
Assert-True 'kinds 与 entry.kind 不一致 ⇒ kinds 补入 ps1' (@($rMismatch.kinds) -contains 'ps1')
Assert-True 'kinds 与 entry.kind 不一致 ⇒ warnings 说明补入' ((@($rMismatch.warnings) -join '|') -match '自动补入')

# 其它三个函数的敌对输入
foreach ($t in @(
        @{ n = 'Test-LctPluginIntegrity $null 目录 + $null Integrity'; b = { Test-LctPluginIntegrity -Dir $null -Integrity $null } },
        @{ n = 'Test-LctPluginIntegrity 数字目录 + 数字 Integrity'; b = { Test-LctPluginIntegrity -Dir 42 -Integrity 99 } },
        @{ n = 'Test-LctPluginIntegrity 数组 Integrity'; b = { Test-LctPluginIntegrity -Dir 'C:\Windows' -Integrity @(1, 2) } },
        @{ n = 'Test-LctPluginEngineApi $null 参数'; b = { Test-LctPluginEngineApi -Requirement $null -EngineApi $null } },
        @{ n = 'Test-LctPluginEngineApi 数字参数'; b = { Test-LctPluginEngineApi -Requirement 2 -EngineApi 1 } },
        @{ n = 'Test-LctPluginEngineApi 500 个 > 垃圾'; b = { Test-LctPluginEngineApi -Requirement ('>' * 500) -EngineApi ('x' * 300) } },
        @{ n = 'Get-LctPluginChecksum $null'; b = { Get-LctPluginChecksum -Path $null } },
        @{ n = 'Get-LctPluginChecksum 空串'; b = { Get-LctPluginChecksum -Path '' } },
        @{ n = 'Get-LctPluginChecksum 非法字符路径'; b = { Get-LctPluginChecksum -Path 'C:\<>|bad?.bin' } },
        @{ n = 'Get-LctPluginChecksum 通配符路径'; b = { Get-LctPluginChecksum -Path 'C:\Windows\*.exe' } },
        @{ n = 'Get-LctPluginChecksum 目录（Windows）'; b = { Get-LctPluginChecksum -Path 'C:\Windows' } }
    )) {
    Test-CallNoThrow $t.n $t.b
}
Assert-True 'checksum 空串 ⇒ ok=false 且 error 非空' ((Get-LctPluginChecksum -Path '').ok -eq $false)
Assert-True 'checksum 通配符路径按字面处理 ⇒ ok=false' ((Get-LctPluginChecksum -Path 'C:\Windows\*.exe').ok -eq $false)

# ---------------------------------------------------------------------------
# 11. 真实样例插件（v1）兼容
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 11. 真实样例插件 plugins\cve-2026-49176（v1）--'
$sampleDir = Join-Path $samplePluginsRoot 'cve-2026-49176'
if (Test-Path -LiteralPath (Join-Path $sampleDir 'plugin.json')) {
    $rs = Invoke-LctFixtureManifest $sampleDir
    Assert-True '样例插件（v1）⇒ ok=true' ($rs.ok -eq $true) (@($rs.errors) -join ' | ')
    Assert-True '样例插件（v1）⇒ degraded=true' ($rs.degraded -eq $true)
    Assert-Equal '样例插件（v1）⇒ manifestVersion=1' 1 $rs.manifestVersion
    Assert-Equal '样例插件（v1）⇒ 0 条错误' 0 (@($rs.errors).Count)
    Assert-True '样例插件（v1）⇒ warnings 含「按 v1 规则运行」' ((@($rs.warnings) -join '|') -match '按 v1 规则运行')
} else {
    Write-Case -Name '样例插件存在（前置条件）' -Ok $false -Detail $sampleDir
}

# ---------------------------------------------------------------------------
# 12. Lint-Plugin.ps1 真跑（子进程，断言退出码 = 问题数）
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- 12. Lint-Plugin.ps1 子进程退出码 --'
$lintSample = Invoke-LctLintChild $samplePluginsRoot
Assert-Equal 'Lint 真实 plugins 树 ⇒ 退出码 0（v1 样例 0 问题）' 0 $lintSample.code
$lintGood = Invoke-LctLintChild $goodRoot
Assert-Equal 'Lint 合法 fixture 集 ⇒ 退出码 0' 0 $lintGood.code
$badDirCount = @(Get-ChildItem -LiteralPath $badRoot -Directory -ErrorAction SilentlyContinue).Count
Assert-Equal '非法 fixture 用例数 = 6' 6 $badDirCount
$lintBad = Invoke-LctLintChild $badRoot
Assert-Equal ('Lint 非法 fixture 集 ⇒ 退出码 = 用例数 ' + $badDirCount) $badDirCount $lintBad.code
$lintAll = Invoke-LctLintChild $fixtureRoot
Assert-Equal 'Lint 整个 fixtures 根 ⇒ 退出码 = 非法用例数' $badDirCount $lintAll.code

# ---------------------------------------------------------------------------
# 13. 汇总
# ---------------------------------------------------------------------------
$total = $script:passCount + $script:failCount
Write-Host ''
Write-Host ('PluginSdkTest 汇总: PASS=' + $script:passCount + ' FAIL=' + $script:failCount + ' 总计=' + $total)
if ($script:failCount -gt 0) {
    Write-Host 'PluginSdkTest: 失败明细'
    foreach ($l in @($script:failLines)) { Write-Host $l }
    Write-Host ('PluginSdkTest: FAILED (' + $script:failCount + ')')
} else {
    Write-Host 'PluginSdkTest: ALL PASS'
}
exit $script:failCount