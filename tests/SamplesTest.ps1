# LocalConfigTool - tests\SamplesTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\SamplesTest.ps1
#
# 守「样本库（预置规则）」的边界：
#   ST-1 目录可读：条目含 id/name/risk/usable，且至少有一条可用（填了 64 位哈希）
#   ST-2 id 严格校验：路径穿越/盘符/分隔符一律拒；正常 id 通过
#   ST-3 哈希格式校验：只接受 64 位十六进制
#   ST-4 预览不落盘（applied=false，且没有新增 .sys）
#   ST-5 占位条目（无哈希）必须拒绝，并说明"没有哈希就没法校验"
#   ST-6 哈希不符必须丢弃、且不留残骸
#   ST-7 哈希正确才落盘，并写来源记录（var\samples\<id>.json）
#   ST-8 未知 id 拒绝
#   ST-9 只写 var\samples（不往别处落盘）
#
# 退出码 = 失败数。本测试**不下载任何网络文件**（全部用本地临时文件），不加载驱动、不发 IOCTL。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-smp-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$store = Join-Path $root 'var\samples'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function SysFiles { return @(Get-ChildItem $store -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.sys' } | ForEach-Object { $_.Name }) }
function CleanSample([string]$Id) {
    foreach ($ext in @('.sys', '.json')) {
        $p = Join-Path $store ($Id + $ext)
        if (Test-Path -LiteralPath $p) {
            try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
        }
    }
}

Write-Host '== ST-1: 目录可读 =='
$cat = Eng 'samples.list' $null
$items = @()
if ($null -ne $cat -and $null -ne $cat.data) { $items = @($cat.data.items) }
Check 'ST-1a samples.list ok=true' ($null -ne $cat -and $cat.ok -eq $true) ('count=' + @($items).Count)
Check 'ST-1b 每条含 id/name/risk/usable' (@($items | Where-Object { [string]$_.id -eq '' -or $null -eq $_.PSObject.Properties['usable'] }).Count -eq 0) ('entries=' + @($items).Count)
$usableCount = @($items | Where-Object { $_.usable -eq $true }).Count
Check 'ST-1c 至少一条可用（填了 64 位哈希）' ($usableCount -ge 1) ('usable=' + $usableCount)
$placeholder = @($items | Where-Object { $_.usable -eq $false }) | Select-Object -First 1
Check 'ST-1d 不可用条目给出原因' ($null -eq $placeholder -or [string]$placeholder.blockedBy -ne '') ''

Write-Host ''
Write-Host '== ST-2/3: id 与哈希格式校验 =='
Import-Module (Join-Path $root 'core\Logging.psm1') -Force -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $root 'core\Samples.psm1') -Force -Global -ErrorAction SilentlyContinue
$badIds = @('../evil', 'a/b', 'C:\x', '..', 'A' + 'x' * 80, '')
$badOk = $true
foreach ($b in $badIds) { if (Test-LctSampleId -Id $b) { $badOk = $false } }
Check 'ST-2a 非法 id 全部被拒（穿越/盘符/分隔符/超长/空）' $badOk ''
Check 'ST-2b 正常 id 通过' ((Test-LctSampleId -Id 'rtcore64-01aa278b') -and (Test-LctSampleId -Id 'adhoc-0123456789ab')) ''
Check 'ST-3a 64 位十六进制通过' (Test-LctSampleSha256 -Sha256 ('a' * 64)) ''
Check 'ST-3b 短哈希/空/非十六进制被拒' ((-not (Test-LctSampleSha256 -Sha256 'abc')) -and (-not (Test-LctSampleSha256 -Sha256 '')) -and (-not (Test-LctSampleSha256 -Sha256 ('z' * 64)))) ''

Write-Host ''
Write-Host '== ST-4: 预览不落盘 =='
$before = @(SysFiles).Count
$preview = Eng 'samples.get' @{ id = 'rtcore64-01aa278b' }
Check 'ST-4a 预览 ok=true 且 applied=false' ($null -ne $preview -and $preview.ok -eq $true -and $preview.data.applied -eq $false) ''
Check 'ST-4b 预览给了计划与目标路径' ($null -ne $preview -and @($preview.data.plan).Count -ge 2 -and [string]$preview.data.targetPath -ne '') ''
$after = @(SysFiles).Count
Check 'ST-4c 预览没有新增 .sys' ($after -eq $before) ('before=' + $before + ' after=' + $after)

Write-Host ''
Write-Host '== ST-5: 占位条目（无哈希）必须拒 =='
if ($null -ne $placeholder) {
    $ph = Eng 'samples.get' @{ id = [string]$placeholder.id } -Apply
    Check 'ST-5a 占位条目被拒且 needHash=true' ($null -ne $ph -and $ph.ok -eq $false -and $ph.data.needHash -eq $true) ''
    Check 'ST-5b 拒绝理由说明没有哈希无法校验' ((@($ph.errors) -join ' ') -match '没有哈希|无法校验|sha256') ''
} else {
    Check 'ST-5 占位条目（SKIP：目录里没有占位条目）' $true 'skip'
}

Write-Host ''
Write-Host '== ST-6: 哈希不符必须丢弃且无残留 =='
$fake = Join-Path $work 'fake.bin'
[IO.File]::WriteAllText($fake, 'this-is-not-a-driver' + [guid]::NewGuid().ToString('N'), (New-Object System.Text.UTF8Encoding($false)))
$realHash = (Get-FileHash -LiteralPath $fake -Algorithm SHA256).Hash
$wrongHash = ('0' * 64)
$before = @(SysFiles).Count
$bad = Eng 'samples.get' @{ url = $fake; sha256 = $wrongHash; name = 'hash-mismatch-test' } -Apply
Check 'ST-6a 哈希不符被拒' ($null -ne $bad -and $bad.ok -eq $false) ''
Check 'ST-6b 错误信息说明已丢弃' ((@($bad.errors) -join ' ') -match '丢弃') ''
$after = @(SysFiles).Count
Check 'ST-6c 没有留下任何 .sys 残骸' ($after -eq $before) ('before=' + $before + ' after=' + $after)
Check 'ST-6d 临时目录里没有 .part 残骸' (@(Get-ChildItem (Join-Path $store '.tmp') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.part' }).Count -eq 0) ''

Write-Host ''
Write-Host '== ST-7: 哈希正确才落盘 + 写来源记录 =='
$good = Eng 'samples.get' @{ url = $fake; sha256 = $realHash; name = 'hash-ok-test' } -Apply
$gid = ''
if ($null -ne $good -and $null -ne $good.data) { $gid = [string]$good.data.id }
Check 'ST-7a 哈希正确 → 获取成功' ($null -ne $good -and $good.ok -eq $true -and $good.data.applied -eq $true -and $good.data.hashVerified -eq $true) ('id=' + $gid)
$savedPath = Join-Path $store ($gid + '.sys')
$provPath = Join-Path $store ($gid + '.json')
Check 'ST-7b 目标文件已存在且哈希一致' ((Test-Path -LiteralPath $savedPath) -and ((Get-FileHash -LiteralPath $savedPath -Algorithm SHA256).Hash -ieq $realHash)) ''
Check 'ST-7c 来源记录已写' ((Test-Path -LiteralPath $provPath) -and ((Get-Content -LiteralPath $provPath -Raw -Encoding UTF8) -match [regex]::Escape($realHash))) ''
if ($gid -ne '') { CleanSample $gid }

Write-Host ''
Write-Host '== ST-8: 未知 id 拒绝 =='
$unknown = Eng 'samples.get' @{ id = 'no-such-sample-xyz' } -Apply
Check 'ST-8a 未知 id 被拒' ($null -ne $unknown -and $unknown.ok -eq $false) ''
Check 'ST-8b 提示先看目录' ((@($unknown.errors) -join ' ') -match 'samples\.list|没有这个 id') ''

Write-Host ''
Write-Host '== ST-9: 只写 var\samples =='
Check 'ST-9a 存储目录在 var\samples 下' ($store -like '*\var\samples') $store
Check 'ST-9b 没有在 samples\ 仓库目录写入 .sys' (@(Get-ChildItem (Join-Path $root 'samples') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.sys' }).Count -eq 0) ''

if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
Write-Host ''
Write-Host ('SamplesTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
