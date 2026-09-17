# MimoProgress.ps1 - live progress console for a delegated MiMo Desktop turn.
#
# Watches the engine-side transcript and prints, in real time:
#   [think] what MiMo is reasoning about (size only)
#   [say  ] the text it is emitting
#   [tool ] every tool call with its own short title (file it edits, command it runs)
#   [file ] files that appear or change under the watched directory
#   ----   a heartbeat line with elapsed time and token spend
#
# It ends by itself when the turn finishes (add -Follow to keep waiting for the
# next one). Safe to run in a second window while work is delegated.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File MimoProgress.ps1
#   ... -SessionId ses_xxx -Dir D:\some\project -IntervalSec 2 -Follow
[CmdletBinding()]
param(
  [string]$SessionId,
  [string]$Dir = 'D:\DSH and MIMOdesktop',
  [int]$IntervalSec = 3,
  [switch]$Follow,
  [switch]$Replay,
  [switch]$NoFiles
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridge = Join-Path $here 'MimoDesktop.ps1'
if (-not (Test-Path $bridge)) { throw "bridge not found: $bridge" }

if (-not $SessionId) {
  $sf = Join-Path $here 'worker-session.txt'
  if (Test-Path $sf) {
    $SessionId = ((Get-Content $sf |
      Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') } |
      Select-Object -First 1)).Trim()
  }
}
if (-not $SessionId) { throw 'no session id: pass -SessionId or fill worker-session.txt' }

function Get-BridgeJson {
  param([string[]]$BridgeArgs)
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $bridge @BridgeArgs 2>$null | Out-String
  if (-not $raw.Trim()) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Get-FileMap {
  param([string]$Root)
  $map = @{}
  if (-not (Test-Path $Root)) { return $map }
  $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' }
  foreach ($f in $items) { $map[$f.FullName] = ($f.Length.ToString() + '|' + $f.LastWriteTimeUtc.Ticks.ToString()) }
  return $map
}

Write-Host ''
Write-Host '  MiMo live progress' -ForegroundColor Cyan
Write-Host "  session : $SessionId"
Write-Host "  workdir : $Dir"
if ($Replay) {
  Write-Host '  mode    : replaying past activity' -ForegroundColor DarkGray
} else {
  Write-Host '  mode    : live (only new activity; -Replay to see history)' -ForegroundColor DarkGray
}
Write-Host '  Ctrl+C to stop' -ForegroundColor DarkGray
Write-Host ''

# Default to "from now" so a watcher started mid-flight shows progress, not the
# whole transcript. -Replay starts from the beginning of the session.
$since = if ($Replay) { [int64]0 } else { [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - 2000 }
$startedAt = Get-Date
$lastBeat = Get-Date
$prevFiles = if ($NoFiles) { @{} } else { Get-FileMap -Root $Dir }
$totalTools = 0
$totalSaid = 0
$totalThink = 0
$prevOut = 0
$prevReason = 0
$turn = 0
$sawRunning = $false
$idleWaits = 0

while ($true) {
  $d = Get-BridgeJson @('progress', '-SessionId', $SessionId, '-Since', "$since", '-Max', '80', '-DetailMax', '110')
  if ($null -eq $d) {
    Write-Host ("{0}  !! bridge call failed (app down?); retrying" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Red
    Start-Sleep -Seconds ([Math]::Max($IntervalSec, 5))
    continue
  }
  # lastAt is "newest activity in the session", which can be OLDER than the
  # cursor when nothing new happened - never let it move backwards, or old
  # events get replayed on the next poll.
  if ($d.lastAt -and [int64]$d.lastAt -gt $since) { $since = [int64]$d.lastAt }
  $totalTools = $totalTools + [int]$d.newTools

  foreach ($e in @($d.events)) {
    switch ([string]$e.kind) {
      'tool' {
        Write-Host ("{0}  [tool ] {1,-16} {2,-9} {3}" -f $e.time, $e.tool, $e.status, $e.detail)
      }
      'text' {
        Write-Host ("{0}  [say  ] {1}" -f $e.time, $e.detail) -ForegroundColor Green
        $totalSaid++
      }
      'reasoning' {
        Write-Host ("{0}  [think] {1}" -f $e.time, $e.detail) -ForegroundColor DarkGray
        $totalThink++
      }
    }
  }

  if (-not $NoFiles) {
    $nowFiles = Get-FileMap -Root $Dir
    foreach ($k in $nowFiles.Keys) {
      if (-not $prevFiles.ContainsKey($k)) {
        Write-Host ("{0}  [file ] + {1}" -f (Get-Date -Format 'HH:mm:ss'), $k.Substring([Math]::Min($Dir.Length + 1, $k.Length))) -ForegroundColor Magenta
      } elseif ($prevFiles[$k] -ne $nowFiles[$k]) {
        Write-Host ("{0}  [file ] ~ {1}" -f (Get-Date -Format 'HH:mm:ss'), $k.Substring([Math]::Min($Dir.Length + 1, $k.Length))) -ForegroundColor Magenta
      }
    }
    $prevFiles = $nowFiles
  }

  $outDelta = [int]$d.totalOutput - $prevOut
  $reasonDelta = [int]$d.totalReason - $prevReason
  $prevOut = [int]$d.totalOutput
  $prevReason = [int]$d.totalReason

  # MiMo can abort its own thinking mid-turn; without this a silent console looks
  # alive forever. Warn once (and keep watching) when nothing new arrives.
  if (@($d.events).Count -gt 0) { $lastActivity = Get-Date; $stallWarned = $false }
  if (-not $lastActivity) { $lastActivity = Get-Date }
  if ($d.running -and -not $stallWarned -and ((Get-Date) - $lastActivity).TotalSeconds -ge 150) {
    Write-Host ("{0}  [stall] nothing new for 150s - MiMo may have stopped thinking" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Red
    $stallWarned = $true
  }

  if (((Get-Date) - $lastBeat).TotalSeconds -ge 30 -and $d.running) {
    $el = (Get-Date) - $startedAt
    Write-Host ("{0}  ---- running {1:hh\:mm\:ss}  say/think {2}/{3}  tools {4}  tokens out {5} think {6} ----" -f `
      (Get-Date -Format 'HH:mm:ss'), $el, $totalSaid, $totalThink, $totalTools, $prevOut, $prevReason) -ForegroundColor Yellow
    $lastBeat = Get-Date
  }

  if ($d.running) { $sawRunning = $true }

  if (-not $d.running) {
    if ($sawRunning) {
      $el = (Get-Date) - $startedAt
      Write-Host ''
      Write-Host ("  turn finished after {0:hh\:mm\:ss}   tools={1}  text={2}  thinking={3}  tokens out={4} think={5}" -f `
        $el, $totalTools, $totalSaid, $totalThink, $prevOut, $prevReason) -ForegroundColor Cyan
      Write-Host ("  transcript: {0} messages" -f $d.messages)
      if (-not $Follow) { break }
      Write-Host '  -Follow: waiting for the next turn...' -ForegroundColor DarkGray
      $sawRunning = $false
      $idleWaits = 0
      $startedAt = Get-Date
      $lastBeat = Get-Date
      $totalTools = 0; $totalSaid = 0; $totalThink = 0
    } else {
      $idleWaits++
      if ($idleWaits -ge 2) {
        Write-Host ("{0}  no turn is running in this session right now." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
        Write-Host '  (delegate something, or run with -Follow to wait for it)'
        if (-not $Follow) { break }
        $idleWaits = 0
      }
    }
  }

  Start-Sleep -Seconds $IntervalSec
}
