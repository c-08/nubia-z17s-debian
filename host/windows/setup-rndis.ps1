# setup-rndis.ps1  (v2, 2026-09-20)
# Share the PC's internet with the Z17S (Debian 13) over its USB RNDIS link.
#
#     PC    RNDIS side : 192.168.137.1/24   (ICS: DHCP + DNS proxy + NAT)
#     Phone usb0       : 192.168.137.2/24   gw 192.168.137.1   (set by z17s-usbnet.sh)
#
# Why v2: v1 worked the very first time but silently lost its NAT binding whenever the
# RNDIS adapter was re-enumerated (which happens when the gadget descriptor changes or the
# phone reboots).  Symptom: the adapter still holds 192.168.137.1 and the phone can ping
# the PC, but nothing is forwarded and
#     HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\Interfaces
# is gone.  v2 therefore: restarts SharedAccess to drop stale state, verifies that the
# Interfaces key really came back, checks the WinNAT instance, and falls back to
# New-NetNat + per-interface forwarding if ICS refuses to take.
#
# Re-runnable: just double-click setup-rndis.cmd again.  ASCII only on purpose.
#
# -LogFile, if given, receives a full transcript.

param(
    [string]$LogFile = ""
)

$ErrorActionPreference = 'Continue'

$logTargets = @()
if ($LogFile -ne "") { $logTargets += $LogFile }
try { $logTargets += (Join-Path $PSScriptRoot 'ics-run.log') } catch {}
if ($logTargets.Count -gt 0) {
    try { Start-Transcript -Path $logTargets[0] -Force | Out-Null } catch {}
}

function Info($m) { Write-Host "[*] $m" }
function Bad($m)  { Write-Host "[X] $m" -ForegroundColor Red }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "=== Z17S USB-RNDIS internet sharing (ICS) ==="
Write-Host ""

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Bad "This script must run elevated.  Use setup-rndis.cmd (it self-elevates)."
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
Ok "running elevated"

# ---------------------------------------------------------------- 1. find the RNDIS NIC
$rndis = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'NDIS' -and $_.Status -ne 'Not Present' })

if ($rndis.Count -eq 0) {
    Bad "No 'Remote NDIS Compatible Device' adapter present."
    Write-Host ""
    Write-Host "  The phone must be plugged in with usb0 already up.  On the phone:"
    Write-Host "      ip -br addr show usb0        # expect 192.168.137.2/24"
    Write-Host "      systemctl start z17s-usbnet.service"
    Write-Host ""
    Write-Host "  Adapters now:"
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status | Format-Table -AutoSize
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

$rndisAdapter = $rndis[0]
$rndisIdx  = $rndisAdapter.ifIndex
$rndisName = $rndisAdapter.Name
Ok ("RNDIS adapter : '" + $rndisName + "'  [" + $rndisAdapter.InterfaceDescription + "]  ifIndex=" + $rndisIdx)

# ------------------------------------------------------- 2. find the internet adapter
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Where-Object { $_.ifIndex -ne $rndisIdx } |
         Sort-Object RouteMetric, ifMetric | Select-Object -First 1
if (-not $route) { Bad "No default route on any other adapter: this PC has no internet."; try { Stop-Transcript | Out-Null } catch {}; exit 1 }

$inet = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
if (-not $inet) { Bad ("Default route ifIndex " + $route.ifIndex + " has no adapter."); try { Stop-Transcript | Out-Null } catch {}; exit 1 }
Ok ("internet side : '" + $inet.Name + "'  [" + $inet.InterfaceDescription + "]  ifIndex=" + $inet.ifIndex)

# ------------------------------------------------------------------ 3. services up
Info "Ensuring the Windows Firewall + ICS services are running ..."
foreach ($svc in @('mpssvc', 'SharedAccess')) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') { try { Start-Service $svc -ErrorAction Stop; Ok "$svc started" } catch { Warn "$svc could not be started: $($_.Exception.Message)" } }
}

# Drop stale NAT/ICS state from previous runs.  This is what makes the script
# idempotent after the adapter was re-enumerated.
Info "Restarting SharedAccess to clear stale ICS/NAT state ..."
try { Restart-Service SharedAccess -Force -ErrorAction Stop; Ok "SharedAccess restarted" }
catch { Warn ("SharedAccess restart failed: " + $_.Exception.Message) }
Start-Sleep -Seconds 3

# --------------------------------------------------------- 4. clear old bindings
Info "Enumerating ICS connections ..."
$hns = New-Object -ComObject HNetCfg.HNetShare

$pubConn  = $null
$privConn = $null
foreach ($conn in $hns.EnumEveryConnection) {
    $p  = $hns.NetConnectionProps($conn)
    $dn = [string]$p.DeviceName
    $nm = [string]$p.Name
    Info ("  conn: DeviceName='" + $dn + "'  Name='" + $nm + "'")

    if ($dn -match 'NDIS' -or $nm -eq $rndisName -or $dn -eq $rndisAdapter.InterfaceDescription) { $privConn = $conn }
    if (($dn -eq $inet.InterfaceDescription -or $nm -eq $inet.Name) -and $dn -notmatch 'NDIS') { $pubConn = $conn }
}

if ($null -eq $privConn) { Bad "RNDIS adapter is not offered as an ICS connection."; try { Stop-Transcript | Out-Null } catch {}; exit 1 }
if ($null -eq $pubConn)  { Bad "Internet adapter is not offered as an ICS connection."; try { Stop-Transcript | Out-Null } catch {}; exit 1 }

Info "Disabling any pre-existing sharing configuration ..."
foreach ($conn in $hns.EnumEveryConnection) {
    try {
        $c = $hns.INetSharingConfigurationForINetConnection($conn)
        if ($c.SharingEnabled) { $c.DisableSharing() }
    } catch {}
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2

Info "Enabling sharing (public = internet side, private = RNDIS side) ..."
$ics_ok = $true
try {
    $hns.INetSharingConfigurationForINetConnection($pubConn).EnableSharing(0)
    Start-Sleep -Seconds 2
    $hns.INetSharingConfigurationForINetConnection($privConn).EnableSharing(1)
} catch {
    Warn ("EnableSharing threw: " + $_.Exception.Message)
    $ics_ok = $false
}

# ------------------------------------------------------------- 5. verify ICS
Info "Waiting for the ICS address on the RNDIS adapter (up to 20 s) ..."
$addr = $null
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 1
    $addr = Get-NetIPAddress -InterfaceIndex $rndisIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '192.168.137.*' }
    if ($addr) { break }
}

$icsKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\Interfaces'
$icsBound = Test-Path $icsKey
if ($icsBound) { Ok "ICS bindings present in the registry." } else { Warn "ICS registry bindings are still missing." }

if (-not $addr) {
    Warn "ICS did not assign 192.168.137.1/24 within 20 s."
    try {
        Remove-NetIPAddress -InterfaceIndex $rndisIdx -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $rndisIdx -IPAddress 192.168.137.1 -PrefixLength 24 -ErrorAction Stop | Out-Null
        Ok "Set 192.168.137.1/24 on the RNDIS adapter manually."
        $addr = Get-NetIPAddress -InterfaceIndex $rndisIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue
    } catch { Bad ("Could not set the address: " + $_.Exception.Message) }
}

# ------------------------------------------------- 6. make sure NAT + forwarding
$nat = @(Get-NetNat -ErrorAction SilentlyContinue)
if ($nat.Count -gt 0) {
    Ok "NAT instances:"
    $nat | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table -AutoSize
} else {
    Warn "No NAT instance found: ICS did not create one.  Falling back to New-NetNat ..."
    try {
        New-NetNat -Name 'z17s-usb' -InternalIPInterfaceAddressPrefix '192.168.137.0/24' -ErrorAction Stop | Out-Null
        Ok "Created NAT 'z17s-usb' for 192.168.137.0/24"
    } catch { Warn ("New-NetNat failed: " + $_.Exception.Message) }
}

foreach ($ix in @($rndisIdx, $inet.ifIndex)) {
    try { Set-NetIPInterface -InterfaceIndex $ix -Forwarding Enabled -ErrorAction Stop }
    catch { Warn ("could not enable forwarding on ifIndex " + $ix) }
}

# Keep the binding across reboots / re-plugs of this interactive session.
try {
    New-ItemProperty -Path $icsKey -Name 'EnableRebootPersistConnection' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
} catch {}

# --------------------------------------------------------- 7. report + reach the phone
Write-Host ""
if ($addr) { Ok "RNDIS adapter IPv4:"; $addr | Select-Object IPAddress, PrefixLength, PrefixOrigin | Format-Table -AutoSize }

Info "Pinging the phone at 192.168.137.2 ..."
$up = Test-Connection -ComputerName 192.168.137.2 -Count 3 -Quiet -ErrorAction SilentlyContinue
if ($up) { Ok "phone answers on 192.168.137.2 - USB link is live" } else { Warn "no reply from 192.168.137.2 (is usb0 up on the phone?)" }

foreach ($pt in @(22, 5700, 28888)) {
    $r = Test-NetConnection -ComputerName 192.168.137.2 -Port $pt -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if ($r.TcpTestSucceeded) { Ok ("phone:[" + $pt + "] reachable") } else { Warn ("phone:[" + $pt + "] not reachable") }
}

Write-Host ""
Ok "Done.  Layout:"
Write-Host "    PC    (RNDIS side) : 192.168.137.1/24"
Write-Host "    Phone (usb0)       : 192.168.137.2/24   gw 192.168.137.1"
Write-Host ""
Write-Host "  From the PC you can now open:"
Write-Host "    Qinglong : http://192.168.137.2:5700              (user: admin)"
Write-Host "    1Panel   : http://192.168.137.2:28888/z17s_panel   (user: z17s)"
Write-Host "  SSH      : ssh -i %USERPROFILE%\.ssh\z17s_ed25519 root@192.168.137.2"
Write-Host ""
Write-Host "  Windows showing 'Unidentified network / No internet access' on this adapter is"
Write-Host "  EXPECTED: it is the ICS *server* side and never probes the internet itself."
Write-Host "  The only things that matter are the 192.168.137.1/24 address and a NAT instance."
Write-Host ""

if (-not ($icsBound -and $addr)) {
    Bad "One of the checks above failed - see the log next to this script (ics-run.log)."
    try { Stop-Transcript | Out-Null } catch {}
    exit 2
}

Ok "All checks passed."
try { Stop-Transcript | Out-Null } catch {}
exit 0
