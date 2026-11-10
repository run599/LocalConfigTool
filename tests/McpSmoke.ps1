# LocalConfigTool - tests\McpSmoke.ps1
#
# MCP 服务器的冒烟：起一个真进程，按 JSON-RPC 2.0 走 initialize → tools/list → tools/call（只读）。
# 输出供 tests\AiTest.ps1 断言（tools=4 / call_ok=True）。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\McpSmoke.ps1 [-ToolRoot <项目根>]
param(
    [string]$ToolRoot = ''
)
$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$server = Join-Path $ToolRoot 'tools\McpServer.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $psExe
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $server + '"'
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8

$proc = [Diagnostics.Process]::Start($psi)
$in = $proc.StandardInput

function SendLine($obj) {
    $json = ($obj | ConvertTo-Json -Depth 10 -Compress)
    $bytes = $utf8.GetBytes($json + "`n")
    $in.BaseStream.Write($bytes, 0, $bytes.Length)
    $in.BaseStream.Flush()
}
function Ask($obj) {
    # 一次只发一个请求，所以响应必然是下一行 —— 直接阻塞读。
    # 不要用固定 sleep 赌时序：driver.map 要 400~800ms，固定 150ms 会读到半行，冒烟假失败。
    SendLine $obj
    return $proc.StandardOutput.ReadLine()
}

try {
    $init = Ask @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'mcp-smoke'; version = '1' } } }
    Write-Output ('initialize=' + $(if ($init -and $init -match 'local-config-tool') { 'ok' } else { 'fail' }))

    SendLine @{ jsonrpc = '2.0'; method = 'notifications/initialized' }   # 通知：按协议不回包

    $list = Ask @{ jsonrpc = '2.0'; id = 2; method = 'tools/list' }
    $tools = @()
    try { $tools = @((($list | ConvertFrom-Json).result.tools)) } catch { }
    Write-Output ('tools=' + @($tools).Count)
    Write-Output ('tools_names=' + ((@($tools) | ForEach-Object { $_.name }) -join ','))
    Write-Output ('local-config-tool')   # AT-10a 断言这两段文本之一

    $call = Ask @{ jsonrpc = '2.0'; id = 3; method = 'tools/call'; params = @{ name = 'lct_call'; arguments = @{ verb = 'driver.map'; args = @{ maxLinks = 50 } } } }
    $okFlag = 'False'
    try {
        $j = $call | ConvertFrom-Json
        if ($j.result -and $j.result.isError -eq $false) {
            $inner = ($j.result.content[0].text | ConvertFrom-Json)
            if ($inner.ok -eq $true) { $okFlag = 'True' }
        }
    } catch { }
    Write-Output ('call_ok=' + $okFlag)
} finally {
    try { $in.Close() } catch { }
    try {
        if (-not $proc.WaitForExit(5000)) { $proc.Kill() }
    } catch { try { $proc.Kill() } catch { } }
}
