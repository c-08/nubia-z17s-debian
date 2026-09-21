@echo off
rem Start the Z17S fallback internet proxy.  Runs as the CURRENT user (no admin needed).
rem Keep this window open while you want the phone to have internet through this PC.
rem ASCII only on purpose.
rem
rem NOTE on the interpreter choice: this PC already has an enabled *inbound allow*
rem firewall rule for
rem     C:\Users\<用户名>\<path-to-python.exe>
rem (Private+Public, TCP, any port).  Windows Firewall silently drops inbound TCP on the
rem RNDIS adapter otherwise (that network is on the Public profile), so we deliberately
rem run the proxy with THAT interpreter.  Do not switch to another python without first
rem adding a firewall rule.
setlocal
title Z17S fallback proxy (keep this window open)

set PY=C:\Users\<用户名>\<path-to-python.exe>
if not exist "%PY%" set PY=C:\Users\<用户名>\.workbuddy\binaries\python\envs\default\Scripts\python.exe
if not exist "%PY%" set PY=python

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
echo     echo "nameserver 192.168.137.1" ^> /etc/resolv.conf
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
