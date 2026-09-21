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
  [int]    $StallWarnSec = 90
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
function Get-CandidatePorts {
  $list = New-Object System.Collections.Generic.List[string]
  # 1) 首选：已知的 acm console（VID 0525 + PID A4A2，PnP 状态 OK）
  try {
    Get-PnpDevice -Class Ports -ErrorAction Stop |
      Where-Object { $_.InstanceId -like '*VID_0525*' -and $_.Status -eq 'OK' } |
      ForEach-Object {
        if ($_.FriendlyName -match '\((COM\d+)\)') { [void]$list.Add($Matches[1]) }
      }
  } catch { }
  # 1.5) Hard-exclude on-board physical serial ports (ACPI\PNP0501 etc).
  #      Real bug we hit: after COM15 disappeared, the on-board COM1 from
  #      SERIALCOMM was still openable, so the logger latched onto COM1 forever
  #      -- status said "port=COM1 idle", i.e. it *looked* like it was recording
  #      while actually reading a dead port, and it never switched back when the
  #      device re-enumerated on COM15.
  $onboard = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  try {
    Get-PnpDevice -Class Ports -ErrorAction Stop |
      Where-Object { $_.InstanceId -like 'ACPI\*' } |
      ForEach-Object {
        if ($_.FriendlyName -match '\((COM\d+)\)') { [void]$onboard.Add($Matches[1]) }
      }
  } catch { }
  if ($onboard.Count -eq 0) { [void]$onboard.Add('COM1') }   # PnP scan failed -> fallback
  # 2) Next: ports registered in the registry (skip on-board ones)
  try {
    $props = (Get-ItemProperty -Path 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM').PSObject.Properties
    foreach ($p in $props) {
      if ($p.Name -like 'PS*') { continue }
      if ("$($p.Value)" -match '^COM\d+$' -and -not $onboard.Contains("$($p.Value)")) {
        [void]$list.Add("$($p.Value)")
      }
    }
  } catch { }
  # 3) Fallback: usual suspects (also skip on-board)
  foreach ($c in @('COM15','COM16','COM14','COM13','COM12','COM11','COM9')) {
    if (-not $onboard.Contains($c)) { [void]$list.Add($c) }
  }
  return ($list | Select-Object -Unique)
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

# ---------------------------------------------------------------- 主流程
$candidates = if ($PortName -eq 'auto') { Get-CandidatePorts } else { @($PortName) }
Write-Host-Line ("[logger] candidate ports: " + ($candidates -join ', '))

# Do NOT exit when no port is found. A dead logger means nobody reads the
# device console, and an unread console can block PID1's write() forever ->
# the boot hangs hard and silently (see docs/修复记录.md §7.1). Waiting is safe.
$open = @{ Ok = $false; Port = $null; Name = $null }
while (-not $open.Ok) {
  $open = Open-SerialPort -Candidates $candidates
  if (-not $open.Ok) {
    Write-Host-Line "[logger] no device port yet - plug in the Z17S USB cable, waiting ${ReopenDelayS}s..."
    Start-Sleep -Seconds $ReopenDelayS
    if ($PortName -eq 'auto') { $candidates = Get-CandidatePorts }
  }
}
$sp = $open.Port
$portName = $open.Name

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
    'state='          + $State,
    'log_file='       + (Split-Path $lf.Path -Leaf),
    'total_bytes='    + $totalBytes,
    'last_data='      + $(if ($lastData)  { $lastData.ToString('yyyy-MM-dd HH:mm:ss') }  else { '(none)' }),
    'last_heartbeat=' + $(if ($lastHeart) { $lastHeart.ToString('yyyy-MM-dd HH:mm:ss') } else { '(none)' }),
    'last_probe='     + $lastProbe,
    'reconnects='     + $reconnects
  )
  try { [System.IO.File]::WriteAllText($StatusFile, ($lines -join "`r`n") + "`r`n") } catch { }
}

# Ctrl+C 也要把收尾信息写进去
try {
  Stamp 'logger start'
  Write-Chunk ("[PC] Z17S serial logger | port=$portName baud=$Baud out=$OutDir`r`n")
  Write-Host-Line "[logger] recording $portName -> $($lf.Path)"
  Write-Host-Line "[logger] Ctrl+C to stop."

  while (-not $stop) {
    # --- 端口掉了就重连（重启前后 COM 会消失，必须等一会再试）
    if ($null -eq $sp -or -not $sp.IsOpen) {
      Stamp 'port lost - waiting to reconnect'
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
        $portName = $re.Name
        $reconnects++
        Stamp 'port reopened'
        Write-Host-Line "[logger] reopened $portName (reconnect #$reconnects)"
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
        if ($probe.Contains('z17s-hb')) { $lastHeart = Get-Date }
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
