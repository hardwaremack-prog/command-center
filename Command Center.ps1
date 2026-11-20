# Command Center - one window with the apps used most on this PC, plus OpenClaw controls.
# Start it with the "Command Center" icon on the Desktop (or Start Command Center.bat in this folder).
# Launch counts are kept in %LOCALAPPDATA%\Command Center\usage.json and drive the "Most used" row,
# together with Windows' own launch counts that Scan-Apps.ps1 reads (scan.json in the same folder).
# The Web servers row lists every local web server it finds, with a live status light and a Stop button.
# Running / Stop (top right) lists everything running on this PC and stops any of it (see Running.ps1).
# Right-click an app tile to stop that app.
# Update (top right) gets the newest version from github.com/hardwaremack-prog/command-center (see Update.ps1).

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$errLog = Join-Path $here 'error.log'
trap {
  $msg = ($_ | Out-String) + "`nAt: " + $_.InvocationInfo.PositionMessage
  try { Set-Content -Path $errLog -Value $msg -Encoding UTF8 } catch {}
  try { [void][Windows.MessageBox]::Show("Command Center couldn't start.`n`n" + $_.Exception.Message + "`n`nDetails: " + $errLog, 'Command Center') } catch {}
  break
}
try { Set-Content -Path $errLog -Value ('started ' + (Get-Date -Format s)) -Encoding UTF8 } catch {}
$traceFile = Join-Path $env:LOCALAPPDATA 'Command Center\startup-trace.txt'
$script:traceT0 = Get-Date
function Trace([string]$m) { try { Add-Content -Path $traceFile -Value ('{0,7:N0} ms  {1}' -f ((Get-Date) - $script:traceT0).TotalMilliseconds, $m) -Encoding UTF8 } catch {} }
try { $td = Split-Path -Parent $traceFile; if (-not (Test-Path $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }; Set-Content -Path $traceFile -Value ('start ' + (Get-Date -Format s)) -Encoding UTF8 } catch {}
# one window at a time: if Command Center is already open, bring it forward - unless this file was
# updated since it started, in which case the old window closes and this one takes over
try {
  $me = Join-Path $here 'Command Center.ps1'
  $changed = (Get-Item -LiteralPath $me).LastWriteTime
  $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Command Center.ps1*' })
  foreach ($o in $others) {
    $gp = Get-Process -Id $o.ProcessId -ErrorAction SilentlyContinue
    if (-not $gp) { continue }
    if ($gp.StartTime -lt $changed) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue; continue }
    if ($gp.MainWindowHandle -ne [IntPtr]::Zero) {
      Add-Type -Namespace CC -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);'
      [void][CC.Win]::ShowWindow($gp.MainWindowHandle, 9); [void][CC.Win]::SetForegroundWindow($gp.MainWindowHandle)
      exit
    }
  }
} catch {}
$U      = $env:USERPROFILE
$Desk   = [Environment]::GetFolderPath('Desktop')
$MyApps = Join-Path $Desk 'My Apps'
$OC     = Join-Path $U '.openclaw'
$PF     = $env:ProgramFiles
$PF86   = ${env:ProgramFiles(x86)}
$WinPS  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# keep the Desktop icon pointing here (same approach as Halo Lab)
try {
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut((Join-Path $Desk 'Command Center.lnk'))
  $sc.TargetPath = $WinPS
  $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $here 'Command Center.ps1') + '"'
  $sc.WorkingDirectory = $here
  $sc.IconLocation = (Join-Path $here 'Command Center.ico') + ',0'
  $sc.WindowStyle = 7
  $sc.Description = 'Command Center: your most used apps and OpenClaw'
  $sc.Save()
} catch {}

# ---------------------------------------------------------------- app list
# n = name, g = group, t = what to open, a = arguments, i = icon file, p = local port (live status dot),
# aumid = Store app id, s = starting rank for "Most used" (from taskbar pins and recent use on this PC)
$apps = @(
  # AI & Dev
  @{ n='LM Studio';       g='AI & Dev';   t="$PF\AMD\AI_Bundle\LMStudio\LM Studio\LM Studio.exe"; p=1234; s=9 }
  @{ n='Halo Lab';        g='AI & Dev';   t="$Desk\Halo Lab.lnk"; i="$MyApps\Apps\Halo Lab\Halo Lab.ico"; p=11500; s=8 }
  @{ n='Halo Studio';     g='AI & Dev';   t="$MyApps\Apps\Halo Studio\Start-Halo-Studio.bat"; i="$MyApps\Apps\Halo Studio\Halo Studio.ico"; p=8395; s=6 }
  @{ n='Cutwise';         g='AI & Dev';   t="$MyApps\Apps\Cutwise\Start Cutwise.bat"; i="$MyApps\Apps\Cutwise\Cutwise.ico"; p=8765; s=6 }
  @{ n='HAL 9000';        g='AI & Dev';   t="$MyApps\Apps\HAL\Start HAL.bat"; s=6 }
  @{ n='Blueprint Wiki';  g='AI & Dev';   t="$Desk\Blueprint Wiki.lnk"; i="$MyApps\Apps\Blueprint Wiki\blueprint-wiki.ico"; s=3 }
  @{ n='PowerShell';      g='AI & Dev';   t=$WinPS; s=4 }
  @{ n='Python IDLE';     g='AI & Dev';   t="$env:LOCALAPPDATA\Programs\Python\Python314\pythonw.exe"; a='-m idlelib' }

  # Internet & Chat
  @{ n='Chrome';          g='Internet & Chat'; t="$PF\Google\Chrome\Application\chrome.exe"; s=10 }
  @{ n='Edge';            g='Internet & Chat'; t="$PF86\Microsoft\Edge\Application\msedge.exe"; s=3 }
  @{ n='Telegram';        g='Internet & Chat'; t="$env:APPDATA\Telegram Desktop\Telegram.exe"; s=8 }
  @{ n='YouTube Favorites'; g='Internet & Chat'; t="$Desk\YouTube Favorites.lnk"; i="$env:LOCALAPPDATA\YouTube Favorites\icon.ico"; s=5 }

  # My Apps
  @{ n='The Shelf';       g='My Apps'; t='http://127.0.0.1:8080/'; i="$Desk\The Shelf.url"; p=8080; s=7 }
  @{ n='Tidy Suite';      g='My Apps'; t="$MyApps\Apps\Tidy Suite\Start Tidy Suite.bat"; s=5 }
  @{ n='NetPulse';        g='My Apps'; t="$Desk\NetPulse.lnk"; i="$MyApps\Apps\NetPulse\netpulse.ico"; s=5 }
  @{ n='Latch';           g='My Apps'; t="$MyApps\Apps\Latch\latch.html"; i="$MyApps\Apps\Latch\latch.ico"; s=3 }
  @{ n='Memory Cleaner';  g='My Apps'; t="$MyApps\Apps\Memory Cleaner\MemoryCleaner.exe"; s=2 }
  @{ n='Stay Awake';      g='My Apps'; t="$MyApps\Apps\Stay Awake\Start Stay Awake.bat" }
  @{ n='Weather Monitor'; g='My Apps'; t="$MyApps\Apps\Weather Monitor\Weather Monitor.html" }
  @{ n='68K Mac Museum';  g='My Apps'; t="$MyApps\Apps\68K Mac Museum\68K Mac Museum.html"; i="$MyApps\Apps\68K Mac Museum\68K Mac Museum.ico" }
  @{ n='Ham Radio Museum'; g='My Apps'; t="$MyApps\Apps\Ham Radio Museum\Ham Radio Museum.html"; i="$MyApps\Apps\Ham Radio Museum\Ham Radio Museum.ico" }
  @{ n='Raspberry Pi Museum'; g='My Apps'; t="$MyApps\Apps\Raspberry Pi Museum\Raspberry Pi Museum.html"; i="$MyApps\Apps\Raspberry Pi Museum\Raspberry Pi Museum.ico" }
  @{ n='Keeper Cars';     g='My Apps'; t="$MyApps\Apps\Keeper Cars\Keeper Cars.html"; i="$MyApps\Apps\Keeper Cars\Keeper Cars.ico" }
  @{ n='All My Apps';     g='My Apps'; t="$MyApps\App Dashboard\My Apps Menu.html"; i="$MyApps\App Dashboard\App Dashboard.ico" }

  # Raspberry Pi
  @{ n='Pi 400 Desktop';  g='Raspberry Pi'; t="$PF\TigerVNC\vncviewer.exe"; a="`"$Desk\VNC-RPI400`""; s=5 }
  @{ n='TigerVNC';        g='Raspberry Pi'; t="$PF\TigerVNC\vncviewer.exe" }
  @{ n='PiMesh';          g='Raspberry Pi'; t="$MyApps\Raspberry Pi\PiMesh\Open PiMesh.html"; i="$MyApps\Raspberry Pi\PiMesh\icon.ico" }
  @{ n='PON Lab';         g='Raspberry Pi'; t="$MyApps\Raspberry Pi\PON Lab\Open PON Lab.html"; i="$MyApps\Raspberry Pi\PON Lab\icon.ico" }
  @{ n='PON Fleet';       g='Raspberry Pi'; t="$MyApps\Apps\PON Fleet\Open PON Fleet.html"; i="$MyApps\Apps\PON Fleet\icon.ico" }
  @{ n='PodDeck';         g='Raspberry Pi'; t="$MyApps\Raspberry Pi\PodDeck\Open PodDeck.html"; i="$MyApps\Raspberry Pi\PodDeck\poddeck.ico" }

  # Games
  @{ n='Minecraft';       g='Games'; aumid='Microsoft.MinecraftUWP_8wekyb3d8bbwe!App'; proc='Minecraft.Windows' }
  @{ n='Roblox';          g='Games'; aumid='ROBLOXCorporation.RobloxGDK_55nm5eh3cm0pr!Game'; proc='RobloxPlayerBeta','RobloxGDK' }
  @{ n='Oregon Trail';    g='Games'; t="$MyApps\Games\Oregon Trail\oregon-trail-final b2.html" }
  @{ n='Dead Mall Arena'; g='Games'; t="$MyApps\Games\Dead Mall Arena\arena-final b11.html" }
  @{ n='Blockscape';      g='Games'; t="$MyApps\Games\Blockscape\blockscape.html" }
  @{ n='Akkanoid';        g='Games'; t="$MyApps\Games\Akkanoid\akkanoid.html" }

  # System
  @{ n='File Explorer';   g='System'; t="$env:SystemRoot\explorer.exe"; s=4 }
  @{ n='Task Manager';    g='System'; t="$env:SystemRoot\System32\Taskmgr.exe"; s=3 }
  @{ n='Hardware Monitor'; g='System'; t="$MyApps\Apps\Hardware Monitor\LibreHardwareMonitor.exe"; p=8085 }
  @{ n='Win Memory Cleaner'; g='System'; t="$U\Downloads\WinMemoryCleaner.exe"; s=2 }
  @{ n='Downloads';       g='System'; t="$U\Downloads" }
  @{ n='My Apps Folder';  g='System'; t=$MyApps }
)

# ---------------------------------------------------------------- usage counts
$dataDir   = Join-Path $env:LOCALAPPDATA 'Command Center'
$usageFile = Join-Path $dataDir 'usage.json'
$usage = @{}
try {
  if (Test-Path $usageFile) {
    $obj = Get-Content $usageFile -Raw | ConvertFrom-Json
    foreach ($pr in $obj.PSObject.Properties) { $usage[$pr.Name] = [int]$pr.Value }
  }
} catch {}
function Save-Usage {
  try {
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
    ($usage | ConvertTo-Json) | Set-Content -Path $usageFile -Encoding UTF8
  } catch {}
}
function Get-Score($app) {
  $seed = 0; if ($app.s) { $seed = [int]$app.s }
  $used = 0; if ($usage.ContainsKey($app.n)) { $used = $usage[$app.n] }
  $win = 0; if ($app.w) { $win = [Math]::Min(30, [int]([int]$app.w / 4)) }   # Windows' own launch count (Scan-Apps.ps1)
  return ($used * 3) + $seed + $win
}

# keep only apps that are actually on this PC
$apps = @($apps | Where-Object {
  if ($_.aumid) { return $true }
  if ($_.t -like 'http*') { return $true }
  return (Test-Path -LiteralPath $_.t)
})
$baseApps = $apps

# ---------------------------------------------------------------- scanned apps (Scan-Apps.ps1)
Trace 'apps listed'
. (Join-Path $here 'Scan-Apps.ps1')
Trace 'Scan-Apps loaded'
. (Join-Path $here 'Running.ps1')
. (Join-Path $here 'Update.ps1')
$scanFile = Join-Path $dataDir 'scan.json'
function Merge-Scan {
  $script:apps = @($baseApps | ForEach-Object { $_.w = 0; $_ })
  $scan = $null
  try { if (Test-Path $scanFile) { $scan = Get-Content $scanFile -Raw | ConvertFrom-Json } } catch {}
  if (-not $scan -or -not $scan.apps) { return }
  $byT = @{}; $byN = @{}
  foreach ($a in $script:apps) { if ($a.t) { $byT[([string]$a.t).ToLower()] = $a }; $byN[([string]$a.n).ToLower()] = $a }
  $found = New-Object System.Collections.ArrayList
  foreach ($s in $scan.apps) {
    $t = ([string]$s.t).ToLower(); $n = ([string]$s.n).ToLower()
    $hit = $null
    if ($byT.ContainsKey($t)) { $hit = $byT[$t] } elseif ($byN.ContainsKey($n)) { $hit = $byN[$n] }
    if ($hit -is [bool]) { continue }   # same name already found by the scan
    if ($hit) { if ([int]$s.uses -gt [int]$hit.w) { $hit.w = [int]$s.uses }; continue }
    if ($t -match 'command center' -or $n -match 'command center') { continue }
    $src = @($s.sources)
    if ([int]$s.uses -lt 1 -and -not ($src | Where-Object { $_ -in 'desktop', 'taskbar' -or $_ -like 'myapps:*' })) { continue }
    $byN[$n] = $true
    [void]$found.Add(@{ n = [string]$s.n; g = 'Found on this PC'; t = [string]$s.t; a = [string]$s.a; i = [string]$s.i; w = [int]$s.uses })
  }
  $extra = @($found | Sort-Object { $_.w } -Descending | Select-Object -First 48)
  $script:apps = @($script:apps) + $extra
}
Merge-Scan
Trace 'merge done'

# ---------------------------------------------------------------- icons
$iconCache = @{}
function Get-AppIcon($app) {
  $src = $app.i
  if (-not $src -or -not (Test-Path -LiteralPath $src)) { $src = $app.t }
  if (-not $src -or $src -like 'http*' -or -not (Test-Path -LiteralPath $src)) { return $null }
  if ($iconCache.ContainsKey($src)) { return $iconCache[$src] }
  $img = $null
  try {
    $ext = [IO.Path]::GetExtension($src).ToLower()
    if ($ext -eq '.ico') {
      $dec = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$src, 'None', 'OnLoad')
      $img = $dec.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
    } elseif ($ext -eq '.png') {
      $img = New-Object Windows.Media.Imaging.BitmapImage ([Uri]$src)
    } elseif ((Get-Item -LiteralPath $src).PSIsContainer -or $ext -eq '.bat' -or $ext -eq '.cmd') {
      $img = $null
    } else {
      $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($src)
      if ($ico) {
        $img = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle,
               [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
      }
    }
  } catch { $img = $null }
  $iconCache[$src] = $img
  return $img
}

# ---------------------------------------------------------------- port status
# live port checks run in the background (see $bgCode); the window only reads the results
function Test-Port([int]$port) {
  if ($bg -and $bg.up) {
    if (-not $bg.watch.ContainsKey($port)) { $bg.watch[$port] = $true }
    if ($bg.up.ContainsKey($port)) { return [bool]$bg.up[$port] }
  }
  return (Test-PortNow $port)
}
function Test-PortNow([int]$port) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $r = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($r.AsyncWaitHandle.WaitOne(200) -and $c.Connected) { return $true }
    return $false
  } catch { return $false } finally { $c.Close() }
}

# ---------------------------------------------------------------- launching
function Show-Error($msg) { [void][Windows.MessageBox]::Show($msg, 'Command Center') }

function Start-App($app) {
  try {
    if ($app.aumid) {
      Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList ("shell:AppsFolder\" + $app.aumid)
    } elseif ($app.t -like 'http*') {
      Start-Process -FilePath $app.t
    } else {
      $p = @{ FilePath = $app.t }
      if ($app.a) { $p.ArgumentList = $app.a }
      if ($app.url) { $p = @{ FilePath = $app.url } }
      if (Test-Path -LiteralPath $app.t -PathType Leaf) { $p.WorkingDirectory = Split-Path -Parent $app.t }
      Start-Process @p
    }
    if ($usage.ContainsKey($app.n)) { $usage[$app.n]++ } else { $usage[$app.n] = 1 }
    Save-Usage
  } catch { Show-Error ("Couldn't open " + $app.n + ".`n`n" + $_.Exception.Message) }
}

function Start-OpenClaw([string]$cmdArgs, [switch]$Hidden, [switch]$KeepOpen) {
  try {
    $flag = '/c'; if ($KeepOpen) { $flag = '/k' }
    $p = @{ FilePath = "$env:SystemRoot\System32\cmd.exe"; ArgumentList = "$flag openclaw $cmdArgs"; WorkingDirectory = $U }
    if ($Hidden) { $p.WindowStyle = 'Hidden' }
    Start-Process @p
  } catch { Show-Error ("Couldn't run openclaw $cmdArgs.`n`n" + $_.Exception.Message) }
}

# ---------------------------------------------------------------- window
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Command Center" Width="1120" Height="800" MinWidth="640" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#0F131B" FontFamily="Segoe UI" Foreground="#E8ECF4">
  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#171D29"/>
    <SolidColorBrush x:Key="CardHover" Color="#212A3B"/>
    <SolidColorBrush x:Key="Line" Color="#263045"/>
    <SolidColorBrush x:Key="Muted" Color="#8C97AD"/>
    <SolidColorBrush x:Key="Accent" Color="#FF6B4A"/>
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Foreground" Value="#E8ECF4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="122"/>
      <Setter Property="Height" Value="108"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource CardHover}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#3A4766"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2A3550"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="#E8ECF4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
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
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PillMain" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#FF6B4A" CornerRadius="16" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#FF8466"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#E85A3A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="Foreground" Value="#1A0F0C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="StopBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#2A1C22" BorderBrush="#5A2C33" BorderThickness="1" CornerRadius="12">
              <TextBlock x:Name="g" Text="&#xE71A;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9"
                         Foreground="#FF7A7A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF5A5A"/>
                <Setter TargetName="g" Property="Foreground" Value="#1A0F0C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#E04848"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="StopPill" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Foreground" Value="#FFB0B0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="#3A1F24" BorderBrush="#5A2C33" BorderThickness="1" CornerRadius="16" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#5A2C33"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#FF5A5A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="24,18,8,0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Grid Grid.Row="0" Margin="0,0,16,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="Command Center" FontSize="26" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubTitle" Foreground="{StaticResource Muted}" FontSize="13" Margin="1,2,0,0"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="RunBtn" Style="{StaticResource StopPill}" Margin="0,0,10,0" VerticalAlignment="Center"
              ToolTip="See everything running on this PC - apps, servers, scripts - and stop any of it"/>
      <Button x:Name="UpdateBtn" Style="{StaticResource Pill}" Margin="0,0,10,0" VerticalAlignment="Center"
              ToolTip="Get the newest Command Center from GitHub"/>
      <Button x:Name="RescanBtn" Style="{StaticResource Pill}" Margin="0,0,10,0" VerticalAlignment="Center"
              ToolTip="Look again for your most used apps and for web servers running on this PC"/>
      <Border Background="{StaticResource Card}" BorderBrush="{StaticResource Line}" BorderThickness="1"
              CornerRadius="18" Width="280" Height="36" VerticalAlignment="Center">
        <Grid>
          <TextBlock x:Name="SearchHint" Text="Search apps - Enter opens the first one" Foreground="#5E6980"
                     Margin="16,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False" FontSize="13"/>
          <TextBox x:Name="Search" Background="Transparent" BorderThickness="0" Foreground="#E8ECF4" CaretBrush="#E8ECF4"
                   Margin="14,0,14,0" VerticalAlignment="Center" FontSize="14"/>
        </Grid>
      </Border>
      </StackPanel>
    </Grid>

    <!-- OpenClaw -->
    <Border Grid.Row="1" Margin="0,0,16,18" CornerRadius="14" Padding="20,16,12,10" BorderThickness="1" BorderBrush="#3A2A2A">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#2A1714" Offset="0"/>
          <GradientStop Color="#171D29" Offset="0.65"/>
        </LinearGradientBrush>
      </Border.Background>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Width="54" Height="54" CornerRadius="14" Background="#FF6B4A" VerticalAlignment="Top" Margin="0,2,16,0">
          <TextBlock x:Name="ClawGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="26" Foreground="#1A0F0C"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="OpenClaw" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <Border CornerRadius="10" Background="#10FFFFFF" Padding="10,3" Margin="12,0,0,0" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="GwDot" Width="8" Height="8" Fill="#5E6980" VerticalAlignment="Center"/>
                <TextBlock x:Name="GwText" Text="Gateway: checking" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border CornerRadius="10" Background="#10FFFFFF" Padding="10,3" Margin="8,0,0,0" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="LmDot" Width="8" Height="8" Fill="#5E6980" VerticalAlignment="Center"/>
                <TextBlock x:Name="LmText" Text="LM Studio: checking" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border x:Name="HwPill" CornerRadius="10" Background="#10FFFFFF" Padding="10,3" Margin="8,0,0,0" VerticalAlignment="Center" Cursor="Hand">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="HwDot" Width="8" Height="8" Fill="#5E6980" VerticalAlignment="Center"/>
                <TextBlock x:Name="HwText" Text="Hardware Monitor: checking" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border x:Name="ShPill" CornerRadius="10" Background="#10FFFFFF" Padding="10,3" Margin="8,0,0,0" VerticalAlignment="Center" Cursor="Hand">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="ShDot" Width="8" Height="8" Fill="#5E6980" VerticalAlignment="Center"/>
                <TextBlock x:Name="ShText" Text="The Shelf: checking" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
          </StackPanel>
          <TextBlock x:Name="ClawInfo" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,5,0,10" TextWrapping="Wrap"/>
          <WrapPanel x:Name="ClawButtons"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- app sections -->
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="0,0,8,16">
      <StackPanel x:Name="Sections"/>
    </ScrollViewer>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
Trace 'window loaded'
# size the window to the screen (this PC has a large display)
$wa = [Windows.SystemParameters]::WorkArea
$win.Width  = [Math]::Max(900, [Math]::Min(1700, $wa.Width * 0.62))
$win.Height = [Math]::Max(640, [Math]::Min(1150, $wa.Height * 0.82))
$ui = @{}
foreach ($name in 'SubTitle','Search','SearchHint','ClawGlyph','GwDot','GwText','LmDot','LmText','HwPill','HwDot','HwText','ShPill','ShDot','ShText','ClawInfo','ClawButtons','Sections','RescanBtn','RunBtn','UpdateBtn') {
  $ui[$name] = $win.FindName($name)
}
$brush = New-Object Windows.Media.BrushConverter
$green = $brush.ConvertFrom('#3DDC84'); $grey = $brush.ConvertFrom('#5E6980'); $red = $brush.ConvertFrom('#FF5A5A')
$amber = $brush.ConvertFrom('#FFB547')
$script:hwWeb = $false
$script:shelfUp = $false
$ui.ShPill.Add_MouseLeftButtonUp({
  try {
    if ($script:shelfUp) { Start-Process 'http://127.0.0.1:8080/' }
    else {
      $shelfDir = Join-Path $env:LOCALAPPDATA 'TheShelf'
      if (Test-Path -LiteralPath $shelfDir) { Start-Process -FilePath $shelfDir }
    }
  } catch {}
})
$hwExe = Join-Path $MyApps 'Apps\Hardware Monitor\LibreHardwareMonitor.exe'
$ui.HwPill.Add_MouseLeftButtonUp({
  try {
    if ($script:hwWeb) { Start-Process 'http://127.0.0.1:8085/' }
    elseif (-not (Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $hwExe)) {
      Start-Process -FilePath $hwExe -WorkingDirectory (Split-Path -Parent $hwExe) -Verb RunAs
    }
  } catch {}
})
$ui.ClawGlyph.Text = [string][char]0xE99A   # robot

# ---- OpenClaw info line (model from config)
$model = ''
try {
  $cfg = Get-Content (Join-Path $OC 'openclaw.json') -Raw | ConvertFrom-Json
  $model = $cfg.agents.defaults.model.primary
} catch {}
$info = 'Your local AI agent'
if ($model) { $info += '  -  model: ' + $model }
$info += '  -  Full Access mode'
$ui.ClawInfo.Text = $info

function Add-ClawButton([string]$text, [scriptblock]$action, [switch]$Main) {
  $b = New-Object Windows.Controls.Button
  $b.Content = $text
  if ($Main) { $b.Style = $win.FindResource('PillMain') } else { $b.Style = $win.FindResource('Pill') }
  $b.Add_Click($action)
  [void]$ui.ClawButtons.Children.Add($b)
}
Add-ClawButton 'Open Dashboard'  { Start-OpenClaw 'dashboard --yes' -Hidden } -Main
Add-ClawButton 'Chat in Terminal' { Start-OpenClaw 'tui' }
Add-ClawButton 'Open LM Studio'  { try { Start-Process -FilePath (Join-Path $env:ProgramFiles 'AMD\AI_Bundle\LMStudio\LM Studio\LM Studio.exe') } catch { Show-Error ("Couldn't open LM Studio.`n`n" + $_.Exception.Message) } }
Add-ClawButton 'Restart Gateway' { Start-OpenClaw 'gateway restart' -KeepOpen }
Add-ClawButton 'Stop Gateway'    { Start-OpenClaw 'gateway stop --force' -KeepOpen }
Add-ClawButton 'Start Gateway'   { Start-OpenClaw 'gateway start' -KeepOpen }
Add-ClawButton 'Live Logs'       { Start-OpenClaw 'logs --follow --local-time' -KeepOpen }
Add-ClawButton 'Status'          { Start-OpenClaw 'status' -KeepOpen }
Add-ClawButton 'Settings Folder' { Start-Process -FilePath $OC }
$upLog = Join-Path $OC 'upgrade-log.txt'
if (Test-Path $upLog) { Add-ClawButton 'Upgrade Log' { Start-Process -FilePath (Join-Path $OC 'upgrade-log.txt') } }

# ---- tiles
$statusDots = New-Object System.Collections.ArrayList
$allTiles   = New-Object System.Collections.ArrayList

function New-Tile($app) {
  $b = New-Object Windows.Controls.Button
  $b.Style = $win.FindResource('Tile')
  $tip = $app.t; if ($app.aumid) { $tip = 'Microsoft Store app' }
  $b.ToolTip = $app.n + "`n" + $tip

  $g = New-Object Windows.Controls.Grid
  $sp = New-Object Windows.Controls.StackPanel
  $sp.VerticalAlignment = 'Center'; $sp.HorizontalAlignment = 'Center'

  $img = Get-AppIcon $app
  if ($img) {
    $im = New-Object Windows.Controls.Image
    $im.Source = $img; $im.Width = 40; $im.Height = 40
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($im, 'HighQuality')
    [void]$sp.Children.Add($im)
  } else {
    $bd = New-Object Windows.Controls.Border
    $bd.Width = 40; $bd.Height = 40; $bd.CornerRadius = 10
    $palette = '#5B8CFF','#3DDC84','#FFB547','#C77DFF','#4CC9F0','#FF6B9A','#FF6B4A'
    $idx = [Math]::Abs($app.n.GetHashCode()) % $palette.Count
    $bd.Background = $brush.ConvertFrom($palette[$idx])
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $app.n.Substring(0,1).ToUpper(); $tb.FontSize = 20; $tb.FontWeight = 'SemiBold'
    $tb.Foreground = $brush.ConvertFrom('#10141C'); $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
    $bd.Child = $tb
    [void]$sp.Children.Add($bd)
  }
  $lbl = New-Object Windows.Controls.TextBlock
  $lbl.Text = $app.n; $lbl.FontSize = 12.5; $lbl.Margin = '6,9,6,0'
  $lbl.TextAlignment = 'Center'; $lbl.TextWrapping = 'Wrap'; $lbl.MaxHeight = 34; $lbl.TextTrimming = 'CharacterEllipsis'
  [void]$sp.Children.Add($lbl)
  [void]$g.Children.Add($sp)

  if ($app.p) {
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8; $dot.Fill = $grey
    $dot.HorizontalAlignment = 'Right'; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,9,9,0'
    $dot.ToolTip = 'Checking...'
    [void]$g.Children.Add($dot)
    [void]$statusDots.Add(@{ Dot = $dot; Port = [int]$app.p; Name = $app.n })
  }
  $b.Content = $g
  $b.Tag = $app
  $b.Add_Click({ param($s, $e) Start-App $s.Tag })
  Add-AppStopMenu $b
  [void]$allTiles.Add($b)
  return $b
}

function Add-Section([string]$title, $list) {
  if (-not $list -or @($list).Count -eq 0) { return }
  $h = New-Object Windows.Controls.TextBlock
  $h.Text = $title.ToUpper(); $h.FontSize = 11.5; $h.FontWeight = 'SemiBold'
  $h.Foreground = $brush.ConvertFrom('#8C97AD'); $h.Margin = '2,4,0,10'
  $wp = New-Object Windows.Controls.WrapPanel
  $wp.Margin = '0,0,0,12'
  foreach ($a in $list) { [void]$wp.Children.Add((New-Tile $a)) }
  $sec = New-Object Windows.Controls.StackPanel
  [void]$sec.Children.Add($h); [void]$sec.Children.Add($wp)
  $sec.Tag = $title
  [void]$ui.Sections.Children.Add($sec)
}

function Build-Sections {
  Trace 'build start'
  $ui.Sections.Children.Clear(); $statusDots.Clear(); $allTiles.Clear()
  Add-ServerSection
  Trace 'server section added'
  $top = $apps | Where-Object { (Get-Score $_) -gt 0 } | Sort-Object { Get-Score $_ } -Descending | Select-Object -First 8
  Add-Section 'Most used' $top
  foreach ($grp in 'AI & Dev','Internet & Chat','My Apps','Raspberry Pi','Games','System','Found on this PC') {
    Add-Section $grp ($apps | Where-Object { $_.g -eq $grp })
  }
  Update-Status
}

# ---- web servers
# Known servers are always listed (red when down); anything else that answers like a web page is added.
$haloPort = 11500; $haloLan = $false
try { $hc = Get-Content (Join-Path $env:LOCALAPPDATA 'HaloLab\config.json') -Raw | ConvertFrom-Json; if ([int]$hc.port -ge 1024) { $haloPort = [int]$hc.port }; $haloLan = [bool]$hc.lan } catch {}
$knownServers = @(
  @{ n = 'OpenClaw gateway'; port = 18789; always = $true; note = 'Your AI agent. Click opens its dashboard.'; open = { Start-OpenClaw 'dashboard --yes' -Hidden }
     stop = { Start-OpenClaw 'gateway stop --force' -Hidden; 'Asked OpenClaw to stop its gateway - the light turns red in a few seconds.' }
     restart = { Start-OpenClaw 'gateway restart' -Hidden; 'Restarting the OpenClaw gateway...' } }
  @{ n = 'LM Studio';        port = 1234;  always = $true; note = 'Model server OpenClaw uses (OpenAI-style API at /v1).'; api = $true
     stop = { $lms = Join-Path $U '.lmstudio\bin\lms.exe'; if (Test-Path -LiteralPath $lms) { Start-Process -FilePath $lms -ArgumentList 'server stop' -WindowStyle Hidden; 'Asked LM Studio to stop serving (the LM Studio app stays open).' } }
     restart = { $lms = Join-Path $U '.lmstudio\bin\lms.exe'; if (Test-Path -LiteralPath $lms) { Start-Process -FilePath $lms -ArgumentList 'server start' -WindowStyle Hidden; 'Asked LM Studio to start serving.' } } }
  @{ n = 'Halo Lab';         port = $haloPort; always = $true; note = 'AI dashboard. Change its port in Halo Lab > Setup.' }
  @{ n = 'Halo Studio';      port = 8395;  always = $true; note = 'AI image editor. Phones and Pis on your network can open it too.' }
  @{ n = 'Cutwise';          port = 8765;  always = $true; note = 'Easy AI video editor. Runs on this PC only.' }
  @{ n = 'The Shelf';        port = 8080;  always = $true; note = 'Your apps, files and AI tab.' }
  @{ n = 'Hardware Monitor'; port = 8085;  always = $true; note = 'LibreHardwareMonitor web server (Options > Remote Web Server).'; procName = 'LibreHardwareMonitor' }
  @{ n = 'Halo Lab engine';  port = 11600; note = 'llama.cpp running the model Halo Lab loaded.'; api = $true }
  @{ n = 'FastFlowLM (NPU)'; port = 52625; note = 'Runs models on the NPU.'; api = $true }
  @{ n = 'ComfyUI';          port = 8188;  note = 'AI image engine Halo Studio uses for generative fill.' }
  @{ n = 'Ollama';           port = 11434; note = 'Ollama model server.'; api = $true; procName = 'ollama' }
)
$bg = [hashtable]::Synchronized(@{ servers = @(); serversAt = $null; scanning = $false; appsDone = $false; stop = $false; lan = $null
  procs = @(); procsAt = $null; procsWanted = $false; procsNow = $false; serversNow = $false
  watch = [hashtable]::Synchronized(@{}); up = [hashtable]::Synchronized(@{}) })
foreach ($k in $knownServers) { $bg.watch[[int]$k.port] = $true }
$script:serverSig = ''

function Copy-Text([string]$t) { try { [Windows.Clipboard]::SetText($t) } catch {} }

function New-ServerTile($srv) {
  $b = New-Object Windows.Controls.Button
  $b.Style = $win.FindResource('Tile'); $b.Width = 262; $b.Height = 74
  $g = New-Object Windows.Controls.Grid; $g.Margin = '12,8,10,8'
  $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
  $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
  $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
  [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
  $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 11; $dot.Height = 11; $dot.Margin = '0,4,11,0'; $dot.VerticalAlignment = 'Top'
  $dot.Fill = $(if ($srv.up) { if ($srv.status -ge 500) { $amber } else { $green } } else { $red })
  [void]$g.Children.Add($dot)
  $sp = New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($sp, 1)
  $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $srv.n; $t1.FontSize = 13.5; $t1.FontWeight = 'SemiBold'; $t1.TextTrimming = 'CharacterEllipsis'
  $t2 = New-Object Windows.Controls.TextBlock; $t2.FontSize = 11.5; $t2.Foreground = $brush.ConvertFrom('#B8C2D6'); $t2.Margin = '0,2,0,0'
  $where = if (-not $srv.up) { 'not running' } elseif ($srv.network) { 'network' } else { 'this PC only' }
  $t2.Text = ':' + $srv.port + '   -   ' + $where
  $t3 = New-Object Windows.Controls.TextBlock; $t3.FontSize = 11; $t3.Foreground = $brush.ConvertFrom('#8C97AD'); $t3.TextTrimming = 'CharacterEllipsis'; $t3.Margin = '0,2,0,0'
  $t3.Text = $(if ($srv.title) { $srv.title } elseif ($srv.process) { $srv.process } else { $srv.note })
  if ($srv.up -and [int]$srv.status -ge 400) { $t3.Text = $t3.Text + '  -  answers HTTP ' + $srv.status }
  [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$sp.Children.Add($t3)
  [void]$g.Children.Add($sp)
  if ($srv.up) {
    $sb = New-Object Windows.Controls.Button; $sb.Style = $win.FindResource('StopBtn')
    $sb.VerticalAlignment = 'Top'; $sb.Margin = '6,0,0,0'; $sb.ToolTip = 'Stop ' + $srv.n; $sb.Tag = $srv
    [Windows.Controls.Grid]::SetColumn($sb, 2)
    $sb.Add_Click({ param($s, $e) $e.Handled = $true; [void](Stop-Server $s.Tag) })
    [void]$g.Children.Add($sb)
  }
  $b.Content = $g
  $tip = $srv.n + '  (port ' + $srv.port + ')'
  if ($srv.note) { $tip += "`n" + $srv.note }
  if ($srv.up) {
    $tip += "`nOpen: " + $srv.url
    if ($srv.lanUrl) { $tip += "`nFrom other devices: " + $srv.lanUrl }
    if ($srv.process) { $tip += "`nProgram: " + $srv.process + ' (PID ' + $srv.pid + ')' }
    if ($srv.status) { $tip += "`nAnswer: HTTP " + $srv.status }
  } else { $tip += "`nNot running right now." }
  $b.ToolTip = $tip
  $b.Tag = @{ n = ($srv.n + ' ' + $srv.port + ' ' + $srv.title); g = 'Web servers'; t = $srv.url; url = $srv.url; srv = $srv }
  $b.Add_Click({ param($s, $e)
    $sv = $s.Tag.srv
    try {
      if ($sv.open) { & $sv.open }
      elseif ($sv.up) { if ($sv.api) { Start-Process ($sv.url.TrimEnd('/') + '/v1/models') } else { Start-Process $sv.url } }
      else { $hit = $apps | Where-Object { $_.p -eq $sv.port } | Select-Object -First 1; if ($hit) { Start-App $hit } }
    } catch {}
  })
  $cm = New-Object Windows.Controls.ContextMenu
  $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Open in browser'; $mi.Tag = $srv.url; $mi.Add_Click({ param($s, $e) try { Start-Process $s.Tag } catch {} }); [void]$cm.Items.Add($mi)
  $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Copy link'; $mi.Tag = $srv.url; $mi.Add_Click({ param($s, $e) Copy-Text $s.Tag }); [void]$cm.Items.Add($mi)
  if ($srv.lanUrl) { $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Copy link for other devices'; $mi.Tag = $srv.lanUrl; $mi.Add_Click({ param($s, $e) Copy-Text $s.Tag }); [void]$cm.Items.Add($mi) }
  if ($srv.up) {
    [void]$cm.Items.Add((New-Object Windows.Controls.Separator))
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Stop'; $mi.Tag = $srv; $mi.Add_Click({ param($s, $e) [void](Stop-Server $s.Tag) }); [void]$cm.Items.Add($mi)
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Force stop (ends the program now)'; $mi.Tag = $srv; $mi.Add_Click({ param($s, $e) [void](Stop-Server $s.Tag -Force) }); [void]$cm.Items.Add($mi)
    if ($srv.restart -or ($apps | Where-Object { $_.p -eq $srv.port })) {
      $mi = New-Object Windows.Controls.MenuItem; $mi.Header = 'Restart'; $mi.Tag = $srv; $mi.Add_Click({ param($s, $e) Restart-Server $s.Tag }); [void]$cm.Items.Add($mi)
    }
  }
  $b.ContextMenu = $cm
  [void]$allTiles.Add($b)
  return $b
}

function Get-ServerList {
  $list = New-Object System.Collections.ArrayList
  $seen = @{}
  $found = @{}; foreach ($s in @($bg.servers)) { $found[[int]$s.port] = $s }
  foreach ($k in $knownServers) {
    $f = $found[[int]$k.port]
    $up = [bool]$f -or (Test-Port $k.port)
    if (-not $up -and -not $k.always) { continue }
    $seen[[int]$k.port] = $true
    [void]$list.Add(@{ n = $k.n; port = $k.port; up = $up; note = $k.note; open = $k.open; api = $k.api
      stop = $k.stop; restart = $k.restart; procName = $k.procName
      url = $(if ($f) { $f.url } else { "http://localhost:$($k.port)/" })
      lanUrl = $(if ($k.n -eq 'Halo Lab' -and $haloLan -and $bg.lan) { "http://$($bg.lan):$($k.port)/" } elseif ($f) { $f.lanUrl } else { $null })
      network = $(if ($k.n -eq 'Halo Lab') { $haloLan } elseif ($f) { [bool]$f.network } else { $false }); process = $(if ($f) { $f.name } else { '' }); pid = $(if ($f) { $f.pid } else { 0 })
      title = $(if ($f) { $f.title } else { '' }); status = $(if ($f) { [int]$f.status } else { 0 }) })
  }
  foreach ($f in @($bg.servers)) {
    if ($seen.ContainsKey([int]$f.port)) { continue }
    $nm = if ($f.title -and $f.title.Length -le 40) { $f.title } elseif ($f.name) { $f.name } else { 'Port ' + $f.port }
    if ([int]$f.status -ge 400 -and $nm -eq $f.name) { $nm = $f.name + ' (helper)' }
    [void]$list.Add(@{ n = $nm; port = [int]$f.port; up = $true; note = ''; url = $f.url; lanUrl = $f.lanUrl; network = [bool]$f.network
      process = $f.name; pid = $f.pid; title = $(if ($nm -eq $f.title) { $f.name } else { $f.title }); status = [int]$f.status })
  }
  return @($list)
}

function Add-ServerSection {
  $list = Get-ServerList
  $script:serverSig = (($list | ForEach-Object { "$($_.port):$($_.up):$($_.status):$($_.network)" }) -join ',')
  $old = $null; foreach ($sec in $ui.Sections.Children) { if ($sec.Tag -eq 'Web servers') { $old = $sec } }
  $h = New-Object Windows.Controls.TextBlock
  $up = @($list | Where-Object { $_.up }).Count
  $when = if ($bg.serversAt) { '   -   checked ' + $bg.serversAt.ToString('h:mm:ss tt') } else { '   -   looking...' }
  $h.Text = ('WEB SERVERS   -   ' + $up + ' running' + $when); $h.FontSize = 11.5; $h.FontWeight = 'SemiBold'
  $h.Foreground = $brush.ConvertFrom('#8C97AD'); $h.Margin = '2,4,0,10'
  $h.ToolTip = 'Every program on this PC that answers like a web page. Green = running, red = not running, amber = answering with an error. The red square stops a server. Right-click a tile to copy its link, force stop or restart it. "network" means phones and other PCs on your home network can reach it too (if the firewall allows).'
  $wp = New-Object Windows.Controls.WrapPanel; $wp.Margin = '0,0,0,12'
  foreach ($s in $list) { [void]$wp.Children.Add((New-ServerTile $s)) }
  $sec = New-Object Windows.Controls.StackPanel
  [void]$sec.Children.Add($h); [void]$sec.Children.Add($wp); $sec.Tag = 'Web servers'
  if ($old) { $i = $ui.Sections.Children.IndexOf($old); $ui.Sections.Children.RemoveAt($i); $ui.Sections.Children.Insert($i, $sec) }
  else { $ui.Sections.Children.Insert(0, $sec) }
  if ($ui.Search.Text) { $ui.Search.Text = $ui.Search.Text }   # re-apply the filter
}

# background: look for web servers every 20 seconds, and rescan apps when asked (or once a day)
$bgCode = {
  param($bg, $scanScript, $scanFile, $runScript)
  $ErrorActionPreference = 'Continue'
  . $scanScript
  . $runScript
  . (Join-Path (Split-Path -Parent $scanScript) 'Update.ps1')
  foreach ($p in @($bg.watch.Keys)) { $bg.up[[int]$p] = Test-TcpPort ([int]$p) }
  # once per start: is there a newer Command Center on GitHub?
  try { $bg.updates = @(Get-CCUpdates (Split-Path -Parent $scanScript)); $bg.updatesAt = Get-Date } catch {}
  $lastApps = [DateTime]::MinValue
  try { if (Test-Path $scanFile) { $lastApps = (Get-Item $scanFile).LastWriteTime } } catch {}
  while (-not $bg.stop) {
    $bg.serversNow = $false
    try {
      if ($bg.rescan -or ((Get-Date) - $lastApps).TotalHours -gt 12) {
        $bg.scanning = $true; $bg.rescan = $false
        $apps = Get-ScannedApps
        $servers = Get-WebServers
        $scan = [ordered]@{ when = (Get-Date -Format s); computer = $env:COMPUTERNAME; lan = (Get-LanAddress); apps = $apps; servers = $servers }
        $dir = Split-Path -Parent $scanFile; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $scan | ConvertTo-Json -Depth 5 | Set-Content -Path $scanFile -Encoding UTF8
        $lastApps = Get-Date; $bg.servers = $servers; $bg.serversAt = Get-Date; $bg.appsDone = $true; $bg.scanning = $false
      } else {
        $bg.servers = Get-WebServers; $bg.serversAt = Get-Date
        if (-not $bg.lan) { $bg.lan = Get-LanAddress }
      }
    } catch { $bg.scanning = $false }
    # quick up/down checks for the status lights every 2.5 seconds until the next full look
    # (and, while the Running / Stop window is open, the list of running programs)
    for ($i = 0; $i -lt 8 -and -not $bg.stop -and -not $bg.rescan -and -not $bg.serversNow; $i++) {
      foreach ($p in @($bg.watch.Keys)) { $bg.up[[int]$p] = Test-TcpPort ([int]$p) }
      if ($bg.procsWanted) { try { $bg.procs = @(Get-RunningList); $bg.procsAt = Get-Date } catch {} }
      $bg.procsNow = $false
      for ($j = 0; $j -lt 10 -and -not $bg.stop -and -not $bg.procsNow -and -not $bg.serversNow -and -not $bg.rescan; $j++) { Start-Sleep -Milliseconds 250 }
    }
  }
}
$bgPs = [powershell]::Create()
[void]$bgPs.AddScript($bgCode).AddArgument($bg).AddArgument((Join-Path $here 'Scan-Apps.ps1')).AddArgument($scanFile).AddArgument((Join-Path $here 'Running.ps1'))
[void]$bgPs.BeginInvoke()
Trace 'background started'
$win.Add_Closed({ $bg.stop = $true })

$ui.RescanBtn.Content = 'Rescan'
$ui.RunBtn.Content = 'Running / Stop'
$ui.RunBtn.Add_Click({ Show-RunningWindow })
$ui.UpdateBtn.Content = 'Update'
$ui.UpdateBtn.Add_Click({ Invoke-CCUpdate })
$script:updSeen = $false
$ui.RescanBtn.Add_Click({ $bg.rescan = $true; $ui.RescanBtn.Content = 'Scanning...'; $ui.RescanBtn.IsEnabled = $false })

# ---- live status
function Update-Status {
  $cache = @{}
  foreach ($p in 18789, 1234) { $cache[$p] = Test-Port $p }
  foreach ($d in $statusDots) { if (-not $cache.ContainsKey($d.Port)) { $cache[$d.Port] = Test-Port $d.Port } }

  if ($cache[18789]) { $ui.GwDot.Fill = $green; $ui.GwText.Text = 'Gateway: running' }
  else               { $ui.GwDot.Fill = $red;   $ui.GwText.Text = 'Gateway: stopped' }
  if ($cache[1234])  { $ui.LmDot.Fill = $green; $ui.LmText.Text = 'LM Studio: serving' }
  else               { $ui.LmDot.Fill = $grey;  $ui.LmText.Text = 'LM Studio: not serving' }

  # The Shelf web app on port 8080
  $script:shelfUp = Test-Port 8080
  if ($script:shelfUp) { $ui.ShDot.Fill = $green; $ui.ShText.Text = 'The Shelf: running'; $ui.ShPill.ToolTip = 'The Shelf is running on port 8080. Click to open it.' }
  else                 { $ui.ShDot.Fill = $red;   $ui.ShText.Text = 'The Shelf: not running'; $ui.ShPill.ToolTip = 'The Shelf is not answering on port 8080. Click to open its folder.' }

  # Hardware monitor: LibreHardwareMonitor web server (port 8085) feeds the OpenClaw status reports
  $hwProc = Get-Process -Name 'LibreHardwareMonitor','HWiNFO64','HWiNFO32','HWiNFO' -ErrorAction SilentlyContinue | Select-Object -First 1
  $script:hwWeb = Test-Port 8085
  if ($script:hwWeb) {
    $ui.HwDot.Fill = $green; $ui.HwText.Text = 'Hardware Monitor: running'
    $ui.HwPill.ToolTip = 'LibreHardwareMonitor web server is answering on port 8085 - status reports get temperatures. Click to open it.'
  } elseif ($hwProc) {
    $ui.HwDot.Fill = $amber; $ui.HwText.Text = ('Hardware Monitor: ' + $hwProc.ProcessName + ' running, web server off')
    $ui.HwPill.ToolTip = 'The monitor is open but its web server is off, so status reports get no temperatures. In LibreHardwareMonitor turn on Options > Remote Web Server (port 8085).'
  } else {
    $ui.HwDot.Fill = $red; $ui.HwText.Text = 'Hardware Monitor: not running'
    $ui.HwPill.ToolTip = 'LibreHardwareMonitor is not running, so OpenClaw status reports have no temperatures. Click to start it (it asks for admin), then make sure Options > Remote Web Server is on.'
  }

  foreach ($d in $statusDots) {
    if ($cache[$d.Port]) { $d.Dot.Fill = $green; $d.Dot.ToolTip = $d.Name + ' is running' }
    else                 { $d.Dot.Fill = $grey;  $d.Dot.ToolTip = $d.Name + ' is not running' }
  }
}

# ---- search
$ui.Search.Add_TextChanged({
  $q = $ui.Search.Text.Trim()
  if ($q) { $ui.SearchHint.Visibility = 'Collapsed' } else { $ui.SearchHint.Visibility = 'Visible' }
  foreach ($sec in $ui.Sections.Children) {
    $wp = $sec.Children[1]; $shown = 0
    foreach ($t in $wp.Children) {
      $hit = (-not $q) -or ($t.Tag.n -like "*$q*") -or ($t.Tag.g -like "*$q*")
      if ($q -and $sec.Tag -eq 'Most used') { $hit = $false }   # no duplicates while searching
      if ($hit) { $t.Visibility = 'Visible'; $shown++ } else { $t.Visibility = 'Collapsed' }
    }
    if ($shown -gt 0) { $sec.Visibility = 'Visible' } else { $sec.Visibility = 'Collapsed' }
  }
})
$ui.Search.Add_KeyDown({ param($s, $e)
  if ($e.Key -eq 'Return') {
    foreach ($sec in $ui.Sections.Children) {
      if ($sec.Visibility -ne 'Visible') { continue }
      foreach ($t in $sec.Children[1].Children) {
        if ($t.Visibility -eq 'Visible') { Start-App $t.Tag; $ui.Search.Text = ''; return }
      }
    }
  } elseif ($e.Key -eq 'Escape') { $ui.Search.Text = '' }
})

# ---- clock / subtitle
function Update-Clock { if ((Get-Date) -lt $script:noteUntil) { return }; $ui.SubTitle.Text = (Get-Date -Format 'dddd, MMMM d  -  h:mm tt') + '   -   ' + $env:COMPUTERNAME }
Update-Clock

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$script:ticks = 0
$timer.Add_Tick({
  $script:ticks++
  # support: create an empty file named take-snapshot in %LOCALAPPDATA%\Command Center to save a picture of this window
  $snapFlag = Join-Path $dataDir 'take-snapshot'
  if ($script:ticks -ge 2 -and (Test-Path $snapFlag)) {
    try {
      Remove-Item $snapFlag -Force
      $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.ActualWidth), ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
      $rt.Render($win)
      $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
      $fs = [IO.File]::Create((Join-Path $dataDir 'snapshot.png')); $enc.Save($fs); $fs.Close()
    } catch {}
  }
  Update-Clock; Update-Status
  if ($bg.updatesAt -and -not $script:updSeen) { $script:updSeen = $true; $script:updList = @($bg.updates); Set-UpdateButton }
  if ($bg.appsDone) {
    $bg.appsDone = $false; $ui.RescanBtn.Content = 'Rescan'; $ui.RescanBtn.IsEnabled = $true
    if (-not $ui.Search.Text) { Merge-Scan; Build-Sections }
  }
  $now = Get-ServerList
  $sig = (($now | ForEach-Object { "$($_.port):$($_.up):$($_.status):$($_.network)" }) -join ',')
  if ($sig -ne $script:serverSig -or $script:serverAt -ne $bg.serversAt) { $script:serverAt = $bg.serversAt; Add-ServerSection }
})
$timer.Start()

# refresh "Most used" whenever the window comes back to the front
$script:lastBuild = Get-Date
$win.Add_Activated({
  if (((Get-Date) - $script:lastBuild).TotalSeconds -gt 20 -and -not $ui.Search.Text) {
    $script:lastBuild = Get-Date; Build-Sections
  }
})

Build-Sections
Trace 'sections built'
$win.Add_ContentRendered({ Trace 'first paint'; [void]$ui.Search.Focus() })
Trace 'showing window'
[void]$win.ShowDialog()
Trace 'closed'
