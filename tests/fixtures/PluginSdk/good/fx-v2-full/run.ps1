# Fixture 入口（仅用于让 v2 完整清单自洽；SDK 逻辑层不会执行它）
param([string]$Action = 'status')
Write-Output ("fixture fx-v2-full action=" + $Action)