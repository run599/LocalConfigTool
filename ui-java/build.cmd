@echo off
rem Build the Java (Swing) UI. No third-party dependencies: JDK only.
setlocal
set "ROOT=%~dp0.."
set "SRC=%~dp0src"
set "OUT=%~dp0out"
if not exist "%OUT%" mkdir "%OUT%"
echo [build] javac -encoding UTF-8
javac -encoding UTF-8 -d "%OUT%" "%SRC%\lctui\Json.java" "%SRC%\lctui\WorkerClient.java" "%SRC%\lctui\Engine.java" "%SRC%\lctui\Ui.java" "%SRC%\lctui\SelfTest.java"
if errorlevel 1 (
  echo [build] FAILED
  exit /b 1
)
echo [build] OK -^> %OUT%
