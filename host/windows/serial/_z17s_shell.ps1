param(
  [string]$CmdFile = "C:\Users\<用户名>\_z17s\cmds.txt",
  [string]$LogFile = "C:\Users\<用户名>\_z17s\shell.log",
  [int]$TimeoutSec = 70,
  [string]$PortName = "",
  [int]$Retries = 3
)
$ErrorActionPreference = "Continue"

function Resolve-Port {
  param([string]$Explicit)
  if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
  $prefer = @()
  $other = @()
  try {
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -like "USB\VID_0525*" -or $_.Name -match "USB 串行设备|USB Serial" } | ForEach-Object {
      if ($_.Name -match "(COM\d+)") { $prefer += $matches[1] }
    }
  } catch { }
  try {
    $comm = Get-ItemProperty -Path "HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM" -ErrorAction SilentlyContinue
    foreach ($p in $comm.PSObject.Properties) {
      if ($p.Name -notlike "PS*" -and "$($p.Value)" -match "^COM\d+$" -and "$($p.Value)" -ne "COM1") { $other += "$($p.Value)" }
    }
  } catch { }
  $all = @(@($prefer + $other) | Where-Object { $_ -match "^COM\d+$" } | Select-Object -Unique)
  if ($all.Count -gt 0) { return [string]$all[0] }
  return "COM9"
}

$dev = Resolve-Port $PortName
$sp = $null
$lastErr = ""
for ($i = 1; $i -le $Retries; $i++) {
  try {
    $sp = New-Object System.IO.Ports.SerialPort $dev, 115200, "None", 8, "One"
    $sp.ReadTimeout = 1500
    $sp.DtrEnable = $true
    $sp.RtsEnable = $true
    $sp.Open()
    $lastErr = ""
    break
  } catch {
    $lastErr = $_.Exception.Message
    $sp = $null
    Start-Sleep -Seconds 2
  }
}
if ($null -eq $sp) {
  $msg = "OPEN FAIL on [" + $dev + "] after " + $Retries + " tries : " + $lastErr
  [System.IO.File]::WriteAllText($LogFile, $msg, (New-Object System.Text.UTF8Encoding($false)))
  Write-Output $msg
  exit 1
}

function Drain([int]$ms) {
  $sb = New-Object System.Text.StringBuilder
  $dl = (Get-Date).AddMilliseconds($ms)
  $buf = New-Object char[] 4096
  while ((Get-Date) -lt $dl) {
    try {
      $n = $sp.Read($buf, 0, $buf.Length)
      if ($n -gt 0) { [void]$sb.Append((-join $buf[0..($n-1)])) }
    } catch { Start-Sleep -Milliseconds 100 }
  }
  return $sb.ToString()
}

[void](Drain 1000)

$all = New-Object System.Text.StringBuilder
$cmds = Get-Content -Path $CmdFile -Encoding UTF8
foreach ($c in $cmds) {
  if ([string]::IsNullOrWhiteSpace($c)) { continue }
  $sp.Write($c + "`r")
  Start-Sleep -Milliseconds 700
  [void]$all.Append((Drain 1500))
}
$sp.Write("echo __ENDMARK__`r")

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  $d = Drain 1000
  [void]$all.Append($d)
  if ($all.ToString() -match "__ENDMARK__") { break }
}
$sp.Close()
[System.IO.File]::WriteAllText($LogFile, $all.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("written: " + $LogFile + " via " + $dev)
