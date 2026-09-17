# Check-Drift.ps1 - fails when the skill no longer matches the bridge.
#
# The rule is "every change to the bridge updates the skill". This turns that
# promise into a check: it compares the bridge's declared version + action list
# against the version stamp and action table in SKILL.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Check-Drift.ps1
#
# Exit code 0 = in sync, 1 = drift (details on stdout).
[CmdletBinding()]
param(
  # Defaults to whatever the bridge's `version` action reports, so the skill
  # path lives in exactly one place (the bridge).
  [string]$SkillPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridge = Join-Path $here 'MimoDesktop.ps1'

if (-not (Test-Path $bridge)) { Write-Host "FAIL bridge not found: $bridge"; exit 1 }

$raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $bridge version 2>$null | Out-String
if (-not $raw.Trim()) { Write-Host 'FAIL could not read bridge version'; exit 1 }
$info = $raw | ConvertFrom-Json

if (-not $SkillPath) { $SkillPath = $info.skill }
if (-not $SkillPath -or -not (Test-Path $SkillPath)) {
  # A deliberately disabled pipeline parks the skill outside the skills root
  # (Set-Delegation.ps1 -Off). That is a valid state, not drift.
  $parked = ''
  if ($SkillPath) { $parked = $SkillPath.Replace('\skills\', '\skills-disabled\') }
  if ($parked -and (Test-Path $parked)) {
    Write-Host "DISABLED: skill parked at $parked (delegation switched off by the user)"
    Write-Host 'IN SYNC (pipeline intentionally off)' -ForegroundColor Yellow
    exit 0
  }
  Write-Host "FAIL skill not found: $SkillPath"
  exit 1
}

$skill = [System.IO.File]::ReadAllText($SkillPath, [System.Text.Encoding]::UTF8)
$problems = @()

# 1) version stamp
$stampPattern = 'bridge-version:\s*([0-9][0-9A-Za-z.\-]*)'
$m = [regex]::Match($skill, $stampPattern)
if (-not $m.Success) {
  $problems += "skill has no 'bridge-version:' stamp (bridge is $($info.version))"
} elseif ($m.Groups[1].Value -ne $info.version) {
  $problems += "version mismatch: bridge=$($info.version) skill=$($m.Groups[1].Value)"
}

# 2) two-way action diff against the skill's action table rows (| `name` | ...)
$documented = @()
foreach ($mm in [regex]::Matches($skill, '(?m)^\|\s*`([a-zA-Z]+)`\s*\|')) {
  $documented += $mm.Groups[1].Value
}
$documented = @($documented | Sort-Object -Unique)
$actual = @($info.actions | Sort-Object -Unique)

$missing = @($actual | Where-Object { $documented -notcontains $_ })
$stale = @($documented | Where-Object { $actual -notcontains $_ })
if ($missing.Count -gt 0) { $problems += "not documented in skill: $($missing -join ', ')" }
if ($stale.Count -gt 0) { $problems += "documented but gone from bridge: $($stale -join ', ')" }

Write-Host ("bridge   : v{0}  ({1} actions)" -f $info.version, $actual.Count)
Write-Host ("skill    : {0}" -f $SkillPath)
Write-Host ("documented: {0} actions" -f $documented.Count)

if ($problems.Count -eq 0) {
  Write-Host 'IN SYNC' -ForegroundColor Green
  exit 0
}
Write-Host 'DRIFT DETECTED - update the skill before shipping the bridge change:' -ForegroundColor Red
foreach ($p in $problems) { Write-Host ("  - " + $p) -ForegroundColor Red }
Write-Host "  bump rule: raise `$BridgeVersion in MimoDesktop.ps1 and the 'bridge-version:' stamp in SKILL.md together"
exit 1
