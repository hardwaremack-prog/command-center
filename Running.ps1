# Running.ps1 - lets Command Center stop anything that is running on this PC.
#   Command Center dot-sources it twice: in its background thread (Get-RunningList, read-only)
#   and in the window (the Running / Stop window, Stop buttons on server tiles, right-click Stop on apps).
#   Stopping works like Task Manager: apps with a window are asked to close first (so they can save),
#   servers and scripts are ended together with their helper processes. Windows' own core processes
#   are never listed and never stopped. Plain ASCII so Windows PowerShell 5.1 reads it.

# never listed, never stopped: Windows would break, log you out or restart itself
$NeverStop = '^(?i)(System|Idle|Registry|Secure System|Memory Compression|smss|csrss|wininit|winlogon|services|lsass|LsaIso|svchost|dwm|fontdrvhost|sihost|ctfmon|conhost|MsMpEng|NisSrv|SecurityHealthService|SecurityHealthSystray|SgrmBroker|audiodg|spoolsv|WUDFHost|dllhost|RuntimeBroker|explorer|StartMenuExperienceHost|ShellExperienceHost|SearchHost|SearchIndexer|SearchProtocolHost|SearchFilterHost|TextInputHost|smartscreen|taskhostw|ApplicationFrameHost|SystemSettingsBroker|LockApp|UserOOBEBroker|wlanext|dasHost|WmiPrvSE|unsecapp|backgroundTaskHost|CompPkgSrv|MoUsoCoreWorker|TiWorker|TrustedInstaller|vmmem|vmmemWSL|vmcompute|Widgets|WidgetService)$'
# programs that run other people's scripts - named after the script they run
$ScriptHosts = '^(?i)(python|pythonw|py|pyw|node|deno|bun|cmd|powershell|pwsh|wscript|cscript|mshta|java|javaw|ruby|php|llama-server|llama-cli|ollama|ollama app|lms|openclaw|uv|uvicorn|flm)$'
$script:niceCache = @{}

function Get-NiceName([string]$exeName, [string]$path, [string]$cl) {
  if ($exeName -match '^(?i)(node|python|pythonw|py|pyw|powershell|pwsh|deno|bun|ruby|php|java|javaw|cmd|wscript|cscript|mshta)$' -and $cl) {
    $m = [regex]::Matches($cl, '(?i)([^\\/"'' ]+\.(js|mjs|cjs|ts|py|pyw|ps1|bat|cmd|vbs|hta|rb|php|jar))')
    if ($m.Count -gt 0) { return ($m[$m.Count - 1].Groups[1].Value + ' (' + $exeName + ')') }
    if ($cl -match '(?i)\s-m\s+([\w\.]+)') { return ($Matches[1] + ' (' + $exeName + ')') }
  }
  if ($path) {
    if ($script:niceCache.ContainsKey($path)) { return $script:niceCache[$path] }
    $d = ''
    try { $d = [string](Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.FileDescription } catch {}
    $d = $d.Trim()
    if (-not $d -or $d.Length -gt 48 -or $d -match '^(?i)(application|program|launcher)$') { $d = $exeName }
    $script:niceCache[$path] = $d
    return $d
  }
  return $exeName
}

function New-ProcRow($c, $p, $ports, [int]$mySession) {
  $id = [int]$c.ProcessId
  $exe = [IO.Path]::GetFileNameWithoutExtension([string]$c.Name)
  $cl = [string]$c.CommandLine
  $path = [string]$c.ExecutablePath
  $title = ''; $hasWin = $false; $mem = 0; $cpu = 0.0; $start = $null; $sess = $mySession
  if ($p) {
    try { $title = [string]$p.MainWindowTitle; $hasWin = ($p.MainWindowHandle -ne [IntPtr]::Zero -and $title) } catch {}
    try { $mem = [int]($p.WorkingSet64 / 1MB) } catch {}
    try { $cpu = [double]$p.TotalProcessorTime.TotalSeconds } catch {}
    try { $start = $p.StartTime } catch {}
    try { $sess = [int]$p.SessionId } catch {}
  }
  $myPorts = @(); if ($ports -and $ports.ContainsKey($id)) { $myPorts = @($ports[$id] | Sort-Object) }
  $kind = if ($myPorts.Count) { 'server' } elseif ($hasWin) { 'app' } elseif ($exe -match $ScriptHosts) { 'script' } else { 'other' }
  if ($sess -ne $mySession -and $sess -eq 0) { $kind = $(if ($myPorts.Count) { 'server' } else { 'service' }) }
  return @{ pid = $id; ppid = [int]$c.ParentProcessId; exe = $exe; name = (Get-NiceName $exe $path $cl); title = $title
            path = $path; cmd = $cl; mem = $mem; cpu = $cpu; ports = $myPorts; kind = $kind; hasWin = [bool]$hasWin
            start = $start; session = $sess }
}

# Everything running right now (read-only). Used by the background thread every few seconds
# while the Running / Stop window is open.
function Get-RunningList {
  $me = $PID
  $mySession = 1; try { $mySession = (Get-Process -Id $PID).SessionId } catch {}
  $ports = @{}
  try {
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
      $o = [int]$c.OwningProcess
      if (-not $ports.ContainsKey($o)) { $ports[$o] = New-Object Collections.ArrayList }
      if (-not $ports[$o].Contains([int]$c.LocalPort)) { [void]$ports[$o].Add([int]$c.LocalPort) }
    }
  } catch {}
  $gp = @{}; foreach ($p in (Get-Process)) { $gp[[int]$p.Id] = $p }
  $out = New-Object Collections.ArrayList
  foreach ($c in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath)) {
    $id = [int]$c.ProcessId
    if ($id -le 4 -or $id -eq $me) { continue }
    $exe = [IO.Path]::GetFileNameWithoutExtension([string]$c.Name)
    if ($exe -match $NeverStop) { continue }
    if ([string]$c.CommandLine -like '*Command Center.ps1*') { continue }   # this window
    [void]$out.Add((New-ProcRow $c $gp[$id] $ports $mySession))
  }
  return @($out)
}

# ---------------------------------------------------------------- everything below runs in the window

function Wait-UI([int]$ms) {
  # waits without freezing the window
  $frame = New-Object Windows.Threading.DispatcherFrame
  $t = New-Object Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds($ms)
  $t.Tag = $frame
  $t.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
  $t.Start()
  [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Get-CimMap {
  $m = @{}
  try { foreach ($c in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath)) { $m[[int]$c.ProcessId] = $c } } catch {}
  return $m
}

function Get-ProcRow([int]$id, $cimMap) {
  if (-not $cimMap) { $cimMap = @{}; try { $c = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop; if ($c) { $cimMap[$id] = $c } } catch {} }
  $c = $cimMap[$id]; if (-not $c) { return $null }
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue; if (-not $p) { return $null }
  $mySession = 1; try { $mySession = (Get-Process -Id $PID).SessionId } catch {}
  return (New-ProcRow $c $p $null $mySession)
}

# Windows' built-in web server (http.sys) answers for some apps (Halo Lab, Hardware Monitor):
# the port then belongs to "System", so ask Windows which program registered it.
function Get-HttpSysOwners([int]$port) {
  $ErrorActionPreference = 'Continue'   # netsh writing to stderr must never stop Command Center
  $ids = New-Object Collections.ArrayList
  try {
    $txt = (& "$env:SystemRoot\System32\netsh.exe" http show servicestate view=requestq 2>$null) | Out-String
    foreach ($blk in ($txt -split 'Request queue name:')) {
      if ($blk -notmatch "(?i)https?://[^\s/]+:$port/") { continue }
      $i = $blk.IndexOf('Process IDs:'); if ($i -lt 0) { continue }
      $rest = $blk.Substring($i + 12)
      foreach ($line in ($rest -split "`r?`n")) {
        $l = $line.Trim()
        if ($l -match '^\d+$') { [void]$ids.Add([int]$l) } elseif ($l) { break }
      }
    }
  } catch {}
  return @($ids | Where-Object { $_ -gt 4 } | Sort-Object -Unique)
}

function Get-PortOwners([int]$port) {
  $owners = @()
  try { $owners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique) } catch {}
  $out = @()
  foreach ($o in $owners) { if ($o -eq 4) { $out += @(Get-HttpSysOwners $port) } elseif ($o -gt 4) { $out += $o } }
  return @($out | Sort-Object -Unique)
}

# every process started by $id (and by those, and so on) - taskkill /T tries to end them too
function Get-Descendants([int]$id, $cimMap) {
  $out = New-Object Collections.ArrayList
  $queue = New-Object Collections.Queue; $queue.Enqueue($id)
  while ($queue.Count) {
    $n = [int]$queue.Dequeue()
    foreach ($c in $cimMap.Values) {
      $k = [int]$c.ProcessId
      if ([int]$c.ParentProcessId -eq $n -and $k -ne $n -and $k -ne $id -and -not $out.Contains($k)) {
        if ([IO.Path]::GetFileNameWithoutExtension([string]$c.Name) -match $NeverStop) { continue }   # conhost etc. close on their own
        [void]$out.Add($k); $queue.Enqueue($k)
      }
    }
  }
  return @($out)
}

# a .bat that started only this server: stop it too, so its black window does not stay behind
function Get-LauncherId($row, $cimMap) {
  if (-not $row -or -not $row.ppid) { return $null }
  if (-not $cimMap) { $cimMap = Get-CimMap }
  $c = $cimMap[[int]$row.ppid]; if (-not $c) { return $null }
  if ([string]$c.Name -notmatch '^(?i)cmd\.exe$' -or [string]$c.CommandLine -notmatch '(?i)\.(bat|cmd)\b') { return $null }
  $kids = @($cimMap.Values | Where-Object { [int]$_.ParentProcessId -eq [int]$c.ProcessId -and [string]$_.Name -notmatch '^(?i)conhost\.exe$' })
  if ($kids.Count -le 1) { return [int]$c.ProcessId }
  return $null
}

$script:noteUntil = [DateTime]::MinValue
function Show-Note([string]$msg) {
  if (-not $msg) { return }
  try { $ui.SubTitle.Text = $msg; $script:noteUntil = (Get-Date).AddSeconds(10) } catch {}
  try { if ($script:runUi) { $script:runUi.RunNote.Text = (Get-Date -Format 'h:mm:ss tt') + '   ' + $msg } } catch {}
}

# The one place that stops things. $rows: process rows (pid, name, exe, hasWin ...).
# Returns a short sentence saying what happened ('' when you said No).
function Invoke-Stop {
  param($rows, [string]$what, [switch]$Force, [switch]$NoAsk, [switch]$WithLauncher)
  $ErrorActionPreference = 'Continue'   # taskkill complaining (e.g. "could not be terminated") is reported, not fatal
  $rows = @($rows | Where-Object { $_ -and [int]$_.pid -gt 4 -and [int]$_.pid -ne $PID })
  if (-not $rows.Count) { return "$what is not running." }
  $bad = @($rows | Where-Object { $_.exe -match $NeverStop })
  if ($bad.Count) { Show-Error ($bad[0].name + " is part of Windows itself, so Command Center won't stop it."); return '' }

  if (-not $NoAsk) {
    $lines = (@($rows | Select-Object -First 12) | ForEach-Object { '   - ' + $_.name + '   (PID ' + $_.pid + ')' }) -join "`n"
    if ($rows.Count -gt 12) { $lines += "`n   ...and " + ($rows.Count - 12) + ' more' }
    $how = if ($Force) { "`n`nForce stop ends it right away - anything not saved is lost." }
           else { "`n`nApps with a window are asked to close (so they can save). Servers and scripts are ended, with their helpers." }
    $ans = [Windows.MessageBox]::Show(("Stop " + $what + "?`n`n" + $lines + $how), 'Command Center', 'YesNo', 'Question')
    if ([string]$ans -ne 'Yes') { return '' }
  }

  $cimMap = Get-CimMap
  $closing = New-Object Collections.ArrayList
  $kill = New-Object Collections.ArrayList
  foreach ($r in $rows) {
    $p = Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue
    if (-not $p) { continue }
    $win0 = $false; try { $win0 = ($p.MainWindowHandle -ne [IntPtr]::Zero) } catch {}
    if (-not $Force -and $win0) {
      $ok = $false; try { $ok = $p.CloseMainWindow() } catch {}
      if ($ok) { [void]$closing.Add(@{ row = $r; proc = $p }); continue }
    }
    [void]$kill.Add($r)
  }
  if ($WithLauncher) {
    foreach ($r in @($kill)) {
      $l = Get-LauncherId $r $cimMap
      if ($l -and -not ($kill | Where-Object { [int]$_.pid -eq $l })) { [void]$kill.Add(@{ pid = $l; name = 'its launcher window'; exe = 'cmd'; helper = $true }) }
    }
  }

  $stopped = New-Object Collections.ArrayList; $denied = New-Object Collections.ArrayList; $failed = New-Object Collections.ArrayList
  $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  foreach ($r in $kill) {
    $id = [int]$r.pid
    if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { if (-not $r.helper) { [void]$stopped.Add($r) }; continue }
    $kids = @(Get-Descendants $id $cimMap)
    $o = ''
    try { $o = (@(& $taskkill /PID $id /T /F 2>&1) | ForEach-Object { [string]$_ }) -join "`n" } catch { $o = [string]$_ }
    for ($w = 0; $w -lt 8 -and (Get-Process -Id $id -ErrorAction SilentlyContinue); $w++) { Wait-UI 100 }
    # the program and every helper it started: which are still running?
    $left = @(@($id) + $kids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if (-not $left.Count) { if (-not $r.helper) { [void]$stopped.Add($r) }; continue }
    $isDenied = $o -match '(?i)denied|access|privilege|could not be terminated'
    foreach ($l in $left) {
      $row = $r
      if ($l -ne $id) {
        $c = $cimMap[[int]$l]
        $ex = if ($c) { [IO.Path]::GetFileNameWithoutExtension([string]$c.Name) } else { 'helper' }
        $nm = if ($c) { Get-NiceName $ex ([string]$c.ExecutablePath) ([string]$c.CommandLine) } else { 'helper' }
        $row = @{ pid = [int]$l; name = ($nm + ' (part of ' + $r.name + ')'); exe = $ex; helper = $true }
      }
      if ($isDenied) { [void]$denied.Add($row) } else { [void]$failed.Add($row) }
    }
    if ($left -notcontains $id -and -not $r.helper) { [void]$stopped.Add($r) }
  }

  # windows that were asked to close get up to 5 seconds
  $stillOpen = New-Object Collections.ArrayList
  if ($closing.Count) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 5) {
      $open = @($closing | Where-Object { $gone = $true; try { $gone = $_.proc.HasExited } catch { $gone = -not (Get-Process -Id ([int]$_.row.pid) -ErrorAction SilentlyContinue) }; -not $gone })
      if (-not $open.Count) { break }
      Wait-UI 200
    }
    foreach ($c in $closing) {
      if (Get-Process -Id ([int]$c.row.pid) -ErrorAction SilentlyContinue) { [void]$stillOpen.Add($c.row) } else { [void]$stopped.Add($c.row) }
    }
  }

  if ($denied.Count) {
    $names = (@($denied) | ForEach-Object { '   - ' + $_.name + '   (PID ' + $_.pid + ')' }) -join "`n"
    $ans = [Windows.MessageBox]::Show(("Windows only lets an administrator stop:`n`n" + $names + "`n`nTry again as administrator? Windows will ask you first."), 'Command Center', 'YesNo', 'Warning')
    if ([string]$ans -eq 'Yes') {
      try {
        $argList = '/F /T ' + ((@($denied) | ForEach-Object { '/PID ' + $_.pid }) -join ' ')
        Start-Process -FilePath $taskkill -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -Wait
      } catch {}
      Wait-UI 300
      foreach ($r in @($denied)) { if (-not (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)) { if (-not $r.helper) { [void]$stopped.Add($r) }; $denied.Remove($r) } }
    }
  }

  try { $bg.procsNow = $true; $bg.serversNow = $true } catch {}
  $parts = @()
  if ($stopped.Count) {
    $n = @($stopped | ForEach-Object { $_.name } | Select-Object -Unique)
    $parts += ('Stopped ' + $(if ($n.Count -le 3) { $n -join ', ' } else { [string]$n.Count + ' programs' }) + '.')
  }
  if ($stillOpen.Count) { $parts += ((@($stillOpen | ForEach-Object { $_.name }) -join ', ') + ' is still open - it may be asking you to save. Use Force stop to end it anyway.') }
  if ($denied.Count)    { $parts += ("Couldn't stop " + (@($denied | ForEach-Object { $_.name }) -join ', ') + ' (needs administrator).') }
  if ($failed.Count)    { $parts += ("Couldn't stop " + (@($failed | ForEach-Object { $_.name }) -join ', ') + '.') }
  if (-not $parts.Count) { $parts += "$what had already stopped." }
  $msg = $parts -join '  '
  if ($stillOpen.Count -or $denied.Count -or $failed.Count) { [void][Windows.MessageBox]::Show($msg, 'Command Center') }
  return $msg
}

# ---- web server tiles
function Remove-ServerFromList([int]$port) {
  try { $bg.servers = @($bg.servers | Where-Object { [int]$_.port -ne $port }); $bg.up[$port] = $false } catch {}
}

function Stop-Server($srv, [switch]$Force, [switch]$NoAsk) {
  if ($srv.stop -and -not $Force) {
    $r = & $srv.stop
    if ($r) { Show-Note $r; try { $bg.serversNow = $true } catch {}; return $true }
  }
  $ids = @(Get-PortOwners ([int]$srv.port))
  if (-not $ids.Count -and $srv.procName) { $ids = @(Get-Process -Name $srv.procName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
  if (-not $ids.Count -and [int]$srv.pid -gt 4) { $ids = @([int]$srv.pid) }
  if (-not $ids.Count) {
    if (-not (Test-PortNow ([int]$srv.port))) { Remove-ServerFromList ([int]$srv.port); Show-Note ($srv.n + ' is not running.'); return $true }
    Show-Error ("Couldn't tell which program runs " + $srv.n + " (port " + $srv.port + ").`n`nOpen 'Running / Stop' at the top of Command Center and stop it from the list.")
    return $false
  }
  $map = Get-CimMap
  $rows = @($ids | ForEach-Object { Get-ProcRow $_ $map } | Where-Object { $_ })
  $msg = Invoke-Stop $rows ($srv.n + ' (port ' + $srv.port + ')') -Force:$Force -NoAsk:$NoAsk -WithLauncher
  if (-not $msg) { return $false }
  if (-not (Test-PortNow ([int]$srv.port))) { Remove-ServerFromList ([int]$srv.port) }
  Show-Note $msg
  return $true
}

function Restart-Server($srv) {
  if ($srv.restart) { $r = & $srv.restart; if ($r) { Show-Note $r }; return }
  $hit = $apps | Where-Object { $_.p -eq $srv.port } | Select-Object -First 1
  if (-not $hit) { return }
  $ans = [Windows.MessageBox]::Show(("Restart " + $srv.n + "?`n`nIt is stopped, then opened again."), 'Command Center', 'YesNo', 'Question')
  if ([string]$ans -ne 'Yes') { return }
  if (Stop-Server $srv -NoAsk) {
    for ($i = 0; $i -lt 20 -and (Test-PortNow ([int]$srv.port)); $i++) { Wait-UI 250 }
    Wait-UI 600
    Start-App $hit
    Show-Note ('Restarting ' + $srv.n + '...')
  }
}

# ---- app tiles: which running programs belong to this tile?
function Find-AppRows($app) {
  $ids = @()
  if ($app.p -and (Test-PortNow ([int]$app.p))) { $ids += @(Get-PortOwners ([int]$app.p)) }
  if ($app.proc) { $ids += @(Get-Process -Name $app.proc -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
  $t = [string]$app.t; $a = [string]$app.a
  $map = $null
  if (-not $ids.Count -and $t -and $t -notlike 'http*') {
    if ($t -like '*.lnk') { $s = Resolve-Shortcut $t; if ($s -and $s.target) { $t = [string]$s.target; $a = [string]$s.args } }
    $exeName = ''; try { $exeName = [IO.Path]::GetFileNameWithoutExtension($t) } catch {}
    $isHost = $exeName -match '^(?i)(powershell|pwsh|cmd|python|pythonw|py|pyw|wscript|cscript|node|mshta)$'
    if ($isHost -and $a -match '(?i)([A-Za-z]:\\[^"]+?\.(ps1|bat|cmd|py|pyw|js|vbs|hta))') { $t = $Matches[1] }
    $ext = ''; try { $ext = [IO.Path]::GetExtension($t).ToLower() } catch {}
    $map = Get-CimMap
    if ($ext -eq '.exe' -and -not $isHost) {
      $ids = @($map.Values | Where-Object { [string]$_.ExecutablePath -eq $t } | ForEach-Object { [int]$_.ProcessId })
    } elseif ($ext -in '.bat', '.cmd', '.ps1', '.py', '.pyw', '.js', '.vbs', '.hta') {
      $dir = (Split-Path -Parent $t).TrimEnd('\') + '\'
      $ids = @($map.Values | Where-Object {
        $cl = [string]$_.CommandLine
        $cl -and $cl.IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $cl -notlike '*Command Center.ps1*' -and [int]$_.ProcessId -ne $PID
      } | ForEach-Object { [int]$_.ProcessId })
      # keep only the top ones - the rest are their helpers and go with them
      $set = @{}; foreach ($i in $ids) { $set[$i] = $true }
      $ids = @($ids | Where-Object { -not $set.ContainsKey([int]$map[$_].ParentProcessId) })
    }
  }
  if (-not $ids.Count) { return @() }
  if (-not $map) { $map = Get-CimMap }
  return @($ids | Sort-Object -Unique | ForEach-Object { Get-ProcRow $_ $map } | Where-Object { $_ -and $_.exe -notmatch $NeverStop })
}

function Add-AppStopMenu($b) {
  $cm = New-Object Windows.Controls.ContextMenu
  $miOpen = New-Object Windows.Controls.MenuItem; $miOpen.Header = 'Open'
  $miOpen.Add_Click({ param($s, $e) Start-App $s.Parent.PlacementTarget.Tag })
  $miStop = New-Object Windows.Controls.MenuItem; $miStop.Header = 'Stop'
  $miStop.Add_Click({ param($s, $e)
    $app = $s.Parent.PlacementTarget.Tag
    $m = Invoke-Stop $s.Parent.Tag $app.n -WithLauncher; Show-Note $m })
  $miForce = New-Object Windows.Controls.MenuItem; $miForce.Header = 'Force stop'
  $miForce.Add_Click({ param($s, $e)
    $app = $s.Parent.PlacementTarget.Tag
    $m = Invoke-Stop $s.Parent.Tag $app.n -Force -WithLauncher; Show-Note $m })
  [void]$cm.Items.Add($miOpen); [void]$cm.Items.Add((New-Object Windows.Controls.Separator))
  [void]$cm.Items.Add($miStop); [void]$cm.Items.Add($miForce)
  $b.ContextMenu = $cm
  $b.Add_ContextMenuOpening({ param($s, $e)
    $cm = $s.ContextMenu; $app = $s.Tag
    $rows = @()
    try { $rows = @(Find-AppRows $app) } catch {}
    $cm.Tag = $rows
    $miStop = $cm.Items[2]; $miForce = $cm.Items[3]
    if ($rows.Count) {
      $miStop.Header = 'Stop ' + $app.n + $(if ($rows.Count -gt 1) { '  (' + $rows.Count + ' programs)' } else { '' })
      $miStop.IsEnabled = $true; $miForce.IsEnabled = $true
    } else {
      $miStop.Header = $(if ($app.t -like '*.html' -or $app.t -like 'http*') { 'Runs in your browser - close its tab' } else { $app.n + ' is not running' })
      $miStop.IsEnabled = $false; $miForce.IsEnabled = $false
    }
  })
}

# ---------------------------------------------------------------- the Running / Stop window
[xml]$runXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Running / Stop - Command Center" Width="980" Height="760" MinWidth="640" MinHeight="420"
        WindowStartupLocation="CenterOwner" Background="#0F131B" FontFamily="Segoe UI" Foreground="#E8ECF4">
  <Window.Resources>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="#E8ECF4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#232C3E" CornerRadius="16" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2F3A52"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#3A4766"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="StopPill" TargetType="Button">
      <Setter Property="Foreground" Value="#FF8A8A"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#3A1F24" BorderBrush="#5A2C33" BorderThickness="1" CornerRadius="16" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF5A5A"/>
                <Setter Property="Foreground" Value="#1A0F0C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#E04848"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="22,16,8,10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,14,12">
      <TextBlock Text="Running on this PC" FontSize="24" FontWeight="SemiBold"/>
      <TextBlock x:Name="RunSub" Text="Looking..." Foreground="#8C97AD" FontSize="13" Margin="1,2,0,0"/>
    </StackPanel>
    <DockPanel Grid.Row="1" Margin="0,0,14,12" LastChildFill="False">
      <Border DockPanel.Dock="Left" Background="#171D29" BorderBrush="#263045" BorderThickness="1" CornerRadius="18" Width="280" Height="36">
        <Grid>
          <TextBlock x:Name="RunHint" Text="Find a program, port or PID" Foreground="#5E6980" Margin="16,0,0,0"
                     VerticalAlignment="Center" IsHitTestVisible="False" FontSize="13"/>
          <TextBox x:Name="RunSearch" Background="Transparent" BorderThickness="0" Foreground="#E8ECF4" CaretBrush="#E8ECF4"
                   Margin="14,0,14,0" VerticalAlignment="Center" FontSize="14"/>
        </Grid>
      </Border>
      <CheckBox x:Name="ShowAll" DockPanel.Dock="Left" Content="Show everything" Foreground="#B8C2D6" FontSize="13"
                VerticalAlignment="Center" Margin="16,0,0,0"
                ToolTip="Also list background programs and Windows services (stopping services needs administrator)"/>
      <Button x:Name="StopAllBtn" DockPanel.Dock="Right" Style="{StaticResource StopPill}" Content="Stop all my servers..."
              ToolTip="Stops every server and script you started - Python, Node, PowerShell, OpenClaw, Ollama, llama.cpp and anything run from the Desktop or My Apps. You see the list first."/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Refresh"/>
    </DockPanel>
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="RunList" Margin="0,0,6,0"/>
    </ScrollViewer>
    <TextBlock x:Name="RunNote" Grid.Row="3" Foreground="#B8C2D6" FontSize="12.5" Margin="2,10,14,0" TextWrapping="Wrap"
               Text="Stop asks apps with a window to close (so they can save). Servers and scripts end together with their helpers. Right-click or ... for Force stop and more."/>
  </Grid>
</Window>
'@

$script:runWin = $null
$script:runUi = $null
$script:runSig = ''
$script:runCells = @{}
$script:runAt = $null
$script:cpuPrev = @{}
$kindInfo = [ordered]@{
  server  = @{ title = 'Servers - programs listening on a port'; color = '#3DDC84' }
  app     = @{ title = 'Apps with a window';                    color = '#5B8CFF' }
  script  = @{ title = 'Scripts and helpers';                   color = '#FFB547' }
  other   = @{ title = 'Background programs';                   color = '#8C97AD' }
  service = @{ title = 'Windows services (need administrator)'; color = '#C77DFF' }
}

function Format-Uptime($start) {
  if (-not $start) { return '' }
  $s = (Get-Date) - $start
  if ($s.TotalMinutes -lt 1) { return 'just started' }
  if ($s.TotalHours -lt 1) { return ('up ' + [int]$s.TotalMinutes + 'm') }
  if ($s.TotalDays -lt 1) { return ('up ' + [int][Math]::Floor($s.TotalHours) + 'h ' + $s.Minutes + 'm') }
  return ('up ' + [int][Math]::Floor($s.TotalDays) + 'd ' + $s.Hours + 'h')
}

function Format-Mem([int]$mb) { if ($mb -ge 1024) { return ('{0:N1} GB' -f ($mb / 1024)) } return ([string]$mb + ' MB') }

function Get-MyServerRows {
  $desk = $Desk.TrimEnd('\') + '\'
  return @(@($bg.procs) | Where-Object {
    ($_.kind -eq 'server' -or $_.kind -eq 'script') -and $_.session -ne 0 -and (
      $_.exe -match $ScriptHosts -or
      ([string]$_.path).StartsWith($desk, [StringComparison]::OrdinalIgnoreCase) -or
      ([string]$_.cmd).IndexOf($desk, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      $_.exe -match '^(?i)(LibreHardwareMonitor|ComfyUI)$')
  } | Where-Object { -not ($_.exe -eq 'cmd' -and -not $_.ports.Count -and ([string]$_.cmd) -match '(?i)^"?[^"]*cmd(\.exe)?"?\s*$') })
}

function New-RunRow($r) {
  $bd = New-Object Windows.Controls.Border
  $bd.CornerRadius = 10; $bd.BorderThickness = 1; $bd.Padding = '12,8,10,8'; $bd.Margin = '0,0,8,6'
  $bd.Background = $brush.ConvertFrom('#171D29'); $bd.BorderBrush = $brush.ConvertFrom('#263045')
  $g = New-Object Windows.Controls.Grid
  foreach ($w in 'Auto', '*', '64', '84', 'Auto', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }

  $img = $null; if ($r.path) { $img = Get-AppIcon @{ t = $r.path } }
  if ($img) {
    $im = New-Object Windows.Controls.Image; $im.Source = $img; $im.Width = 28; $im.Height = 28; $im.Margin = '0,0,12,0'
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($im, 'HighQuality'); [void]$g.Children.Add($im)
  } else {
    $b0 = New-Object Windows.Controls.Border; $b0.Width = 28; $b0.Height = 28; $b0.CornerRadius = 8; $b0.Margin = '0,0,12,0'
    $b0.Background = $brush.ConvertFrom($kindInfo[$r.kind].color)
    $tb = New-Object Windows.Controls.TextBlock; $tb.Text = ([string]$r.name).Substring(0, 1).ToUpper(); $tb.FontWeight = 'SemiBold'
    $tb.Foreground = $brush.ConvertFrom('#10141C'); $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
    $b0.Child = $tb; [void]$g.Children.Add($b0)
  }

  $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($sp, 1)
  $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $r.name; $t1.FontSize = 13.5; $t1.FontWeight = 'SemiBold'; $t1.TextTrimming = 'CharacterEllipsis'
  $bits = @('PID ' + $r.pid)
  if ($r.ports.Count) { $bits += ('port ' + (($r.ports | Select-Object -First 4) -join ', ')) }
  if ($r.title -and $r.title -ne $r.name) { $bits += $r.title }
  elseif ($r.exe -and $r.name -notlike "*$($r.exe)*") { $bits += ($r.exe + '.exe') }
  $up = Format-Uptime $r.start; if ($up) { $bits += $up }
  $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = ($bits -join '   -   '); $t2.FontSize = 11.5; $t2.Margin = '0,2,0,0'
  $t2.Foreground = $brush.ConvertFrom('#8C97AD'); $t2.TextTrimming = 'CharacterEllipsis'
  [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$g.Children.Add($sp)
  $tip = $r.name + '  (PID ' + $r.pid + ')'
  if ($r.path) { $tip += "`n" + $r.path }
  if ($r.cmd -and $r.cmd -ne ('"' + $r.path + '"') -and $r.cmd -ne $r.path) { $c = [string]$r.cmd; if ($c.Length -gt 300) { $c = $c.Substring(0, 300) + '...' }; $tip += "`n" + $c }
  $sp.ToolTip = $tip

  $cpu = New-Object Windows.Controls.TextBlock; $cpu.HorizontalAlignment = 'Right'; $cpu.VerticalAlignment = 'Center'; $cpu.FontSize = 12.5
  $cpu.Foreground = $brush.ConvertFrom('#B8C2D6'); $cpu.ToolTip = 'CPU'; [Windows.Controls.Grid]::SetColumn($cpu, 2)
  $mem = New-Object Windows.Controls.TextBlock; $mem.HorizontalAlignment = 'Right'; $mem.VerticalAlignment = 'Center'; $mem.FontSize = 12.5
  $mem.Foreground = $brush.ConvertFrom('#B8C2D6'); $mem.Margin = '0,0,14,0'; $mem.ToolTip = 'Memory'; $mem.Text = Format-Mem $r.mem
  [Windows.Controls.Grid]::SetColumn($mem, 3)
  [void]$g.Children.Add($cpu); [void]$g.Children.Add($mem)
  $script:runCells[[int]$r.pid] = @{ cpu = $cpu; mem = $mem }

  $stop = New-Object Windows.Controls.Button; $stop.Style = $script:runWin.FindResource('StopPill'); $stop.Padding = '14,5'
  $stop.Content = $(if ($r.hasWin) { 'Close' } else { 'Stop' }); $stop.Tag = $r; $stop.VerticalAlignment = 'Center'
  $stop.ToolTip = $(if ($r.hasWin) { 'Ask ' + $r.name + ' to close (it can still ask you to save)' } else { 'Stop ' + $r.name + ' and its helpers' })
  $stop.Add_Click({ param($s, $e) $m = Invoke-Stop @($s.Tag) $s.Tag.name -WithLauncher; Show-Note $m })
  [Windows.Controls.Grid]::SetColumn($stop, 4); [void]$g.Children.Add($stop)

  $more = New-Object Windows.Controls.Button; $more.Style = $script:runWin.FindResource('Pill'); $more.Padding = '10,5'
  $more.Content = '...'; $more.VerticalAlignment = 'Center'; $more.ToolTip = 'Force stop and more'
  [Windows.Controls.Grid]::SetColumn($more, 5); [void]$g.Children.Add($more)
  $cm = New-RunMenu $r
  $more.ContextMenu = $cm; $bd.ContextMenu = $cm
  $more.Add_Click({ param($s, $e) $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.IsOpen = $true })

  $bd.Child = $g
  return $bd
}

function New-RunMenu($r) {
  $cm = New-Object Windows.Controls.ContextMenu
  $add = {
    param([string]$h, [scriptblock]$act)
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $h; $mi.Tag = $r; $mi.Add_Click($act); [void]$cm.Items.Add($mi)
  }
  & $add ($(if ($r.hasWin) { 'Close' } else { 'Stop' })) { param($s, $e) Show-Note (Invoke-Stop @($s.Tag) $s.Tag.name -WithLauncher) }
  & $add 'Force stop (ends it now, with its helpers)' { param($s, $e) Show-Note (Invoke-Stop @($s.Tag) $s.Tag.name -Force -WithLauncher) }
  $same = @(@($bg.procs) | Where-Object { $_.exe -eq $r.exe -and $_.session -eq $r.session })
  if ($same.Count -gt 1 -and $r.exe -notmatch '^(?i)(cmd|powershell|pwsh)$') {
    & $add ('Stop every ' + $r.exe + '.exe  (' + $same.Count + ' running)') { param($s, $e)
      $all = @(@($bg.procs) | Where-Object { $_.exe -eq $s.Tag.exe -and $_.session -eq $s.Tag.session })
      Show-Note (Invoke-Stop $all ('every ' + $s.Tag.exe + '.exe')) }
  }
  [void]$cm.Items.Add((New-Object Windows.Controls.Separator))
  if ($r.ports.Count) {
    & $add ('Open http://localhost:' + $r.ports[0] + '/') { param($s, $e) try { Start-Process ('http://localhost:' + $s.Tag.ports[0] + '/') } catch {} }
  }
  if ($r.path) { & $add 'Show file in Explorer' { param($s, $e) try { Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ('/select,"' + $s.Tag.path + '"') } catch {} } }
  if ($r.cmd) { & $add 'Copy command line' { param($s, $e) Copy-Text ([string]$s.Tag.cmd) } }
  & $add ('Copy PID  (' + $r.pid + ')') { param($s, $e) Copy-Text ([string]$s.Tag.pid) }
  return $cm
}

function Update-RunList([switch]$Force) {
  if (-not $script:runWin) { return }
  $ru = $script:runUi
  $all = @($bg.procs)
  if (-not $bg.procsAt) { $ru.RunSub.Text = 'Looking...'; return }
  # CPU % since the last look
  $now = $bg.procsAt; $cores = [Environment]::ProcessorCount
  $cpuPct = @{}; $next = @{}
  foreach ($r in $all) {
    $prev = $script:cpuPrev[[int]$r.pid]
    if ($prev) { $dt = ($now - $prev.at).TotalSeconds; if ($dt -gt 0.2) { $cpuPct[[int]$r.pid] = [Math]::Max(0, ($r.cpu - $prev.cpu) / ($dt * $cores) * 100) } }
    $next[[int]$r.pid] = @{ cpu = $r.cpu; at = $now }
  }
  if ($script:runAt -ne $now) { $script:cpuPrev = $next; $script:runAt = $now }

  $showAll = [bool]$ru.ShowAll.IsChecked
  $q = $ru.RunSearch.Text.Trim()
  $list = @($all | Where-Object {
    ($showAll -or $_.kind -in 'server', 'app', 'script') -and
    (-not $q -or $_.name -like "*$q*" -or $_.exe -like "*$q*" -or $_.title -like "*$q*" -or [string]$_.pid -eq $q -or ($_.ports -contains ($q -as [int])) -or ([string]$_.cmd) -like "*$q*")
  })
  $totMem = 0; foreach ($r in $all) { $totMem += $r.mem }
  $mine = @(Get-MyServerRows).Count
  $ru.RunSub.Text = ('{0} shown  -  {1} programs running  -  {2} memory in use  -  {3} of your servers and scripts' -f $list.Count, $all.Count, (Format-Mem $totMem), $mine) +
                    '   -   checked ' + $now.ToString('h:mm:ss tt')
  $ru.StopAllBtn.IsEnabled = ($mine -gt 0)

  $sig = ($showAll, $q, (($list | ForEach-Object { "$($_.kind)|$($_.pid)|$($_.title)|$($_.ports -join '.')" }) -join ',')) -join '#'
  if ($Force -or $sig -ne $script:runSig) {
    $script:runSig = $sig
    $script:runCells = @{}
    $ru.RunList.Children.Clear()
    foreach ($k in $kindInfo.Keys) {
      $grp = @($list | Where-Object { $_.kind -eq $k })
      if (-not $grp.Count) { continue }
      $grp = $(if ($k -eq 'server') { @($grp | Sort-Object { [int]($_.ports | Select-Object -First 1) }) } else { @($grp | Sort-Object { $_.mem } -Descending) })
      $h = New-Object Windows.Controls.TextBlock
      $h.Text = ($kindInfo[$k].title.ToUpper() + '   -   ' + $grp.Count); $h.FontSize = 11.5; $h.FontWeight = 'SemiBold'
      $h.Foreground = $brush.ConvertFrom($kindInfo[$k].color); $h.Margin = '2,10,0,8'
      [void]$ru.RunList.Children.Add($h)
      foreach ($r in $grp) { [void]$ru.RunList.Children.Add((New-RunRow $r)) }
    }
    if (-not $list.Count) {
      $h = New-Object Windows.Controls.TextBlock; $h.Text = 'Nothing matches.'; $h.Foreground = $brush.ConvertFrom('#8C97AD'); $h.Margin = '2,10,0,0'
      [void]$ru.RunList.Children.Add($h)
    }
  }
  foreach ($r in $list) {
    $c = $script:runCells[[int]$r.pid]; if (-not $c) { continue }
    $c.mem.Text = Format-Mem $r.mem
    $p = $cpuPct[[int]$r.pid]
    $c.cpu.Text = $(if ($null -eq $p) { '' } elseif ($p -lt 0.1) { '0%' } elseif ($p -lt 10) { '{0:N1}%' -f $p } else { '{0:N0}%' -f $p })
    $c.cpu.Foreground = $(if ($p -ge 25) { $amber } else { $brush.ConvertFrom('#B8C2D6') })
  }
}

function Show-RunningWindow {
  if ($script:runWin) { try { $script:runWin.Activate() | Out-Null; return } catch {} }
  $rw = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $runXaml))
  $rw.Owner = $win
  $script:runWin = $rw
  $script:runUi = @{}
  foreach ($n in 'RunSub', 'RunHint', 'RunSearch', 'ShowAll', 'StopAllBtn', 'RefreshBtn', 'RunList', 'RunNote') { $script:runUi[$n] = $rw.FindName($n) }
  $script:runSig = ''; $script:cpuPrev = @{}; $script:runAt = $null
  $bg.procsWanted = $true; $bg.procsNow = $true
  $ru = $script:runUi
  $ru.RunSearch.Add_TextChanged({
    if ($script:runUi.RunSearch.Text) { $script:runUi.RunHint.Visibility = 'Collapsed' } else { $script:runUi.RunHint.Visibility = 'Visible' }
    Update-RunList })
  $ru.RunSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Text = '' } })
  $ru.ShowAll.Add_Click({ Update-RunList })
  $ru.RefreshBtn.Add_Click({ $bg.procsNow = $true; $script:runUi.RunSub.Text = 'Looking...' })
  $ru.StopAllBtn.Add_Click({
    $rows = @(Get-MyServerRows)
    if (-not $rows.Count) { Show-Note 'None of your servers or scripts are running.'; return }
    Show-Note (Invoke-Stop $rows 'all your servers and scripts' -WithLauncher)
  })
  $script:runTimer = New-Object Windows.Threading.DispatcherTimer
  $script:runTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
  $script:runTimer.Add_Tick({ if ($script:runWin -and $script:runAt -ne $bg.procsAt) { Update-RunList } })
  $rw.Add_Closed({ $bg.procsWanted = $false; try { $script:runTimer.Stop() } catch {}; $script:runWin = $null; $script:runUi = $null; $script:runCells = @{} })
  $script:runTimer.Start()
  $rw.Width = [Math]::Min(1200, [Math]::Max(760, $win.ActualWidth * 0.85))
  $rw.Height = [Math]::Max(520, $win.ActualHeight * 0.9)
  $rw.Show()
  [void]$ru.RunSearch.Focus()
}
