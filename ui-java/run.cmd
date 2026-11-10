@echo off
rem Launch the Java (Swing) UI. Working directory must be the tool root so that
rem core\worker.ps1 can be found and relative paths (var\, presets\) resolve.
setlocal
set "ROOT=%~dp0.."
cd /d "%ROOT%"
java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -cp "%~dp0out" lctui.Ui
