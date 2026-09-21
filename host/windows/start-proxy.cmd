@echo off
rem Start the Z17S fallback internet proxy.  Runs as the CURRENT user (no admin needed).
rem Keep this window open while you want the phone to have internet through this PC.
rem ASCII only on purpose.
rem
rem NOTE on the interpreter choice: Windows Firewall silently drops inbound TCP on the
rem RNDIS adapter (that network is on the Public profile).  Inbound is therefore allowed
rem only for programs that already have an *inbound allow* rule.
rem   - If the phone cannot reach the proxy, add a rule for your python.exe (as admin):
rem         netsh advfirewall firewall add rule name="z17s-proxy" dir=in action=allow ^
rem               program="C:\path\to\python.exe" protocol=TCP
rem   - Override the interpreter with:  set Z17S_PYTHON=C:\path\to\python.exe
setlocal
title Z17S fallback proxy (keep this window open)

set PY=python
if defined Z17S_PYTHON set PY=%Z17S_PYTHON%

echo ============================================================
echo  Z17S fallback internet proxy  (no administrator needed)
echo ------------------------------------------------------------
echo  interpreter : %PY%
echo  HTTP proxy  : 0.0.0.0:3128
echo  DNS relay   : udp/53  (forwards to 223.5.5.5)
echo.
echo  On the phone:
echo     export http_proxy=http://192.168.137.1:3128
echo     export https_proxy=http://192.168.137.1:3128
echo     nmcli con mod z17s-usb0 ipv4.dns 192.168.137.1
echo     nmcli device reapply usb0
echo   (proxy mode has NO NAT, so DNS must point at this PC's relay.
echo    Do NOT hand-edit /etc/resolv.conf - NetworkManager owns it and will wipe it.)
echo.
echo  Quick check from the phone:
echo     curl -x http://192.168.137.1:3128 -o /dev/null -w "%%{http_code}\n" https://mirrors.aliyun.com/
echo     nslookup mirrors.aliyun.com 192.168.137.1
echo ============================================================
echo.

"%PY%" "%~dp0z17s-proxy.py" --port 3128 --dns-port 53
echo.
echo proxy exited with code %errorlevel%
pause
