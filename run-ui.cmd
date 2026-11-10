@echo off
rem ===========================================================================
rem  LocalConfigTool - launch the WinForms front end (ui\ConfigUI.ps1)
rem  Author: task-3 (ui-winforms)
rem  NOTE: this file must stay pure ASCII. The tool root path contains a
rem  non-ASCII user name, so the path is always built with %~dp0 instead of
rem  being hard coded or passed through an ASCII conversion.
rem  Usage:
rem      run-ui.cmd                 (double click / normal launch)
rem      run-ui.cmd -SelfCheck      (headless self check; prints OK, exit 0)
rem ===========================================================================
setlocal
set "TOOLROOT=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TOOLROOT%ui\ConfigUI.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & set "RC=%RC%"

if not "%RC%"=="0" (
  echo.
  echo LocalConfigTool returned exit code %RC%.
  if "%~1"=="" pause
)
exit /b %RC%