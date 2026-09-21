@echo off
rem ===========================================================================
rem  Z17S - pull the on-device system backup to this PC
rem
rem  Usage:
rem     pull-backup.cmd                 -> saves to .\z17s-backup\<timestamp>\
rem     pull-backup.cmd D:\my\path      -> saves to D:\my\path\<timestamp>\
rem
rem  Requires: `ssh z17s` alias configured (see ~/.ssh/config), scp available
rem ===========================================================================
setlocal enabledelayedexpansion

if "%~1"=="" (
    set "DEST=%~dp0z17s-backup"
) else (
    set "DEST=%~1"
)

echo === Z17S backup pull ===
echo Target dir: %DEST%
echo.

rem ---- 1. find the newest backup folder on the device -----------------------
echo [1/3] Looking for the latest backup on device...
set "STAMP="
for /f "usebackq delims=" %%i in (`ssh z17s "ls -1t /root/z17s-backup/"`) do (
    if not defined STAMP set "STAMP=%%i"
)

if not defined STAMP (
    echo   ERROR: could not list /root/z17s-backup on the device.
    echo   - is the device online?  try: ssh z17s
    echo   - has a backup been made?  run scripts/backup-system.sh on the device
    exit /b 1
)
echo   Latest backup: %STAMP%

rem ---- 2. copy ---------------------------------------------------------------
echo.
echo [2/3] Copying files (this may take a few minutes for rootfs)...
if not exist "%DEST%\%STAMP%" mkdir "%DEST%\%STAMP%"

scp -r z17s:/root/z17s-backup/%STAMP%/* "%DEST%\%STAMP%\"
if errorlevel 1 (
    echo   ERROR: scp failed.
    exit /b 1
)

rem ---- 3. report -------------------------------------------------------------
echo.
echo [3/3] Done.
echo.
echo Files:
dir /b "%DEST%\%STAMP%"
echo.
echo Saved to: %DEST%\%STAMP%
echo.
echo NOTE: verify integrity before you need it. In Git Bash:
echo    cd "%DEST%\%STAMP%" ^&^& md5sum -c MD5SUMS.txt
echo.
echo Most important files:
echo    10-boot-sde18.img.gz    boot partition (kernel) - restores a non-booting phone
echo    20-persist-sda2.tar.gz  WiFi MAC / Bluetooth NV - UNRECOVERABLE if lost
echo    50-rootfs-sda10.tar.gz  full root filesystem
echo.
endlocal
