@echo off
REM ===========================================================================
REM  Z17S Debian 13 —— 从 PC 拉取根文件系统备份（Windows 双击版）
REM
REM  作用：调用 host\pull-rootfs.sh（需要 Git Bash）。
REM  为什么不能在设备上打包根分区 —— 见 docs\备份与恢复.md。
REM
REM  参数原样透传给 .sh，例如：
REM      pull-rootfs.cmd --slim
REM ===========================================================================
setlocal

set "REPO=%~dp0..\.."
set "SH=%REPO%\host\pull-rootfs.sh"

if not exist "%SH%" (
    echo [错误] 找不到 %SH%
    echo        请确认本文件位于仓库的 host\windows\ 目录下。
    pause
    exit /b 1
)

REM --- 找 Git Bash（按可能性排序）---
set "BASH="
where bash.exe >nul 2>nul && set "BASH=bash.exe"
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined BASH (
    echo [错误] 找不到 bash.exe —— 请先安装 Git for Windows
    echo        下载： https://git-scm.com/download/win
    pause
    exit /b 1
)

echo 使用: %BASH%
"%BASH%" "%SH%" %*

echo.
echo [退出码 %ERRORLEVEL%]
pause
