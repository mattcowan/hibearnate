<#
.SYNOPSIS
    Tray app that switches Windows power settings between Away, Keep Working
    and Auto, and restarts Explorer on Ctrl+Alt+Shift+E.

.DESCRIPTION
    Away (applied at every launch): closing the lid hibernates, idle standby
    turns into hibernate, and the network is off during standby.

    Keep Working: closing the lid does nothing and the system does not idle
    sleep, for a fixed time or until switched back. When it ends, the machine
    returns to Away and hibernates if the lid is closed or nobody is using it.

    Auto: Keep Working while a Claude Code session looks busy, Away otherwise.
    "Busy" is a Working card on the status dashboard OR a claude.exe process
    tree that started a new process or used CPU since the last poll. Either
    signal alone is enough, because neither is reliable alone: cards can go
    stale, and claude.exe uses about as little CPU while the model generates
    as it does idle (only tool runs show up).

    See readme.md for install steps and the reason behind each setting.

.PARAMETER SelfTest
    Run the checks that need no tray (settings round trip, Claude activity
    sample, dashboard read), print the results and exit. Leaves the machine
    in the Away profile.

.PARAMETER TraceAuto
    Log the Auto inputs on every poll, to tune the CPU threshold.
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TraceAuto
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'PowerProfiles.cs') -ReferencedAssemblies System.Windows.Forms

# ---------------------------------------------------------------- settings

$Config = @{
    AwaySleepAfterAcSeconds = 15 * 60  # idle on AC before standby (was 60 min)
    AwaySleepAfterDcSeconds = 5 * 60   # idle on battery before standby (unchanged)
    HibernateAfterSeconds   = 20 * 60  # time in standby before hibernate
    KeepWorkingChoices      = @(20, 60, 120, 180, 0)  # minutes; 0 = until switched back
    PollSeconds             = 10       # short, so spawn detection sees brief tool commands
    AutoMaxMinutes          = 180      # cap on one continuous Auto keep-awake stretch
    AutoQuietMinutes        = 10       # Auto waits this long with no busy signal before Away
    ClaudeBusyCpuMs         = 2000     # CPU per poll (10 s) that marks a session tree busy;
                                       # idle trees measured at up to about 1000
    DashboardUrl            = 'http://127.0.0.1:4787/api/board'
    DashboardFreshHours     = 6        # ignore Working cards with no activity for longer
    HibernateIdleLidClosed  = 2        # minutes idle before hibernating with the lid closed
    HibernateIdleLidOpen    = 10       # minutes idle before hibernating with the lid open
    BatteryFloorPercent     = 15       # Keep Working hibernates on battery below this
    LogDir                  = Join-Path $env:LOCALAPPDATA 'WindowsPowerProfiles'
}
$LogPath = Join-Path $Config.LogDir 'power-profiles.log'

$SUB_BUTTONS = [guid]'4f971e89-eebd-4455-a8de-9e59040e7347'
$SUB_SLEEP   = [guid]'238c9fa8-0aad-41ed-83f4-97be242c8f20'
$SUB_NONE    = [guid]'fea3413e-7e05-4911-9a71-700331f1c294'

$Settings = [ordered]@{
    LidAction      = @{ Sub = $SUB_BUTTONS; Id = [guid]'5ca83367-6e45-459f-a27b-476b1d01c936' }  # 0 nothing, 1 sleep, 2 hibernate, 3 shut down
    SleepAfter     = @{ Sub = $SUB_SLEEP;   Id = [guid]'29f6c1db-86da-48c5-9fdb-f2b67b1f44da' }  # seconds, 0 = never
    HibernateAfter = @{ Sub = $SUB_SLEEP;   Id = [guid]'9d7815a6-7ee4-497e-8888-515a05f02364' }  # seconds in standby
    StandbyNetwork = @{ Sub = $SUB_NONE;    Id = [guid]'f15576e8-98b7-4186-b944-eafa664402d9' }  # 0 off, 1 on, 2 managed by Windows
}

# Each value is @(AC, DC).
$Profiles = @{
    Away = [ordered]@{
        LidAction      = @(2, 2)
        SleepAfter     = @($Config.AwaySleepAfterAcSeconds, $Config.AwaySleepAfterDcSeconds)
        HibernateAfter = @($Config.HibernateAfterSeconds, $Config.HibernateAfterSeconds)
        StandbyNetwork = @(0, 0)
    }
    KeepWorking = [ordered]@{
        LidAction      = @(0, 0)
        SleepAfter     = @(0, 0)
        HibernateAfter = @($Config.HibernateAfterSeconds, $Config.HibernateAfterSeconds)
        StandbyNetwork = @(0, 0)
    }
}

# ---------------------------------------------------------------- helpers

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path $Config.LogDir)) {
            New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
        }
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
            Move-Item $LogPath "$LogPath.old" -Force
        }
        Add-Content -Path $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch {
        # Logging must never take the tray down.
    }
}

function Format-Span([TimeSpan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return '{0}s' -f [int]$Span.TotalSeconds }
    if ($Span.TotalHours -lt 1) { return '{0}m' -f [int][math]::Floor($Span.TotalMinutes) }
    if ($Span.TotalDays -lt 1) { return '{0}h {1}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes }
    return '{0}d {1}h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours
}

function Format-Minutes([int]$Minutes) {
    if ($Minutes -le 0) { return 'until I switch back' }
    if ($Minutes -lt 60) { return "$Minutes minutes" }
    if ($Minutes -eq 60) { return '1 hour' }
    return '{0} hours' -f ($Minutes / 60)
}

# Writes a profile, re-activates the scheme, and reads every value back.
# Returns the names of settings that did not take, so callers can report them.
function Set-PowerProfile([string]$Name) {
    $wanted = $Profiles[$Name]
    foreach ($key in $wanted.Keys) {
        $s = $Settings[$key]
        [WindowsPowerProfiles.PowerSettings]::Write($s.Sub, $s.Id, [uint32]$wanted[$key][0], [uint32]$wanted[$key][1])
    }
    [WindowsPowerProfiles.PowerSettings]::Commit()
    [WindowsPowerProfiles.PowerSettings]::KeepSystemAwake($Name -eq 'KeepWorking')

    $failed = @()
    foreach ($key in $wanted.Keys) {
        $s = $Settings[$key]
        $actual = [WindowsPowerProfiles.PowerSettings]::Read($s.Sub, $s.Id)
        if ($actual[0] -ne $wanted[$key][0] -or $actual[1] -ne $wanted[$key][1]) {
            $failed += '{0} (wanted {1}/{2}, got {3}/{4})' -f $key, $wanted[$key][0], $wanted[$key][1], $actual[0], $actual[1]
        }
    }
    return $failed
}

function Get-DashboardWorking {
    try {
        $board = Invoke-RestMethod -Uri $Config.DashboardUrl -TimeoutSec 2
        $fresh = (Get-Date).ToUniversalTime().AddHours(-$Config.DashboardFreshHours)
        $working = @($board.cards | Where-Object {
            $_.column -eq 'working' -and -not $_.archivedAt -and -not $_.sessionEndedAt -and
            $(
                $stamp = if ($_.lastActiveAt) { $_.lastActiveAt } else { $_.updatedAt }
                $stamp -and ([datetime]::Parse($stamp).ToUniversalTime() -gt $fresh)
            )
        })
        return $working.Count
    } catch {
        return -1  # dashboard not running or unreadable
    }
}

# ---------------------------------------------------------------- self-test

if ($SelfTest) {
    'Settings before:'
    foreach ($key in $Settings.Keys) {
        $v = [WindowsPowerProfiles.PowerSettings]::Read($Settings[$key].Sub, $Settings[$key].Id)
        '  {0,-15} AC={1,-10} DC={2}' -f $key, $v[0], $v[1]
    }
    foreach ($name in 'KeepWorking', 'Away') {
        $failed = Set-PowerProfile $name
        if ($failed) { "Profile $name FAILED: $($failed -join '; ')" } else { "Profile $name applied and verified." }
    }
    [WindowsPowerProfiles.PowerSettings]::KeepSystemAwake($false)

    $activity = New-Object WindowsPowerProfiles.ClaudeActivity 'claude.exe'
    $null = $activity.Sample($Config.ClaudeBusyCpuMs)
    Start-Sleep -Seconds $Config.PollSeconds
    $sample = $activity.Sample($Config.ClaudeBusyCpuMs)
    'Claude sessions: {0}, busy: {1}, new processes: {2}, max CPU ms in {3}s: {4:N0}' -f $sample.Sessions, $sample.BusySessions, $sample.Spawns, $Config.PollSeconds, $sample.MaxCpuMs
    "  per session (pid:cpu+spawns): $($sample.Detail)"
    "Dashboard Working cards (fresh): $(Get-DashboardWorking)"
    "Idle for: $(Format-Span ([WindowsPowerProfiles.UserIdle]::Get()))"
    return
}

# ---------------------------------------------------------------- single instance

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\WindowsPowerProfiles', [ref]$createdNew)
if (-not $createdNew) {
    Write-Log 'Second instance exited; one is already running.'
    return
}

# ---------------------------------------------------------------- state

$State = @{
    Mode            = 'Away'      # Away | KeepWorking | Auto
    Effective       = 'Away'      # profile actually applied: Away | KeepWorking
    KeepUntil       = $null       # [datetime] for timed Keep Working
    AutoAwakeSince  = $null       # start of the current Auto keep-awake stretch
    AutoLastBusy    = $null       # last poll with a busy signal
    AutoCapped      = $false      # cap reached; stays Away until signals go quiet
    AutoReason      = ''
    PendingHibernate = $false
}

$Activity = New-Object WindowsPowerProfiles.ClaudeActivity 'claude.exe'
$State.LastDisplayOn = $null

# ---------------------------------------------------------------- tray icon

function New-DotIcon([System.Drawing.Color]$Color, [bool]$Ring) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 2, 2, 28, 28)
    if ($Ring) {
        # Auto mode: a white ring inside the dot.
        $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 4), 9, 9, 14, 14)
    }
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$Icons = @{
    Away            = New-DotIcon ([System.Drawing.Color]::SeaGreen) $false
    KeepWorking     = New-DotIcon ([System.Drawing.Color]::OrangeRed) $false
    AutoAway        = New-DotIcon ([System.Drawing.Color]::SeaGreen) $true
    AutoKeepWorking = New-DotIcon ([System.Drawing.Color]::OrangeRed) $true
}

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $Icons.Away
$Tray.Text = 'Power: Away'
$Tray.Visible = $true

function Update-Tray {
    $text = switch ($State.Mode) {
        'Away' { 'Power: Away (lid hibernates)' }
        'KeepWorking' {
            if ($State.KeepUntil) {
                'Power: Keep Working, {0} left' -f (Format-Span ($State.KeepUntil - (Get-Date)))
            } else {
                'Power: Keep Working until switched back'
            }
        }
        'Auto' {
            if ($State.Effective -eq 'KeepWorking') { "Power: Auto, awake ($($State.AutoReason))" }
            elseif ($State.AutoCapped) { 'Power: Auto, Away (time cap reached)' }
            else { 'Power: Auto, Away (Claude idle)' }
        }
    }
    # NotifyIcon throws on tooltip text longer than 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $Tray.Text = $text
    $iconKey = if ($State.Mode -eq 'Auto') { 'Auto' + $State.Effective } else { $State.Effective }
    $Tray.Icon = $Icons[$iconKey]

    $MenuAway.Checked = $State.Mode -eq 'Away'
    $MenuKeep.Checked = $State.Mode -eq 'KeepWorking'
    $MenuAuto.Checked = $State.Mode -eq 'Auto'
}

function Show-Note([string]$Text) {
    $Tray.ShowBalloonTip(5000, 'Power profile', $Text, [System.Windows.Forms.ToolTipIcon]::Info)
}

# ---------------------------------------------------------------- mode changes

function Set-Effective([string]$Name, [string]$Why) {
    if ($State.Effective -eq $Name -and $Why -ne 'launch') { return }
    $failed = Set-PowerProfile $Name
    $State.Effective = $Name
    if ($failed) {
        Write-Log "WARNING: $Name applied with errors: $($failed -join '; ')"
        Show-Note "Some $Name settings did not apply. See the log."
    }
    Write-Log "Profile $Name ($Why)"
}

function Enter-Away([string]$Why) {
    $State.Mode = 'Away'
    $State.KeepUntil = $null
    Set-Effective 'Away' $Why
    Update-Tray
}

function Enter-KeepWorking([int]$Minutes) {
    $State.Mode = 'KeepWorking'
    $State.KeepUntil = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { $null }
    $State.PendingHibernate = $false
    Set-Effective 'KeepWorking' "manual, $(Format-Minutes $Minutes)"
    Update-Tray
}

function Enter-Auto {
    $State.Mode = 'Auto'
    $State.KeepUntil = $null
    $State.AutoCapped = $false
    $State.PendingHibernate = $false
    # Coming from Keep Working, stay awake through one quiet period rather than
    # dropping straight to Away. Coming from Away, wait for a real busy signal.
    if ($State.Effective -eq 'KeepWorking') {
        $State.AutoAwakeSince = Get-Date
        $State.AutoLastBusy = Get-Date
        $State.AutoReason = 'from Keep Working'
    } else {
        $State.AutoAwakeSince = $null
        $State.AutoLastBusy = $null
    }
    # The CPU baseline is stale while Auto is off; reset it so the first delta is not inflated.
    $null = $Activity.Sample($Config.ClaudeBusyCpuMs)
    Write-Log 'Mode Auto'
    Update-AutoMode
    Update-Tray
}

# Called whenever a keep-awake stretch ends on its own (timer, Auto, cap).
# Arms a hibernate that fires on a later poll once nobody is using the machine.
function Complete-Work([string]$Why) {
    Write-Log "Work ended: $Why"
    $State.PendingHibernate = $true
    Show-Note "$Why. Back to Away; the machine will hibernate when idle."
    Test-PendingHibernate
}

function Invoke-Hibernate([string]$Why) {
    $State.PendingHibernate = $false
    if ($State.Mode -ne 'Auto') { $State.Mode = 'Away' }
    $State.KeepUntil = $null
    Set-Effective 'Away' 'before hibernate'
    Update-Tray
    Write-Log "Hibernating: $Why"
    try {
        [WindowsPowerProfiles.PowerSettings]::Hibernate()
    } catch {
        Write-Log "ERROR: hibernate failed: $_"
        Show-Note 'Hibernate failed. See the log.'
    }
}

function Test-PendingHibernate {
    if (-not $State.PendingHibernate -or $State.Effective -ne 'Away') { return }
    $idle = [WindowsPowerProfiles.UserIdle]::Get()
    $lidClosed = $Window.LidOpen -eq $false
    if ($idle.TotalSeconds -lt 60) {
        # Someone is at the keyboard (for example docked with the lid shut).
        $State.PendingHibernate = $false
        Write-Log 'Pending hibernate canceled: user active'
    } elseif ($lidClosed -and $idle.TotalMinutes -ge $Config.HibernateIdleLidClosed) {
        Invoke-Hibernate "work ended, lid closed, idle $(Format-Span $idle)"
    } elseif ($idle.TotalMinutes -ge $Config.HibernateIdleLidOpen) {
        Invoke-Hibernate "work ended, idle $(Format-Span $idle)"
    }
}

function Update-AutoMode {
    $sample = $Activity.Sample($Config.ClaudeBusyCpuMs)
    $cards = Get-DashboardWorking
    $now = Get-Date
    $busy = ($cards -gt 0) -or ($sample.BusySessions -gt 0)
    $reasons = @()
    if ($cards -gt 0) { $reasons += "$cards card" + $(if ($cards -gt 1) { 's' }) }
    if ($sample.BusySessions -gt 0) { $reasons += "$($sample.BusySessions) busy" }
    if ($busy) {
        $State.AutoLastBusy = $now
        $State.AutoReason = $reasons -join ', '
    }

    if ($TraceAuto) {
        Write-Log ('Auto poll: cards={0} sessions={1} busy={2} spawns={3} maxCpuMs={4:N0} [{5}]' -f $cards, $sample.Sessions, $sample.BusySessions, $sample.Spawns, $sample.MaxCpuMs, $sample.Detail)
    }

    $quiet = -not $State.AutoLastBusy -or ($now - $State.AutoLastBusy).TotalMinutes -ge $Config.AutoQuietMinutes

    if ($State.AutoCapped) {
        if ($quiet) {
            $State.AutoCapped = $false
            Write-Log 'Auto: signals quiet, time cap cleared'
        }
        return
    }

    if ($State.Effective -eq 'Away' -and $busy) {
        $State.AutoAwakeSince = $now
        $State.PendingHibernate = $false
        Set-Effective 'KeepWorking' "Auto: $($State.AutoReason)"
    } elseif ($State.Effective -eq 'KeepWorking') {
        if (($now - $State.AutoAwakeSince).TotalMinutes -ge $Config.AutoMaxMinutes) {
            $State.AutoCapped = $true
            Set-Effective 'Away' 'Auto: time cap reached'
            Complete-Work "Auto stayed awake for $(Format-Minutes $Config.AutoMaxMinutes)"
        } elseif ($quiet) {
            Set-Effective 'Away' 'Auto: Claude idle'
            Complete-Work 'Claude sessions went quiet'
        }
    }
}

function Test-Battery {
    if ($State.Effective -ne 'KeepWorking') { return }
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ($power.PowerLineStatus -eq 'Offline' -and $power.BatteryLifePercent -le ($Config.BatteryFloorPercent / 100)) {
        Invoke-Hibernate ('battery at {0:P0}' -f $power.BatteryLifePercent)
    }
}

function Invoke-Poll {
    if ($State.Mode -eq 'KeepWorking' -and $State.KeepUntil -and (Get-Date) -ge $State.KeepUntil) {
        Enter-Away 'timer ended'
        Complete-Work 'Keep Working time ended'
    } elseif ($State.Mode -eq 'Auto') {
        Update-AutoMode
    }
    Test-Battery
    Test-PendingHibernate
    Update-Tray
}

# ---------------------------------------------------------------- Explorer restart

function Restart-Explorer {
    $old = @(Get-Process explorer -ErrorAction SilentlyContinue | Sort-Object StartTime)
    $before = if ($old) {
        'explorer up {0}, {1:N0} MB, {2:N0} handles' -f (Format-Span ((Get-Date) - $old[0].StartTime)),
            (($old | Measure-Object WorkingSet64 -Sum).Sum / 1MB), (($old | Measure-Object HandleCount -Sum).Sum)
    } else { 'explorer was not running' }

    # Start menu and search run in their own hosts; a frozen Start often lives there.
    Stop-Process -Name explorer, StartMenuExperienceHost, SearchHost, ShellExperienceHost -Force -ErrorAction SilentlyContinue
    foreach ($p in $old) { [void]$p.WaitForExit(3000) }

    # Winlogon restarts the shell by itself (AutoRestartShell = 1). Start one only if
    # it does not, because a second explorer.exe opens a File Explorer window.
    $deadline = (Get-Date).AddSeconds(5)
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
        $before += '; started explorer manually'
    }

    # Context for spotting a pattern later: how long since the last wake and display-on.
    $wake = try {
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 507 } -MaxEvents 1
        'last standby exit {0} ago' -f (Format-Span ((Get-Date) - $e.TimeCreated))
    } catch { 'last standby exit unknown' }
    $display = if ($State.LastDisplayOn) { 'display on for {0}' -f (Format-Span ((Get-Date) - $State.LastDisplayOn)) } else { 'display-on time unknown' }

    Write-Log "Explorer restart: $before; $wake; $display"
}

# ---------------------------------------------------------------- menu

$Menu = New-Object System.Windows.Forms.ContextMenuStrip

$MenuAway = New-Object System.Windows.Forms.ToolStripMenuItem 'Away (lid hibernates)'
$MenuAway.add_Click({ try { $State.PendingHibernate = $false; Enter-Away 'manual' } catch { Write-Log "ERROR: $_" } })

$MenuKeep = New-Object System.Windows.Forms.ToolStripMenuItem 'Keep Working'
foreach ($minutes in $Config.KeepWorkingChoices) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem ('For ' + (Format-Minutes $minutes))
    if ($minutes -le 0) { $item.Text = 'Until I switch back' }
    $item.Tag = $minutes
    $item.add_Click({ param($s, $e) try { Enter-KeepWorking ([int]$s.Tag) } catch { Write-Log "ERROR: $_" } })
    [void]$MenuKeep.DropDownItems.Add($item)
}

$MenuAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto (follow Claude sessions)'
$MenuAuto.add_Click({ try { Enter-Auto } catch { Write-Log "ERROR: $_" } })

$MenuExplorer = New-Object System.Windows.Forms.ToolStripMenuItem 'Restart Explorer'
$MenuExplorer.ShortcutKeyDisplayString = 'Ctrl+Alt+Shift+E'
$MenuExplorer.add_Click({ try { Restart-Explorer } catch { Write-Log "ERROR: $_" } })

$MenuLog = New-Object System.Windows.Forms.ToolStripMenuItem 'Open log'
$MenuLog.add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } })

$MenuExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit (sets Away)'
$MenuExit.add_Click({
    try { Set-Effective 'Away' 'exit'; Write-Log 'Exit' } catch { Write-Log "ERROR on exit: $_" }
    $Timer.Stop()
    $Window.Dispose()
    $Tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

[void]$Menu.Items.AddRange(@(
    $MenuAway, $MenuKeep, $MenuAuto,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $MenuExplorer, $MenuLog,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $MenuExit
))
$Tray.ContextMenuStrip = $Menu

# Left click opens the same menu as right click. NotifyIcon only exposes this
# through a private method.
$ShowMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance, NonPublic')
$Tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $ShowMenu.Invoke($Tray, $null) }
})

# ---------------------------------------------------------------- hotkey, lid, display

$Window = New-Object WindowsPowerProfiles.MessageWindow
$mods = [WindowsPowerProfiles.MessageWindow]::MOD_CONTROL -bor [WindowsPowerProfiles.MessageWindow]::MOD_ALT -bor [WindowsPowerProfiles.MessageWindow]::MOD_SHIFT
if (-not $Window.RegisterHotkey($mods, [System.Windows.Forms.Keys]::E)) {
    Write-Log 'WARNING: Ctrl+Alt+Shift+E is taken by another app; the hotkey is off. Use the tray menu.'
    $MenuExplorer.ShortcutKeyDisplayString = '(hotkey unavailable)'
}
$Window.add_HotkeyPressed({ try { Restart-Explorer } catch { Write-Log "ERROR: $_" } })
$Window.add_LidChanged({
    try {
        Write-Log $(if ($Window.LidOpen) { 'Lid opened' } else { 'Lid closed' })
        if ($Window.LidOpen) { $State.PendingHibernate = $false } else { Test-PendingHibernate }
    } catch { Write-Log "ERROR: $_" }
})
$Window.add_DisplayChanged({
    $label = switch ($Window.DisplayState) { 0 { 'off' } 1 { 'on' } 2 { 'dimmed' } default { "state $($Window.DisplayState)" } }
    if ($Window.DisplayState -eq 1) { $State.LastDisplayOn = Get-Date }
    Write-Log "Display $label"
})
$Window.RegisterPowerNotifications()

# ---------------------------------------------------------------- run

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = $Config.PollSeconds * 1000
$Timer.add_Tick({ try { Invoke-Poll } catch { Write-Log "ERROR in poll: $_" } })

$null = $Activity.Sample($Config.ClaudeBusyCpuMs)  # baseline for the first Auto poll
Write-Log "Started (pid $PID)"
Set-Effective 'Away' 'launch'
Update-Tray
$Timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    [WindowsPowerProfiles.PowerSettings]::KeepSystemAwake($false)
    $Tray.Visible = $false
    $Tray.Dispose()
    $mutex.ReleaseMutex()
}
