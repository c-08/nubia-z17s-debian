<#
.SYNOPSIS
  Z17S 串口持续记录器：把设备 console 输出实时落盘到 PC。

.DESCRIPTION
  为什么需要它（这是整套日志方案里唯一"整机停摆也能拿到证据"的一环）：

    09-21 设备跑 RCU stall 卡死时，屏幕和串口一直在刷 stall 报告，
    但 journald 里一条都没有 —— 因为整机停摆时用户态进程完全不被调度，
    连 journald 都读不了 /dev/kmsg。设备侧再怎么加脚本也救不了这一刻。

    唯一出路是让 PC 侧一直"趴"在串口上录：console 输出走的是 printk 原子路径，
    不需要用户态参与，所以停摆现场照样能出来。

  顺带的好处：串口 console 在无人读取时写满缓冲会阻塞，之前就因此把
  systemd PID1 卡死过 82 分钟。PC 侧持续读，等于顺手把这个雷也拆了。

  特性：
    - 自动探测 COM 口，断线自动重连（重启前后 COM 会掉）
    - 每块数据前打 PC 侧时间戳锚点，卡死时刻一眼可见
    - 识别设备心跳 z17s-hb，超时即在日志里显式告警
    - 按大小轮转，旧文件自动清理
    - 每次写入都 Flush($true) 真正落盘，不怕 PC 侧突然关机

.PARAMETER PortName
  'auto'（默认）自动探测；也可写死 'COM15'。

.PARAMETER DrainSeconds
  Seconds right after opening the port during which incoming data is treated as
  BACKLOG (device output that piled up while nobody was reading). Backlog heartbeats
  are tagged and never used as a boot-time anchor. Default 4. Raise it if the device
  has been unread for a long time and the backlog bursts out slowly.

.EXAMPLE
  .\z17s-serial-log.ps1
  .\z17s-serial-log.ps1 -PortName COM15 -OutDir D:\z17s-log
#>
[CmdletBinding()]
param(
  [string] $PortName     = 'auto',
  [string] $OutDir       = '',
  [int]    $Baud         = 115200,
  [int]    $MaxFileMB    = 16,
  [int]    $KeepFiles    = 40,
  [int]    $PollMs       = 150,
  [int]    $ReopenDelayS = 6,
  [int]    $StallWarnSec = 90,
  [int]    $DrainSeconds = 4,
  [int]    $EarlyFallbackSec = 180,
  [switch] $WatchEarlyConsole
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $PSScriptRoot 'serial-log'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$StatusFile = Join-Path $OutDir 'serial-log.status'

function Write-Host-Line {
  param([string]$Text)
  Write-Host $Text
}

# ---------------------------------------------------------------- 串口探测
# Only ever open a port that is BOTH present (PnP Status = OK) and belongs to a
# Linux USB gadget (VID_0525). Two real accidents drove this rewrite:
#
#   (1) After the device re-enumerated, the on-board COM1 (ACPI\PNP0501) was
#       still openable, so the logger latched onto COM1 and reported
#       "state=idle" forever -- it *looked* like it was recording.
#   (2) 2026-09-22 21:07: the device rebuilds its gadget at boot+45s, so the
#       old COM number becomes a phantom entry with Status=Unknown. The logger
#       opened that phantom (COM11) anyway, read one block, then looped on
#       "still no port". Meanwhile nobody drained the real console.
#
# Therefore: no SERIALCOMM registry scan, no guessed COM list. Present +
# VID_0525 only. If nothing matches we wait -- which is the correct behaviour,
# because the console only needs a reader while the device is actually there.
#
# Gadget PIDs seen on this phone:
#   A4A7 - early/legacy gadget that carries the boot console (appears ~10s in).
#          Built by `modprobe g_serial` in z17s-early.service: **serial only,
#          no RNDIS**, so the host's COM handle is the ONLY thing the PC side
#          can hold on it.
#   A4A2 - our configfs composite (RNDIS + ACM), built at boot+45s by
#          z17s-usbnet.sh.
#
# (3) 2026-09-22 -- WHY WE NO LONGER HOLD A4A7 BY DEFAULT.
#     At boot+45s z17s-usbnet.sh runs `modprobe -r g_serial` and rebuilds the
#     whole gadget. If a host holds the old ACM port open at that instant,
#     gs_close() waits for the port (u_serial.c:691) and the unbind wedges --
#     ttyGS0 is destroyed while the kernel console still points at it, so
#     PID1's write to /dev/console blocks forever: the "half-dead" state of
#     docs/修复记录.md §17, recoverable only by a 15s power-button hold.
#     A/B test the same night: boot with the cable unplugged (nobody holds the
#     port) -> the +49s rebuild went through cleanly, gs_close WARN count 0,
#     RCU stall count 0, device fully healthy. Conclusion: the PC-side holder
#     is the necessary ingredient.
#     Therefore the logger now only ever opens A4A2 (the FINAL composite, built
#     after the rebuild, so holding it is harmless). It deliberately skips
#     A4A7 and waits instead. Cost: the 0..45s window is not captured live --
#     but nothing is lost, because the kernel console is registered with
#     CON_PRINTBUFFER, so the early log is replayed as soon as somebody drains
#     the port after the rebuild (observed 2026-09-22: messages from uptime
#     20..26s arrived at uptime 127s on the new gadget).
#     Use -WatchEarlyConsole to opt back in when you accept the risk (e.g. you
#     are debugging kernel init and have unplugged the RNDIS side by hand).
function Get-PhonePortInfo {
  param([switch]$IncludeEarly)
  # -WatchEarlyConsole (script scope) opts the whole logger back in; keep call
  # sites unchanged so the policy can never be missed at one of them.
  $wantEarly = $IncludeEarly -or [bool]$script:WatchEarlyConsole
  $found = New-Object System.Collections.Generic.List[object]
  $devs = $null
  try { $devs = @(Get-PnpDevice -Class Ports -Status OK -ErrorAction Stop) } catch { return $found }
  foreach ($d in $devs) {
    if ($d.InstanceId -notlike 'USB\VID_0525&PID_*') { continue }
    $com = $null
    if ($d.FriendlyName -match '\((COM\d+)\)') { $com = $Matches[1] }
    if (-not $com) { continue }
    $pid4 = ''
    if ($d.InstanceId -match 'PID_([0-9A-Fa-f]{4})') { $pid4 = $Matches[1].ToUpper() }
    if ($pid4 -ne 'A4A2' -and -not $wantEarly) {
      Write-Host-Line "[logger] SKIP $com (PID $pid4): early boot console, holding it can wedge the device at boot+45s"
      continue
    }
    # composite gadget: the ACM node is "...\PID_A4A2&MI_02\<hub node>"
    $mi = ''
    if ($d.InstanceId -match '&MI_(\d+)') { $mi = $Matches[1] }
    $node = ''
    $ix = $d.InstanceId.LastIndexOf('\')
    if ($ix -ge 0 -and $ix -lt ($d.InstanceId.Length - 1)) { $node = $d.InstanceId.Substring($ix + 1) }
    $found.Add([pscustomobject]@{ Com = $com; InstanceId = $d.InstanceId; Pid = $pid4; Mi = $mi; Node = $node })
  }
  # A4A2 (the final RNDIS+ACM composite) is the one we want to hold.
  return @($found | Sort-Object @{ Expression = { if ($_.Pid -eq 'A4A2') { 0 } else { 1 } } })
}

function Get-CandidatePorts {
  $info = Get-PhonePortInfo
  if ($info.Count -gt 0) { return @($info | ForEach-Object { $_.Com }) }
  # Last resort for hosts without the PnpDevice module: enumerate port names but
  # never touch the on-board ACPI serial port. Deliberately noisy in the log.
  try {
    $names = @([System.IO.Ports.SerialPort]::GetPortNames() | Where-Object { $_ -ne 'COM1' })
    if ($names.Count -gt 0) {
      Write-Host-Line "[logger] WARN Get-PnpDevice found no gadget; falling back to raw port list: $($names -join ', ')"
      return $names
    }
  } catch { }
  return @()
}

function Open-SerialPort {
  param([string[]]$Candidates)
  foreach ($name in $Candidates) {
    $sp = $null
    try {
      $sp = New-Object System.IO.Ports.SerialPort $name, $Baud, 'None', 8, 'One'
      $sp.ReadTimeout   = [Math]::Max(200, $PollMs)
      $sp.WriteTimeout  = 1000
      $sp.DtrEnable     = $true
      $sp.RtsEnable     = $true
      $sp.Open()
      return @{ Ok = $true; Port = $sp; Name = $name }
    } catch {
      if ($sp) { try { $sp.Dispose() } catch { } }
    }
  }
  return @{ Ok = $false; Port = $null; Name = $null }
}

# ---------------------------------------------------------------- 日志文件
function New-LogFile {
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $path  = Join-Path $OutDir ("serial-$stamp.log")
  $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Append,
                                        [System.IO.FileAccess]::Write,
                                        [System.IO.FileShare]::ReadWrite)
  return @{ Stream = $fs; Path = $path }
}

function Remove-OldLogs {
  $files = Get-ChildItem -LiteralPath $OutDir -Filter 'serial-*.log' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime
  if ($files.Count -le $KeepFiles) { return }
  $files | Select-Object -First ($files.Count - $KeepFiles) | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
  }
}

# ------------------------------------------------------------------ 句柄保鲜
# 真事故：设备在开机 +45 秒重建 gadget，COM15 被摘掉又重新枚举，而记录器
# 手里还攥着旧句柄 —— IsOpen 仍是 true、Read() 不报错、也永远读不到字节，
# status 于是长期显示 "state=idle total_bytes=0"，看着像"设备卡死"，
# 其实卡死的是记录器自己（它从 23:27 一直骗到重启）。
# 判据：这个 COM 号背后的 PnP InstanceId 变了（或消失了）→ 旧句柄作废。
# ⚠️ 必须只认 Status=OK 的节点：同一个 COM 号会留下 Status=Unknown 的幽灵条目，
#    不筛的话会一直返回幽灵的 InstanceId，保鲜逻辑反而永不触发。
function Get-PortInstanceId {
  param([string]$Com)
  if (-not $Com) { return $null }
  try {
    $dev = Get-PnpDevice -Class Ports -Status OK -ErrorAction Stop |
           Where-Object { $_.InstanceId -notlike 'ACPI\*' -and $_.FriendlyName -match "\($Com\)" } |
           Select-Object -First 1
    if ($dev) { return $dev.InstanceId }
  } catch { }
  return $null
}

function Get-PortInfoOf {
  param([string]$Com)
  if (-not $Com) { return $null }
  $hit = Get-PhonePortInfo | Where-Object { $_.Com -eq $Com } | Select-Object -First 1
  return $hit
}

# ---------------------------------------------------------------- 主流程
$candidates = if ($PortName -eq 'auto') { Get-CandidatePorts } else { @($PortName) }
$info0 = @(Get-PhonePortInfo)
Write-Host-Line ("[logger] policy: " + $(if ($WatchEarlyConsole) {
    'WATCH-EARLY-CONSOLE (A4A7 allowed) - accept the boot+45s wedge risk' }
  else { 'final composite only (PID A4A2); A4A7 is skipped on purpose' }))
Write-Host-Line ("[logger] gadget ports present: " + $(if ($info0.Count -gt 0) {
    (($info0 | ForEach-Object { "$($_.Com)(PID $($_.Pid))" }) -join ', ') } else { '(none)' }))

# Do NOT exit when no port is found. A dead logger means nobody reads the
# device console, and an unread console can block PID1's write() forever ->
# the boot hangs hard and silently (see docs/修复记录.md §7.1). Waiting is safe.
$open = @{ Ok = $false; Port = $null; Name = $null }
$waitStart = Get-Date
while (-not $open.Ok) {
  $open = Open-SerialPort -Candidates $candidates
  if (-not $open.Ok) {
    Write-Host-Line "[logger] no device port yet - plug in the Z17S USB cable, waiting ${ReopenDelayS}s..."
    Start-Sleep -Seconds $ReopenDelayS
    if (-not $WatchEarlyConsole -and
        ((Get-Date) - $waitStart).TotalSeconds -ge $EarlyFallbackSec) {
      # The composite never came up at all -> the device is most likely sitting
      # in the g_serial rollback state (z17s-usbnet.sh failed to build A4A2).
      # In that state A4A7 *is* the final console and no further teardown will
      # happen, so waiting forever would just leave us blind. Take it, loudly.
      $script:WatchEarlyConsole = $true
      Write-Host-Line ("[logger] WARN no A4A2 after ${EarlyFallbackSec}s - falling back to the early " +
        "console (A4A7). The composite gadget probably failed to build; check " +
        "/var/log/z17s-usbnet.log on the device.")
    }
    if ($PortName -eq 'auto') { $candidates = Get-CandidatePorts }
  }
}
$sp = $open.Port
$portName = $open.Name
# drain window after opening the port: data arriving inside it is treated as backlog
# (see the $drainUntil note further down)
$drainUntil = (Get-Date).AddSeconds($DrainSeconds)
$hbFresh    = $false
$portInfo = Get-PortInfoOf $portName
$portPid  = if ($portInfo) { $portInfo.Pid } else { '' }
$portMi   = if ($portInfo) { $portInfo.Mi } else { '' }
$portNode = if ($portInfo) { $portInfo.Node } else { '' }

$lf      = New-LogFile
$fs      = $lf.Stream
Remove-OldLogs

$buf         = New-Object char[] 8192
$totalBytes  = 0
$reconnects  = 0
$lastData    = $null
$lastHeart   = $null
$hbTail      = ''            # 心跳识别的滚动尾巴：USB 分包可能把 "z17s-hb" 拆到两块里
$lastProbe   = ''            # 诊断用：最近一块数据的可打印形式（写进 status）
$lastStallWarn = $null
$lastStatus  = (Get-Date)
$lastCleanup = (Get-Date)
$portInst    = if ($portInfo) { $portInfo.InstanceId } else { Get-PortInstanceId $portName }
$lastPortCk  = Get-Date
$hbUptime    = $null          # 心跳里带的设备 uptime，用来识别"刚开机"
$devBootAt   = $null          # 推算出的设备开机时刻
$bootLogged  = $false         # 只标一次"本次日志覆盖了一次冷启动"
# NOTE (ASCII only - PS 5.1 reads BOM-less files as ANSI and CJK breaks parsing):
#   Opening the port first delivers BACKLOG: while nobody was reading /dev/ttyGS0 the
#   device kept writing (logwatch heartbeat every 10s) and those bytes piled up in the
#   tty buffer, so they all rush out at once on open. They are NOT "just now".
#   Deriving the boot time from them is wildly wrong (measured: real boot 21:22 was
#   reported as 22:31, because the oldest backlog heartbeat was uptime=1871 from 21:53).
#   So after opening we run a drain window; heartbeats inside it are tagged backlog and
#   are never used as a time anchor.
$drainUntil  = $null          # end of the drain window; heartbeats before it may be backlog
$hbFresh     = $false         # have we seen a FRESH (non-backlog) heartbeat yet
$devBootSrc  = ''             # where dev_boot_at came from: fresh / backlog
$backlogNoted = $false        # the backlog notice is written to the log only once
$stop        = $false

function Write-Chunk {
  param([string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $fs.Write($bytes, 0, $bytes.Length)
  $fs.Flush($true)          # $true = FlushFileBuffers，真落盘
}

function Stamp {
  param([string]$Tag)
  Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') + " " + $Tag + "]`r`n")
}

function Write-Status {
  param([string]$State)
  $now = Get-Date
  $lines = @(
    'pc_time='        + $now.ToString('yyyy-MM-dd HH:mm:ss'),
    'port='           + $portName,
    'port_pid='       + $portPid,
    'port_mi='        + $portMi,
    'port_node='      + $portNode,
    'state='          + $State,
    'log_file='       + (Split-Path $lf.Path -Leaf),
    'total_bytes='    + $totalBytes,
    'last_data='      + $(if ($lastData)  { $lastData.ToString('yyyy-MM-dd HH:mm:ss') }  else { '(none)' }),
    'last_heartbeat=' + $(if ($lastHeart) { $lastHeart.ToString('yyyy-MM-dd HH:mm:ss') } else { '(none)' }),
    'hb_uptime_s='    + $(if ($null -ne $hbUptime) { $hbUptime } else { '(none)' }),
    'dev_boot_at='    + $(if ($devBootAt) { $devBootAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '(unknown)' }),
    # dev_boot_at is only trustworthy when hb_src=fresh; =backlog means we have not yet
    # seen a fresh heartbeat (backlog data can skew the boot time by tens of minutes)
    'hb_src='         + $(if ($devBootSrc) { $devBootSrc } else { '(none)' }),
    'last_probe='     + $lastProbe,
    'reconnects='     + $reconnects
  )
  try { [System.IO.File]::WriteAllText($StatusFile, ($lines -join "`r`n") + "`r`n") } catch { }
}

# Ctrl+C 也要把收尾信息写进去
try {
  Stamp 'logger start'
  Write-Chunk ("[PC] Z17S serial logger | port=$portName pid=$portPid mi=$portMi node=$portNode baud=$Baud out=$OutDir`r`n")
  Write-Chunk ("[PC] gadget PID legend: A4A7=early boot console, A4A2=final RNDIS+ACM composite (built by z17s-usbnet.sh at boot+45s)`r`n")
  Write-Host-Line "[logger] recording $portName -> $($lf.Path)"
  Write-Host-Line "[logger] Ctrl+C to stop."

  while (-not $stop) {
    # --- 端口掉了就重连（重启前后 COM 会消失，必须等一会再试）
    if ($null -eq $sp -or -not $sp.IsOpen) {
      Stamp ("port lost (" + $portName + " PID " + $portPid + ")" +
             $(if ($devBootAt) { ", device uptime ~" + [int]((Get-Date) - $devBootAt).TotalSeconds + "s" } else { '' }) +
             " - waiting to reconnect")
      Write-Status 'reconnecting'
      try { if ($sp) { $sp.Dispose() } } catch { }
      $sp = $null
      Start-Sleep -Seconds $ReopenDelayS
      # Re-scan every time: the COM number almost always changes after re-enumeration
      if ($PortName -eq 'auto') {
        $candidates = Get-CandidatePorts
        Write-Host-Line ("[logger] re-scan candidates: " + ($candidates -join ', '))
      }
      $re = Open-SerialPort -Candidates $candidates
      if ($re.Ok) {
        $sp = $re.Port
        $oldName = $portName
        $oldInst = $portInst
        $oldPid  = $portPid
        $portName = $re.Name
        $portInfo = Get-PortInfoOf $portName
        $portInst = if ($portInfo) { $portInfo.InstanceId } else { Get-PortInstanceId $portName }
        $portPid  = if ($portInfo) { $portInfo.Pid } else { '' }
        $portMi   = if ($portInfo) { $portInfo.Mi } else { '' }
        $portNode = if ($portInfo) { $portInfo.Node } else { '' }
        $reconnects++
        # after a reconnect the backlog piled up during the outage floods out too
        $drainUntil = (Get-Date).AddSeconds($DrainSeconds)
        $hbFresh    = $false
        $bootLogged = $false
        $backlogNoted = $false
        Stamp 'port reopened'
        Write-Host-Line "[logger] reopened $portName (PID $portPid, reconnect #$reconnects)"
        # 设备换了 COM 号 = gadget 被重建。这是"开机 +45 秒自伤"的现场指纹，
        # 必须显式写进日志，否则以后翻日志只会看到一次莫名其妙的断流。
        if ($oldInst -and $portInst -and $oldInst -ne $portInst) {
          Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') +
                       " device RE-ENUMERATED: $oldName (PID $oldPid) -> $portName (PID $portPid)" +
                       " - gadget was rebuilt" + $(if ($devBootAt) {
                           ", device uptime ~" + [int]((Get-Date) - $devBootAt).TotalSeconds + "s" } else { '' }) + "]`r`n")
        }
      } else {
        Write-Host-Line "[logger] still no port, retrying..."
      }
      continue
    }

    # --- 读
    $got = $false
    try {
      $n = $sp.Read($buf, 0, $buf.Length)
      if ($n -gt 0) {
        $text = -join $buf[0..($n - 1)]
        $totalBytes += $n
        $got = $true

        # 静默超过 2 秒后重新来数据，打一个时间锚点
        if ($null -eq $lastData -or ((Get-Date) - $lastData).TotalSeconds -gt 2) {
          Stamp 'data'
        }
        $lastData = Get-Date

        # 心跳识别：把上一块的尾巴拼进来一起找。
        # ⚠️ 不能只看单块 —— USB CDC/ACM 会分包，一行 42 字节可能被切成两块，
        #    而 "z17s-hb" 恰好跨在切点上时就漏检（曾因此误报"设备卡死"）。
        $probe = $hbTail + $text
        if ($probe.Contains('z17s-hb')) {
          $lastHeart = Get-Date
          # Heartbeat looks like "z17s-hb uptime=47 load=0.74/0.20/0.07".
          # uptime is the only anchor that tells whether this log starts at a cold boot,
          # and it is what lets us derive the device boot time.
          #
          # BUT what arrives right after opening the port is BACKLOG (old heartbeats that
          # piled up while nobody was reading). Deriving the boot time from it is off by
          # tens of minutes (measured: 69 min). Discriminators:
          #   (a) inside the drain window right after open, or
          #   (b) this block carries several heartbeats (backlog bursts out, a fresh
          #       heartbeat only comes once every 10s)
          # -> treat as backlog: tag it, never use it as a time anchor.
          # count on $text, NOT on $probe: $probe carries a 16-char tail of the previous
          # block, and if that tail happens to end exactly on "z17s-hb" a single fresh
          # heartbeat would be miscounted as two and wrongly classified as backlog.
          $hbCount = ([regex]::Matches($text, 'z17s-hb')).Count
          $isBacklog = $false
          if (-not $hbFresh) {
            if ($drainUntil -and (Get-Date) -lt $drainUntil) { $isBacklog = $true }
            elseif ($hbCount -ge 2)                          { $isBacklog = $true }
          }
          if ($probe -match 'uptime=(\d+)') {
            $hbUptime = [int]$Matches[1]
            if ($isBacklog) {
              # backlog: record the derived value in status but tag it, so nobody trusts it
              if (-not $devBootAt -or $devBootSrc -ne 'fresh') {
                $devBootAt  = (Get-Date).AddSeconds(-$hbUptime)
                $devBootSrc = 'backlog'
              }
              if (-not $backlogNoted) {
                $backlogNoted = $true
                Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') +
                             " NOTE everything below until the next 'device boot @ ... (fresh)'" +
                             " line is BACKLOG - buffered device output from before this logger" +
                             " opened the port. Its uptime values are in the past and MUST NOT" +
                             " be used as a time anchor.]`r`n")
              }
            } else {
              $devBootAt  = (Get-Date).AddSeconds(-$hbUptime)
              $devBootSrc = 'fresh'
              if (-not $hbFresh) {
                $hbFresh = $true
                Write-Host-Line ("[logger] first fresh heartbeat: device boot @ " +
                  $devBootAt.ToString('HH:mm:ss') + " (uptime " + $hbUptime + "s)")
              }
              if (-not $bootLogged) {
                $bootLogged = $true
                Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') +
                             " device boot @ " + $devBootAt.ToString('HH:mm:ss') +
                             " (uptime " + $hbUptime + "s, fresh) - gadget rebuild expected @ " +
                             $devBootAt.AddSeconds(45).ToString('HH:mm:ss') + "]`r`n")
              }
            }
          }
        }
        $hbTail = if ($probe.Length -gt 16) { $probe.Substring($probe.Length - 16) } else { $probe }

        # 诊断：把这一块的可打印形式写进 status，出问题时一眼看清到底收到了什么
        $lastProbe = ($text -replace '[^\x20-\x7E]', '?')
        if ($lastProbe.Length -gt 50) { $lastProbe = $lastProbe.Substring(0, 50) }

        Write-Chunk $text
      }
    }
    catch [System.TimeoutException] {
      # 正常：这一段没有数据
    }
    catch {
      Write-Host-Line ("[logger] read error: " + $_.Exception.Message)
      Stamp 'read error'
      try { $sp.Close() } catch { }
      $sp = $null
      continue
    }

    # --- 心跳停摆告警：只有"曾经收到过心跳"才启用，否则没装 logwatch 会误报
    if ($null -ne $lastHeart) {
      $age = ((Get-Date) - $lastHeart).TotalSeconds
      if ($age -gt $StallWarnSec) {
        if ($null -eq $lastStallWarn -or ((Get-Date) - $lastStallWarn).TotalSeconds -gt $StallWarnSec) {
          Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') +
                       " !! NO z17s-hb HEARTBEAT for " + [int]$age + "s (last " +
                       $lastHeart.ToString('HH:mm:ss') + ") - device may be stalled !!]`r`n")
          $lastStallWarn = Get-Date
        }
      } else {
        $lastStallWarn = $null
      }
    }

    # --- 轮转
    if ($fs.Length -gt ($MaxFileMB * 1MB)) {
      Stamp 'log rotated'
      try { $fs.Flush($true); $fs.Close() } catch { }
      $lf = New-LogFile
      $fs = $lf.Stream
      Write-Host-Line "[logger] rotated -> $($lf.Path)"
    }

    # --- 状态文件每 10 秒刷新一次
    if (((Get-Date) - $lastStatus).TotalSeconds -ge 10) {
      Write-Status $(if ($got) { 'reading' } else { 'idle' })
      $lastStatus = Get-Date

      # --- 句柄保鲜：设备重枚举过就把这个死句柄换掉（见 Get-PortInstanceId 注释）
      $nowInst = Get-PortInstanceId $portName
      if ($nowInst -ne $portInst) {
        Write-Chunk ("`r`n[PC " + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') +
                     " !! COM instance changed (" + $portInst + " -> " + $nowInst +
                     ") - closing stale handle !!]`r`n")
        Write-Host-Line "[logger] stale handle on $portName, reopening..."
        try { if ($sp) { $sp.Close() } } catch { }
        try { if ($sp) { $sp.Dispose() } } catch { }
        $sp = $null
      }
    }

    # --- 每小时清一次旧日志
    if (((Get-Date) - $lastCleanup).TotalSeconds -ge 3600) {
      Remove-OldLogs
      $lastCleanup = Get-Date
    }

    Start-Sleep -Milliseconds $PollMs
  }
}
finally {
  try { Stamp 'logger stop' } catch { }
  try { if ($fs) { $fs.Flush($true); $fs.Close() } } catch { }
  try { if ($sp -and $sp.IsOpen) { $sp.Close() } } catch { }
  Write-Host-Line "[logger] stopped. log: $($lf.Path)"
}
