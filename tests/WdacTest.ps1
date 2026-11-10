# =====================================================================
# LocalConfigTool - tests\WdacTest.ps1
# 职责：task-5（WDAC 黑名单模块）自测
# 铁律（本文件的核心约束）：
#   * 绝不允许把任何策略部署到系统 CI 存储（System32\CodeIntegrity）——
#     本测试只碰隔离的 LCT_VAR_DIR、临时目录，以及**只读**地读取系统 CodeIntegrity。
#   * 全程记录 System32\CodeIntegrity 的文件清单 + SHA256，测试前后必须完全一致。
#   * 需要写系统的那条成功路径（真实 deploy）刻意不执行，只在报告里 SKIP 说明。
# 运行：powershell -NoProfile -ExecutionPolicy Bypass -File tests\WdacTest.ps1
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
function Short([string]$Text, [int]$Max = 160) {
    $t = ([string]$Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '...' }
    return $t
}
function Joined($Items) { return (Short ((@($Items | ForEach-Object { [string]$_ }) -join ' / '))) }

$root = Split-Path -Parent $PSScriptRoot

# ---------- 隔离环境（先设 LCT_VAR_DIR 再碰任何模块函数）----------
$testId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$varDir = Join-Path $env:TEMP ('lct-wdac-test-' + $testId)
$scanDir = Join-Path $varDir 'scan'
$tmpDir = Join-Path $varDir 'tmp'
foreach ($d in @($varDir, $scanDir, $tmpDir)) { if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force } }
$env:LCT_VAR_DIR = $varDir

# 假目标文件（占位 .exe/.dll；绝不拿真实系统程序当目标）
$fakeExe = Join-Path $scanDir 'evil.exe'
$fakeDll = Join-Path $scanDir 'bad.dll'
foreach ($f in @($fakeExe, $fakeDll)) { [IO.File]::WriteAllBytes($f, @(1..256 | ForEach-Object { [byte]($_ % 251) })) }

# ---------- 系统 CI 存储快照（只读）----------
$ciDir = Join-Path $env:SystemRoot 'System32\CodeIntegrity'
$ciPolicyPath = Join-Path $ciDir 'SiPolicy.p7b'
function Get-CiSnapshot {
    $items = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $ciDir -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $h = '<hash-failed>'
        try { $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
        $null = $items.Add((($f.FullName.Substring($ciDir.Length)) + '|' + $f.Length + '|' + $h))
    }
    return [string[]]@($items)
}
$ciBefore = Get-CiSnapshot
$ciHadSiPolicy = (Test-Path -LiteralPath $ciPolicyPath)

# ---------- 装载模块 ----------
$loadError = ''
try {
    Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $root 'core\Wdac.psm1') -Force -Global -ErrorAction Stop
} catch { $loadError = $_.Exception.Message }
if ($loadError -ne '') {
    Write-Host ('FATAL: 模块装载失败: ' + $loadError)
    exit 99
}
$modulePath = Join-Path $root 'core\Wdac.psm1'
$rulesPath = Join-Path $varDir 'wdac\rules.json'
$stagingDir = Join-Path $varDir 'wdac\staging'
$backupRoot = Join-Path $varDir 'backups'
$moduleSource = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
# 只检查“非纯注释行”，这样模块可以在注释里写明规则而不误伤
$moduleCodeLines = @(Get-Content -LiteralPath $modulePath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*#' })
$moduleCodeText = ($moduleCodeLines -join "`n")

Write-Host ('WdacTest: varDir=' + $varDir)
Write-Host ('WdacTest: 系统 CI 目录=' + $ciDir + ' (只读；测试前存在 SiPolicy.p7b=' + [string]$ciHadSiPolicy + ')')

# =====================================================================
Section '① 规则增删（rules.json 持久化 / 去重 / 校验）'

$r0 = @(Get-LctWdacRules)
Check '① 初始规则数为 0' (@($r0).Count -eq 0) ('count=' + @($r0).Count)

$rp = Add-LctWdacRule -Kind 'path' -Value $fakeExe -Reason 'preview only'
Check '① Add 预览：ok=true 且 applied=false' ($rp.ok -and (-not $rp.applied)) ('ok=' + $rp.ok + ' applied=' + $rp.applied)
Check '① 预览未写出 rules.json' (-not (Test-Path -LiteralPath $rulesPath))

$a1 = Add-LctWdacRule -Kind 'path' -Value $fakeExe -Reason 'block fake exe' -Apply
Check '① Add path -Apply 成功' ($a1.ok -and $a1.applied) (Joined $a1.errors)
Check '① rules.json 已落盘' (Test-Path -LiteralPath $rulesPath)
Check '① 规则数=1' (@(Get-LctWdacRules).Count -eq 1) ('count=' + @(Get-LctWdacRules).Count)
Check '① 规则含 id/kind/value/reason' ((([string]$a1.data.rule.id) -like 'ID_DENY_LCT_PATH_*') -and ([string]$a1.data.rule.reason) -eq 'block fake exe') ('id=' + $a1.data.rule.id)

$a2 = Add-LctWdacRule -Kind 'path' -Value $fakeExe -Reason 'duplicate' -Apply
Check '① 重复添加幂等：ok=true / applied=false' ($a2.ok -and (-not $a2.applied)) ('ok=' + $a2.ok + ' applied=' + $a2.applied)
Check '① 重复添加后规则数仍=1' (@(Get-LctWdacRules).Count -eq 1)
$w2 = (@($a2.warnings) -join ' ')
Check '① 重复添加标注“无变化/已存在”' ($w2 -match '已存在' -or $w2 -match '无变化') (Short $w2)

$bad1 = Add-LctWdacRule -Kind 'path' -Value 'relative\evil.exe' -Reason 'x' -Apply
Check '① 相对路径被拒（ok=false 且有 errors）' ((-not $bad1.ok) -and (@($bad1.errors).Count -gt 0)) (Joined $bad1.errors)
$bad2 = Add-LctWdacRule -Kind 'hash' -Value 'ZZZZ-not-hex' -Reason 'x' -Apply
Check '① 非法 hash 被拒' (-not $bad2.ok) (Joined $bad2.errors)
$bad3 = Add-LctWdacRule -Kind 'hash' -Value 'ABCD' -Reason 'x' -Apply
Check '① hash 长度不符被拒' (-not $bad3.ok) (Joined $bad3.errors)
$bad4 = Add-LctWdacRule -Kind 'path' -Value (Join-Path $env:windir 'System32\cmd.exe') -Reason 'x' -Apply
$e4 = (@($bad4.errors) -join ' ')
Check '① 命中 C:\Windows 的 path 规则被拒' ((-not $bad4.ok) -and ($e4 -match 'Windows')) (Short $e4)
$bad5 = Add-LctWdacRule -Kind 'fileName' -Value '*' -Reason 'x' -Apply
Check '① 全通配 fileName 被拒' (-not $bad5.ok) (Joined $bad5.errors)
$bad6 = Add-LctWdacRule -Kind 'fileName' -Value '*.exe' -Reason 'x' -Apply
Check '① *.exe 这类泛化 fileName 被拒' (-not $bad6.ok) (Joined $bad6.errors)
$bad7 = Add-LctWdacRule -Kind 'bogus' -Value 'x' -Reason 'x' -Apply
Check '① 非法 kind 被拒' (-not $bad7.ok) (Joined $bad7.errors)
$bad8 = Add-LctWdacRule -Kind 'path' -Value $env:TEMP -Reason 'x' -Apply
Check '① 目录（非文件）被拒' (-not $bad8.ok) (Joined $bad8.errors)

$f1 = Add-LctWdacRule -Kind 'fileName' -Value 'evil-tool.exe' -Reason 'name rule' -Apply
$h1 = Add-LctWdacRule -Kind 'hash' -Value ('AB' * 32) -Reason 'hash rule' -Apply
Check '① fileName / hash 规则添加成功' ($f1.ok -and $h1.ok) (Joined (@($f1.errors) + @($h1.errors)))
Check '① 规则数=3' (@(Get-LctWdacRules).Count -eq 3) ('count=' + @(Get-LctWdacRules).Count)

$rawJson = $null
try { $rawJson = (Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $rawJson = $null }
Check '① rules.json 可直接解析且含 3 条' (($null -ne $rawJson) -and (@($rawJson.rules).Count -eq 3)) ('count=' + @($rawJson.rules).Count)
Check '① rules.json 保留 reason 字段' (@($rawJson.rules | Where-Object { -not [string]::IsNullOrEmpty($_.reason) }).Count -eq 3)

$rm1 = Remove-LctWdacRule -Kind 'fileName' -Value 'evil-tool.exe' -Apply
Check '① Remove -Apply 成功且规则数=2' ($rm1.ok -and $rm1.applied -and (@(Get-LctWdacRules).Count -eq 2)) ('count=' + @(Get-LctWdacRules).Count)
$rm2 = Remove-LctWdacRule -Kind 'fileName' -Value 'not-there.exe' -Apply
Check '① 删除不存在的规则：幂等 ok=true / applied=false' ($rm2.ok -and (-not $rm2.applied)) (Joined $rm2.warnings)
$rm3 = Remove-LctWdacRule -Kind 'hash' -Value ('AB' * 32)
Check '① 删除预览未改盘（仍 2 条）' ($rm3.ok -and (-not $rm3.applied) -and (@(Get-LctWdacRules).Count -eq 2)) ('count=' + @(Get-LctWdacRules).Count)

# =====================================================================
Section '② 构建策略（缺 -ScanPath 拒绝 / 预览不落盘 / audit + enforce 产物）'

$noScan = New-LctWdacPolicy -Mode audit -Apply
$eNoScan = (@($noScan.errors) -join ' ')
Check '② 缺 -ScanPath 被拒绝执行' ((-not $noScan.ok) -and ($eNoScan -match 'ScanPath')) (Short $eNoScan)
Check '② 缺 -ScanPath 时未产出 policy.xml' (-not (Test-Path -LiteralPath (Join-Path $stagingDir 'policy.xml')))

$bPreview = New-LctWdacPolicy -Mode audit -ScanPath $scanDir
Check '② 预览：ok=true / applied=false' ($bPreview.ok -and (-not $bPreview.applied)) (Joined $bPreview.errors)
Check '② 预览未产出 policy.xml（默认只预览）' (-not (Test-Path -LiteralPath (Join-Path $stagingDir 'policy.xml')))
$scanFull = (Resolve-Path -LiteralPath $scanDir).ProviderPath
Check '② 预览给出 xmlPath / scanPath' (([string]$bPreview.data.xmlPath) -like '*\staging\policy.xml' -and ([string]$bPreview.data.scanPath) -eq $scanFull) ('xml=' + $bPreview.data.xmlPath)

$bAudit = New-LctWdacPolicy -Mode audit -ScanPath $scanDir -Apply
Check '② audit 构建成功（ok=true / applied=true）' ($bAudit.ok -and $bAudit.applied) (Joined $bAudit.errors)
$xmlA = [string]$bAudit.data.xmlPath
$cipA = [string]$bAudit.data.cipPath
Copy-Item -LiteralPath $xmlA -Destination (Join-Path $tmpDir 'audit.xml') -Force
Check '② policy.xml 产出' (Test-Path -LiteralPath $xmlA) $xmlA
Check '② policy.cip 产出且体积合理（>200B）' ((Test-Path -LiteralPath $cipA) -and ((Get-Item -LiteralPath $cipA).Length -gt 200)) ('size=' + (Get-Item -LiteralPath $cipA).Length)
Check '② staging 内含 rules.json 快照' (Test-Path -LiteralPath (Join-Path $stagingDir 'rules.json'))
$readmeOk = (Test-Path -LiteralPath (Join-Path $stagingDir 'README.txt'))
$readmeTxt = ''
if ($readmeOk) { $readmeTxt = Get-Content -LiteralPath (Join-Path $stagingDir 'README.txt') -Raw -Encoding UTF8 }
Check '② staging README.txt 含 F8 + WinRE 恢复步骤' ($readmeOk -and ($readmeTxt -match 'F8') -and ($readmeTxt -match 'WinRE'))
$optsA = @($bAudit.data.options)
Check '② audit 含 Enabled:Audit Mode' ($optsA -contains 'Enabled:Audit Mode') (Short ($optsA -join ' ; ') 230)
Check '② audit 含 Unsigned System Integrity Policy' ($optsA -contains 'Enabled:Unsigned System Integrity Policy')
Check '② audit 含 Advanced Boot Options Menu（救命绳）' ($optsA -contains 'Enabled:Advanced Boot Options Menu')
Check '② audit 含 Boot Audit On Failure（救命绳）' ($optsA -contains 'Enabled:Boot Audit On Failure')
Check '② audit 含 Enabled:UMCI（AllowAll 官方基底）' ($optsA -contains 'Enabled:UMCI')
Check '② audit 有 allow 机制（AllowAll 配方）' ([bool]$bAudit.data.hasAllowMechanism) ([string]$bAudit.data.allowMechanismText)
Check '② audit 允许审计部署' ([bool]$bAudit.data.canDeployAudit)
Check '② audit 禁止强制部署（模式未就绪）' (-not [bool]$bAudit.data.canDeployEnforce) (Joined $bAudit.data.enforceBlockers)
Check '② deny 规则条数=2 且与规则库一致' ([int]$bAudit.data.rulesCount -eq 2) ('rulesCount=' + $bAudit.data.rulesCount)
Check '② 官方序列化 + XML 直写两条分支都被用到' (([int]$bAudit.data.officialRuleCount -ge 1) -and ([int]$bAudit.data.domRuleCount -ge 1)) ('official=' + $bAudit.data.officialRuleCount + ' dom=' + $bAudit.data.domRuleCount)
Check '② 报告用户可写目录 FilePath 规则的失效风险' (@($bAudit.data.userWritableHits).Count -ge 1) (Joined ($bAudit.data.userWritableHits | ForEach-Object { [string]$_.value + ' -> ' + [string]$_.reason }))
Check '② 结果明确「需重启」' ([bool]$bAudit.data.needRestart -and ([string]$bAudit.data.restartText -match '重启')) (Short ([string]$bAudit.data.restartText))

$bEnforce = New-LctWdacPolicy -Mode enforce -ScanPath $scanDir -Apply
Check '② enforce 构建成功' ($bEnforce.ok -and $bEnforce.applied) (Joined $bEnforce.errors)
Copy-Item -LiteralPath ([string]$bEnforce.data.xmlPath) -Destination (Join-Path $tmpDir 'enforce.xml') -Force
$optsE = @($bEnforce.data.options)
Check '② enforce 不含 Enabled:Audit Mode' (-not ($optsE -contains 'Enabled:Audit Mode')) (Short ($optsE -join ' ; ') 230)
Check '② enforce 含 Advanced Boot Options Menu' ($optsE -contains 'Enabled:Advanced Boot Options Menu')
Check '② enforce 含 Boot Audit On Failure' ($optsE -contains 'Enabled:Boot Audit On Failure')
Check '② enforce 允许强制部署（allow 机制 + 两条救命绳）' ([bool]$bEnforce.data.canDeployEnforce) (Joined $bEnforce.data.enforceBlockers)
Check '② audit 与 enforce 的 PolicyID 不同且非空' ((-not [string]::IsNullOrEmpty([string]$bAudit.data.policyId)) -and ([string]$bAudit.data.policyId -ne [string]$bEnforce.data.policyId)) ('audit=' + $bAudit.data.policyId + ' enforce=' + $bEnforce.data.policyId)
Check '② PolicyID 未沿用 AllowAll 的固定 GUID' (([string]$bEnforce.data.policyId) -notlike '*A244370E*') ([string]$bEnforce.data.policyId)

$null = Remove-LctWdacRule -Kind 'path' -Value $fakeExe -Apply
$null = Remove-LctWdacRule -Kind 'hash' -Value ('AB' * 32) -Apply
Check '② 清空规则库后规则数=0' (@(Get-LctWdacRules).Count -eq 0) ('count=' + @(Get-LctWdacRules).Count)
$bEmpty = New-LctWdacPolicy -Mode audit -ScanPath $scanDir -Apply
$eEmpty = (@($bEmpty.errors) -join ' ')
Check '② 空规则库构建被拒绝（errors 说明没有规则）' ((-not $bEmpty.ok) -and ($eEmpty -match '没有规则|规则条数为 0')) (Short $eEmpty)
$null = Add-LctWdacRule -Kind 'path' -Value $fakeExe -Reason 'restore for later checks' -Apply

# =====================================================================
Section '③ 安全门 Test-LctWdacPolicy：4 类危险输入必须报错拒绝'

$xmlNoAllow = Join-Path $tmpDir 'noallow-enforce.xml'
$xmlCritical = Join-Path $tmpDir 'critical-windows.xml'
$xmlNoLifeSaver = Join-Path $tmpDir 'no-lifesaver-enforce.xml'
$xmlAuditNoAllow = Join-Path $tmpDir 'noallow-audit.xml'

$optUnsigned = '    <Rule><Option>Enabled:Unsigned System Integrity Policy</Option></Rule>'
$optAdvBoot = '    <Rule><Option>Enabled:Advanced Boot Options Menu</Option></Rule>'
$optBootAudit = '    <Rule><Option>Enabled:Boot Audit On Failure</Option></Rule>'
$optAudit = '    <Rule><Option>Enabled:Audit Mode</Option></Rule>'

$denyOnlyRules = '  <FileRules><Deny ID="ID_DENY_LCT_A" FilePath="C:\Tools\evil.exe" /></FileRules>'
$allowPlusDenyRules = @'
  <FileRules>
    <Allow ID="ID_ALLOW_LCT_A" FileName="*" />
    <Deny ID="ID_DENY_LCT_A" FilePath="C:\Tools\evil.exe" />
  </FileRules>
'@
$criticalRules = @'
  <FileRules>
    <Allow ID="ID_ALLOW_LCT_A" FileName="*" />
    <Deny ID="ID_DENY_LCT_B" FilePath="C:\Windows\System32\cmd.exe" />
  </FileRules>
'@
$scenDenyOnly = '    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS"><ProductSigners><FileRulesRef><FileRuleRef RuleID="ID_DENY_LCT_A" /></FileRulesRef></ProductSigners></SigningScenario>'
$scenAllowDeny = '    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS"><ProductSigners><FileRulesRef><FileRuleRef RuleID="ID_ALLOW_LCT_A" /><FileRuleRef RuleID="ID_DENY_LCT_A" /></FileRulesRef></ProductSigners></SigningScenario>'
$scenCrit = '    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS"><ProductSigners><FileRulesRef><FileRuleRef RuleID="ID_ALLOW_LCT_A" /><FileRuleRef RuleID="ID_DENY_LCT_B" /></FileRulesRef></ProductSigners></SigningScenario>'

function New-TestXml([string]$Path, [string]$Rules, [string]$FileRules, [string]$Scen) {
    $tpl = @'
<?xml version="1.0" encoding="utf-8"?>
<SiPolicy xmlns="urn:schemas-microsoft-com:sipolicy">
  <VersionEx>10.0.0.0</VersionEx>
  <Rules>
{{RULES}}
  </Rules>
{{FILERULES}}
  <Signers />
  <SigningScenarios>
{{SCEN}}
  </SigningScenarios>
</SiPolicy>
'@
    $t = $tpl.Replace('{{RULES}}', $Rules).Replace('{{FILERULES}}', $FileRules).Replace('{{SCEN}}', $Scen)
    [IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}
$optEnforceSet = (@($optUnsigned, $optAdvBoot, $optBootAudit) -join "`n")
$optAuditSet = (@($optUnsigned, $optAudit, $optAdvBoot, $optBootAudit) -join "`n")
$null = New-TestXml -Path $xmlNoAllow -Rules $optEnforceSet -FileRules $denyOnlyRules -Scen $scenDenyOnly
$null = New-TestXml -Path $xmlCritical -Rules $optEnforceSet -FileRules $criticalRules -Scen $scenCrit
$null = New-TestXml -Path $xmlNoLifeSaver -Rules $optUnsigned -FileRules $allowPlusDenyRules -Scen $scenAllowDeny
$null = New-TestXml -Path $xmlAuditNoAllow -Rules $optAuditSet -FileRules $denyOnlyRules -Scen $scenDenyOnly

# (a) 空规则：微软自带 AllowAll.xml（真实策略，0 条 deny）
$allowAllXml = Join-Path $env:windir 'schemas\CodeIntegrity\ExamplePolicies\AllowAll.xml'
$tA = Test-LctWdacPolicy -XmlPath $allowAllXml
$eA = (@($tA.errors) -join ' ')
Check '③(a) 空规则策略被拒（errors 提到规则条数为 0）' ((-not $tA.ok) -and ($eA -match '规则条数为 0')) (Short $eA)

# (b) 无任何 allow 机制 + 强制意图
$tB = Test-LctWdacPolicy -XmlPath $xmlNoAllow
$eB = (@($tB.errors) -join ' ')
Check '③(b) 无 allow 机制的强制意图策略被拒' ((-not $tB.ok) -and ($eB -match 'allow 机制')) (Short $eB)
Check '③(b) canDeployEnforce=false 且 enforceBlockers 给出原因' ((-not [bool]$tB.data.canDeployEnforce) -and (@($tB.data.enforceBlockers).Count -gt 0)) (Joined $tB.data.enforceBlockers)

# (c) deny 命中 C:\Windows
$tC = Test-LctWdacPolicy -XmlPath $xmlCritical
$eC = (@($tC.errors) -join ' ')
Check '③(c) 命中 C:\Windows 的 deny 规则被拒' ((-not $tC.ok) -and ($eC -match 'Windows')) (Short $eC)
Check '③(c) 命中项进入 data.criticalHits' (@($tC.data.criticalHits).Count -ge 1) (Joined ($tC.data.criticalHits | ForEach-Object { [string]$_.reason }))

# (d) 强制意图但缺两条救命绳
$tD = Test-LctWdacPolicy -XmlPath $xmlNoLifeSaver
$eD = (@($tD.errors) -join ' ')
Check '③(d) 缺救命绳的强制意图策略被拒（两条都报）' ((-not $tD.ok) -and (@($tD.errors).Count -ge 2) -and ($eD -match 'Advanced Boot Options Menu') -and ($eD -match 'Boot Audit On Failure')) (Short $eD)

# (e) 审计 + 无 allow 机制：不拦审计部署，但禁止转强制
$tE = Test-LctWdacPolicy -XmlPath $xmlAuditNoAllow
$wE = (@($tE.warnings) -join ' ')
Check '③(e) 审计 + 无 allow 机制：errors 为空（不拦审计部署）' ($tE.ok -and (@($tE.errors).Count -eq 0)) (Joined $tE.errors)
Check '③(e) 但 canDeployEnforce=false 且 warnings 说明禁止转强制' ((-not [bool]$tE.data.canDeployEnforce) -and ($wE -match '禁止转强制')) (Short $wE)

# (f) 正向对照：自己构建出的策略必须通过安全门
$tAudit = Test-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'audit.xml')
Check '③(f) 自建 audit 策略通过安全门（ok=true / canDeployAudit=true）' ($tAudit.ok -and [bool]$tAudit.data.canDeployAudit) (Joined $tAudit.errors)
$tEnforce = Test-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'enforce.xml')
Check '③(f) 自建 enforce 策略通过安全门（allow 机制 + 救命绳齐备）' ($tEnforce.ok -and [bool]$tEnforce.data.canDeployEnforce) (Joined $tEnforce.errors)

# =====================================================================
Section '④ 部署确认文本（错误文本必须拒绝，且不复制任何文件）'

$bkBefore = @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count
$d1 = Deploy-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'audit.xml') -Mode audit -ConfirmText 'I-UNDERSTAND' -Apply
$e1 = (@($d1.errors) -join ' ')
Check '④ 错误 confirm 文本被拒（errors 指明 I-UNDERSTAND-AUDIT）' ((-not $d1.ok) -and ($e1 -match 'I-UNDERSTAND-AUDIT')) (Short $e1)
Check '④ 错误 confirm：未创建备份目录' (@(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count -eq $bkBefore) ('backups=' + @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count)
Check '④ 错误 confirm：data 未给出 revertCmdPath' ([string]::IsNullOrEmpty([string]$d1.data.revertCmdPath))
Check '④ 错误 confirm：系统 CI 快照未变' (@(Compare-Object $ciBefore (Get-CiSnapshot)).Count -eq 0)

$d2 = Deploy-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'enforce.xml') -Mode enforce -ConfirmText 'I-UNDERSTAND-AUDIT' -Apply
$e2 = (@($d2.errors) -join ' ')
Check '④ enforce 用 audit 文本被拒（errors 指明 I-UNDERSTAND-ENFORCE）' ((-not $d2.ok) -and ($e2 -match 'I-UNDERSTAND-ENFORCE')) (Short $e2)
Check '④ enforce 文本错误：未创建备份目录' (@(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count -eq $bkBefore)

$d3 = Deploy-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'audit.xml') -Mode audit -ConfirmText 'I-UNDERSTAND-AUDIT'
Check '④ 正确文本 + 预览：ok=true / applied=false / 需重启' ($d3.ok -and (-not $d3.applied) -and [bool]$d3.data.needRestart) (Joined $d3.errors)
Check '④ 预览：未创建备份目录、未复制策略到系统' ((@(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count -eq $bkBefore) -and (-not (Test-Path -LiteralPath $ciPolicyPath)))
Check '④ 预览 data 给出 requiredConfirmText / targetPolicyPath' (([string]$d3.data.requiredConfirmText) -eq 'I-UNDERSTAND-AUDIT' -and ([string]$d3.data.targetPolicyPath) -eq $ciPolicyPath) ('target=' + $d3.data.targetPolicyPath)

$d4 = Deploy-LctWdacPolicy -XmlPath $xmlAuditNoAllow -Mode enforce -ConfirmText 'I-UNDERSTAND-ENFORCE' -Apply
$e4d = (@($d4.errors) -join ' ')
Check '④ 无 allow 机制的策略即使文本正确也被安全门拒绝' ((-not $d4.ok) -and ($e4d -match 'allow 机制')) (Short $e4d)
$d5 = Deploy-LctWdacPolicy -XmlPath (Join-Path $tmpDir 'audit.xml') -Mode enforce -ConfirmText 'I-UNDERSTAND-ENFORCE' -Apply
$e5 = (@($d5.errors) -join ' ')
Check '④ 审计模式 XML 不能按 enforce 部署' ((-not $d5.ok) -and ($e5 -match 'Audit Mode')) (Short $e5)
Check '④ 以上拒绝路径均未创建备份目录' (@(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue).Count -eq $bkBefore)
Check '④ 以上拒绝路径后系统 CI 快照仍未变' (@(Compare-Object $ciBefore (Get-CiSnapshot)).Count -eq 0)
Skip '④ 成功部署路径（真实写 System32\CodeIntegrity）' 'task-5 明令禁止在测试中把任何策略部署到系统 CI 存储'

# =====================================================================
Section '⑤ 回滚（不存在的 stamp 必须 ok=false）'

$rv1 = Restore-LctWdacPolicy -Stamp 'wdac-19700101-000000-abcdef' -Apply
$er1 = (@($rv1.errors) -join ' ')
Check '⑤ 不存在的 stamp：ok=false' (-not $rv1.ok) ('ok=' + $rv1.ok)
Check '⑤ 不存在的 stamp：errors 提到备份不存在' ($er1 -match '备份不存在') (Short $er1)
$rv2 = Restore-LctWdacPolicy -Stamp 'nope-not-a-stamp'
Check '⑤ 不存在的 stamp（预览）同样 ok=false / applied=false' ((-not $rv2.ok) -and (-not $rv2.applied) -and (-not [bool]$rv2.data.applied)) ('ok=' + $rv2.ok + ' applied=' + $rv2.applied)
Check '⑤ 不存在的 stamp：系统 CI 快照未变' (@(Compare-Object $ciBefore (Get-CiSnapshot)).Count -eq 0)

if ($ciHadSiPolicy) {
    Skip '⑤ 合成备份回滚成功路径' '本机本来就存在 SiPolicy.p7b，为避免改动真实系统策略而跳过'
} else {
    $fakeStamp = 'wdac-20260101-000000-abc123'
    $fakeRoot = Join-Path $backupRoot $fakeStamp
    $fakeBk = Join-Path $fakeRoot 'backup'
    if (-not (Test-Path -LiteralPath $fakeBk)) { $null = New-Item -ItemType Directory -Path $fakeBk -Force }
    [IO.File]::WriteAllText((Join-Path $fakeBk 'SiPolicy.p7b.absent'), $ciPolicyPath, (New-Object System.Text.ASCIIEncoding))
    [IO.File]::WriteAllText((Join-Path $fakeRoot 'meta.json'), ('{"id":"' + $fakeStamp + '","verb":"wdac.deploy","wdac":{"mode":"audit"}}'), (New-Object System.Text.UTF8Encoding($true)))
    $rv3 = Restore-LctWdacPolicy -Stamp $fakeStamp -Apply
    Check '⑤ 合成备份（原状态=不存在）回滚成功且不改动系统' ($rv3.ok -and (-not $rv3.applied) -and (-not (Test-Path -LiteralPath $ciPolicyPath))) (Joined $rv3.errors)
    $note3 = (@($rv3.changes | ForEach-Object { [string]$_.note }) -join ' ')
    Check '⑤ 合成备份回滚：note 说明系统本来就没有策略文件' ($note3 -match '本来就没有') (Short $note3)
    $rv4 = Restore-LctWdacPolicy -Stamp $fakeStamp
    Check '⑤ 合成备份回滚预览：applied=false 且给出 plan' ($rv4.ok -and (-not $rv4.applied) -and @($rv4.data.plan).Count -ge 1) (Joined $rv4.data.plan)
}

# =====================================================================
Section '⑥ 系统 CI 存储全程未被改动'

$ciAfter = Get-CiSnapshot
$ciDiff = @(Compare-Object $ciBefore $ciAfter)
Check '⑥ 文件清单 + SHA256 前后完全一致' ($ciDiff.Count -eq 0) ('diff=' + $ciDiff.Count + ' ' + (Joined ($ciDiff | ForEach-Object { [string]$_.InputObject })))
Check '⑥ 系统 SiPolicy.p7b 的存在性前后一致' ((Test-Path -LiteralPath $ciPolicyPath) -eq $ciHadSiPolicy) ('now=' + (Test-Path -LiteralPath $ciPolicyPath))
Check '⑥ 模块源码（非注释行）不含任何永久删除命令' (-not ($moduleCodeText -match 'Remove-Item'))
Check '⑥ 模块源码（非注释行）不含 Write-Host 调用' (-not ($moduleCodeText -match 'Write-Host'))

# =====================================================================
Section '⑦ 只读 getter（status / verify）形状与内容'

$st = Get-LctWdacStatus
Check '⑦ status 含关键字段' (($null -ne $st.secureBoot) -and ($null -ne $st.ciEnforcementText) -and (([string]$st.systemPolicyPath) -eq $ciPolicyPath) -and ($null -ne $st.rulesCount) -and ($null -ne $st.stagingDir)) ('ci=' + $st.ciEnforcementText + ' sb=' + $st.secureBoot + ' rules=' + $st.rulesCount)
Check '⑦ status 的 rulesCount 与 rules getter 一致' ([int]$st.rulesCount -eq @(Get-LctWdacRules).Count) ('status=' + $st.rulesCount + ' getter=' + @(Get-LctWdacRules).Count)
Check '⑦ status 有 activePolicies / driverPolicy / vbsPolicy 字段' (($null -ne $st.activePolicies) -and ($null -ne $st.driverPolicy) -and ($null -ne $st.vbsPolicy)) ('active=' + @($st.activePolicies).Count)

$vf = Get-LctWdacVerify
$verdictPool = @('可安全转强制', '尚不明确', '危险')
Check '⑦ verify 的 verdictText 属于三档精确文案' ($verdictPool -contains [string]$vf.verdictText) ([string]$vf.verdictText + ' / ' + (Short ([string]$vf.verdictReason) 110))
Check '⑦ verify 读取 CodeIntegrity Operational 事件日志' (([string]$vf.events.logName) -eq 'Microsoft-Windows-CodeIntegrity/Operational') ('available=' + $vf.events.available + ' scanned=' + $vf.events.scanned + ' err=' + (Short ([string]$vf.events.error) 70))
Check '⑦ verify 在无系统策略时给「尚不明确」' (($ciHadSiPolicy) -or ([string]$vf.verdictText -eq '尚不明确')) ('systemPolicyExists=' + $vf.systemPolicy.exists + ' verdict=' + $vf.verdictText)
Check '⑦ verify 明示「用户态黑名单语义无法在重启前证明」' ((@($vf.limitations) -join ' ') -match '重启前') (Short ((@($vf.limitations) -join ' / ')) 200)
Check '⑦ verify 给出 verdict / verdictText / needsRestart 三个键' (($vf.PSObject.Properties.Name -contains 'verdict') -and ($vf.PSObject.Properties.Name -contains 'verdictText') -and ($null -ne $vf.needsRestart))

# =====================================================================
Write-Host ''
Write-Host ('WdacTest 结果: PASS=' + $script:Pass + ' FAIL=' + $script:Fail)
Write-Host ('测试产物（保留以便复查）：' + $varDir)
if ($script:Fail -gt 0) {
    Write-Host '--- 失败项 ---'
    foreach ($l in @($script:Lines)) { if ($l -like '`[FAIL`]*') { Write-Host $l } }
}
exit $script:Fail