# LocalConfigTool - tests\CtlSimplifyTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\CtlSimplifyTest.ps1
#
# 守「IOCTL 操作简化」三件事（A/B/C）：
#   C 目录条目自带 profile ⇒ samples.get 下载后自动落盘，拿到样本就能发 action
#   A profile 的 action 可声明 presets（默认值）与 require（必须由人给的字段）
#   B payload 三种写法：JSON / 简写 key=value / 省略；值支持 @ntoskrnl 自动取内核基址
#
#   CT-1 本地目录条目可被 samples.list 看到
#   CT-2 samples.get -Apply（本地文件）⇒ 哈希通过 + profile 自动落盘
#   CT-3 省略 payload ⇒ 被 require 拦住（绝不向 0 地址发 IOCTL）
#   CT-4 简写 addr=@ntoskrnl ⇒ ok、只预览（ioctlSent=false）、presets 补上 readSize
#   CT-5 JSON 写法仍然可用
#   CT-6 坏简写（没有 =）⇒ refused=payload
#   CT-7 driver.kernelbase ⇒ 取到 ntoskrnl 基址
#   CT-8 再次 samples.get ⇒ profile 已存在则跳过（不覆盖人工审定版本）
#   CT-9 清理后无残留
#
# 全部用本地文件，**不访问网络**；不加载驱动、**不发送任何 IOCTL**（全是预览）。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'core\Engine.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:TEMP ('lct-ctl-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$af = Join-Path $work 'arg.json'
$sid = 'lctlocal-test-driver'
$sampleFile = "lcttestdrv.sys"
$storeSamples = Join-Path $root 'var\samples'
$storeProfiles = Join-Path $root 'var\driver-profiles'
$localCatalog = Join-Path $storeSamples 'catalog.local.json'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function Eng([string]$Verb, $Payload, [switch]$Apply) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engine, '-Verb', $Verb)
    if ($null -ne $Payload) {
        [IO.File]::WriteAllText($af, ($Payload | ConvertTo-Json -Depth 12 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $a += @('-ArgsFile', $af)
    }
    if ($Apply) { $a += '-Apply' }
    $raw = & $psExe @a 2>$null
    if (-not $raw) { return $null }
    try { return (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}
function Recycle([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    # 必须先加载程序集：否则 [Microsoft.VisualBasic.FileIO.FileSystem] 不可用、异常被 catch 吞掉 ⇒ 文件删不掉
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { }
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}

# ---- 准备：本地假驱动 + 本地目录条目（含 profile，带 presets/require）----
$fake = Join-Path $work $sampleFile
[IO.File]::WriteAllText($fake, ('not-a-driver ' + [guid]::NewGuid().ToString('N')), (New-Object System.Text.UTF8Encoding($false)))
$hash = (Get-FileHash -LiteralPath $fake -Algorithm SHA256).Hash
$catalogObj = [ordered]@{
    schema = 2
    entries = @([ordered]@{
            id = $sid; name = '本地测试条目（无网络）'; risk = 'low'; tags = @('test')
            url = $fake; sha256 = $hash; notes = 'CtlSimplifyTest 临时条目'
            profile = [ordered]@{
                id = $sid; kind = 'driver-profile'; engineApi = 2
                target = [ordered]@{ sha256 = $hash; fileName = $sampleFile }
                locate = [ordered]@{ strategy = 'symlink'; candidates = @('\??\LctNoSuchDevice'); serviceNameHint = ''; notes = '测试用：设备不存在，只做预览' }
                actions = [ordered]@{
                    probe = [ordered]@{
                        ioctl = '0x00222000'
                        require = @('addr')
                        presets = [ordered]@{ readSize = 4; offset = 0 }
                        in = @(
                            [ordered]@{ name = 'addr'; type = 'u64' },
                            [ordered]@{ name = 'offset'; type = 'u32' },
                            [ordered]@{ name = 'readSize'; type = 'u32' }
                        )
                        out = @(
                            [ordered]@{ name = 'code'; type = 'u32' },
                            [ordered]@{ name = 'done'; type = 'u32' }
                        )
                    }
                }
                layout = [ordered]@{ method = 'buffered'; align = 8; endian = 'little' }
                risk = [ordered]@{ level = 'low'; notes = '测试用' }
                requires = [ordered]@{ restart = $false; admin = $true; elevation = 'admin' }
            }
        })
}
[IO.File]::WriteAllText($localCatalog, ($catalogObj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))

try {
    Write-Host '== CT-1: 本地条目可见 =='
    $list = Eng 'samples.list' $null
    $found = @()
    if ($null -ne $list -and $null -ne $list.data) { $found = @($list.data.items | Where-Object { [string]$_.id -eq $sid }) }
    Check 'CT-1 本地条目出现在目录里' (@($found).Count -eq 1) ('count=' + @($found).Count)

    Write-Host ''
    Write-Host '== CT-2: samples.get ⇒ 哈希通过 + profile 自动落盘（C） =='
    $get = Eng 'samples.get' @{ id = $sid } -Apply
    Check 'CT-2a 获取成功且哈希校验通过' ($null -ne $get -and $get.ok -eq $true -and $get.data.hashVerified -eq $true) ''
    $profPath = Join-Path $storeProfiles ($sid + '.json')
    $profSaved = $false
    if ($null -ne $get -and $null -ne $get.data -and $null -ne $get.data.profile) { $profSaved = [bool]$get.data.profile.saved }
    Check 'CT-2b profile 已自动落盘' ($profSaved -and (Test-Path -LiteralPath $profPath)) ('path=' + $profPath)
    if ($null -ne $get -and $null -ne $get.data -and $null -ne $get.data.profile) {
        @($get.data.profile.errors) | ForEach-Object { "     profErr: " + $_ }
    }

    Write-Host ''
    Write-Host '== CT-3: 省略 payload ⇒ require 拦住（不向 0 地址发 IOCTL） =='
    $noPay = Eng 'driver.ctl.send' @{ profile = $sid; action = 'probe' }
    $gate = ''
    if ($null -ne $noPay -and $null -ne $noPay.data -and $null -ne $noPay.data.gate) { $gate = [string]$noPay.data.gate.refused }
    Check 'CT-3a 被拦住（require 或 no-payload）' ($null -ne $noPay -and $noPay.ok -eq $false -and ($gate -eq 'require' -or $gate -eq 'no-payload')) ('gate=' + $gate)
    Check 'CT-3b 明确提到 addr' ((@($noPay.errors) -join ' ') -match 'addr') ''

    Write-Host ''
    Write-Host '== CT-4: 简写 addr=@ntoskrnl + presets（只预览） =='
    $sh = Eng 'driver.ctl.send' @{ profile = $sid; action = 'probe'; payload = 'addr=@ntoskrnl' }
    Check 'CT-4a ok=true 且只预览（未发 IOCTL）' ($null -ne $sh -and $sh.ok -eq $true -and (-not [bool]$sh.data.applied) -and (-not [bool]$sh.data.ioctlSent)) ''
    $warns = ''
    if ($null -ne $sh) { $warns = (@($sh.warnings) -join ' ') }
    Check 'CT-4b 提示用了简写' ($warns -match '简写') ''
    Check 'CT-4c @ntoskrnl 已解析成基址' ($warns -match '内核基址|ntoskrnl') ''
    Check 'CT-4d presets 生效（补了字段）' ($warns -match 'presets|预置') ''

    Write-Host ''
    Write-Host '== CT-5: JSON 写法仍可用 =='
    $js = Eng 'driver.ctl.send' @{ profile = $sid; action = 'probe'; payload = '{"addr":"0xFFFFF80142A00000","readSize":8}' }
    Check 'CT-5 JSON payload ok 且只预览' ($null -ne $js -and $js.ok -eq $true -and (-not [bool]$js.data.ioctlSent)) ''

    Write-Host ''
    Write-Host '== CT-6: 坏简写必须拒 =='
    $bad = Eng 'driver.ctl.send' @{ profile = $sid; action = 'probe'; payload = 'addr' }
    $badGate = ''
    if ($null -ne $bad -and $null -ne $bad.data -and $null -ne $bad.data.gate) { $badGate = [string]$bad.data.gate.refused }
    Check 'CT-6 坏简写 ⇒ refused=payload' ($null -ne $bad -and $bad.ok -eq $false -and $badGate -eq 'payload') ('gate=' + $badGate)

    Write-Host ''
    Write-Host '== CT-7: driver.kernelbase =='
    $kb = Eng 'driver.kernelbase' $null
    $kbOk = $false
    if ($null -ne $kb -and $null -ne $kb.data) { $kbOk = ($kb.ok -eq $true -and [int64]$kb.data.address -ne 0) }
    Check 'CT-7 取到内核基址' $kbOk ('name=' + $(if ($null -ne $kb -and $null -ne $kb.data) { $kb.data.name } else { '' }))

    Write-Host ''
    Write-Host '== CT-8: 再次获取 ⇒ profile 已存在则跳过 =='
    $get2 = Eng 'samples.get' @{ id = $sid } -Apply
    $skipped = $false
    if ($null -ne $get2 -and $null -ne $get2.data -and $null -ne $get2.data.profile) { $skipped = [bool]$get2.data.profile.skipped }
    Check 'CT-8 不覆盖已有 profile（skipped=true）' $skipped ''
} finally {
    Recycle $localCatalog
    Recycle (Join-Path $storeProfiles ($sid + '.json'))
    Recycle (Join-Path $storeSamples ($sid + '.sys'))
    Recycle (Join-Path $storeSamples ($sid + '.json'))
    if (Test-Path -LiteralPath $work) { try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($work, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { } }
}

Write-Host ''
Write-Host '== CT-9: 清理无残留 =='
Check 'CT-9a 本地目录条目已移除' (-not (Test-Path -LiteralPath $localCatalog)) ''
Check 'CT-9b profile 已移除' (-not (Test-Path -LiteralPath (Join-Path $storeProfiles ($sid + '.json')))) ''
Check 'CT-9c 样本已移除' (-not (Test-Path -LiteralPath (Join-Path $storeSamples ($sid + '.sys')))) ''

Write-Host ''
Write-Host ('CtlSimplifyTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail