@echo off
setlocal EnableExtensions
title Z17S Serial Logger  (Ctrl+C to stop)

rem ===================================================================
rem  KEEP THIS FILE PURE ASCII.
rem  cmd.exe re-reads a .bat/.cmd by byte offset while decoding; on a
rem  Chinese Windows console (cp936) a UTF-8 Chinese line makes the
rem  parser split/merge lines, and the stray tokens get executed:
rem      'port' is not recognized as an internal or external command
rem      '<chinese tail>' is not recognized as an internal or external command
rem  Same class of bug as the PS 5.1 non-BOM UTF-8 .ps1 issue.
rem  English-only banner = immune. Do NOT add Chinese here.
rem ===================================================================

set "PS1=%~dp0z17s-serial-log.ps1"
set "OUT=%~dp0..\..\..\..\_z17s\serial-log"

if not exist "%PS1%" (
  echo [ERROR] script not found: %PS1%
  pause
  exit /b 1
)
if not exist "%OUT%" mkdir "%OUT%" 2>nul

echo ==================================================
echo   Z17S serial logger
echo   port   : auto - only the phone's USB gadget COM
echo   script : %PS1%
echo   output : %OUT%
echo   stop   : Ctrl+C  (leave this window open)
echo --------------------------------------------------
echo   All device console output is written to the
echo   directory above, in real time.
echo.
echo   The COM number CHANGES on every device boot:
echo   the gadget is rebuilt ~45s after boot, so the
echo   logger follows it automatically. Reconnects are
echo   normal - they are not an error.
echo ==================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -OutDir "%OUT%"

echo.
echo [logger exited]
pause
