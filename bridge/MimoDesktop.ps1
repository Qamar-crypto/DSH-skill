<#
MimoDesktop.ps1 - local bridge to a running Xiaomi MiMo Desktop app.

MiMo Desktop (Electron) runs a loopback-only HTTP API and writes its
endpoint + bearer token to:
    %APPDATA%\Xiaomi MiMo\desktop-api.json   -> {api,port,token,pid}

Reverse-engineered surface (app build 26.914.142245):
    GET  /v1/health                                  -> {ok,api,app,engine}
    GET  /v1/sessions?limit=N                        -> [session...]
    GET  /v1/sessions/{id}/messages?dir=...          -> [{info,parts}...]
    GET  /v1/sessions/{id}/events?dir=...            -> SSE event stream
    POST /v1/sessions/{id}/turns                     -> 202 {ok:true}
         body {message,model,dir,perm,origin,files,plugins}
    GET  /v1/sessions/{id}/files?u=<path>&dir=...    -> file bytes

Notes:
  * There is NO session-create endpoint. The app's "new chat" is a client-side
    draft until its first message reaches the engine, so a brand-new chat is
    invisible to /v1/sessions.
  * Valid model ids: mimo-auto | mimo-flash | mimo-pro
  * Valid perm values: Use -Perm ask  (= ask-me-before-edits, the app default)
    or -Perm full (= full access). Raw strings via -PermRaw.
  * This file is intentionally pure ASCII so any PowerShell code page can read it.

Usage:
  powershell -NoProfile -File MimoDesktop.ps1 health
  powershell -NoProfile -File MimoDesktop.ps1 list [-Limit 10]
  powershell -NoProfile -File MimoDesktop.ps1 messages -SessionId ses_xxx [-Last 3] [-Full]
  powershell -NoProfile -File MimoDesktop.ps1 send -SessionId ses_xxx -Message "..." [-Dir D:\path] [-Perm ask]
  powershell -NoProfile -File MimoDesktop.ps1 ask  -SessionId ses_xxx -Message "..." [-TimeoutSec 180]
  powershell -NoProfile -File MimoDesktop.ps1 watch -SessionId ses_xxx [-TimeoutSec 30]
  powershell -NoProfile -File MimoDesktop.ps1 file -SessionId ses_xxx -Path <session-relative path> -Out <local file>
  powershell -NoProfile -File MimoDesktop.ps1 newjob -Name "<name>" -Message "..." [-Base <parent folder>]
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [ValidateSet('health', 'start', 'list', 'messages', 'progress', 'attachments', 'saveattachments', 'send', 'ask', 'wait', 'watch', 'file', 'version', 'newproject', 'newtask', 'newjob', 'help')]
  [string]$Action,

  [string]$SessionId,
  [string]$Message,
  # newjob: project folder name (joined onto D:\ or E:\ or -Base). No illegal chars.
  [string]$Name,
  # newjob: optional existing parent folder. Must not be on C: or F:.
  [string]$Base = '',
  # Long specs break native argument passing (embedded newlines get split).
  # Put the prompt in a file and pass -MessageFile instead.
  [string]$MessageFile,
  [string]$Dir,
  [ValidateSet('ask', 'full', '')]
  [string]$Perm = '',
  [string]$PermRaw,
  [string]$Path,
  [string]$Out,
  [string[]]$Files,
  [string]$Origin,
  [string]$Model = 'mimo-auto',
  [int]$Limit = 10,
  [int]$Last = 3,
  [int]$TimeoutSec = 180,
  # wait: declare the turn stalled when the transcript stops changing this long.
  [int]$StallSec = 150,
  [int64]$Since = 0,
  [int]$Max = 40,
  [int]$DetailMax = 100,
  [switch]$Full,
  [switch]$WithReasoning,
  [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$CredPath = Join-Path $env:APPDATA 'Xiaomi MiMo\desktop-api.json'
# The bridge may launch MiMo Desktop itself (explicitly authorised by the user),
# so delegated work does not require the app to be started by hand first.
$MimoExe = 'D:\MIMO Desk\Xiaomi MiMo\Xiaomi MiMo.exe'
# Bump this whenever the bridge changes (new action, new parameter, changed
# behaviour). Check-Drift.ps1 compares it against the skill's stamp, so the
# skill can never silently fall behind the bridge.
$BridgeVersion = '1.2.1'
$BridgeActions = @('health', 'start', 'list', 'messages', 'progress', 'attachments',
  'saveattachments', 'send', 'ask', 'wait', 'watch', 'file', 'version',
  'newproject', 'newtask', 'newjob')
$AutoStart = -not $NoAutoStart

# -MessageFile exists because a multi-line prompt passed as a native argument
# gets split by PowerShell's argument marshalling. Normalise it once, here.
if (-not $Message -and $MessageFile) {
  if (-not (Test-Path $MessageFile)) { throw "-MessageFile not found: $MessageFile" }
  $Message = [System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)
}

# The app's perm enum is Chinese; build it from code points to keep this file ASCII.
$PERM_ASK = -join ([char]0x5E2E, [char]0x6211, [char]0x5BA1, [char]0x6279)                                              # ask me
$PERM_FULL = -join ([char]0x5B8C, [char]0x5168, [char]0x8BBF, [char]0x95EE, [char]0x6743, [char]0x9650)                  # full access

function Resolve-Perm {
  param([string]$Name, [string]$Raw)
  if ($Raw) { return $Raw }
  switch ($Name) {
    'ask' { return $PERM_ASK }
    'full' { return $PERM_FULL }
    default { return '' }
  }
}

function Read-MimoCred {
  if (-not (Test-Path $CredPath)) { return $null }
  try { return (Get-Content $CredPath -Raw | ConvertFrom-Json) } catch { return $null }
}

# A credential is only usable when its pid is alive AND the API answers.
function Test-MimoCredLive {
  param($Cred)
  if (-not $Cred -or -not $Cred.port -or -not $Cred.token) { return $false }
  if (-not (Get-Process -Id $Cred.pid -ErrorAction SilentlyContinue)) { return $false }
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($Cred.port)/v1/health" `
      -Headers @{ Authorization = "Bearer $($Cred.token)" } -TimeoutSec 5 -UseBasicParsing
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

# Launches MiMo Desktop when it is not running, then waits until it publishes a
# usable credential. Never spawns a second instance: a duplicate would rewrite
# desktop-api.json with its own port and break an already-working bridge.
function Start-MimoDesktop {
  param([int]$WaitSeconds = 150)
  $cred = Read-MimoCred
  if (Test-MimoCredLive $cred) { return $cred }
  if (-not (Test-Path $MimoExe)) { throw "MiMo Desktop executable not found: $MimoExe" }
  $procs = @(Get-Process -Name 'Xiaomi MiMo' -ErrorAction SilentlyContinue)
  if ($procs.Count -gt 0) {
    [Console]::Error.WriteLine("[bridge] MiMo Desktop is running (pid $($procs[0].Id)) but has no live API credential yet; waiting")
  } else {
    [Console]::Error.WriteLine("[bridge] starting MiMo Desktop: $MimoExe")
    Start-Process -FilePath $MimoExe -WorkingDirectory (Split-Path -Parent $MimoExe) | Out-Null
  }
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $c = Read-MimoCred
    if (Test-MimoCredLive $c) { return $c }
  }
  throw "MiMo Desktop did not publish a usable API credential within $WaitSeconds s"
}

function Get-MimoCred {
  $c = Read-MimoCred
  if (Test-MimoCredLive $c) { return $c }
  if (-not $AutoStart) {
    throw "MiMo Desktop API is unavailable (cred file: $CredPath). Run action 'start' first."
  }
  return (Start-MimoDesktop)
}

function Invoke-Mimo {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$UrlPath,
    $Body,
    [int]$Timeout = 60
  )
  $c = Get-MimoCred
  $uri = "http://127.0.0.1:$($c.port)$UrlPath"
  $reqArgs = @{
    Method      = $Method
    Uri         = $uri
    Headers     = @{ Authorization = "Bearer $($c.token)" }
    TimeoutSec  = $Timeout
    ErrorAction = 'Stop'
  }
  if ($null -ne $Body) {
    # Windows PowerShell 5.1 encodes string bodies as ISO-8859-1; send raw UTF-8
    # bytes so non-ASCII prompts survive the round trip.
    $json = $Body | ConvertTo-Json -Depth 6 -Compress
    $reqArgs.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
    $reqArgs.ContentType = 'application/json; charset=utf-8'
  }
  try {
    $r = Invoke-WebRequest @reqArgs -UseBasicParsing
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Content = $r.Content }
  } catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $body = ''
    try { $body = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
    throw "MiMo API $Method $UrlPath failed: HTTP $code $body"
  }
}

function Get-Sessions {
  param([int]$Take = 10)
  $r = Invoke-Mimo -Method GET -UrlPath "/v1/sessions?limit=$Take" -Timeout 60
  return ($r.Content | ConvertFrom-Json)
}

function Get-Messages {
  param([Parameter(Mandatory)][string]$Id, [string]$Directory)
  $qs = ''
  if ($Directory) { $qs = '?dir=' + [uri]::EscapeDataString($Directory) }
  $r = Invoke-Mimo -Method GET -UrlPath "/v1/sessions/$Id/messages$qs" -Timeout 90
  return ($r.Content | ConvertFrom-Json)
}

# Newest message timestamp in the session. `send` returns it as `mark` so a
# following `wait -Since <mark>` is scoped to that one turn: turns the user
# starts by hand in the same session then cannot be measured by mistake.
function Get-SessionMark {
  param([Parameter(Mandatory)][string]$Id, [string]$Directory)
  $m = @(Get-Messages -Id $Id -Directory $Directory)
  $mark = [int64]0
  foreach ($msg in $m) {
    $created = [int64]$msg.info.time.created
    if ($created -gt $mark) { $mark = $created }
  }
  return $mark
}

function Get-PartText {
  param($Message, [switch]$WithReasoning)
  $sb = New-Object System.Text.StringBuilder
  foreach ($p in @($Message.parts)) {
    if ($null -eq $p) { continue }
    $names = @($p.PSObject.Properties.Name)
    if (-not ($names -contains 'text') -or -not $p.text) { continue }
    $type = if ($names -contains 'type') { [string]$p.type } else { '' }
    # MiMo parts are typed: step-start | reasoning | text | step-finish.
    # Only 'text' is the visible answer; reasoning is the chain of thought.
    if ($type -eq 'reasoning' -and -not $WithReasoning) { continue }
    if ($type -eq 'step-start' -or $type -eq 'step-finish' -or $type -eq 'snapshot' -or $type -eq 'patch') { continue }
    [void]$sb.AppendLine([string]$p.text)
  }
  return $sb.ToString().Trim()
}

function Format-Message {
  param($Message, [switch]$Long, [switch]$WithReasoning)
  $when = $null
  if ($Message.info.time.created) {
    $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Message.info.time.created).LocalDateTime.ToString('HH:mm:ss')
  }
  $text = Get-PartText $Message -WithReasoning:$WithReasoning
  $chars = $text.Length
  $reasoningChars = @($Message.parts | Where-Object { $_.type -eq 'reasoning' -and $_.text }).Count
  if (-not $Long) {
    $text = ($text -replace '\s+', ' ')
    if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
  }
  return [pscustomobject]@{
    role           = $Message.info.role
    time           = $when
    model          = if ($Message.info.providerID) { "$($Message.info.providerID)/$($Message.info.modelID)" } else { $null }
    chars          = $chars
    reasoningParts = $reasoningChars
    text           = $text
  }
}

function New-TurnBody {
  param([string]$Text)
  $body = @{ message = $Text; model = $Model }
  if ($Dir) { $body.dir = $Dir }
  # origin is the app's conversation id (e.g. c1789655256245-1, as seen in its
  # log for turns typed in the GUI); passing it may make the UI attribute the
  # turn to that conversation instead of the default "__main__".
  if ($Origin) { $body.origin = $Origin }
  $p = Resolve-Perm -Name $Perm -Raw $PermRaw
  if ($p) { $body.perm = $p }
  if ($Files) { $body.files = @($Files) }
  return $body
}

# Streams the session's SSE event feed and returns $true once the harness goes
# idle (i.e. the current turn finished) or $false on timeout / stream close.
# With -Emit the frames are written straight to the process stdout, so callers
# can capture them in a background job without polluting the return value.
function Wait-MimoIdle {
  param(
    [Parameter(Mandatory)][string]$Id,
    [int]$Timeout = 600,
    [switch]$Emit
  )
  $c = Get-MimoCred
  if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http }
  $uri = "http://127.0.0.1:$($c.port)/v1/sessions/$Id/events"
  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromSeconds($Timeout + 10)
  $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
  [void]$req.Headers.Add('Authorization', "Bearer $($c.token)")
  $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
  if (-not $resp.IsSuccessStatusCode) { throw "events stream failed: HTTP $([int]$resp.StatusCode)" }
  # .NET Framework has ReadAsStreamAsync() only (ReadAsStream() is .NET 5+).
  $reader = New-Object System.IO.StreamReader($resp.Content.ReadAsStreamAsync().Result)
  $deadline = (Get-Date).AddSeconds($Timeout)
  $curEvent = ''
  $lastPayload = ''
  $sawIdle = $false
  while ((Get-Date) -lt $deadline) {
    $line = $reader.ReadLine()
    if ($null -eq $line) { break }
    if ($line -match '^\s*$' -or $line.StartsWith(':')) { continue }
    if ($line.StartsWith('event:')) { $curEvent = $line.Substring(6).Trim(); continue }
    if (-not $line.StartsWith('data:')) { continue }
    $payload = $line.Substring(5).Trim()
    # The stream repeats identical busy / text-partial frames; collapse them.
    if ($payload -eq $lastPayload) { continue }
    $lastPayload = $payload
    if ($Emit) {
      [Console]::Out.WriteLine("event: $curEvent")
      [Console]::Out.WriteLine("data: $payload")
    }
    # Turn finished: the app emits {"type":"idle"} ("closed" when the stream ends).
    if ($payload -match '"type"\s*:\s*"(closed|idle|session\.idle)"') { $sawIdle = $true; break }
  }
  $reader.Dispose()
  $client.Dispose()
  return $sawIdle
}

switch ($Action) {
  'help' {
    Get-Help $PSCommandPath -Detailed
    break
  }

  'newproject' {
    # Create a project in MiMo Desktop whose folder is exactly -Dir. MiMo's HTTP
    # API has no create routes at all, so this drives the app's own Ctrl+O folder
    # picker (see MimoUiAuto.ps1 for the measurements behind it).
    if (-not $Dir) { throw 'newproject requires -Dir <project folder>' }
    if (-not (Test-Path -LiteralPath $Dir)) { throw "project folder not found: $Dir" }
    $ui = Join-Path $PSScriptRoot 'MimoUiAuto.ps1'
    if (-not (Test-Path $ui)) { throw "UI automation script missing: $ui" }
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $Dir, (New-Object System.Text.UTF8Encoding($false)))
    try {
      $log = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ui -Action newproject -ProjectFile $tmp 2>&1)
      $code = $LASTEXITCODE
    } finally {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { throw ("newproject failed (exit {0}): {1}" -f $code, ($log -join ' | ')) }
    [pscustomobject]@{
      ok     = $true
      action = 'newproject'
      dir    = $Dir
      note   = 'MiMo shows this folder in its project list; sessions created with newtask land in it.'
      log    = @($log)
    } | ConvertTo-Json -Depth 4
    break
  }

  'newtask' {
    # Create a session *inside* the project at -Dir and submit the task text.
    # Returns the session id, so the caller can continue with send/wait on it.
    if (-not $Dir) { throw 'newtask requires -Dir <project folder>' }
    if (-not (Test-Path -LiteralPath $Dir)) { throw "project folder not found: $Dir" }
    $ui = Join-Path $PSScriptRoot 'MimoUiAuto.ps1'
    if (-not (Test-Path $ui)) { throw "UI automation script missing: $ui" }
    $mdir = [System.IO.Path]::GetTempFileName()
    $mm = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($mdir, $Dir, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($mm, $Message, (New-Object System.Text.UTF8Encoding($false)))
    try {
      $log = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ui -Action newtask -ProjectFile $mdir -MessageFile $mm 2>&1)
      $code = $LASTEXITCODE
    } finally {
      Remove-Item -LiteralPath $mdir, $mm -Force -ErrorAction SilentlyContinue
    }
    $line = @($log | Where-Object { $_ -match '^NEW SESSION: ' }) | Select-Object -Last 1
    if ($code -ne 0 -or -not $line) { throw ("newtask failed (exit {0}): {1}" -f $code, ($log -join ' | ')) }
    $id = ([regex]'id=(\S+)').Match($line).Groups[1].Value
    [pscustomobject]@{
      ok        = $true
      action    = 'newtask'
      dir       = $Dir
      sessionId = $id
      log       = @($log)
    } | ConvertTo-Json -Depth 4
    break
  }

  'newjob' {
    # newjob: create/reuse a dedicated work folder, open it as a MiMo project,
    # then create a session inside that project and submit -Message there.
    # Keeps jobs from piling up in one conversation.
    # Allowed drives: D: / E: only (C: and F: are banned by policy).
    if (-not $Name) { throw 'newjob requires -Name <project name>' }
    $jobName = [string]$Name
    if ($jobName.Length -gt 60) { throw ("newjob -Name too long (max 60), got {0}" -f $jobName.Length) }
    if ($jobName -match '[\\/:*?\"<>|]') {
      throw 'newjob -Name illegal chars: \ / : * ? " < > | are not allowed'
    }
    if (-not $Message) { throw 'newjob requires -Message <task text>' }

    $parent = ''
    if ($Base) {
      if (-not (Test-Path -LiteralPath $Base -PathType Container)) {
        throw "newjob -Base parent folder not found: $Base"
      }
      $resolvedBase = (Resolve-Path -LiteralPath $Base).Path
      $root = [System.IO.Path]::GetPathRoot($resolvedBase)
      $drive = ''
      if ($root) { $drive = $root.Substring(0, 2).ToUpperInvariant() }
      if ($drive -eq 'C:' -or $drive -eq 'F:') {
        throw ("newjob -Base drive {0} is not allowed (C: and F: are banned; use D: or E:)" -f $drive)
      }
      $parent = $resolvedBase
    } else {
      # Default parent: one dedicated folder instead of scattering job folders
      # across the drive root (the user could not find them any more). The Chinese
      # leaf name lives in ui-names.json because this script must stay ASCII.
      $leaf = 'MiMo Jobs'
      $uiNames = Join-Path $PSScriptRoot 'ui-names.json'
      if (Test-Path -LiteralPath $uiNames) {
        try {
          $cfg = [System.IO.File]::ReadAllText($uiNames, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
          if ($cfg.jobsParentName) { $leaf = [string]$cfg.jobsParentName }
        } catch { }
      }
      if (Test-Path -LiteralPath 'D:\') { $parent = Join-Path 'D:\' $leaf }
      elseif (Test-Path -LiteralPath 'E:\') { $parent = Join-Path 'E:\' $leaf }
      else { throw 'newjob failed: no usable drive (C: and F: are not allowed; need D: or E:)' }
      if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }
    }

    $target = Join-Path $parent $jobName
    $created = $false
    if (Test-Path -LiteralPath $target) {
      if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "newjob target exists but is not a folder: $target"
      }
    } else {
      try {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $created = $true
      } catch {
        throw ("newjob failed to create folder: {0} ({1})" -f $target, $_.Exception.Message)
      }
    }

    # Reuse the same MimoUiAuto.ps1 path as newproject / newtask (temp UTF-8
    # files + argument arrays; never concatenated command strings).
    $ui = Join-Path $PSScriptRoot 'MimoUiAuto.ps1'
    if (-not (Test-Path $ui)) { throw "UI automation script missing: $ui" }

    $allLog = @()

    # Step 1: newproject
    $tmpProj = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpProj, $target, (New-Object System.Text.UTF8Encoding($false)))
    try {
      $logProj = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ui -Action newproject -ProjectFile $tmpProj 2>&1)
      $codeProj = $LASTEXITCODE
    } finally {
      Remove-Item -LiteralPath $tmpProj -Force -ErrorAction SilentlyContinue
    }
    $allLog += $logProj
    if ($codeProj -ne 0) {
      throw ("newjob newproject failed (exit {0}): {1}" -f $codeProj, ($logProj -join ' | '))
    }

    # Step 2: newtask (session + message inside that project)
    $tmpDir = [System.IO.Path]::GetTempFileName()
    $tmpMsg = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpDir, $target, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($tmpMsg, $Message, (New-Object System.Text.UTF8Encoding($false)))
    try {
      $logTask = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ui -Action newtask -ProjectFile $tmpDir -MessageFile $tmpMsg 2>&1)
      $codeTask = $LASTEXITCODE
    } finally {
      Remove-Item -LiteralPath $tmpDir, $tmpMsg -Force -ErrorAction SilentlyContinue
    }
    $allLog += $logTask
    $line = @($logTask | Where-Object { $_ -match '^NEW SESSION: ' }) | Select-Object -Last 1
    if ($codeTask -ne 0 -or -not $line) {
      throw ("newjob newtask failed (exit {0}): {1}" -f $codeTask, ($logTask -join ' | '))
    }
    $sid = ([regex]'id=(\S+)').Match($line).Groups[1].Value
    if (-not $sid) { throw ("newjob newtask produced no sessionId: {0}" -f ($logTask -join ' | ')) }

    [pscustomobject]@{
      ok        = $true
      action    = 'newjob'
      name      = $jobName
      dir       = $target
      created   = $created
      sessionId = $sid
      log       = @($allLog)
    } | ConvertTo-Json -Depth 4
    break
  }

  'version' {
    [pscustomobject]@{
      version = $BridgeVersion
      actions = @($BridgeActions)
      skill   = 'C:\Users\MI\.dsh\skills\mimo-delegate\SKILL.md'
      drift   = 'powershell -NoProfile -ExecutionPolicy Bypass -File <this dir>\Check-Drift.ps1'
    } | ConvertTo-Json -Depth 3
    break
  }

  'start' {
    $before = Read-MimoCred
    $wasLive = Test-MimoCredLive $before
    $cred = Start-MimoDesktop
    [pscustomobject]@{
      alreadyRunning = $wasLive
      pid            = $cred.pid
      port           = $cred.port
      exe            = $MimoExe
    } | ConvertTo-Json
    break
  }

  'health' {
    $c = Get-MimoCred
    $r = Invoke-Mimo -Method GET -UrlPath '/v1/health' -Timeout 10
    [pscustomobject]@{
      credFile = $CredPath
      pid      = $c.pid
      port     = $c.port
      health   = ($r.Content | ConvertFrom-Json)
    } | ConvertTo-Json -Depth 4
    break
  }

  'list' {
    $s = Get-Sessions -Take $Limit
    $s | ForEach-Object {
      [pscustomobject]@{
        id        = $_.id
        title     = $_.title
        directory = $_.directory
        updated   = if ($_.time.updated) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$_.time.updated).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { $null }
      }
    } | ConvertTo-Json -Depth 4
    break
  }

  'messages' {
    if (-not $SessionId) { throw '-SessionId is required' }
    $m = Get-Messages -Id $SessionId -Directory $Dir
    $tail = @($m) | Select-Object -Last $Last
    [pscustomobject]@{
      sessionId = $SessionId
      total     = @($m).Count
      shown     = @($tail).Count
      messages  = @($tail | ForEach-Object { Format-Message $_ -Long:$Full -WithReasoning:$WithReasoning })
    } | ConvertTo-Json -Depth 6
    break
  }

  'send' {
    if (-not $SessionId) { throw '-SessionId is required' }
    if (-not $Message) { throw '-Message is required' }
    # Capture the transcript mark BEFORE posting: pass it to `wait -Since` so the
    # wait is scoped to THIS turn. Without it, a turn the user starts by hand in
    # the same session can be measured instead (that produced a bogus 570s wait).
    $mark = Get-SessionMark -Id $SessionId -Directory $Dir
    $r = Invoke-Mimo -Method POST -UrlPath "/v1/sessions/$SessionId/turns" -Body (New-TurnBody -Text $Message) -Timeout 60
    [pscustomobject]@{
      sessionId = $SessionId
      http      = $r.Status
      response  = $r.Content
      model     = $Model
      mark      = $mark
      next      = "wait -SessionId $SessionId -Since $mark -TimeoutSec <n>"
    } | ConvertTo-Json
    break
  }

  'ask' {
    if (-not $SessionId) { throw '-SessionId is required' }
    if (-not $Message) { throw '-Message is required' }
    $n0 = @(Get-Messages -Id $SessionId -Directory $Dir).Count
    [void](Invoke-Mimo -Method POST -UrlPath "/v1/sessions/$SessionId/turns" -Body (New-TurnBody -Text $Message) -Timeout 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $best = $null
    $stable = 0
    $completed = $false
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 3
      $new = @(Get-Messages -Id $SessionId -Directory $Dir) | Select-Object -Skip $n0
      $reply = $new | Where-Object { $_.info.role -eq 'assistant' } | Select-Object -Last 1
      if (-not $reply) { continue }
      $txt = Get-PartText $reply -WithReasoning:$WithReasoning
      # time.completed is set exactly when the turn ends, including turns that
      # finish with no visible text at all (MiMo does this after long reasoning).
      if ($reply.info.time.completed) { $best = $txt; $completed = $true; break }
      if ($txt) {
        if ($best -and $txt.Length -eq $best.Length) { $stable++ } else { $stable = 0 }
        $best = $txt
        if ($stable -ge 3) { break }
      }
    }
    [pscustomobject]@{
      sessionId   = $SessionId
      newMessages = (@(Get-Messages -Id $SessionId -Directory $Dir).Count - $n0)
      completed   = $completed
      timedOut    = (-not $completed)
      emptyReply  = ($completed -and -not $best)
      reply       = $best
    } | ConvertTo-Json -Depth 4
    break
  }

  'watch' {
    if (-not $SessionId) { throw '-SessionId is required' }
    [void](Wait-MimoIdle -Id $SessionId -Timeout $TimeoutSec -Emit)
    break
  }

  'wait' {
    # Block until the CURRENT turn finishes (no new turn is sent), then return
    # its visible text. Use this after 'send' for long jobs, where 'ask' would
    # have to poll the whole message history over and over.
    #
    # Deliberately avoids `Select-Object -Last 1` and `$a[$a.Count-1]`: on this
    # PowerShell 5.1 build both paths blew up with a bogus
    # "Cannot convert ... to System.Int32" (the element got bound as an index).
    # A plain foreach walk is unambiguous.
    # Polls the transcript instead of streaming SSE. The earlier streaming
    # version had a race that cost a 7-minute hang: the turn could finish AFTER
    # the "is it already done?" probe but BEFORE the stream was attached, so the
    # idle frame never arrived. Re-reading the transcript cannot race.
    if (-not $SessionId) { throw '-SessionId is required' }
    # A turn can DIE (MiMo aborts its thinking) instead of finishing. Polling
    # until the full timeout then wastes the whole budget, so detect two cases
    # and return at once:
    #   failed  - the newest assistant message carries an error / bad finish
    #   stalled - the transcript has not changed for -StallSec seconds
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stallLimit = if ($StallSec -gt 0) { $StallSec } else { 150 }
    # -Since scopes the wait to messages created after that mark (the value
    # `send` returns). 0 keeps the old "newest assistant message" behaviour.
    $mark = [int64]$Since
    $newest = $null
    $done = $false
    $failed = $false
    $stalled = $false
    $reason = ''
    $waited = 0
    $lastSignature = ''
    $idleSince = Get-Date
    while ($true) {
      $m = @(Get-Messages -Id $SessionId -Directory $Dir)
      $b = @($m | Where-Object {
        $_.info.role -eq 'assistant' -and ($mark -le 0 -or [int64]$_.info.time.created -gt $mark)
      })
      # Walk instead of indexing: "$a[$a.Count-1]" and Select-Object -Last both
      # tripped this PowerShell 5.1 build, and a local named $last silently
      # collides with the typed parameter [int]$Last.
      $newest = $null
      foreach ($x in $b) { $newest = $x }

      $partCount = 0
      if ($newest) { $partCount = @($newest.parts).Count }
      $signature = "$(@($m).Count)|$(if ($newest) { $newest.info.id } else { '' })|$partCount"
      if ($signature -ne $lastSignature) { $lastSignature = $signature; $idleSince = Get-Date }

      if ($newest) {
        if ($newest.info.time.completed) { $done = $true; break }
        $errText = ''
        try { if ($newest.info.error) { $errText = ($newest.info.error | ConvertTo-Json -Depth 3 -Compress) } } catch {}
        if ($errText) { $failed = $true; $reason = "error: $errText"; break }
        $finish = ''
        try { $finish = [string]$newest.info.finish } catch {}
        if ($finish -match '^(error|failed|aborted|cancelled|canceled|interrupted)$') {
          $failed = $true; $reason = "finish=$finish"; break
        }
      }

      if ((Get-Date) -ge $deadline) { $reason = 'timeout'; break }
      if (((Get-Date) - $idleSince).TotalSeconds -ge $stallLimit) {
        $stalled = $true
        $reason = "transcript unchanged for ${stallLimit}s (MiMo likely stopped thinking)"
        break
      }
      $sleep = if ($waited -lt 60) { 5 } else { 15 }
      Start-Sleep -Seconds $sleep
      $waited += $sleep
    }
    $reply = $null
    if ($newest) { $reply = Get-PartText $newest -WithReasoning:$WithReasoning }
    if (-not $m) { $m = @() }
    [pscustomobject]@{
      sessionId = $SessionId
      messages  = @($m).Count
      waitedSec = $waited
      completed = $done
      failed    = $failed
      stalled   = $stalled
      reason    = $reason
      reply     = $reply
    } | ConvertTo-Json -Depth 6
    break
  }

  'progress' {
    # Incremental, cheap activity feed for a running delegation: everything that
    # happened after -Since (unix ms). Meant to be polled every few seconds by a
    # watcher, so it only reports deltas and caps every string.
    if (-not $SessionId) { throw '-SessionId is required' }
    $m = @(Get-Messages -Id $SessionId -Directory $Dir)
    $sinceMs = [int64]$Since
    $events = @()
    $newestCreated = [int64]0
    $outTokens = 0
    $reasonTokens = 0
    $toolCount = 0
    $newestA = $null
    foreach ($msg in $m) {
      $created = [int64]$msg.info.time.created
      if ($created -gt $newestCreated) { $newestCreated = $created }
      if ($msg.info.role -eq 'assistant') { $newestA = $msg }
      if ($msg.info.role -eq 'assistant' -and $msg.info.tokens) {
        $outTokens += [int]$msg.info.tokens.output
        $reasonTokens += [int]$msg.info.tokens.reasoning
      }
      foreach ($p in @($msg.parts)) {
        if ($null -eq $p) { continue }
        $ptype = [string]$p.type
        # Filter per PART, not per message: one assistant message accumulates
        # many parts (tool calls, text, reasoning) over minutes, so the message
        # created time would drop everything after the first part.
        $evTime = $created
        if ($p.state -and $p.state.time -and $p.state.time.start) { $evTime = [int64]$p.state.time.start }
        elseif ($p.time -and $p.time.start) { $evTime = [int64]$p.time.start }
        elseif ($p.time -and $p.time.created) { $evTime = [int64]$p.time.created }
        if ($evTime -le $sinceMs) { continue }
        if ($evTime -gt $newestCreated) { $newestCreated = $evTime }
        $detail = ''
        $kind = ''
        $tool = ''
        $status = ''
        if ($ptype -eq 'tool') {
          $toolCount++
          $kind = 'tool'
          $tool = [string]$p.tool
          if ($p.state) {
            $status = [string]$p.state.status
            if ($p.state.title) { $detail = [string]$p.state.title }
            elseif ($p.state.input) {
              if ($p.state.input.command) { $detail = [string]$p.state.input.command }
              elseif ($p.state.input.filePath) { $detail = [string]$p.state.input.filePath }
              elseif ($p.state.input.prompt) { $detail = [string]$p.state.input.prompt }
              elseif ($p.state.input.description) { $detail = [string]$p.state.input.description }
            }
          }
        } elseif ($ptype -eq 'text' -and $p.text) {
          $kind = 'text'
          $detail = [string]$p.text
        } elseif ($ptype -eq 'reasoning') {
          $kind = 'reasoning'
          $detail = 'thinking (' + ([string]$p.text).Length + ' chars)'
        } else {
          continue
        }
        $detail = ($detail -replace '\s+', ' ').Trim()
        if ($detail.Length -gt $DetailMax) { $detail = $detail.Substring(0, $DetailMax) + '...' }
        $events += [pscustomobject]@{
          at     = $evTime
          time   = [DateTimeOffset]::FromUnixTimeMilliseconds($evTime).LocalDateTime.ToString('HH:mm:ss')
          role   = $msg.info.role
          kind   = $kind
          tool   = $tool
          status = $status
          detail = $detail
        }
      }
    }
    $capped = $false
    if ($events.Count -gt $Max) {
      $events = $events[($events.Count - $Max)..($events.Count - 1)]
      $capped = $true
    }
    $running = $true
    if ($newestA -and $newestA.info.time.completed) { $running = $false }
    [pscustomobject]@{
      sessionId   = $SessionId
      messages    = @($m).Count
      since       = $sinceMs
      lastAt      = $newestCreated
      running     = $running
      eventsShown = @($events).Count
      capped      = $capped
      totalOutput = $outTokens
      totalReason = $reasonTokens
      newTools    = $toolCount
      events      = @($events)
    } | ConvertTo-Json -Depth 5
    break
  }

  'attachments' {
    if (-not $SessionId) { throw '-SessionId is required' }
    $m = Get-Messages -Id $SessionId -Directory $Dir
    $items = @()
    foreach ($msg in @($m)) {
      foreach ($p in @($msg.parts)) {
        if ($null -eq $p) { continue }
        # fetchable set == parts of type "file"; and /files only serves those
        # whose url starts with file: (data: urls are rejected as forbidden-file).
        if ($p.type -ne 'file' -or -not $p.url) { continue }
        $u = [string]$p.url
        $kind = if ($u -like 'data:*') { 'data' } elseif ($u -like 'file:*') { 'file' } else { 'other' }
        $items += [pscustomobject]@{
          kind      = $kind
          fetchable = ($kind -eq 'file')
          mime      = if ($p.mime) { $p.mime } else { 'application/octet-stream' }
          filename  = $p.filename
          bytes     = $u.Length
          # data: urls are megabytes of base64 - never echo them whole
          url       = if ($u.Length -gt 160) { $u.Substring(0, 160) + "...[len=$($u.Length)]" } else { $u }
        }
      }
    }
    [pscustomobject]@{
      sessionId     = $SessionId
      count         = @($items).Count
      fetchable     = @($items | Where-Object { $_.fetchable }).Count
      attachments   = @($items)
    } | ConvertTo-Json -Depth 4
    break
  }

  'saveattachments' {
    if (-not $SessionId) { throw '-SessionId is required' }
    if (-not $Out) { throw '-Out <directory> is required' }
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $m = Get-Messages -Id $SessionId -Directory $Dir
    $saved = @()
    $idx = 0
    foreach ($msg in @($m)) {
      foreach ($p in @($msg.parts)) {
        if ($null -eq $p) { continue }
        if ($p.type -ne 'file' -or -not $p.url) { continue }
        $u = [string]$p.url
        # MiMo attaches media inline as data: URLs; decode them to real files.
        if ($u -notlike 'data:*') { continue }
        $comma = $u.IndexOf(',')
        if ($comma -lt 0) { continue }
        $meta = $u.Substring(5, $comma - 5)
        if ($meta -notlike '*;base64') { continue }
        $mime = ($meta -split ';')[0]
        $ext = 'bin'
        if ($mime -eq 'image/png') { $ext = 'png' }
        elseif ($mime -eq 'image/jpeg') { $ext = 'jpg' }
        elseif ($mime -eq 'image/webp') { $ext = 'webp' }
        elseif ($mime -eq 'image/gif') { $ext = 'gif' }
        elseif ($mime -eq 'application/pdf') { $ext = 'pdf' }
        elseif ($mime -match '/') { $ext = ($mime -split '/')[-1] }
        $stem = 'attachment'
        if ($p.filename) { $stem = ([string]$p.filename -replace '[^A-Za-z0-9._-]', '_') }
        if ($stem.Length -gt 60) { $stem = $stem.Substring(0, 60) }
        $name = "{0:d3}-{1}.{2}" -f $idx, $stem, $ext
        $target = Join-Path $Out $name
        try {
          $bytes = [Convert]::FromBase64String($u.Substring($comma + 1))
          [System.IO.File]::WriteAllBytes($target, $bytes)
          $magic = ($bytes[0..([Math]::Min(7, $bytes.Length - 1))] | ForEach-Object { $_.ToString('x2') }) -join ''
          $saved += [pscustomobject]@{ file = $target; bytes = $bytes.Length; mime = $mime; magic = $magic }
        } catch {
          $saved += [pscustomobject]@{ file = $target; bytes = -1; mime = $mime; magic = "decode failed: $($_.Exception.Message)" }
        }
        $idx++
      }
    }
    [pscustomobject]@{ sessionId = $SessionId; out = $Out; saved = @($saved).Count; files = @($saved) } | ConvertTo-Json -Depth 4
    break
  }

  'file' {
    if (-not $SessionId) { throw '-SessionId is required' }
    if (-not $Path) { throw '-Path is required' }
    # The app only serves paths that arrive as a file: URL; anything else is
    # rejected as forbidden-file (403). Convert a local path for convenience.
    if ($Path -like 'file:*') {
      $fileUrl = $Path
    } else {
      $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
      $fileUrl = ([System.Uri]::new($resolved)).AbsoluteUri
    }
    $qs = '?u=' + $fileUrl
    if ($Dir) { $qs += '&dir=' + [uri]::EscapeDataString($Dir) }
    $c = Get-MimoCred
    $uri = "http://127.0.0.1:$($c.port)/v1/sessions/$SessionId/files$qs"
    if ($Out) {
      Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $($c.token)" } -OutFile $Out -TimeoutSec 120 -UseBasicParsing
      "saved: $Out"
    } else {
      (Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $($c.token)" } -TimeoutSec 120 -UseBasicParsing).Content
    }
    break
  }
}
