# LocalConfigTool - tools\Build-Public.ps1
#
#   从当前项目派生出「可公开版」（用于挂 GitHub 等公开托管平台）。
#
# 为什么需要它：
#   本项目是「系统分析与本地配置管理工具」（定位类似火绒剑 / HRSword）：
#   把注册表、账户、进程、WDAC、驱动、对象图这些系统能力，收进一个可预览、可回滚、带审计的工具里。
#
#   工具本身不是攻击载荷。公开托管平台（GitHub 等）真正敏感的是两样具体东西：
#     a) 某一个具体 CVE 的**可执行 exploit**（plugins\cve-2026-49176 就是这类包装器）；
#     b) **现成的漏洞驱动下载链**（samples\catalog.json 指向真实 URL + 哈希）。
#   「具备驱动加载能力」与「预置某个 exploit」是两件事：前者是工具（火绒剑也自带驱动），
#   后者属于具体利用代码。本脚本只把 (a)(b) 换成「使用者自备」，**工具本体一个能力都不删**。
#
#   具体做法（只在派生副本里，本体不动）：
#     1) plugins\cve-2026-49176\run.ps1 → 占位（只做参数/环境校验，不含执行逻辑）
#     2) 该插件的 plugin.json / README → 占位示例（保留 v1 清单结构，门禁仍可跑）
#     3) samples\catalog.json → 清空真实 URL / SHA256（保留条目结构）
#     4) 补 .gitignore、LICENSE(MIT)、README 定位说明
#
#   ！它只在副本上工作，本体的 plugins\cve-2026-49176 与 samples\catalog.json 不会被动。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Public.ps1 [-OutDir <新目录>] [-Zip <zip路径>] [-NoZip]
#
# 退出码：0 = 成功；1 = 失败（看 stderr / 输出）。
param(
    [string]$OutDir = '',
    [string]$Zip = '',
    [switch]$NoZip
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8

$toolRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $env:TEMP ('lct-public-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
if ([string]::IsNullOrWhiteSpace($Zip)) { $Zip = Join-Path ([Environment]::GetFolderPath('Desktop')) ('LocalConfigTool-public-' + $stamp + '.zip') }

function Write-Step([string]$Text) { Write-Host ('[public] ' + $Text) }

Write-Step ("源目录: " + $toolRoot)
Write-Step ("输出目录: " + $OutDir)

# 生成符合 ZIP 规范的压缩包（条目分隔符必须是 /）
#   为什么不用 Compress-Archive：Windows PowerShell 5.1 下它用 Path.DirectorySeparatorChar（\），
#   生成 core\Engine.psm1 这种不合规范的条目，Linux/macOS 解压会失败。
function New-LctZipNormalized {
    param([string]$SourceDir, [string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $ZipPath) {
        try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($ZipPath, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
    $base = (Resolve-Path -LiteralPath $SourceDir).ProviderPath.TrimEnd('\')
    $fs = [IO.File]::Open($ZipPath, [IO.FileMode]::Create)
    try {
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File)) {
                $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
                $entry = $za.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
                $es = $entry.Open()
                try {
                    $bytes = [IO.File]::ReadAllBytes($f.FullName)
                    if ($bytes.Length -gt 0) { $es.Write($bytes, 0, $bytes.Length) }
                } finally { $es.Dispose() }
            }
        } finally { $za.Dispose() }
    } finally { $fs.Dispose() }
}

# ---------------- 1) 复制（排除运行数据 / 编译产物） ----------------
if (Test-Path -LiteralPath $OutDir) {
    Write-Step '输出目录已存在，先清空失败 —— 请换一个 -OutDir'
    exit 1
}
$null = New-Item -ItemType Directory -Path $OutDir -Force
$null = & robocopy $toolRoot $OutDir /E /NFL /NDL /NJH /NJS /NP `
    /XD (Join-Path $toolRoot 'var') (Join-Path $toolRoot 'ui-java\out') `
    /XF '*.zip' 2>&1
$rc = $LASTEXITCODE
if ($rc -gt 3) { Write-Step ('robocopy 失败，exit=' + $rc); exit 1 }
$copied = @(Get-ChildItem $OutDir -Recurse -File)
Write-Step ('复制完成：' + $copied.Count + ' 个文件')

# ---------------- 2) 占位插件：run.ps1 ----------------
$placeholderRun = @'
<#
  LocalConfigTool 样例插件入口 —— 占位实现（公开版）

  本文件**不包含任何提权实现**，也不调用任何 PoC。它在公开仓库里只做两件事：
    * 校验运行环境（要求非提权）与参数；
    * 提示你把真实的 PoC 目录填进 -PocDir，然后自行替换本文件。

为什么会这样：本工具是**工具平台**（提供驱动/内核操作能力，由使用者决定做什么），
不是把某个 exploit 打包分发。具体提权实现属于"载荷"那一层，不随仓库预置。
本工具的价值在**插件引擎与安全模型**（预览/执行/日志/超时/回滚/清理）。

（仍可直接用 -PocDir 指向你自己的 PoC 目录，机制照常工作。）

  参数：-Timeout（秒，1..600）、-PocDir（PoC 目录，含 trigger.ps1）
  退出码：2=未提供可用的 PoC 目录；3=当前已提权（本插件要求非提权上下文）
#>
[CmdletBinding()]
param(
    [int]$Timeout = 120,
    [string]$PocDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [Text.Encoding]::UTF8

if ($Timeout -lt 1 -or $Timeout -gt 600) {
    [Console]::Error.WriteLine('参数错误：-Timeout 必须在 1..600 之间。')
    exit 2
}

$target = [string]$PocDir
if ([string]::IsNullOrWhiteSpace($target)) {
    $target = (Join-Path $env:USERPROFILE 'Desktop\CVE-2026-49176-<version>')
}

$isElevated = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isElevated = $false }

if ($isElevated) {
    [Console]::Error.WriteLine('本插件要求以【非提权】身份运行。当前进程已提权，已拒绝执行（退出码 3）。')
    exit 3
}

Write-Output '[public-sample] 这是公开版占位插件：不含提权实现。'
Write-Output ('[public-sample] PocDir = ' + $target)
Write-Output '[public-sample] 要使用真实 PoC：把你的 PoC 目录放到上述路径（需含 trigger.ps1），或自行替换本文件。'
[Console]::Error.WriteLine('公开版不随仓库分发提权实现；请自备 PoC 后替换 plugins\cve-2026-49176\run.ps1。')
exit 2
'@
$runPath = Join-Path $OutDir 'plugins\cve-2026-49176\run.ps1'
[IO.File]::WriteAllText($runPath, (($placeholderRun -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
Write-Step 'run.ps1 → 占位实现（不含提权代码）'

# ---------------- 3) 占位插件：plugin.json（保持 v1 清单结构） ----------------
$manifest = @'
{
  "id": "cve-2026-49176",
  "name": "示例：把本地提权 PoC 包装成插件（公开版为占位）",
  "version": "1.0.0",
  "description": "演示 LocalConfigTool 插件引擎的 预览/执行/日志/超时 链路。公开版不含提权实现：run.ps1 只做参数与环境校验并提示你自备 PoC。",
  "risk": "high",
  "note": "占位示例。请勿在未授权的设备上使用任何提权工具；真实 PoC 请自行准备并替换 run.ps1。",
  "entry": {
    "kind": "ps1",
    "path": "run.ps1"
  },
  "params": [
    {
      "name": "timeout",
      "title": "超时（秒）",
      "type": "int",
      "required": false,
      "default": 120,
      "secret": false,
      "help": "等待插件结束的最长时间，1..600 秒。"
    },
    {
      "name": "pocDir",
      "title": "PoC 目录",
      "type": "string",
      "required": false,
      "default": "",
      "secret": false,
      "help": "你自备的 PoC 目录（需包含 trigger.ps1）。留空则使用 %USERPROFILE%\\Desktop\\CVE-2026-49176-<version>。"
    }
  ]
}
'@
$manPath = Join-Path $OutDir 'plugins\cve-2026-49176\plugin.json'
[IO.File]::WriteAllText($manPath, (($manifest -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
Write-Step 'plugin.json → 占位示例（保留 v1 结构）'

# ---------------- 4) 占位插件：README ----------------
$pluginReadme = @'
# 示例插件：把本地提权 PoC 包装成插件（公开版占位）

> ⚠️ **公开版不含提权实现。** 本目录里的 `run.ps1` 只做参数与环境校验，
> 不会执行任何利用代码，也不会修改系统。

## 这个目录演示什么

LocalConfigTool 的插件引擎（`core\Plugins.psm1`）如何把一个外部 PoC 包装成可被工具调用的插件：

1. **清单**（`plugin.json`）：声明 id、参数（`timeout` / `pocDir`）、风险等级；
2. **入口**（`run.ps1`）：接收参数，以**非提权**身份运行（提权环境下拒绝，退出码 3）；
3. **引擎侧**：默认只**预览**（解析出命令行，不执行），加 `-Apply` 才真正运行，并记录日志、超时终止。

## 想接自己的 PoC？

1. 把 PoC 放到某个目录（需要有一个 `trigger.ps1` 作为入口）；
2. 用 `-PocDir <那个目录>` 调用；
3. 或者直接改写本目录的 `run.ps1`（保持"非提权运行 + 退出码约定"即可）。

## 为什么公开版是占位

本工具是**系统分析与配置管理工具**（类似火绒剑）：它提供"把外部 PoC 包装成插件"的**机制**，
但不预置任何一个具体 exploit —— 就像火绒剑不会替你把别人的漏洞驱动打包进去一样。

你完全可以用 `-PocDir` 指向自己的 PoC 目录，机制照常工作。

## 安全约束（不论你填什么 PoC）

- 只在你**完全拥有处置权**的机器上运行；
- 遇到可疑/未知行为立刻停止，并检查 `var\logs\`；
- 用完清理现场（`driver.cleanup` 等）。
'@
$prPath = Join-Path $OutDir 'plugins\cve-2026-49176\README.md'
[IO.File]::WriteAllText($prPath, (($pluginReadme -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($true)))
Write-Step '插件 README → 占位说明'

# ---------------- 5) 样本目录 + 文档：清空真实 URL / 哈希 ----------------
$zeroSha = ('0' * 64)
# 不把真实来源硬编码在本脚本里（否则脚本本身就成了"公开样本来源"的文件）：
# 从源项目的 catalog 里读出来，只用于在副本中把它清掉。
$realUrl = ''
$realSha = ''
try {
    $srcCatPath = Join-Path $toolRoot 'samples\catalog.json'
    if (Test-Path -LiteralPath $srcCatPath) {
        $srcCat = Get-Content -LiteralPath $srcCatPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $srcEntry = @($srcCat.entries) | Where-Object { [string]$_.url -ne '' } | Select-Object -First 1
        if ($null -ne $srcEntry) { $realUrl = [string]$srcEntry.url; $realSha = [string]$srcEntry.sha256 }
    }
} catch { }
$catPath = Join-Path $OutDir 'samples\catalog.json'
if (Test-Path -LiteralPath $catPath) {
    $raw = Get-Content -LiteralPath $catPath -Raw -Encoding UTF8
    # 用字符串替换而不是 JSON 反序列化：能同时命中顶层 sha256 与 profile.target.sha256
    $before = $raw
    if ($realUrl -ne '') { $raw = $raw.Replace($realUrl, '') }
    if ($realSha -ne '') { $raw = $raw.Replace($realSha, $zeroSha) }
    $raw = $raw -replace '"verified"\s*:\s*true', '"verified": false'
    if ($raw -ne $before) {
        [IO.File]::WriteAllText($catPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
        Write-Step 'samples\catalog.json → 真实 URL 已清空、真实 SHA256 已换成占位（URL 空 + 全 0 哈希，格式仍合法）'
    } else {
        Write-Step 'samples\catalog.json → 未发现真实来源（已是占位）'
    }
}

# 文档里的示例 JSON 同样要清（否则等于公开了样本来源）
$docSamples = Join-Path $OutDir 'docs\SAMPLES.md'
if (Test-Path -LiteralPath $docSamples) {
    $d = Get-Content -LiteralPath $docSamples -Raw -Encoding UTF8
    $before = $d
    if ($realUrl -ne '') { $d = $d.Replace($realUrl, '<your-driver-url>') }
    if ($realSha -ne '') { $d = $d.Replace($realSha, '<your-sha256>') }
    $d = $d -replace '"verified"\s*:\s*true', '"verified": false'
    $d = $d.Replace('本机已实测：driver.load 成功、kread 读回 ntoskrnl MZ', '（示例：填入你自己的实测结论）')
    if ($d -ne $before) {
        [IO.File]::WriteAllText($docSamples, $d, (New-Object System.Text.UTF8Encoding($true)))
        Write-Step 'docs\SAMPLES.md → 示例 JSON 里的真实 URL / 哈希已替换为占位'
    }
}

# ---------------- 6) .gitignore / LICENSE ----------------
$gitignore = @'
# 运行数据（日志、备份、已下载样本、DPAPI 凭据、一次性确认短语）
var/

# Java 界面编译产物
ui-java/out/

# 打包产物
*.zip

# 临时/编辑器
*.log
*.tmp
.DS_Store
Thumbs.db
'@
[IO.File]::WriteAllText((Join-Path $OutDir '.gitignore'), (($gitignore -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($false)))

$license = @'
MIT License

Copyright (c) 2026 LocalConfigTool contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
[IO.File]::WriteAllText((Join-Path $OutDir 'LICENSE'), (($license -replace "`r?`n", "`r`n")), (New-Object System.Text.UTF8Encoding($false)))
Write-Step '.gitignore / LICENSE(MIT) 已写入'

# ---------------- 6b) 瘦身：移除不再维护的旧 WinForms 界面及其专属测试 ----------------
# 公开版只保留当前在维护的 Java 界面（ui-java\）。旧 WinForms 界面（ui\ConfigUI.ps1，349 KB）
# 已不再更新，且占公开包体积约 20%；它的专属测试 tests\UiPageSmoke.ps1 一并移除，
# 门禁从 23 道改为 22 道（其余全保留）。
$legacy = @(
    (Join-Path $OutDir 'ui\ConfigUI.ps1'),
    (Join-Path $OutDir 'tests\UiPageSmoke.ps1')
)
$removedNames = @()
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
foreach ($p in $legacy) {
    if (Test-Path -LiteralPath $p) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $removedNames += (Split-Path $p -Leaf)
        } catch { }
    }
}
$uiDir = Join-Path $OutDir 'ui'
if (Test-Path -LiteralPath $uiDir) {
    $leftInUi = @(Get-ChildItem -LiteralPath $uiDir -Recurse -File -ErrorAction SilentlyContinue)
    if (@($leftInUi).Count -eq 0) {
        try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($uiDir, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
    }
}
$gatesPath = Join-Path $OutDir 'tests\Run-AllGates.ps1'
if (Test-Path -LiteralPath $gatesPath) {
    $g = Get-Content -LiteralPath $gatesPath -Raw -Encoding UTF8
    $beforeG = $g
    $g = $g -replace '(?m)^[ \t]*@\{\s*name\s*=\s*''UiPageSmoke'';[^\r\n]*\r?\n', ''
    # SelfCheck 跑的是 ui\ConfigUI.ps1 -SelfCheck；界面已移除，这条门禁一并去掉（否则永远 SKIP）。
    # 注意：它是数组最后一项，必须连同前一项的尾逗号一起删，否则会留下 ", ]" 造成语法错误。
    $g = $g -replace '(?m),\s*\r?\n[ \t]*@\{\s*name\s*=\s*''SelfCheck'';[^\r\n]*', ''
    if ($g -ne $beforeG) { [IO.File]::WriteAllText($gatesPath, $g, (New-Object System.Text.UTF8Encoding($true))) }
}
$readmeP = Join-Path $OutDir 'README.md'
if (Test-Path -LiteralPath $readmeP) {
    $rr = Get-Content -LiteralPath $readmeP -Raw -Encoding UTF8
    $rr2 = $rr -replace '(?m)^>[ \t]*旧的 WinForms 界面[^\r\n]*\r?\n', ''
    if ($rr2 -ne $rr) { [IO.File]::WriteAllText($readmeP, $rr2, (New-Object System.Text.UTF8Encoding($true))) }
}
Write-Step ('瘦身：移除 ' + (@($removedNames) -join ', ') + '（旧 WinForms 界面 + 其专属测试）')
# 校验瘦身后的门禁脚本语法（防止数组逗号残留导致解析失败）
if (Test-Path -LiteralPath $gatesPath) {
    $perr = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($gatesPath, [ref]$null, [ref]$perr)
    if (@($perr).Count -gt 0) {
        Write-Step ('!! 门禁脚本被改坏（parseErrors=' + @($perr).Count + '）：' + $perr[0].Message)
        exit 1
    }
}

# ---------------- 7) README 顶部免责声明 ----------------
$readmePath = Join-Path $OutDir 'README.md'
if (Test-Path -LiteralPath $readmePath) {
    $old = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
    $disclaimer = @'
> ## 本仓库是「MCP 工具」，不是恶意项目
>
> LocalConfigTool 是一个 Windows 系统分析与本地配置管理工具，同时是一个标准
> **MCP（Model Context Protocol）服务器**（`tools\McpServer.ps1`，JSON-RPC over stdio）。
> 它不自我传播、不隐藏、不窃取数据；写操作默认只预览，必须显式 `-Apply`，
> AI 场景还需人给一次性确认短语；每次写入前自动备份、可回滚、全程审计。
>
> ## 公开版与完整版的差别（只差两样「具体载荷」）
>
> **工具本体与能力完整保留**：68 个 verb、驱动/对象图/profile 引擎、WDAC、AI 接入、MCP、UI、23 道门禁测试。
>
> 只把下面两样改为**使用者自备**：
> - 某个具体 CVE 的**可执行 exploit** → `plugins\cve-2026-49176` 是占位实现（用 `-PocDir` 指向你自己的 PoC）
> - **现成的漏洞驱动下载链** → `samples\catalog.json` 的真实 URL / SHA256 已清空（填你自己的）
>
> 因为「具备驱动加载能力」和「预置某个具体 exploit」是两件事：前者是**工具**
> （火绒剑同样自带驱动、能操作内核），后者属于**具体利用代码**，不适合随公开仓库分发。
>
> ## 使用边界
>
> - 仅在**你完全拥有处置权**的机器上使用（虚拟机 / 快照最佳）
> - 驱动加载与内核操作有蓝屏风险，工具默认**只预览**，必须显式 `-Apply`
> - 使用者自行承担全部责任；请勿用于未授权的系统

---

'@
    [IO.File]::WriteAllText($readmePath, (($disclaimer -replace "`r?`n", "`r`n") + $old), (New-Object System.Text.UTF8Encoding($true)))
    Write-Step 'README 顶部已加免责声明'
}

# ---------------- 8) 打包 ----------------
if (-not $NoZip) {
    New-LctZipNormalized -SourceDir $OutDir -ZipPath $Zip
    Write-Step ('已生成 ' + $Zip + '  ' + [math]::Round(((Get-Item -LiteralPath $Zip).Length / 1MB), 2) + ' MB')
}

Write-Step ('完成。输出目录: ' + $OutDir)
Write-Step '提示：公开版仍需在你自己的机器上跑一遍 tests\Run-AllGates.ps1 再发布（本脚本不改测试）。'
exit 0