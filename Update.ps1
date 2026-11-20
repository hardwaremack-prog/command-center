# Update.ps1 - the "Update" button: gets the newest Command Center from GitHub.
#   Command Center dot-sources it. When it starts, the background thread checks GitHub once
#   (Get-CCUpdates, read-only); the button then shows how many files are newer.
#   Clicking the button shows what will change, then: downloads the files, checks each one
#   arrived whole, checks PowerShell files have no typing errors, saves your current files in
#   backups\<date and time>, puts the new ones in place and restarts Command Center.
#   Your own settings (%LOCALAPPDATA%\Command Center) are never touched.
#   Plain ASCII so Windows PowerShell 5.1 reads it.

$CCRepo   = 'hardwaremack-prog/command-center'
$CCBranch = 'main'
# repo files that are for GitHub only, not for the app folder
$CCSkip   = '^(?i)(README\.md|screenshot\.png|LICENSE.*|\..*)$'

function Get-GitBlobSha([string]$path) {
  # the same fingerprint GitHub uses, so files are compared exactly
  $bytes = [IO.File]::ReadAllBytes($path)
  return (Get-GitBlobShaBytes $bytes)
}
function Get-GitBlobShaBytes([byte[]]$bytes) {
  $head = [Text.Encoding]::ASCII.GetBytes('blob ' + $bytes.Length + [char]0)
  $sha = [Security.Cryptography.SHA1]::Create()
  [void]$sha.TransformBlock($head, 0, $head.Length, $null, 0)
  [void]$sha.TransformFinalBlock($bytes, 0, $bytes.Length)
  return (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Invoke-GitHub([string]$url) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $wc = New-Object Net.WebClient
  $wc.Headers['User-Agent'] = 'CommandCenter-Updater'
  $wc.Headers['Accept'] = 'application/vnd.github+json'
  try { return $wc.DownloadData($url) } finally { $wc.Dispose() }
}

# Which files on GitHub differ from the ones in $dir. Read-only.
function Get-CCUpdates([string]$dir) {
  $json = [Text.Encoding]::UTF8.GetString((Invoke-GitHub "https://api.github.com/repos/$CCRepo/contents?ref=$CCBranch"))
  $items = $json | ConvertFrom-Json
  $out = New-Object Collections.ArrayList
  foreach ($it in $items) {
    if ($it.type -ne 'file' -or [string]$it.name -match $CCSkip) { continue }
    $local = Join-Path $dir $it.name
    $status = 'new'
    if (Test-Path -LiteralPath $local) {
      if ((Get-GitBlobSha $local) -eq [string]$it.sha) { continue }
      $status = 'changed'
    }
    [void]$out.Add(@{ name = [string]$it.name; sha = [string]$it.sha; size = [int]$it.size; url = [string]$it.download_url; status = $status })
  }
  return @($out)
}

# ---------------------------------------------------------------- the button (runs in the window)
$script:updList = $null

function Set-UpdateButton {
  $n = @($script:updList).Count
  if ($null -eq $script:updList) { $ui.UpdateBtn.Content = 'Update'; $ui.UpdateBtn.Style = $win.FindResource('Pill') }
  elseif ($n -gt 0) {
    $ui.UpdateBtn.Content = 'Update available (' + $n + ')'
    $ui.UpdateBtn.Style = $win.FindResource('PillMain')
    $ui.UpdateBtn.ToolTip = "Newer files on GitHub:`n" + ((@($script:updList) | ForEach-Object { '  ' + $_.name + ' (' + $_.status + ')' }) -join "`n") + "`n`nClick to update."
  } else {
    $ui.UpdateBtn.Content = 'Up to date'
    $ui.UpdateBtn.Style = $win.FindResource('Pill')
    $ui.UpdateBtn.ToolTip = "Matches github.com/$CCRepo. Click to check again."
  }
}

function Invoke-CCUpdate {
  $ui.UpdateBtn.IsEnabled = $false; $ui.UpdateBtn.Content = 'Checking GitHub...'
  $win.Cursor = [Windows.Input.Cursors]::Wait
  try {
    Wait-UI 50
    try { $list = @(Get-CCUpdates $here) }
    catch { Show-Error ("Couldn't reach GitHub to check for updates.`n`n" + $_.Exception.Message); return }
    $script:updList = $list
    if (-not $list.Count) { Set-UpdateButton; Show-Note "Command Center is up to date with GitHub ($CCRepo)."; return }

    $lines = ($list | ForEach-Object { '   - ' + $_.name + '   (' + $_.status + ')' }) -join "`n"
    $ans = [Windows.MessageBox]::Show(("Update Command Center from GitHub?`n`n" + $lines +
      "`n`nYour current files are saved in the backups folder first. Command Center restarts when it's done."), 'Command Center', 'YesNo', 'Question')
    if ([string]$ans -ne 'Yes') { return }

    # 1. download everything and check it before touching anything
    $ui.UpdateBtn.Content = 'Downloading...'; Wait-UI 30
    $got = @{}
    foreach ($f in $list) {
      try { $bytes = Invoke-GitHub $f.url } catch { Show-Error ("Couldn't download " + $f.name + ". Nothing was changed.`n`n" + $_.Exception.Message); return }
      if ((Get-GitBlobShaBytes $bytes) -ne $f.sha) { Show-Error ($f.name + " didn't download completely. Nothing was changed - try again."); return }
      if ($f.name -like '*.ps1') {
        $tmp = Join-Path $env:TEMP ('cc-update-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllBytes($tmp, $bytes)
        $tok = $null; $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$errs)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if ($errs -and $errs.Count) { Show-Error ($f.name + " on GitHub has an error (line " + $errs[0].Extent.StartLineNumber + ": " + $errs[0].Message + ").`n`nNothing was changed."); return }
      }
      $got[$f.name] = $bytes
    }

    # 2. back up what is here now
    $bdir = Join-Path $here ('backups\' + (Get-Date -Format 'yyyy-MM-dd HHmmss'))
    New-Item -ItemType Directory -Path $bdir -Force | Out-Null
    foreach ($f in $list) { $p = Join-Path $here $f.name; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $bdir -Force } }

    # 3. put the new files in place (undo everything if one fails)
    $done = New-Object Collections.ArrayList
    try {
      foreach ($f in $list) { [IO.File]::WriteAllBytes((Join-Path $here $f.name), $got[$f.name]); [void]$done.Add($f.name) }
    } catch {
      foreach ($n in $done) { $b = Join-Path $bdir $n; if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination $here -Force } else { Remove-Item -LiteralPath (Join-Path $here $n) -Force -ErrorAction SilentlyContinue } }
      Show-Error ("Couldn't save the update, so the old version was put back.`n`n" + $_.Exception.Message)
      return
    }

    # 4. restart: a newer Command Center.ps1 makes the new window replace this one
    $main = Join-Path $here 'Command Center.ps1'
    try { (Get-Item -LiteralPath $main).LastWriteTime = Get-Date } catch {}
    try { Add-Content -Path (Join-Path $here 'update-log.txt') -Value ((Get-Date -Format s) + '  updated from GitHub: ' + (($list | ForEach-Object { $_.name }) -join ', ') + '  (backup: ' + $bdir + ')') -Encoding UTF8 } catch {}
    Start-Process -FilePath $WinPS -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $main + '"') -WorkingDirectory $here
    $ui.UpdateBtn.Content = 'Restarting...'
  } finally {
    $win.Cursor = $null
    $ui.UpdateBtn.IsEnabled = $true
    if ([string]$ui.UpdateBtn.Content -like 'Checking*' -or [string]$ui.UpdateBtn.Content -like 'Downloading*') { Set-UpdateButton }
  }
}
