@echo off
REM ===================================================================
REM  Z17S flashing environment (cmd version)
REM
REM  Usage - run once in cmd:
REM      C:\Users\<用户名>\flash\env.cmd
REM  After that, adb / fastboot in this window are the new ones.
REM
REM  Why this is needed: C:\Windows\adb.exe on this machine is the 2012
REM  build (adb 1.0.26) which has no RSA auth and cannot talk to
REM  Android 10.
REM ===================================================================

set "FLASH=C:\Users\<用户名>\flash"

REM put the new platform-tools first on PATH
set "PATH=%FLASH%\platform-tools;%PATH%"

REM the old adb server (v26) squats on port 5037 and makes the new client
REM fail with "adb server version (26) doesn't match this client (41)".
REM kill it and let the new client start its own server.
taskkill /F /IM adb.exe >nul 2>&1

echo.
echo adb      = %FLASH%\platform-tools\adb.exe
echo fastboot = %FLASH%\platform-tools\fastboot.exe
echo.
adb version
echo.
echo -- devices --
adb devices
