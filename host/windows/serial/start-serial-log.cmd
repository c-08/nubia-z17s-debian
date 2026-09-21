@echo off
chcp 65001 >nul
title Z17S Serial Logger  (Ctrl+C to stop)
setlocal EnableExtensions

set "PS1=%~dp0z17s-serial-log.ps1"
set "OUT=%~dp0..\..\..\..\_z17s\serial-log"

if not exist "%PS1%" (
  echo [ERROR] script not found: %PS1%
  pause
  exit /b 1
)
if not exist "%OUT%" mkdir "%OUT%" 2>nul

echo ==================================================
echo   Z17S 串口持续记录器
echo   port   : auto (COM15 优先)
echo   script : %PS1%
echo   output : %OUT%
echo   停止   : Ctrl+C
echo --------------------------------------------------
echo   设备 console 的全部输出会实时写进上面的目录。
echo   设备重启 / COM 口消失后会自动重连，无需干预。
echo ==================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -OutDir "%OUT%"

echo.
echo [logger exited]
pause
