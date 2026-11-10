@echo off
rem LocalConfigTool - engine CLI entry (double-click friendly, ASCII only)
rem Usage: engine.cmd engine.verbs
rem        engine.cmd registry.get -Args "{\"path\":\"HKCU:\\Software\"}"
rem        engine.cmd account.uac -Args "{\"enable\":false}" -Apply
rem Note: cd to the tool dir first so the relative script path never contains
rem non-ASCII characters (the user name in this project's path is CJK).
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "core\Engine.ps1" %*
exit /b %ERRORLEVEL%