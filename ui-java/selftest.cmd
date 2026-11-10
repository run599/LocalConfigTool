@echo off
rem Headless performance self-test: proves the persistent worker (item 1).
setlocal
set "ROOT=%~dp0.."
cd /d "%ROOT%"
java -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -cp "%~dp0out" lctui.SelfTest "%ROOT%"
