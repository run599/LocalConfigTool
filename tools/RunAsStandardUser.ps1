# LocalConfigTool - tools\RunAsStandardUser.ps1
#
# 用途：从**提权**会话里，以**普通用户（Medium 完整性）**身份运行一个脚本，并把它的输出写成文件。
#       用于验证「非提权时某个操作会不会被正确拦住 / 提权路线能否从普通用户起步」。
#
# 为什么这么做（实测结论，别再走弯路）：
#   × runas /trustlevel:0x20000 —— 该 SAFER 受限令牌里 PowerShell 起不来（无输出、无结果文件）。
#   × TokenLinkedToken + DuplicateTokenEx + CreateProcessWithTokenW —— 本机报 1346/5，复制主令牌失败。
#   ✔ explorer.exe <脚本> —— Explorer 本身跑在 Medium，由它拉起就是**真正的普通用户上下文**
#     （实测 isAdmin=False、完整性 Medium RID 8192），最贴近"用户双击运行"。
#
# 关键陷阱（都踩过）：
#   * 启动器 .cmd 必须**纯 ASCII**：里面带中文路径会被 ASCII 编码写成 '?'，
#     PowerShell 报「路径中具有非法字符」。所以路径走 UTF-8 的 paths.json，不经命令行传递。
#   * 被运行的脚本里，读引擎原生 stdout 前必须 `[Console]::OutputEncoding = UTF8`，
#     否则中文被 GBK 重编码成乱码（本项目老坑），JSON 都会解析失败。
#   * Engine.ps1 用 [Console]::Out 写 JSON，**同进程管道抓不到**，必须用子进程调用再捕获。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\RunAsStandardUser.ps1 `
#       -Script C:\Temp\my-verify.ps1 -OutDir C:\Temp\my-verify-out -TimeoutSec 600
#   被运行的脚本需要接收 -OutDir 参数，并在结束时写 DONE.txt。
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Script)) { throw ('找不到要运行的脚本: ' + $Script) }
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# 路径经 UTF-8 文件传递，绝不进 .cmd
$paths = Join-Path $OutDir 'runner-paths.json'
[IO.File]::WriteAllText($paths, ([ordered]@{ script = (Resolve-Path -LiteralPath $Script).Path; outDir = (Resolve-Path -LiteralPath $OutDir).Path } | ConvertTo-Json), $utf8)

$runner = Join-Path $OutDir 'runner.ps1'
$runnerCode = @'
param([string]$OutDir)
try { [Console]::OutputEncoding = (New-Object System.Text.UTF8Encoding($false)) } catch { }
$cfg = Get-Content (Join-Path $OutDir 'runner-paths.json') -Raw -Encoding UTF8 | ConvertFrom-Json
& ([string]$cfg.script) -OutDir ([string]$cfg.outDir)
'@
[IO.File]::WriteAllText($runner, $runnerCode, (New-Object System.Text.UTF8Encoding($true)))

# 启动器 .cmd 只用 ASCII
$cmd = Join-Path $OutDir 'runner.cmd'
$line = "@echo off`r`n`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$runner`" -OutDir `"$OutDir`"`r`n"
[IO.File]::WriteAllText($cmd, $line, (New-Object System.Text.ASCIIEncoding))

$done = Join-Path $OutDir 'DONE.txt'
if (Test-Path -LiteralPath $done) {
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($done, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}
Write-Host ('[RunAsStandardUser] 用 explorer 以 Medium 拉起: ' + $Script)
& explorer.exe $cmd
$waited = 0
while ($waited -lt $TimeoutSec) {
    Start-Sleep -Milliseconds 800
    $waited++
    if (Test-Path -LiteralPath $done) {
        Write-Host ('[RunAsStandardUser] 完成（约 ' + [math]::Round($waited * 0.8) + ' 秒），输出在 ' + $OutDir)
        exit 0
    }
}
Write-Host ('[RunAsStandardUser] 超时（' + $TimeoutSec + ' 秒）未看到 DONE.txt')
exit 1
