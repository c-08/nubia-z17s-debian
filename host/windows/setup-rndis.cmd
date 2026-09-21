@echo off
rem Self-elevating launcher for setup-rndis.ps1
rem ASCII only on purpose (avoid codepage issues).
setlocal
net session >nul 2>&1
if %errorlevel%==0 goto :run
echo Requesting administrator privileges...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:run
echo === Z17S USB-RNDIS / ICS setup (running as admin) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-rndis.ps1"
echo.
pause
