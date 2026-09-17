# Sync-GitHub.ps1 - keep the GitHub copy of this tooling up to date.
#
#   -Action status   (default) show uncommitted work and local-vs-remote drift
#   -Action push -Message "..."  mirror the bridge files into the repo, commit,
#                                and push main + tags
#
# Why a mirror instead of moving the files: the live tooling lives in
# D:\Deepseek Harness\_mimo_bridge and every skill / AGENTS.md / plugin setting
# references it by absolute path. Mirroring the tracked files into the plugin
# repo's bridge\ folder keeps those paths stable while still putting a copy on
# GitHub after every change.
#
# GitHub is currently unreachable directly from this machine, so git runs
# through the local clash proxy when one is listening.
[CmdletBinding()]
param(
  [ValidateSet('status', 'push')]
  [string]$Action = 'status',
  [string]$Message = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Bridge = $PSScriptRoot
$Repo = Join-Path $Bridge 'plugin\dsh-plugin-mimo-delegate'
$Mirror = Join-Path $Repo 'bridge'
# Files worth versioning: the tooling itself, not scratch specs or the plugin
# package (the plugin is the repo root already).
$MirrorFiles = @(
  'MimoDesktop.ps1', 'MimoProgress.ps1', 'MimoProgress.cmd',
  'Set-Delegation.ps1', 'Check-Drift.ps1', 'Install-Plugin.ps1',
  'Sync-GitHub.ps1', 'README.md'
)
$ProxyCandidates = @('http://127.0.0.1:7897', 'http://127.0.0.1:7890')

function Get-GitProxyArgs {
  foreach ($p in $ProxyCandidates) {
    try {
      $port = ([uri]$p).Port
      $listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -eq $port })
      if ($listening.Count -gt 0) { return @('-c', "http.proxy=$p", '-c', "https.proxy=$p") }
    } catch {}
  }
  return @()
}

function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$GitArgs)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $all = @(Get-GitProxyArgs) +
      @('-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false') +
      @('-C', $Repo) + $GitArgs
    return (& git @all 2>&1 | Out-String)
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

if (-not (Test-Path (Join-Path $Repo '.git'))) {
  Write-Host "NOT A REPO: $Repo" -ForegroundColor Red
  Write-Host 'run: git init, add the remote, then re-run with -Action push'
  exit 1
}

if ($Action -eq 'status') {
  $dirty = (Invoke-Git @('status', '--porcelain')).Trim()
  if ($dirty) {
    Write-Host 'uncommitted changes:' -ForegroundColor Yellow
    $dirty -split "`n" | ForEach-Object { "  $_" }
  } else {
    Write-Host 'working tree: clean'
  }
  $local = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
  Write-Host "local  HEAD: $local"
  $fetch = Invoke-Git @('fetch', 'origin')
  if ($fetch -match 'fatal|error|Could not|unable') {
    Write-Host 'FETCH FAILED (network?):' -ForegroundColor Red
    $fetch.Trim() -split "`n" | Select-Object -First 2 | ForEach-Object { "  $_" }
    Write-Host 'DRIFT UNKNOWN - cannot see the remote' -ForegroundColor Red
    exit 1
  }
  $remote = (Invoke-Git @('rev-parse', 'origin/main')).Trim()
  Write-Host "remote HEAD: $remote"
  if ($local -and $remote -and $local -eq $remote) {
    Write-Host 'IN SYNC with GitHub' -ForegroundColor Green
    exit 0
  }
  Write-Host 'OUT OF SYNC - run: .\Sync-GitHub.ps1 -Action push -Message "<what changed>"' -ForegroundColor Red
  exit 1
}

# -Action push
New-Item -ItemType Directory -Force -Path $Mirror | Out-Null
$copied = 0
foreach ($f in $MirrorFiles) {
  $src = Join-Path $Bridge $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $Mirror $f) -Force; $copied++ }
}
$rulesDir = Join-Path $Bridge 'rules'
if (Test-Path $rulesDir) {
  $mirrorRules = Join-Path $Mirror 'rules'
  New-Item -ItemType Directory -Force -Path $mirrorRules | Out-Null
  Get-ChildItem $rulesDir -Filter '*.md' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $mirrorRules $_.Name) -Force; $copied++
  }
}
Write-Host "mirrored $copied file(s) into bridge\"

$msg = if ($Message) { $Message } else { 'sync bridge tooling' }
$headBefore = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
[void](Invoke-Git @('add', '-A'))
$status = (Invoke-Git @('status', '--porcelain')).Trim()
if (-not $status) {
  Write-Host 'nothing to commit' -ForegroundColor Yellow
} else {
  $commit = Invoke-Git @('commit', '-q', '-m', $msg)
  $headAfter = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
  if ($commit -match 'fatal|error') { Write-Host $commit.Trim() -ForegroundColor Red }
  elseif (-not $headAfter -or $headAfter -eq $headBefore) {
    Write-Host 'COMMIT FAILED - HEAD did not change' -ForegroundColor Red
    Write-Host $commit.Trim() -ForegroundColor Red
    exit 1
  } else {
    Write-Host "committed: $msg" -ForegroundColor Green
  }
}

$push = Invoke-Git @('push', 'origin', 'main')
if ($push -match 'fatal|error|Could not|unable') {
  Write-Host 'PUSH FAILED:' -ForegroundColor Red
  $push.Trim() -split "`n" | Select-Object -First 3 | ForEach-Object { "  $_" }
  exit 1
}
($push.Trim() -split "`n") | Select-Object -Last 1 | ForEach-Object { "  $_" }
$tags = Invoke-Git @('push', '--tags', 'origin')
if ($tags -match 'fatal|error') { Write-Host 'tag push failed (non-fatal)' -ForegroundColor Yellow }

$local = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
$remote = (Invoke-Git @('rev-parse', 'origin/main')).Trim()
Write-Host "local  HEAD: $local"
Write-Host "remote HEAD: $remote"
if ($local -eq $remote) { Write-Host 'IN SYNC with GitHub' -ForegroundColor Green; exit 0 }
Write-Host 'STILL OUT OF SYNC' -ForegroundColor Red
exit 1
