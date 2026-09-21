# Z17S 刷机环境变量
#
# 用法：在 PowerShell 里先执行一次（注意开头那个点和一个空格）
#     . C:\Users\<用户名>\flash\env.ps1
# 之后就可以直接用 $adb / $fastboot，不用每次写完整路径。
#
# 为什么要这么麻烦：这台机器 C:\Windows\adb.exe 是 2012 年的 adb 1.0.26，
# 不支持 RSA 认证，连不上 Android 10。必须显式用新版。

$FlashDir = "C:\Users\<用户名>\flash"

# 把新版 platform-tools 放到 PATH 最前面
$env:Path = "$FlashDir\platform-tools;$env:Path"

$adb      = "$FlashDir\platform-tools\adb.exe"
$fastboot = "$FlashDir\platform-tools\fastboot.exe"

# 老 adb 留下的服务进程会占着 5037 端口，导致新版报
# "adb server version (26) doesn't match this client (41)"。
# 这里自动清掉旧进程再起新服务。
$old = Get-Process -Name adb -ErrorAction SilentlyContinue
if ($old) {
    Write-Host "发现旧版 adb 服务（PID $($old.Id -join ', ')），正在重启..." -ForegroundColor Yellow
    $old | Stop-Process -Force
    Start-Sleep -Seconds 1
}

Write-Host ""
Write-Host "adb      -> $adb"
Write-Host "fastboot -> $fastboot"
& $adb version
Write-Host ""
Write-Host "设备列表：" -NoNewline
& $adb devices
