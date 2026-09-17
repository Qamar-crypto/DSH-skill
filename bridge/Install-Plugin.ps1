# Install-Plugin.ps1 - install / revert / inspect the mimo-delegate DSH plugin.
#
#   -Action status   (default) report whether it is installed and whether the
#                    profile can resolve the plugin's own imports
#   -Action install  copy the package into the profile's node_modules and add it
#                    to dsh.profile.bundles, then tell you to reload DSH Desktop
#   -Action revert   remove both
#
# Why a copy instead of a symlink: the plugin's own imports (@deepseek-ai/*
# schemastery) must resolve against the PROFILE's node_modules. A junction would
# make Node resolve from the source directory instead and fail.
[CmdletBinding()]
param(
  [ValidateSet('status', 'install', 'revert')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$name = 'dsh-plugin-mimo-delegate'
$src = Join-Path $PSScriptRoot $name
$profile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$profilePkg = Join-Path $profile 'package.json'
$target = Join-Path $profile "node_modules\$name"
$required = @('package.json', 'cordis.patch.yml', 'lib\index.js', 'lib\client.js')

function Get-Bundles {
  param([string]$Path)
  $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  return @($json.dsh.profile.bundles)
}

function Show-Status {
  Write-Host "source      : $src"
  foreach ($f in $required) {
    $p = Join-Path $src $f
    $state = if (Test-Path $p) { "OK $([math]::Round((Get-Item $p).Length/1KB,1)) KB" } else { 'MISSING' }
    Write-Host ("  {0,-18} {1}" -f $f, $state)
  }
  Write-Host "installed   : $(if (Test-Path (Join-Path $target 'package.json')) { 'YES' } else { 'no' })  ($target)"
  if (Test-Path $profilePkg) {
    $bundles = Get-Bundles -Path $profilePkg
    Write-Host "in bundles  : $(if ($bundles -contains $name) { 'YES' } else { 'no' })"
  }
  $schema = Join-Path $profile 'node_modules\@deepseek-ai\schemastery'
  Write-Host "dep resolve : schemastery $(if (Test-Path $schema) { 'present' } else { 'MISSING' })"
}

switch ($Action) {
  'status' { Show-Status; break }

  'install' {
    if (-not (Test-Path (Join-Path $src 'package.json'))) { throw "source package not found: $src" }
    foreach ($f in $required) {
      if (-not (Test-Path (Join-Path $src $f))) { throw "source is incomplete, missing $f" }
    }
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $src '*') -Destination $target -Recurse -Force
    Write-Host "copied -> $target" -ForegroundColor Green

    $backup = "$profilePkg.bak-mimo-delegate"
    Copy-Item $profilePkg $backup -Force
    Write-Host "profile package.json backed up -> $backup"

    $json = [System.IO.File]::ReadAllText($profilePkg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $bundles = @($json.dsh.profile.bundles)
    if ($bundles -notcontains $name) {
      $json.dsh.profile.bundles = @($bundles + $name)
      $out = $json | ConvertTo-Json -Depth 20
      [System.IO.File]::WriteAllText($profilePkg, $out, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host "added '$name' to dsh.profile.bundles" -ForegroundColor Green
    } else {
      Write-Host "already listed in dsh.profile.bundles"
    }
    Write-Host ''
    Write-Host 'NEXT: reload DSH Desktop (tray menu or restart the app) to load the plugin.' -ForegroundColor Yellow
    break
  }

  'revert' {
    if (Test-Path $target) { Remove-Item $target -Recurse -Force; Write-Host "removed $target" -ForegroundColor Yellow }
    $json = [System.IO.File]::ReadAllText($profilePkg, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $bundles = @($json.dsh.profile.bundles) | Where-Object { $_ -ne $name }
    $json.dsh.profile.bundles = @($bundles)
    [System.IO.File]::WriteAllText($profilePkg, ($json | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "removed '$name' from dsh.profile.bundles" -ForegroundColor Yellow
    Write-Host 'reload DSH Desktop to unload it' -ForegroundColor Yellow
    break
  }
}
