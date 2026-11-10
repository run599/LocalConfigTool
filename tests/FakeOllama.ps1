param(
    [int]$Port = 18437,
    [string]$Response = '加载 rtcore64 驱动读内核头，最后清理',
    [int]$LifeSeconds = 120,
    [string]$ResponseFile = '',
    [string]$HeaderLog = '',
    [int]$ForceStatus = 0
)
$ErrorActionPreference = 'Stop'
$resp = $Response
if ($ResponseFile -ne '' -and (Test-Path -LiteralPath $ResponseFile)) { $resp = [IO.File]::ReadAllText($ResponseFile, [Text.Encoding]::UTF8) }
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host ("fake-llm listening on http://127.0.0.1:" + $Port)
$deadline = (Get-Date).AddSeconds($LifeSeconds)
while ((Get-Date) -lt $deadline) {
    $client = $null
    try {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $stream = $client.GetStream()
        $buf = New-Object byte[] 16384
        $headerText = ''
        $t0 = (Get-Date)
        while ($headerText -notmatch "`r`n`r`n") {
            if (((Get-Date) - $t0).TotalSeconds -gt 3.0) { break }
            if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 10; continue }
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $headerText += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        }
        if ($headerText -match '(?i)Expect:\s*100-continue') {
            $c100 = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $stream.Write($c100, 0, $c100.Length); $stream.Flush()
        }
        # 记录请求头（供测试断言 key 是否注入）
        if ($HeaderLog -ne '') {
            try {
                $reqLine = ($headerText -split "`r`n")[0]
                $line = 'REQ ' + $reqLine
                foreach ($h in ($headerText -split "`r`n")) {
                    if ($h -match '(?i)^(Authorization|x-api-key|anthropic-version|Content-Type)\s*:') { $line += ' | ' + $h.Trim() }
                }
                Add-Content -LiteralPath $HeaderLog -Value $line -Encoding UTF8
            } catch { }
        }
        $isChunked = ($headerText -match '(?i)Transfer-Encoding:\s*chunked')
        $contentLength = 0
        if ($headerText -match '(?i)Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
        $endIdx = $headerText.IndexOf("`r`n`r`n")
        $bodyHave = 0
        if ($endIdx -ge 0) { $bodyHave = $headerText.Length - ($endIdx + 4) }
        $t1 = (Get-Date)
        while (((Get-Date) - $t1).TotalSeconds -lt 1.5) {
            if (-not $isChunked -and $contentLength -gt 0 -and $bodyHave -ge $contentLength) { break }
            if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 15; continue }
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $bodyHave += $n
        }
        $path = '/api/generate'
        if ($headerText -match '(?i)^POST\s+(\S+)') { $path = $Matches[1] }
        $statusLine = 'HTTP/1.1 200 OK'
        $json = ''
        if ($ForceStatus -ge 400) {
            $statusLine = 'HTTP/1.1 ' + $ForceStatus + ' Error'
            $json = '{"error":{"message":"fake unauthorized","type":"invalid_request_error"}}'
        } elseif ($path -match '/v1/messages') {
            $json = '{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":' + ($resp | ConvertTo-Json) + '}]}'
        } elseif ($path -match '/chat/completions') {
            $json = '{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":' + ($resp | ConvertTo-Json) + '},"finish_reason":"stop"}]}'
        } else {
            $json = '{"model":"fake","response":' + ($resp | ConvertTo-Json) + ',"done":true}'
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $hdr = $statusLine + "`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Start-Sleep -Milliseconds 100
    } catch { }
    finally { if ($null -ne $client) { try { $client.Close() } catch { } } }
}
$listener.Stop()