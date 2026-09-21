param(
  [string]$PortName = "COM15",
  [int]$Seconds = 30,
  [string]$LogFile = "$PSScriptRoot\serial-passive.log"
)
$ErrorActionPreference = "Continue"
$sp = $null
for ($i = 1; $i -le 5; $i++) {
  try {
    $sp = New-Object System.IO.Ports.SerialPort $PortName, 115200, "None", 8, "One"
    $sp.ReadTimeout = 1000
    $sp.DtrEnable = $true
    $sp.RtsEnable = $true
    $sp.Open()
    break
  } catch { $sp = $null; Start-Sleep -Seconds 2 }
}
if ($null -eq $sp) {
  [System.IO.File]::WriteAllText($LogFile, "OPEN FAIL on $PortName", (New-Object System.Text.UTF8Encoding($false)))
  "open failed"; exit 1
}
$sb = New-Object System.Text.StringBuilder
$deadline = (Get-Date).AddSeconds($Seconds)
$buf = New-Object char[] 4096
while ((Get-Date) -lt $deadline) {
  try {
    $n = $sp.Read($buf, 0, $buf.Length)
    if ($n -gt 0) { [void]$sb.Append((-join $buf[0..($n-1)])) }
  } catch { Start-Sleep -Milliseconds 120 }
}
# nudge: press Enter once and keep reading a little
try { $sp.Write("`r") } catch {}
Start-Sleep -Seconds 3
try {
  $n = $sp.Read($buf, 0, $buf.Length)
  if ($n -gt 0) { [void]$sb.Append((-join $buf[0..($n-1)])) }
} catch {}
$sp.Close()
[System.IO.File]::WriteAllText($LogFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"written " + $sb.Length + " chars"
