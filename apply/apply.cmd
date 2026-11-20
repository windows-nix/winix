@echo off
rem Self-elevating launcher for apply.ps1. Arguments are passed through; keep
rem them free of quotes (they travel inside a -Command string once).
setlocal
set "ARGS=%*"
set "PAUSE_AT_END="
if "%~1"=="--elevated" (
  set "PAUSE_AT_END=1"
  set "ARGS=%ARGS:~11%"
)

net session >nul 2>&1
if errorlevel 1 (
  if defined ARGS (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath '%~f0' -ArgumentList '--elevated %ARGS%' -Verb RunAs -Wait -PassThru; exit $p.ExitCode"
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs -Wait -PassThru; exit $p.ExitCode"
  )
  rem Bare exit /b keeps the current errorlevel; %errorlevel% here would be
  rem expanded when the block is parsed, before powershell ran.
  exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply.ps1" %ARGS%
set "RC=%errorlevel%"
rem The elevated console closes on exit; keep the summary readable. Unattended
rem runs (FirstLogonCommands) are already elevated and never pause.
if defined PAUSE_AT_END pause
exit /b %RC%
