# LocalConfigTool - core\worker.ps1
#
# 常驻引擎 worker（① 常驻 worker 的基础设施）。
#
# 为什么需要它：每次动作用 `powershell.exe -File core\Engine.ps1` 都要重新起进程 + 导入 12 个模块，
# 实测固定开销约 2.2 秒；而常驻进程只付一次导入成本，之后每条请求只要 0~10 毫秒。
#
# 协议（面向 Java UI / 任何父进程）：
#   启动后由父进程写入一行 UTF-8 JSON，worker 回一行 UTF-8 JSON：
#     {"verb":"engine.verbs"}                       -> {"ok":true,"verb":"engine.verbs","data":{...},...}
#     {"verb":"driver.profile.list","args":{}}      -> 同上
#     {"verb":"driver.profile.validate","args":{"id":"x"},"apply":true}
#     {"verb":"__ping"}                             -> {"ok":true,"pong":true,"toolRoot":"..."}  （就绪探测）
#   写入 EOF（父进程关闭 stdin）即退出。
#
# 约定：
#   - stdout 只输出 JSON 行（一行一条），任何诊断信息走 stderr，避免污染协议；
#   - 一律 UTF-8（Windows PowerShell 控制台默认 GBK，不显式设置中文会乱码 —— 本项目踩过这个坑）；
#   - 单线程串行处理（引擎本身不是并发的）；请求间互不影响，单条异常只回一条 error，不终止进程。
param(
    [Parameter(Mandatory = $true)][string]$ToolRoot
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
# 协议铁律：stdout 只能出现 JSON 行。Import-Module 会往 verbose/warning/information 流写
# “模块中某些函数名含未获批准的动词”这类提示，不掐掉就会把协议冲掉（实测踩过）。
$VerbosePreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::InputEncoding = $utf8 } catch { }
try { [Console]::OutputEncoding = $utf8 } catch { }
try { $OutputEncoding = $utf8 } catch { }

function Write-JsonLine([string]$Text) {
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
}

function Exit-Worker([string]$Reason) {
    try { [Console]::Error.WriteLine('[worker] ' + $Reason) } catch { }
    exit 0
}

# ---- 一次性导入引擎（唯一的启动成本） ----
try {
    $engineModule = Join-Path $ToolRoot 'core\Engine.psm1'
    if (-not (Test-Path -LiteralPath $engineModule)) { Exit-Worker ('找不到 ' + $engineModule) }
    Import-Module $engineModule -Force -Global -ErrorAction Stop -Verbose:$false -WarningAction SilentlyContinue 4>$null 6>$null
} catch {
    Write-JsonLine ('{"ok":false,"errors":["worker 导入引擎失败: ' + (($_.Exception.Message -replace '\\', '\\\\') -replace '"', '\"') + '"]}')
    Exit-Worker 'import failed'
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }          # EOF：父进程关闭了 stdin
    if ($line.Trim() -eq '') { continue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $req = $null
        try { $req = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw ('请求不是合法 JSON: ' + $_.Exception.Message) }
        $verb = [string]$req.verb
        if ($verb -eq '') { throw '缺少 verb' }
        if ($verb -eq '__ping') {
            Write-JsonLine ('{"ok":true,"pong":true,"toolRoot":"' + (($ToolRoot -replace '\\', '\\\\') -replace '"', '\"') + '"}')
            continue
        }
        $bag = @{}
        if ($null -ne $req.PSObject.Properties['args'] -and $null -ne $req.args) {
            foreach ($p in $req.args.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        }
        $isApply = $false
        if ($null -ne $req.PSObject.Properties['apply']) { $isApply = [bool]$req.apply }
        $result = Invoke-LctEngine -Verb $verb -Args $bag -Apply:$isApply
        $json = ($result | ConvertTo-Json -Depth 12 -Compress)
        if ([string]::IsNullOrWhiteSpace($json)) { $json = '{"ok":false,"errors":["引擎返回空"]}' }
    } catch {
        $msg = (($_.Exception.Message -replace '\\', '\\\\') -replace '"', '\"') -replace "`r?`n", ' '
        $json = '{"ok":false,"errors":["worker 处理异常: ' + $msg + '"]}'
    }
    try {
        $sw.Stop()
        # 附带耗时，方便 UI 显示真实延迟（毫秒）
        if ($json.TrimEnd().EndsWith('}')) {
            $json = $json.TrimEnd()
            $json = $json.Substring(0, $json.Length - 1) + ',"workerMs":' + $sw.ElapsedMilliseconds + '}'
        }
    } catch { }
    Write-JsonLine $json
}
exit 0
