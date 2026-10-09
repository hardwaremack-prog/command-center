# Scan-Apps.ps1 - finds the apps you use most and every web server running on this PC.
#
#   Run it on its own:  powershell -ExecutionPolicy Bypass -File Scan-Apps.ps1
#     -> writes %LOCALAPPDATA%\Command Center\scan.json and prints a short summary.
#   Command Center dot-sources it (". .\Scan-Apps.ps1") to reuse the functions below.
#
# Where "most used" comes from:
#   - Windows' own launch counter (UserAssist in the registry): how many times you opened
#     each program or shortcut from Start, the taskbar or the desktop, and when you last did.
#   - Shortcuts on the Desktop, in the Start menu and pinned to the taskbar.
#   - Apps in Desktop\My Apps (folders with a Start/Open file, an .exe or a same-named .html).
# Web servers: every TCP port something is listening on, which program owns it, whether it is
# reachable from other devices, and whether it answers like a web page (status + page title).
#
# Read-only: it never changes anything. Plain ASCII so Windows PowerShell 5.1 reads it.

param([switch]$Quiet)

$CCData = Join-Path $env:LOCALAPPDATA 'Command Center'

# ---------------------------------------------------------------- helpers
function ConvertFrom-Rot13([string]$s) {
  $sb = New-Object Text.StringBuilder
  foreach ($c in $s.ToCharArray()) {
    $n = [int]$c
    if ($n -ge 65 -and $n -le 90) { $n = (($n - 65 + 13) % 26) + 65 }
    elseif ($n -ge 97 -and $n -le 122) { $n = (($n - 97 + 13) % 26) + 97 }
    [void]$sb.Append([char]$n)
  }
  return $sb.ToString()
}

$KnownFolders = @{
  '{6D809377-6AF0-444B-8957-A3773F02200E}' = $env:ProgramFiles
  '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
  '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = (Join-Path $env:SystemRoot 'System32')
  '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = (Join-Path $env:SystemRoot 'SysWOW64')
  '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:SystemRoot
  '{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}' = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
  '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}' = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
  '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}' = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned')
  '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}' = [Environment]::GetFolderPath('Desktop')
  '{374DE290-123F-4565-9164-39C4925E467B}' = (Join-Path $env:USERPROFILE 'Downloads')
  '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}' = $env:LOCALAPPDATA
  '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}' = $env:APPDATA
  '{5E6C858F-0E22-4760-9AFE-EA3317B67173}' = $env:USERPROFILE
}
function Expand-KnownFolder([string]$p) {
  if ($p -match '^(\{[0-9A-Fa-f-]{36}\})(.*)$') {
    $base = $KnownFolders[$Matches[1].ToUpper()]
    if ($base) { return ($base + $Matches[2]) }
  }
  return [Environment]::ExpandEnvironmentVariables($p)
}

$script:wsh = $null
function Resolve-Shortcut([string]$lnk) {
  try {
    if (-not $script:wsh) { $script:wsh = New-Object -ComObject WScript.Shell }
    $sc = $script:wsh.CreateShortcut($lnk)
    return @{ target = $sc.TargetPath; args = $sc.Arguments; icon = (($sc.IconLocation -split ',')[0]) }
  } catch { return $null }
}

function Get-UrlTarget([string]$url) {
  try { foreach ($l in (Get-Content -LiteralPath $url)) { if ($l -match '^URL=(.+)$') { return $Matches[1].Trim() } } } catch {}
  return $null
}

$SkipName = '(?i)uninstall|unins\d|readme|read me|help|documentation|manual|release notes|license|website|on the web|support|feedback|changelog|setup|installer|\bupdate\b|repair|crash ?report'

# ---------------------------------------------------------------- Windows launch counts
function Get-LaunchCounts {
  $out = @{}
  $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
  foreach ($guid in '{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}', '{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}') {
    $key = Join-Path $root "$guid\Count"
    if (-not (Test-Path $key)) { continue }
    $item = Get-Item $key
    foreach ($name in $item.GetValueNames()) {
      $data = $item.GetValue($name)
      if (-not ($data -is [byte[]]) -or $data.Length -lt 68) { continue }
      $count = [BitConverter]::ToInt32($data, 4)
      if ($count -le 0) { continue }
      $last = $null
      try { $ft = [BitConverter]::ToInt64($data, 60); if ($ft -gt 0) { $last = [DateTime]::FromFileTime($ft) } } catch {}
      $path = Expand-KnownFolder (ConvertFrom-Rot13 $name)
      if ($path -match '^UEME_') { continue }
      $k = $path.ToLower()
      if ($out.ContainsKey($k)) { $out[$k].uses += $count; if ($last -and (-not $out[$k].last -or $last -gt $out[$k].last)) { $out[$k].last = $last } }
      else { $out[$k] = @{ path = $path; uses = $count; last = $last } }
    }
  }
  return $out
}

# ---------------------------------------------------------------- apps
function Get-ScannedApps {
  $counts = Get-LaunchCounts
  $apps = @{}   # key: lower-case target (+args)
  function Add-Found($name, $target, $arguments, $icon, $source, $shortcut) {
    if (-not $target -or -not $name) { return }
    if ($name -match $SkipName) { return }
    $isUrl = $target -match '^[a-z]+://'
    if (-not $isUrl -and -not (Test-Path -LiteralPath $target)) { return }
    if (-not $isUrl -and $target -match '(?i)\\(rundll32|msiexec|cmd|explorer|conhost)\.exe$' -and -not $arguments) { return }
    $k = ($target + '|' + $arguments).ToLower()
    $uses = 0; $last = $null
    foreach ($ck in @($target.ToLower(), ($shortcut + '').ToLower())) {
      if ($ck -and $counts.ContainsKey($ck)) { $uses += $counts[$ck].uses; $l = $counts[$ck].last; if ($l -and (-not $last -or $l -gt $last)) { $last = $l } }
    }
    if ($apps.ContainsKey($k)) {
      $a = $apps[$k]
      if ($uses -gt $a.uses) { $a.uses = $uses }
      if ($last -and (-not $a.lastUsed -or $last.ToString('s') -gt $a.lastUsed)) { $a.lastUsed = $last.ToString('s') }
      if ($a.sources -notcontains $source) { $a.sources += $source }
      return
    }
    $apps[$k] = [ordered]@{
      n = $name; t = $target; a = $arguments; i = $icon; uses = $uses
      lastUsed = $(if ($last) { $last.ToString('s') } else { $null }); sources = @($source)
    }
  }

  $desk = [Environment]::GetFolderPath('Desktop')
  $places = @(
    @{ dir = $desk; src = 'desktop'; deep = $false }
    @{ dir = [Environment]::GetFolderPath('CommonDesktopDirectory'); src = 'desktop'; deep = $false }
    @{ dir = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); src = 'taskbar'; deep = $false }
    @{ dir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'); src = 'start'; deep = $true }
    @{ dir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'); src = 'start'; deep = $true }
  )
  foreach ($pl in $places) {
    if (-not (Test-Path -LiteralPath $pl.dir)) { continue }
    $files = if ($pl.deep) { Get-ChildItem -LiteralPath $pl.dir -Recurse -File -Include *.lnk, *.url -ErrorAction SilentlyContinue }
             else { Get-ChildItem -LiteralPath $pl.dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.lnk', '.url' } }
    foreach ($f in $files) {
      $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) -replace ' - Shortcut$', ''
      if ($f.Extension -eq '.url') {
        $u = Get-UrlTarget $f.FullName
        if ($u) { Add-Found $name $u '' $f.FullName $pl.src $f.FullName }
      } else {
        $r = Resolve-Shortcut $f.FullName
        if ($r -and $r.target) {
          $icon = $r.icon; if (-not $icon -or -not (Test-Path -LiteralPath $icon)) { $icon = $r.target }
          Add-Found $name $r.target $r.args $icon $pl.src $f.FullName
        }
      }
    }
  }

  # Desktop\My Apps: one entry per app folder
  $my = Join-Path $desk 'My Apps'
  if (Test-Path -LiteralPath $my) {
    foreach ($grp in Get-ChildItem -LiteralPath $my -Directory -ErrorAction SilentlyContinue) {
      foreach ($d in Get-ChildItem -LiteralPath $grp.FullName -Directory -ErrorAction SilentlyContinue) {
        $files = @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue)
        $entry = $files | Where-Object { $_.Name -match '^(Start|Open) .*\.(bat|cmd|html|lnk)$' } | Select-Object -First 1
        if (-not $entry) { $entry = $files | Where-Object { $_.Extension -eq '.html' -and $_.BaseName -eq $d.Name } | Select-Object -First 1 }
        if (-not $entry) { $entry = $files | Where-Object { $_.Extension -eq '.exe' -and $_.Name -notmatch $SkipName } | Select-Object -First 1 }
        if (-not $entry) { $entry = $files | Where-Object { $_.Name -in 'index.html', 'app.html' } | Select-Object -First 1 }
        if (-not $entry) { continue }
        $ico = $files | Where-Object { $_.Extension -eq '.ico' } | Select-Object -First 1
        $iconPath = if ($ico) { $ico.FullName } else { $entry.FullName }
        Add-Found $d.Name $entry.FullName '' $iconPath ('myapps:' + $grp.Name) $null
      }
    }
  }

  # programs Windows counted but that have no shortcut in the places above
  foreach ($c in $counts.Values) {
    if ($c.uses -lt 5 -or $c.path -notmatch '(?i)\.exe$') { continue }
    $k = ($c.path + '|').ToLower()
    if ($apps.ContainsKey($k)) { continue }
    $name = [IO.Path]::GetFileNameWithoutExtension($c.path)
    try { $vi = (Get-Item -LiteralPath $c.path -ErrorAction Stop).VersionInfo; if ($vi.FileDescription) { $name = $vi.FileDescription.Trim() } } catch {}
    Add-Found $name $c.path '' $c.path 'recent' $null
  }

  return @($apps.Values | Sort-Object { [int]$_.uses } -Descending)
}

# ---------------------------------------------------------------- web servers
$SystemProcs = '^(?i)(System|Idle|svchost|lsass|wininit|services|spoolsv|smss|csrss|winlogon|MsMpEng|NisSrv|SearchIndexer|jhi_service|WUDFHost|dasHost|mDNSResponder|vmms|vmcompute)$'
$script:NotHttp = @{}   # "port|pid" -> time it last failed to answer like a web server (re-checked after 3 minutes)

function Test-TcpPort([int]$port, [int]$ms = 250) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $r = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($r.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) { return $true }
    return $false
  } catch { return $false } finally { $c.Close() }
}

function Get-ProcInfo {
  $m = @{}
  try {
    foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId, Name, CommandLine, ExecutablePath)) {
      $m[[int]$p.ProcessId] = $p
    }
  } catch {}
  return $m
}

function Get-FriendlyServerName($proc) {
  if (-not $proc) { return '' }
  $name = [IO.Path]::GetFileNameWithoutExtension([string]$proc.Name)
  $cl = [string]$proc.CommandLine
  # node/python/powershell: name it after the script it runs
  if ($name -match '^(?i)(node|python|pythonw|py|powershell|pwsh|deno|bun|ruby|php|java)$' -and $cl) {
    $m = [regex]::Matches($cl, '(?i)([^\\/"'' ]+\.(js|mjs|cjs|ts|py|ps1|rb|php|jar))')
    if ($m.Count -gt 0) { return ($m[$m.Count - 1].Groups[1].Value + ' (' + $name + ')') }
  }
  try { if ($proc.ExecutablePath) { $d = (Get-Item -LiteralPath $proc.ExecutablePath).VersionInfo.FileDescription; if ($d) { return $d.Trim() } } } catch {}
  return $name
}

function Test-Http([string]$hostName, [int]$port, [int]$timeoutMs = 1500) {
  $r = [ordered]@{ http = $false; status = 0; title = ''; server = '' }
  try {
    $req = [Net.HttpWebRequest]::Create("http://${hostName}:$port/")
    $req.Timeout = $timeoutMs; $req.ReadWriteTimeout = $timeoutMs
    $req.AllowAutoRedirect = $true; $req.MaximumAutomaticRedirections = 3
    $req.UserAgent = 'CommandCenter/1.0'; $req.KeepAlive = $false
    # apps on Windows' built-in web server often only answer to the name "localhost"
    if ($hostName -eq '127.0.0.1' -or $hostName -eq '[::1]') { try { $req.Host = "localhost:$port" } catch {} }
    $resp = $null
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
    $r.http = $true; $r.status = [int]$resp.StatusCode; $r.server = [string]$resp.Headers['Server']
    if ([string]$resp.ContentType -match 'html') {
      $st = $resp.GetResponseStream(); $buf = New-Object byte[] 65536; $tot = 0
      while ($tot -lt $buf.Length) { $n = $st.Read($buf, $tot, $buf.Length - $tot); if ($n -le 0) { break }; $tot += $n }
      $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $tot)
      if ($txt -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') { $r.title = [Net.WebUtility]::HtmlDecode($Matches[1]) -replace '\s+', ' ' }
    }
    $resp.Close()
  } catch {}
  return $r
}

function Get-LanAddress {
  try {
    foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
      if ($a.IPAddress -like '127.*' -or $a.IPAddress -like '169.254.*') { continue }
      if ($a.InterfaceAlias -match '(?i)vEthernet|Loopback|WSL|Hyper-V|VirtualBox|VMware|Tailscale|WireGuard') { continue }
      return $a.IPAddress
    }
  } catch {}
  return $null
}

# Returns every listening TCP port that answers like a web server.
function Get-WebServers([switch]$IncludeNonHttp) {
  $procs = Get-ProcInfo
  $lan = Get-LanAddress
  $byPort = @{}
  $conns = @()
  try { $conns = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch {}
  foreach ($c in $conns) {
    $p = [int]$c.LocalPort
    if (-not $byPort.ContainsKey($p)) { $byPort[$p] = @{ port = $p; pid = [int]$c.OwningProcess; binds = New-Object Collections.ArrayList } }
    [void]$byPort[$p].binds.Add([string]$c.LocalAddress)
  }
  $out = New-Object Collections.ArrayList
  foreach ($e in ($byPort.Values | Sort-Object { $_.port })) {
    $proc = $procs[$e.pid]
    $pname = if ($proc) { [IO.Path]::GetFileNameWithoutExtension([string]$proc.Name) } else { '' }
    # PID 4 (System) owns ports served through Windows' built-in web server (http.sys):
    # Halo Lab and LibreHardwareMonitor use it, so those are checked too; Windows' own ones are dropped below.
    $viaHttpSys = ($e.pid -eq 4)
    if ($viaHttpSys) { if ($e.port -in 135, 139, 445, 5357, 2869, 47001, 5985, 5986) { continue }; $pname = '' }
    elseif ($pname -match $SystemProcs -or $e.pid -le 4) { continue }
    $network = [bool]($e.binds | Where-Object { $_ -notmatch '^(127\.|::1$)' })
    if ($e.pid -eq 4) { $network = $false }   # http.sys listens everywhere but only answers the addresses an app reserved
    $probeHost = '127.0.0.1'
    if (-not ($e.binds | Where-Object { $_ -in '0.0.0.0', '127.0.0.1' })) {
      if ($e.binds -contains '::' -or $e.binds -contains '::1') { $probeHost = '[::1]' }
      else { $probeHost = ($e.binds | Select-Object -First 1) }
    }
    $key = "$($e.port)|$($e.pid)"
    $h = $null
    $failedAt = $script:NotHttp[$key]
    if (-not $failedAt -or ((Get-Date) - $failedAt).TotalMinutes -gt 3) {
      $h = Test-Http $probeHost $e.port 3000
      if ($h.http) { $script:NotHttp.Remove($key) } else { $script:NotHttp[$key] = Get-Date }
    }
    if ((-not $h -or -not $h.http) -and -not $IncludeNonHttp) { continue }
    if ($viaHttpSys -and $h -and $h.status -ge 400 -and -not $h.title) { continue }
    $openHost = if ($probeHost -eq '127.0.0.1' -or $probeHost -eq '[::1]') { 'localhost' } else { $probeHost }
    [void]$out.Add([ordered]@{
      port = $e.port; pid = $e.pid; process = $pname; name = $(if ($viaHttpSys) { 'Windows web server (http.sys)' } else { Get-FriendlyServerName $proc })
      binds = @($e.binds); network = $network
      url = "http://${openHost}:$($e.port)/"
      lanUrl = $(if ($network -and $lan) { "http://${lan}:$($e.port)/" } else { $null })
      http = [bool]($h -and $h.http); status = $(if ($h) { $h.status } else { 0 })
      title = $(if ($h -and $h.status -lt 400 -and $h.title -notmatch '^(?i)(error|not found|404|index of /?)$') { $h.title } else { '' }); server = $(if ($h) { $h.server } else { '' })
    })
  }
  return @($out)
}

# ---------------------------------------------------------------- run on its own
if ($MyInvocation.InvocationName -ne '.') {
  if (-not (Test-Path $CCData)) { New-Item -ItemType Directory -Path $CCData -Force | Out-Null }
  $apps = Get-ScannedApps
  $servers = Get-WebServers
  $scan = [ordered]@{ when = (Get-Date -Format s); computer = $env:COMPUTERNAME; lan = (Get-LanAddress); apps = $apps; servers = $servers }
  $file = Join-Path $CCData 'scan.json'
  $scan | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8
  if (-not $Quiet) {
    Write-Host ("Found {0} apps and {1} web servers. Saved to {2}" -f $apps.Count, $servers.Count, $file)
    Write-Host ''
    Write-Host 'Most used (Windows launch counts):'
    foreach ($a in ($apps | Select-Object -First 15)) { Write-Host ('  {0,5}  {1}' -f $a.uses, $a.n) }
    Write-Host ''
    Write-Host 'Web servers:'
    foreach ($s in $servers) {
      $where = if ($s.network) { 'network' } else { 'this PC' }
      Write-Host ('  :{0,-6} {1,-8} {2}  {3}' -f $s.port, $where, $s.name, $s.title)
    }
  }
}
