# LocalConfigTool - tests\JavaUiTest.ps1
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\JavaUiTest.ps1
#
# 守 Java(Swing) 界面的四件事（需求 ①②③④）里可自动验证的部分：
#   JU-1 javac 编译通过（无第三方依赖，JDK only）
#   JU-2 无界面自检跑通（SELFTEST OK）
#   JU-3 常驻 worker 生效：engine.verbs 连续 20 次平均 < 50ms（冷启动约 2.2 秒/次）
#   JU-4 引擎 verb 数 >= 50（通用控制台能覆盖全部能力）
#   JU-5 代表性 verb 全部 ok=true
#   JU-6 自检结束后不残留 worker 进程（相对运行前计数不增加）
#   JU-7 源码没有把 Consolas/Cascadia 当文本区字体（它们无 CJK 字形，中文会变 ?）
#   JU-8 逻辑字体 Monospaced 能显示中文与 ✔✖→（文本区实际用的就是它）
#
# 退出码 = 失败数。本测试不加载驱动、不发 IOCTL、不修改系统。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'ui-java\src\lctui'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ('  [PASS] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
    else { $script:fail++; Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) }
}
function WorkerCount {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'worker\.ps1' }).Count
    } catch { return -1 }
}

$before = WorkerCount

Write-Host '== JU-1: javac 编译 =='
$build = (& cmd.exe /c "`"$root\ui-java\build.cmd`"" 2>&1 | Out-String)
$buildOk = ($LASTEXITCODE -eq 0) -and ($build -match '\[build\] OK')
Check 'JU-1 javac 0 错误（JDK only，无第三方依赖）' $buildOk ('lines=' + (@($build -split "`r?`n").Count))

Write-Host ''
Write-Host '== JU-2..5: 无界面自检（常驻 worker 实测） =='
$out = (& cmd.exe /c "`"$root\ui-java\selftest.cmd`"" 2>&1 | Out-String)
$lines = @($out -split "`r?`n")
Check 'JU-2 自检跑通（SELFTEST OK）' ($out -match 'SELFTEST OK') ''

$avg = -1.0
$m = [regex]::Match($out, 'METRIC avg_ms=([0-9.]+)')
if ($m.Success) { $avg = [double]$m.Groups[1].Value }
Check 'JU-3 常驻 worker：engine.verbs 20 次平均 < 50ms' (($avg -ge 0) -and ($avg -lt 50)) ('avg=' + $avg + ' ms（冷启动约 2200 ms/次）')

$vc = -1
$mv = [regex]::Match($out, 'METRIC verb_count=(\d+)')
if ($mv.Success) { $vc = [int]$mv.Groups[1].Value }
Check 'JU-4 引擎 verb 数 >= 50' ($vc -ge 50) ('verb_count=' + $vc)

$failed = @($lines | Where-Object { $_ -match '\[2\].*ok=false' })
Check 'JU-5 代表性 verb 全部 ok=true' (@($failed).Count -eq 0) ('failed=' + @($failed).Count)

$startup = -1
$ms = [regex]::Match($out, 'METRIC worker_start_ms=(\d+)')
if ($ms.Success) { $startup = [int]$ms.Groups[1].Value }
Check 'JU-5b worker 启动成本已记录（一次性）' ($startup -gt 0 -and $startup -lt 60000) ('worker_start_ms=' + $startup)

Write-Host ''
Write-Host '== JU-6: 不残留 worker 进程 =='
Start-Sleep -Milliseconds 800
$after = WorkerCount
Check 'JU-6 自检结束后 worker 数不增加' (($before -lt 0) -or ($after -le $before)) ('before=' + $before + ' after=' + $after)

Write-Host ''
Write-Host '== JU-7..8: 中文显示（等宽字体不能吃掉 CJK） =='
# Consolas / Cascadia 没有 CJK 字形：实测 canDisplayUpTo("共") = 0，文本区里的中文会变成 ?
$badFonts = @(Select-String -Path (Join-Path $srcDir '*.java') -Pattern 'new Font\("Consolas|new Font\("Cascadia' -ErrorAction SilentlyContinue)
Check 'JU-7 源码未把 Consolas/Cascadia 当文本区字体' (@($badFonts).Count -eq 0) ('hits=' + @($badFonts).Count)

$fk = [regex]::Match($out, 'METRIC font_cjk_ok=(\d)')
Check 'JU-8 逻辑字体 Monospaced 能显示中文与 ✔✖→' ($fk.Success -and $fk.Groups[1].Value -eq '1') ('font_cjk_ok=' + $(if ($fk.Success) { $fk.Groups[1].Value } else { 'missing' }))

Write-Host ''
Write-Host ('JavaUiTest summary: PASS=' + $pass + ' FAIL=' + $fail)
exit $fail
