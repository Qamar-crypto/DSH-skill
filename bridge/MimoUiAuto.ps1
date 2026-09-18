# MimoUiAuto.ps1 - UI automation for MiMo Desktop (project + session creation).
#
# WHY THIS EXISTS: MiMo's desktop API has no create routes at all (probe results:
# only health, session list, messages, turns, events, files), the engine API needs
# an in-memory random password, and writing the engine's SQLite store is unsafe.
# Driving the app's own UI is therefore the only supported way to create a project
# or a session - and it is what a human does anyway.
#
# ASCII-only on purpose: PowerShell 5.1 decodes script files with the ANSI code
# page, so any non-ASCII literal here would be corrupted. All text (paths, task
# messages) is read from UTF-8 files.
#
# NOTE: Huorong (??) HIPS quarantines scripts that combine key synthesis, screen
# capture and clipboard access, so this file has to be in its trust list.
#
# Actions:
#   probe                 - print MiMo pid/hwnd/foreground/window rect
#   focus                 - restore + activate MiMo and verify it is foreground
#   shot -Out png         - PrintWindow capture (main window only)
#   screencap -Out png    - on-screen capture of the window region (sees popovers)
#   click -X -Y           - click a point in window coordinates (same scale as shot)
#   keys -Keys "CTRL+N"   - send a key sequence to the focused MiMo window
#   newtask -ProjectFile -MessageFile
#                         - new task inside the given project, then report the
#                           session id the app created for it
#
param(
  [ValidateSet('probe', 'focus', 'shot', 'screencap', 'click', 'keys', 'newtask', 'hover', 'paste', 'newproject', 'tree', 'invoke', 'setvalue')][string]$Action = 'probe',
  [string]$Out = '',
  [int]$X = -1,
  [int]$Y = -1,
  [string]$Keys = '',
  [string]$ProjectFile = '',
  [string]$MessageFile = '',
  [int]$SettleMs = 1500
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

$win32 = @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, IntPtr extra);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
[DllImport("user32.dll", EntryPoint = "SendMessageW")] public static extern IntPtr SendMessagePtr(IntPtr h, uint msg, IntPtr w, IntPtr l);
'@
Add-Type -Namespace W -Name A -MemberDefinition $win32
[void][W.A]::SetProcessDPIAware()

function Get-WindowHandles {
  # The callback only collects handles: building strings inside a
  # scriptblock-as-delegate truncates them to one character.
  $handles = New-Object System.Collections.ArrayList
  $cb = [W.A+EnumWindowsProc] {
    param([IntPtr]$h, [IntPtr]$p)
    [void]$handles.Add($h)
    return $true
  }
  [void][W.A]::EnumWindows($cb, [IntPtr]::Zero)
  return $handles
}

function Get-WindowInfo([IntPtr]$h) {
  # CharSet.Unicode on the P/Invokes matters: with the default (ANSI) marshalling
  # a UTF-16 window title comes back as its first character only.
  $wpid = [uint32]0
  [void][W.A]::GetWindowThreadProcessId($h, [ref]$wpid)
  $sb = New-Object System.Text.StringBuilder 512
  [void][W.A]::GetWindowTextW($h, $sb, 512)
  $cb2 = New-Object System.Text.StringBuilder 256
  [void][W.A]::GetClassNameW($h, $cb2, 256)
  return [pscustomobject]@{
    Hwnd    = $h
    Pid     = [int]$wpid
    Class   = $cb2.ToString()
    Title   = $sb.ToString()
    Visible = [bool][W.A]::IsWindowVisible($h)
  }
}

function Get-WindowList {
  $out = @()
  foreach ($h in (Get-WindowHandles)) { $out += (Get-WindowInfo $h) }
  return $out
}

function Get-MimoProcess {
  $p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'MiMo' -and $_.MainWindowHandle -ne 0 })
  if ($p.Count -eq 0) { throw 'MiMo main window not found (is the app running?)' }
  return $p[0]
}

function Get-Rect([IntPtr]$h) {
  $r = New-Object W.A+RECT
  if (-not [W.A]::GetWindowRect($h, [ref]$r)) { throw 'GetWindowRect failed' }
  return $r
}

function Get-Foreground {
  $h = [W.A]::GetForegroundWindow()
  $fp = [uint32]0
  [void][W.A]::GetWindowThreadProcessId($h, [ref]$fp)
  $proc = Get-Process -Id ([int]$fp) -ErrorAction SilentlyContinue
  return [pscustomobject]@{ Hwnd = $h; Pid = [int]$fp; Name = $(if ($proc) { $proc.ProcessName } else { '?' }) }
}

function Focus-Mimo($mimo, [int]$TargetPid) {
  # NOTE: the parameter must not be called $Pid - that name is a read-only
  # automatic variable in PowerShell and binding to it throws VariableNotWritable.
  [void][W.A]::ShowWindow([IntPtr]$mimo.MainWindowHandle, 9)
  [void][Microsoft.VisualBasic.Interaction]::AppActivate($TargetPid)
  Start-Sleep -Milliseconds 700
  $fg = Get-Foreground
  if ($fg.Pid -ne $TargetPid) { throw "focus failed: foreground pid $($fg.Pid) is not MiMo ($TargetPid)" }
  return $fg
}

function Send-Vk([int]$vk, [int]$holdMs = 45) {
  [W.A]::keybd_event([byte]$vk, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $holdMs
  [W.A]::keybd_event([byte]$vk, 0, 2, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
}

function Send-Sequence([string]$spec) {
  $named = @{ 'ENTER' = 0x0D; 'ESC' = 0x1B; 'TAB' = 0x09; 'SPACE' = 0x20; 'BACKSPACE' = 0x08; 'DELETE' = 0x2E; 'CTRL' = 0x11; 'SHIFT' = 0x10; 'ALT' = 0x12; 'HOME' = 0x24; 'END' = 0x23 }
  foreach ($step in ($spec -split ',')) {
    $keys = @()
    foreach ($k in ($step.Trim() -split '\+')) {
      $u = $k.Trim().ToUpper()
      if ($named.ContainsKey($u)) { $keys += $named[$u] }
      elseif ($u.Length -eq 1 -and $u -match '[A-Z0-9]') { $keys += [int][char]$u }
      else { throw "unsupported key '$k' in step '$step'" }
    }
    if ($keys.Count -eq 0) { continue }
    $mods = @($keys | Where-Object { $_ -in 0x11, 0x10, 0x12 })
    $main = @($keys | Where-Object { $_ -notin 0x11, 0x10, 0x12 })
    foreach ($m in $mods) { [W.A]::keybd_event([byte]$m, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 30 }
    if ($main.Count -gt 0) { Send-Vk $main[0] }
    for ($i = $mods.Count - 1; $i -ge 0; $i--) { [W.A]::keybd_event([byte]$mods[$i], 0, 2, [IntPtr]::Zero); Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 120
  }
}

function Move-WindowPoint([IntPtr]$hwnd, [int]$wx, [int]$wy, [int]$WaitMs) {
  $r = Get-Rect $hwnd
  $sx = $r.Left + $wx
  $sy = $r.Top + $wy
  Write-Host ("hover screen {0},{1}" -f $sx, $sy)
  [void][W.A]::SetCursorPos($sx, $sy)
  Start-Sleep -Milliseconds $WaitMs
}

function Click-Window([IntPtr]$hwnd, [int]$wx, [int]$wy, [int]$WaitMs) {
  $r = Get-Rect $hwnd
  $sx = $r.Left + $wx
  $sy = $r.Top + $wy
  Write-Host ("window {0},{1} {2}x{3} -> click screen {4},{5}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top), $sx, $sy)
  [void][W.A]::SetCursorPos($sx, $sy)
  Start-Sleep -Milliseconds 250
  [W.A]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [W.A]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $WaitMs
}

function Save-Shot([IntPtr]$hwnd, [string]$path, [bool]$FromScreen) {
  Add-Type -AssemblyName System.Drawing
  $r = Get-Rect $hwnd
  $w = $r.Right - $r.Left
  $ht = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  if ($FromScreen) {
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $ht))
  } else {
    $hdc = $g.GetHdc()
    [void][W.A]::PrintWindow($hwnd, $hdc, 2)
    $g.ReleaseHdc($hdc)
  }
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host ("saved {0} ({1} bytes, {2}x{3})" -f $path, (Get-Item $path).Length, $w, $ht)
}

function Set-Clip([string]$text) {
  # Clipboard paste is the only IME-safe way to deliver non-ASCII text.
  [System.Windows.Forms.Clipboard]::SetText($text)
}

function Get-Clip {
  return [System.Windows.Forms.Clipboard]::GetText()
}

function Get-MimoElement {
  # The Chromium page exposes a real accessibility tree, but only after a client
  # asks for it: the first query returns a handful of nodes and the tree is
  # populated on the next one. Query twice, then address elements by NAME instead
  # of by pixel coordinates - that is what keeps this script from being brittle.
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$mimo.MainWindowHandle)
  [void]$el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  Start-Sleep -Milliseconds 900
  return $el
}

function Find-Elements($root, [string]$name, [string]$typeFilter) {
  # "$name" matches by accessible name; "id:<automationId>" matches by id, which is
  # stabler for fields whose name is a placeholder (composer-input, proj-chip).
  if ($name -like 'id:*') {
    $id = $name.Substring(3)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
  } else {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
  }
  $hits = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
  if ($typeFilter) { $hits = @($hits | Where-Object { $_.Current.ControlType.ProgrammaticName -eq $typeFilter }) }
  return $hits
}

function Get-PatternShorts($e) {
  # Each pattern has its own identifiers class, so ProgrammaticName is e.g.
  # "InvokePatternIdentifiers.Pattern" but "ExpandCollapsePatternIdentifiers.Pattern".
  # Reduce both to their short name ("Invoke", "ExpandCollapse", "SelectionItem").
  return @($e.GetSupportedPatterns() | ForEach-Object { ($_.ProgrammaticName -replace '^([A-Za-z]+)PatternIdentifiers\.Pattern$', '$1') })
}

function Get-SupportedPatterns($e) {
  return ((Get-PatternShorts $e) -join ',')
}

function Wait-Elements($root, [string]$name, [int]$Seconds = 8) {
  # Poll for an element instead of sleeping a guessed amount: menus animate, the
  # accessibility tree lags, and the app may already be in either state.
  for ($i = 0; $i -lt ($Seconds * 4); $i++) {
    $hits = @(Find-Elements $root $name $null)
    if ($hits.Count -gt 0) { return $hits }
    Start-Sleep -Milliseconds 250
  }
  return @()
}

function Invoke-Element([string]$name, $root) {
  # Activate an element by name/id, waiting for it to exist first.
  $hits = Wait-Elements $root $name 8
  if ($hits.Count -eq 0) { throw "no element matching '$name' (waited 8s)" }
  foreach ($h in $hits) {
    $pats = Get-PatternShorts $h
    if ($pats -contains 'Invoke') { $h.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Write-Host ("  invoke '{0}'" -f $h.Current.Name); return $true }
    if ($pats -contains 'ExpandCollapse') { $h.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Write-Host ("  expand '{0}'" -f $h.Current.Name); return $true }
    if ($pats -contains 'SelectionItem') { $h.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Write-Host ("  select '{0}'" -f $h.Current.Name); return $true }
    if ($pats -contains 'LegacyIAccessible') { $h.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern).DoDefaultAction(); Write-Host ("  default-action '{0}'" -f $h.Current.Name); return $true }
  }
  throw "element '$name' supports no clickable pattern"
}

function Set-ElementValue([string]$name, [string]$text, $root) {
  $hits = @()
  for ($i = 0; $i -lt 24; $i++) {
    $hits = @(Find-Elements $root $name $null | Where-Object { (Get-PatternShorts $_) -contains 'Value' })
    if ($hits.Count -gt 0) { break }
    Start-Sleep -Milliseconds 250
  }
  if ($hits.Count -eq 0) { throw "no writable element matching '$name' (waited 6s)" }
  $hits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
  Write-Host ("  set '{0}' (id={1})" -f $hits[0].Current.Name, $hits[0].Current.AutomationId)
}

function Wait-FolderDialog([int]$TargetPid, [int]$Seconds = 10) {
  $dlg = $null
  for ($i = 0; $i -lt ($Seconds * 2) -and -not $dlg; $i++) {
    Start-Sleep -Milliseconds 500
    $dlg = @(Get-WindowList | Where-Object { $_.Pid -eq $TargetPid -and $_.Class -eq '#32770' -and $_.Visible }) | Select-Object -First 1
  }
  return $dlg
}

function Submit-FolderDialog($dlg, [string]$dir) {
  # The folder picker is a legacy dialog: its OK button is child window id 1 and
  # the folder box is edit id 1152, so both can be driven without focus or keys.
  $edit = [W.A]::GetDlgItem([IntPtr]$dlg.Hwnd, 1152)
  if ($edit -eq [IntPtr]::Zero) { throw 'folder dialog: edit 1152 not found' }
  [void][W.A]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, $dir)
  Start-Sleep -Milliseconds 400
  $ok = [W.A]::GetDlgItem([IntPtr]$dlg.Hwnd, 1)
  if ($ok -eq [IntPtr]::Zero) { throw 'folder dialog: OK button (id 1) not found' }
  [void][W.A]::SendMessagePtr($ok, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 1200
}

function Clear-Overlays($root) {
  # Popups (a menu, the project picker) hide the rest of the page from the
  # accessibility tree, so a half-finished flow can leave the app in a state where
  # nothing is addressable. Press ESC until no overlay signature is left.
  for ($i = 0; $i -lt 5; $i++) {
    $overlay = $false
    if ((Wait-Elements $root $UI.useExistingFolder 1).Count -gt 0) { $overlay = $true }
    if ((Wait-Elements $root ("id:" + $UI.projSearchId) 1).Count -gt 0) { $overlay = $true }
    if (-not $overlay) { return $true }
    Write-Host '  an overlay was open - pressing ESC'
    Send-Sequence 'ESC'
    Start-Sleep -Milliseconds 700
  }
  return $false
}

function Get-ApiContext {
  $cred = Join-Path $env:APPDATA 'Xiaomi MiMo\desktop-api.json'
  $j = (Get-Content $cred -Raw -Encoding UTF8 | ConvertFrom-Json)
  return [pscustomobject]@{
    Base = ("http://127.0.0.1:{0}" -f $j.port)
    Head = @{ Authorization = "Bearer $($j.token)"; Host = ("127.0.0.1:{0}" -f $j.port); 'Content-Type' = 'application/json' }
  }
}

$mimo = Get-MimoProcess
$mimoPid = [int]$mimo.Id
$mimoHwnd = [IntPtr]$mimo.MainWindowHandle

# UI labels live in a UTF-8 data file: PowerShell 5.1 reads script files with the
# ANSI code page, so Chinese literals inside this .ps1 would be corrupted.
$uiNamesPath = Join-Path $PSScriptRoot 'ui-names.json'
if (-not (Test-Path $uiNamesPath)) { throw "ui-names.json not found next to this script: $uiNamesPath" }
$UI = [System.IO.File]::ReadAllText($uiNamesPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

Write-Host ("MiMo pid={0} hwnd={1} title='{2}'" -f $mimoPid, $mimoHwnd, $mimo.MainWindowTitle)

switch ($Action) {
  'probe' {
    $r = Get-Rect $mimoHwnd
    $fg = Get-Foreground
    Write-Host ("window rect = {0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    Write-Host ("foreground = pid {0} ({1})" -f $fg.Pid, $fg.Name)
  }
  'focus' {
    [void](Focus-Mimo $mimo $mimoPid)
    Write-Host 'focus OK'
  }
  'shot' {
    if (-not $Out) { throw '-Out is required' }
    Save-Shot $mimoHwnd $Out $false
  }
  'screencap' {
    if (-not $Out) { throw '-Out is required' }
    Save-Shot $mimoHwnd $Out $true
  }
  'hover' {
    if ($X -lt 0 -or $Y -lt 0) { throw '-X and -Y are required' }
    [void](Focus-Mimo $mimo $mimoPid)
    Move-WindowPoint $mimoHwnd $X $Y $SettleMs
    Write-Host 'hovered'
  }
  'paste' {
    # Put the contents of -MessageFile on the clipboard and press Ctrl+V. Used for
    # both the project search box and the composer, so no Chinese ever travels
    # through key-synthesis or a command line.
    if (-not $MessageFile -or -not (Test-Path $MessageFile)) { throw '-MessageFile is required' }
    $text = ([System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)).Trim()
    $keep = Get-Clip
    Set-Clip $text
    Start-Sleep -Milliseconds 250
    Send-Sequence 'CTRL+V'
    Start-Sleep -Milliseconds 400
    if ($keep) { Set-Clip $keep }
    Write-Host ("pasted {0} chars" -f $text.Length)
  }
  'click' {
    if ($X -lt 0 -or $Y -lt 0) { throw '-X and -Y (window coordinates) are required' }
    [void](Focus-Mimo $mimo $mimoPid)
    Click-Window $mimoHwnd $X $Y $SettleMs
    Write-Host 'clicked'
  }
  'keys' {
    if (-not $Keys) { throw '-Keys is required' }
    [void](Focus-Mimo $mimo $mimoPid)
    Send-Sequence $Keys
    Start-Sleep -Milliseconds $SettleMs
    Write-Host ("sent: {0}" -f $Keys)
  }
  'tree' {
    # Dump the interactive elements so automation can address them by name.
    $root = Get-MimoElement
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    Write-Host ("elements: {0}" -f $all.Count)
    $keep = @('ControlType.Button', 'ControlType.Edit', 'ControlType.Document', 'ControlType.Text', 'ControlType.ListItem', 'ControlType.MenuItem', 'ControlType.Hyperlink')
    $n = 0
    foreach ($e in $all) {
      $t = $e.Current.ControlType.ProgrammaticName
      if ($keep -notcontains $t) { continue }
      $nm = $e.Current.Name
      if (-not $nm) { continue }
      $n++
      if ($n -gt 90) { break }
      Write-Host ("  [{0}] name='{1}' id='{2}' patterns={3}" -f $t.Replace('ControlType.', ''), $nm, $e.Current.AutomationId, (Get-SupportedPatterns $e))
    }
  }
  'invoke' {
    # Click an element by its accessible name. Driven by whatever pattern the
    # element actually supports: buttons use Invoke, dropdown chips use
    # ExpandCollapse, list rows use SelectionItem. No coordinates, no keystrokes.
    if (-not $Keys) { throw '-Keys is required: the element name to click' }
    $root = Get-MimoElement
    $hits = @(Find-Elements $root $Keys $null)
    if ($hits.Count -eq 0) { throw "no element named '$Keys'" }
    $target = $null
    $how = ''
    foreach ($h in $hits) {
      $pats = Get-PatternShorts $h
      if ($pats -contains 'Invoke') { $target = $h; $how = 'Invoke'; break }
      if ($pats -contains 'ExpandCollapse') { $target = $h; $how = 'Expand'; break }
      if ($pats -contains 'SelectionItem') { $target = $h; $how = 'Select'; break }
      if ($pats -contains 'LegacyIAccessible') { $target = $h; $how = 'DefaultAction'; break }
    }
    if (-not $target) { throw "element '$Keys' supports no clickable pattern" }
    Write-Host ("activating '{0}' via {1}" -f $target.Current.Name, $how)
    switch ($how) {
      'Invoke' { $target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
      'Expand' { $target.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() }
      'Select' { $target.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }
      'DefaultAction' { $target.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern).DoDefaultAction() }
    }
    Start-Sleep -Milliseconds $SettleMs
    Write-Host 'activated'
  }
  'setvalue' {
    # Set a text field's value through UIA (IME-safe, no keystrokes). Address the
    # field by name or by "id:<automationId>".
    if (-not $Keys) { throw '-Keys is required: the field name or id:<automationId>' }
    if (-not $MessageFile -or -not (Test-Path $MessageFile)) { throw '-MessageFile is required' }
    $text = ([System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)).Trim()
    $root = Get-MimoElement
    $hits = @(Find-Elements $root $Keys $null | Where-Object { (Get-PatternShorts $_) -contains 'Value' })
    if ($hits.Count -eq 0) { throw "no writable element matching '$Keys'" }
    $hits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    Start-Sleep -Milliseconds 500
    Write-Host ("set '{0}' (id={1}) to {2} chars" -f $hits[0].Current.Name, $hits[0].Current.AutomationId, $text.Length)
  }

  'newproject' {
    # Create a project whose folder is exactly the given path, through the app's
    # own UI: [new project] -> [use an existing folder] -> pick the folder.
    # Labels come from ui-names.json (see the note at the top of that file).
    if (-not $ProjectFile -or -not (Test-Path $ProjectFile)) { throw '-ProjectFile is required' }
    $dir = ([System.IO.File]::ReadAllText($ProjectFile, [System.Text.Encoding]::UTF8)).Trim()
    [void](Focus-Mimo $mimo $mimoPid)
    $root = Get-MimoElement
    [void](Clear-Overlays $root)
    $root = Get-MimoElement
    # The menu may already be open; only click the sidebar entry when its items are
    # not visible yet.
    if ((Wait-Elements $root $UI.useExistingFolder 1).Count -eq 0) {
      Invoke-Element $UI.newProjectButton $root
      Start-Sleep -Milliseconds 500
      $root = Get-MimoElement
    }
    Invoke-Element $UI.useExistingFolder $root
    $dlg = Wait-FolderDialog $mimoPid 10
    if (-not $dlg) { throw 'folder dialog did not open' }
    Write-Host ("  dialog hwnd={0} title='{1}'" -f $dlg.Hwnd, $dlg.Title)
    Submit-FolderDialog $dlg $dir
    $left = @(Get-WindowList | Where-Object { $_.Pid -eq $mimoPid -and $_.Class -eq '#32770' -and $_.Visible }).Count
    if ($left -gt 0) { throw 'folder dialog did not close - project not created' }
    Write-Host ("project submitted: {0}" -f $dir)
  }
  'newtask' {
    # Create a session *inside* the project at -Dir and submit the task text.
    # No coordinates and no typing: elements are addressed by accessible name or
    # automation id, and the text fields are written through the UIA Value pattern.
    if (-not $ProjectFile -or -not (Test-Path $ProjectFile)) { throw '-ProjectFile is required' }
    if (-not $MessageFile -or -not (Test-Path $MessageFile)) { throw '-MessageFile is required' }
    $dir = ([System.IO.File]::ReadAllText($ProjectFile, [System.Text.Encoding]::UTF8)).Trim()
    $msg = ([System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)).Trim()
    $name = Split-Path $dir -Leaf
    $api = Get-ApiContext
    $before = @()
    foreach ($s in (Invoke-RestMethod -Uri ("{0}/v1/sessions?limit=30" -f $api.Base) -Headers $api.Head -TimeoutSec 10)) { $before += $s.id }
    Write-Host ("sessions before: {0}, project='{1}'" -f $before.Count, $name)

    [void](Focus-Mimo $mimo $mimoPid)
    $root = Get-MimoElement
    [void](Clear-Overlays $root)
    $root = Get-MimoElement
    Invoke-Element $UI.newTaskButton $root
    Start-Sleep -Milliseconds 900
    $root = Get-MimoElement
    Invoke-Element ("id:" + $UI.projChipId) $root
    Start-Sleep -Milliseconds 800
    $root = Get-MimoElement
    try { Set-ElementValue ("id:" + $UI.projSearchId) $name $root } catch { Write-Host ("  search box unavailable: {0}" -f $_.Exception.Message) }
    Start-Sleep -Milliseconds 700
    $root = Get-MimoElement
    Invoke-Element $name $root
    Start-Sleep -Milliseconds 700
    $root = Get-MimoElement
    Set-ElementValue ("id:" + $UI.composerId) $msg $root
    Start-Sleep -Milliseconds 500
    Send-Sequence 'ENTER'
    Write-Host 'task submitted'

    $hit = $null
    for ($i = 0; $i -lt 10 -and -not $hit; $i++) {
      Start-Sleep -Seconds 3
      foreach ($s in (Invoke-RestMethod -Uri ("{0}/v1/sessions?limit=30" -f $api.Base) -Headers $api.Head -TimeoutSec 10)) {
        if ($before -notcontains $s.id -and $s.directory -eq $dir) { $hit = $s; break }
      }
      Write-Host ("  polling {0}s: match={1}" -f (($i + 1) * 3), $(if ($hit) { $hit.id } else { '-' }))
    }
    if (-not $hit) { Write-Host 'NO SESSION CREATED IN THE PROJECT'; exit 1 }
    Write-Host ("NEW SESSION: id={0} directory='{1}' title='{2}'" -f $hit.id, $hit.directory, $hit.title)
  }
}



