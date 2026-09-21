param(
  [Parameter(Mandatory=$true)][string]$LocalFile,
  [Parameter(Mandatory=$true)][string]$RemotePath,
  [string]$PortName = "",
  [int]$ChunkSize = 4096,
  [int]$SettleMs = 0,
  [int]$TimeoutSec = 1800,
  [int]$ReadyTimeoutSec = 60
)
$ErrorActionPreference = "Continue"

function Resolve-Port {
  param([string]$Explicit)
  if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
  $prefer = @(); $other = @()
  try {
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -like "USB\VID_0525*" } | ForEach-Object {
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

if (-not (Test-Path -LiteralPath $LocalFile)) { Write-Output "LOCAL FILE NOT FOUND: $LocalFile"; exit 1 }
$dev = Resolve-Port $PortName
$total = (Get-Item -LiteralPath $LocalFile).Length
$localMd5 = (Get-FileHash -LiteralPath $LocalFile -Algorithm MD5).Hash.ToLower()
$raw = [System.IO.File]::ReadAllBytes($LocalFile)
$b64 = [Convert]::ToBase64String($raw)
$b64len = $b64.Length
Write-Output ("file=$LocalFile size=$total md5=$localMd5 port=$dev b64len=$b64len")

$sp = New-Object System.IO.Ports.SerialPort $dev, 115200, "None", 8, "One"
$sp.ReadTimeout = 500
$sp.WriteTimeout = 120000
$sp.DtrEnable = $true
$sp.RtsEnable = $true
$sp.Handshake = [System.IO.Ports.Handshake]::XOnXOff
$sp.ReadBufferSize = 1048576
$sp.WriteBufferSize = 65536
try { $sp.Open() } catch { Write-Output ("OPEN FAIL: " + $_.Exception.Message); exit 1 }
Start-Sleep -Milliseconds 400
try { [void]$sp.ReadExisting() } catch { }

$cmd = 'stty -echo -icanon min 1 time 0; echo __READY__; head -c ' + $b64len + ' > /tmp/push-x.b64; stty echo icanon; base64 -d /tmp/push-x.b64 > ' + $RemotePath + '; rm -f /tmp/push-x.b64; sync; echo REMOTE_SIZE=$(wc -c < ' + $RemotePath + '); echo REMOTE_MD5=$(md5sum ' + $RemotePath + '); echo __DONE__'
$sp.Write($cmd + "`r")

$sb = New-Object System.Text.StringBuilder
$dl = (Get-Date).AddSeconds($ReadyTimeoutSec)
$ready = $false
while ((Get-Date) -lt $dl) {
  try { $ch = $sp.ReadExisting(); if ($ch) { [void]$sb.Append($ch) } } catch { }
  if ($sb.ToString() -match "__READY__") { $ready = $true; break }
  Start-Sleep -Milliseconds 150
}
Write-Output ("ready=" + $ready)
if (-not $ready) { $sp.Close(); Write-Output ("NO READY, buf=" + $sb.ToString()); exit 1 }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sent = 0
while ($sent -lt $b64len) {
  $n = [Math]::Min($ChunkSize, $b64len - $sent)
  try { $sp.Write($b64.Substring($sent, $n)) } catch {
    Write-Output ("WRITE FAIL at offset $sent : " + $_.Exception.Message); break
  }
  $sent += $n
  if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}
$sw.Stop()
$secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
if ($secs -gt 0) { $rate = [Math]::Round($sent / $secs / 1024, 1) } else { $rate = 0 }
Write-Output ("sent=$sent chars time=${secs}s rate=${rate}KB/s")

$sb2 = New-Object System.Text.StringBuilder
$dl2 = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $dl2) {
  try { $ch = $sp.ReadExisting(); if ($ch) { [void]$sb2.Append($ch) } } catch { }
  if ($sb2.ToString() -match "__DONE__") { break }
  Start-Sleep -Milliseconds 250
}
$sp.Close()
$out = ($sb2.ToString() -replace "`r", "")
Write-Output ("remote:" + $out.Trim())
Write-Output ("local md5 : " + $localMd5)
