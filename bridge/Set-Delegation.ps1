# Set-Delegation.ps1 - one-command on/off switch for the MiMo delegation pipeline.
#
#   -Action status | on | off        (canonical form; -Status / -On / -Off also work)
#
#   on   -> restore the skill into the skills root AND put the enabled rule block
#           back into ~/.dsh/AGENTS.md
#   off  -> park the skill outside the skills root AND neutralise that rule block
#   status (default) -> report the current state
#
# Why both halves: the skill alone is not the pipeline. Even if the skill file is
# gone, the AGENTS.md block is loaded every session and would still tell the model
# to delegate, so the switch has to move both.
#
# WHY THERE ARE NO CHINESE LITERALS IN THIS FILE:
# this script used to embed the rule blocks as here-strings. PowerShell 5.1 reads
# a BOM-less script as ANSI, so the moment an editor rewrote this file without a
# BOM the Chinese was mis-decoded and the script wrote mojibake straight into
# ~/.dsh/AGENTS.md (it happened once). The blocks now live in UTF-8 files that
# are always read explicitly as UTF-8, and this script stays pure ASCII so no
# code page can ever corrupt it again.
[CmdletBinding()]
param(
  [ValidateSet('status', 'on', 'off')]
  [string]$Action = '',
  [switch]$On,
  [switch]$Off,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($On) { $Action = 'on' }
elseif ($Off) { $Action = 'off' }
elseif ($Status) { $Action = 'status' }
elseif (-not $Action) { $Action = 'status' }

$Agents = Join-Path $env:USERPROFILE '.dsh\AGENTS.md'
$Live = Join-Path $env:USERPROFILE '.dsh\skills\mimo-delegate'
$Parked = Join-Path $env:USERPROFILE '.dsh\skills-disabled\mimo-delegate'
$RulesDir = Join-Path $PSScriptRoot 'rules'
$OnFile = Join-Path $RulesDir 'mimo-delegate-on.md'
$OffFile = Join-Path $RulesDir 'mimo-delegate-off.md'
$BeginMarker = '<!-- mimo-delegate:'
$EndMarker = '<!-- /mimo-delegate -->'
$ReplacementChar = [char]0xFFFD
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-RuleBlock {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { throw "rule block file missing: $Path" }
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ($text.Contains($ReplacementChar)) {
    throw "rule block file is not valid UTF-8 (contains U+FFFD): $Path"
  }
  if ($text -notmatch '(?s)^\s*<!-- mimo-delegate:(on|off) -->') {
    throw "rule block file has no marker as its first line: $Path"
  }
  return $text.TrimEnd() + "`n"
}

function Read-Agents {
  if (-not (Test-Path $Agents)) { throw "AGENTS.md not found: $Agents" }
  return [System.IO.File]::ReadAllText($Agents, [System.Text.Encoding]::UTF8)
}

function Set-RuleBlock {
  param([string]$Block)
  $text = Read-Agents
  $i = $text.IndexOf($BeginMarker)
  $j = $text.IndexOf($EndMarker)
  if ($i -lt 0 -or $j -lt 0) {
    throw "marker block not found in $Agents (expected $BeginMarker ... $EndMarker)"
  }
  $j += $EndMarker.Length
  $new = $text.Substring(0, $i) + $Block + $text.Substring($j)
  [System.IO.File]::WriteAllText($Agents, $new, $Utf8NoBom)
  # Verify the write landed verbatim; never leave a half-written rule file.
  $back = [System.IO.File]::ReadAllText($Agents, [System.Text.Encoding]::UTF8)
  if ($back -ne $new) {
    [System.IO.File]::WriteAllText($Agents, $text, $Utf8NoBom)
    throw "AGENTS.md read-back mismatch; previous content restored"
  }
  if ($back.Contains($ReplacementChar)) {
    [System.IO.File]::WriteAllText($Agents, $text, $Utf8NoBom)
    throw "AGENTS.md contains U+FFFD after write; previous content restored"
  }
}

function Get-State {
  $skillLive = Test-Path (Join-Path $Live 'SKILL.md')
  $skillParked = Test-Path (Join-Path $Parked 'SKILL.md')
  $ruleOn = $false
  if (Test-Path $Agents) {
    $txt = [System.IO.File]::ReadAllText($Agents, [System.Text.Encoding]::UTF8)
    $ruleOn = $txt.Contains('<!-- mimo-delegate:on -->')
  }
  return [pscustomobject]@{
    SkillLive   = $skillLive
    SkillParked = $skillParked
    RuleOn      = $ruleOn
  }
}

switch ($Action) {
  'status' {
    $s = Get-State
    Write-Host ("skill file in skills root : {0}" -f $(if ($s.SkillLive) { 'YES' } else { 'no' }))
    Write-Host ("parked copy (disabled)    : {0}" -f $(if ($s.SkillParked) { 'YES' } else { 'no' }))
    Write-Host ("AGENTS.md rule block      : {0}" -f $(if ($s.RuleOn) { 'ON (delegation enabled)' } else { 'OFF (delegation disabled)' }))
    if ($s.SkillLive -and $s.RuleOn) { Write-Host '=> pipeline is ON' -ForegroundColor Green }
    elseif (-not $s.SkillLive -and -not $s.RuleOn) { Write-Host '=> pipeline is OFF' -ForegroundColor Yellow }
    else { Write-Host '=> MIXED state - run on or off to make it consistent' -ForegroundColor Red }
    break
  }

  'off' {
    $block = Get-RuleBlock -Path $OffFile
    if (Test-Path (Join-Path $Live 'SKILL.md')) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Parked) | Out-Null
      if (Test-Path $Parked) { Remove-Item $Parked -Recurse -Force }
      Move-Item -LiteralPath $Live -Destination $Parked -Force
      Write-Host "skill parked  -> $Parked" -ForegroundColor Yellow
    } else {
      Write-Host 'skill already not in the skills root'
    }
    Set-RuleBlock -Block $block
    Write-Host 'AGENTS.md rule block -> OFF' -ForegroundColor Yellow
    Write-Host 'delegation is now OFF' -ForegroundColor Yellow
    break
  }

  'on' {
    $block = Get-RuleBlock -Path $OnFile
    if (Test-Path (Join-Path $Parked 'SKILL.md')) {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Live) | Out-Null
      if (Test-Path $Live) { Remove-Item $Live -Recurse -Force }
      Move-Item -LiteralPath $Parked -Destination $Live -Force
      Write-Host "skill restored -> $Live" -ForegroundColor Green
    } elseif (Test-Path (Join-Path $Live 'SKILL.md')) {
      Write-Host 'skill already in place'
    } else {
      throw "no skill copy found (neither $Live nor $Parked) - restore from the session transcript"
    }
    Set-RuleBlock -Block $block
    Write-Host 'AGENTS.md rule block -> ON' -ForegroundColor Green
    Write-Host 'delegation is now ON' -ForegroundColor Green
    break
  }
}
