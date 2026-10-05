<#
.SYNOPSIS
    Tray app that switches Windows power settings between Away, Keep Working
    and Auto, and restarts Explorer on Ctrl+Alt+Shift+E.

.DESCRIPTION
    Away (applied at every launch): closing the lid hibernates, idle standby
    turns into hibernate, and the network is off during standby.

    Keep Working: closing the lid does nothing and the system does not idle
    sleep, for a fixed time or until switched back. When it ends (or the
    battery falls to the floor), the machine returns to Away and hibernates
    once nobody is using it. Every clean way out of the app puts Away back.

    Auto: Keep Working while a Claude Code session looks busy, Away otherwise.
    "Busy" is a Working card on the status dashboard OR a Claude session's
    process tree (claude.exe, or node.exe running Claude Code's cli.js) that
    started a new process or used CPU since the last poll. Either
    signal alone is enough, because neither is reliable alone: cards can go
    stale, and a Claude session uses about as little CPU while the model
    generates as it does idle (only tool runs show up).

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
Add-Type -Path (Join-Path $PSScriptRoot 'Hibearnate.cs') -ReferencedAssemblies System.Windows.Forms

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
    # Optional: a claude-status-dashboard board (github.com/mattcowan/claude-status-dashboard).
    # Set to $null to turn the dashboard signal off; Auto then uses the process checks only.
    DashboardUrl            = 'http://127.0.0.1:4787/api/board'
    DashboardFreshHours     = 6        # ignore Working cards with no activity for longer
    HibernateIdleLidClosed  = 2        # minutes idle before hibernating with the lid closed
    HibernateIdleLidOpen    = 10       # minutes idle before hibernating with the lid open
    BatteryFloorPercent     = 15       # at or below this on battery, Keep Working ends (Away, then idle hibernate)
    LogDir                  = Join-Path $env:LOCALAPPDATA 'Hibearnate'
}
$LogPath = Join-Path $Config.LogDir 'power-profiles.log'
$BaselinePath = Join-Path $Config.LogDir 'baseline.json'

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
# Records the settings this app changes, as they were before its first run, so
# Restore-Baseline.ps1 can put them back on any machine. Never overwrites an
# existing file: a later run would record the app's own Away values instead.
# Each entry carries its own GUIDs and the plan it came from, so the restore
# script needs neither this file's tables nor the C# helper.
function Save-Baseline {
    if (Test-Path $BaselinePath) {
        # Never overwrite (the settings may already be the app's own), but say
        # so if the record cannot be used, because nothing can rebuild it.
        if (-not (Test-BaselineFile $BaselinePath)) {
            Write-Log "WARNING: $BaselinePath is not a usable baseline; Restore-Baseline.ps1 will refuse it"
            Show-Note 'The record of the original power settings is damaged. See the log.'
        }
        return
    }
    $scheme = [Hibearnate.PowerSettings]::ActiveScheme()
    $entries = foreach ($key in $Settings.Keys) {
        $s = $Settings[$key]
        $v = [Hibearnate.PowerSettings]::Read($s.Sub, $s.Id)
        [ordered]@{ Name = $key; Subgroup = "$($s.Sub)"; Setting = "$($s.Id)"; AC = $v[0]; DC = $v[1] }
    }
    if (-not (Test-Path $Config.LogDir)) {
        New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
    }
    # Write a temp file, check it, then rename it into place. The rename is
    # atomic on one volume and fails if the target exists, so the record is
    # either complete or absent, and a second writer can never replace it.
    $tempPath = "$BaselinePath.tmp"
    [ordered]@{ RecordedAt = (Get-Date).ToString('s'); Scheme = "$scheme"; Settings = @($entries) } |
        ConvertTo-Json -Depth 4 | Set-Content -Path $tempPath -Encoding UTF8
    if (-not (Test-BaselineFile $tempPath)) {
        Remove-Item $tempPath -ErrorAction SilentlyContinue
        throw "the baseline written to $tempPath did not read back correctly"
    }
    [System.IO.File]::Move($tempPath, $BaselinePath)
    Write-Log "Baseline recorded: $BaselinePath"
}

# True when the file parses and holds a plan GUID and, for every setting this
# app changes, its GUIDs and numeric AC and DC values. Restore-Baseline.ps1
# carries its own copy of this check, so it still works without this script.
function Test-BaselineFile([string]$Path) {
    try {
        $b = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([string]$b.Scheme, [ref]$guid)) { return $false }
        $names = @($b.Settings | ForEach-Object { $_.Name })
        foreach ($key in $Settings.Keys) { if ($names -notcontains $key) { return $false } }
        foreach ($s in $b.Settings) {
            if (-not [guid]::TryParse([string]$s.Subgroup, [ref]$guid)) { return $false }
            if (-not [guid]::TryParse([string]$s.Setting, [ref]$guid)) { return $false }
            if ($s.AC -isnot [ValueType] -or $s.DC -isnot [ValueType]) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Set-PowerProfile([string]$Name) {
    $wanted = $Profiles[$Name]
    foreach ($key in $wanted.Keys) {
        $s = $Settings[$key]
        [Hibearnate.PowerSettings]::Write($s.Sub, $s.Id, [uint32]$wanted[$key][0], [uint32]$wanted[$key][1])
    }
    [Hibearnate.PowerSettings]::Commit()
    [Hibearnate.PowerSettings]::KeepSystemAwake($Name -eq 'KeepWorking')

    $failed = @()
    foreach ($key in $wanted.Keys) {
        $s = $Settings[$key]
        $actual = [Hibearnate.PowerSettings]::Read($s.Sub, $s.Id)
        if ($actual[0] -ne $wanted[$key][0] -or $actual[1] -ne $wanted[$key][1]) {
            $failed += '{0} (wanted {1}/{2}, got {3}/{4})' -f $key, $wanted[$key][0], $wanted[$key][1], $actual[0], $actual[1]
        }
    }
    return $failed
}

function Get-DashboardWorking {
    if (-not $Config.DashboardUrl) { return -1 }  # signal turned off
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

# ---------------------------------------------------------------- single instance

# Taken before the self-test too: the self-test rewrites the power settings,
# and a running tray would keep showing the state it thinks it applied.
# Ownership comes from WaitOne(0), not from the createdNew flag of the
# constructor: createdNew only says whether the named mutex already existed,
# so any handle left open (for example by a self-test run inside an
# interactive shell) would make every later start think a tray was running.
$mutex = New-Object System.Threading.Mutex($false, 'Local\Hibearnate')
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true  # the previous owner died without releasing it; we own it now
}
if (-not $owned) {
    $mutex.Dispose()
    if ($SelfTest) {
        $Host.UI.WriteErrorLine('The tray app is running. Use Exit in its menu, then run -SelfTest again.')
        exit 1
    }
    Write-Log 'Second instance exited; one is already running.'
    return
}

# ---------------------------------------------------------------- self-test

if ($SelfTest) {
    try {
        Save-Baseline  # the self-test writes settings too
        'Settings before:'
        foreach ($key in $Settings.Keys) {
            $v = [Hibearnate.PowerSettings]::Read($Settings[$key].Sub, $Settings[$key].Id)
            '  {0,-15} AC={1,-10} DC={2}' -f $key, $v[0], $v[1]
        }
        foreach ($name in 'KeepWorking', 'Away') {
            $failed = Set-PowerProfile $name
            if ($failed) { "Profile $name FAILED: $($failed -join '; ')" } else { "Profile $name applied and verified." }
        }
        [Hibearnate.PowerSettings]::KeepSystemAwake($false)

        $activity = New-Object Hibearnate.ClaudeActivity 'claude.exe'
        $null = $activity.Sample($Config.ClaudeBusyCpuMs)
        Start-Sleep -Seconds $Config.PollSeconds
        $sample = $activity.Sample($Config.ClaudeBusyCpuMs)
        'Claude sessions: {0}, busy: {1}, new processes: {2}, max CPU ms in {3}s: {4:N0}' -f $sample.Sessions, $sample.BusySessions, $sample.Spawns, $Config.PollSeconds, $sample.MaxCpuMs
        "  per session (pid:cpu+spawns): $($sample.Detail)"
        "Dashboard Working cards (fresh): $(Get-DashboardWorking)"
        "Idle for: $(Format-Span ([Hibearnate.UserIdle]::Get()))"
    } finally {
        # Release and close the handle: in an interactive shell the process
        # lives on, and an open handle would outlive this run.
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    return
}

# Uninstall.ps1 sets this event to ask the tray to exit cleanly (and so put
# the Away settings back) instead of being killed in Keep Working.
$ExitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\Hibearnate.Exit')
$ExitEvent.Reset()

# ---------------------------------------------------------------- state

$State = @{
    Mode            = 'Away'      # Away | KeepWorking | Auto
    Effective       = 'Away'      # profile actually applied: Away | KeepWorking | None (nothing written yet)
    KeepUntil       = $null       # [datetime] for timed Keep Working
    KeepMinutes     = 0           # the Keep Working choice, so the menu can mark it (0 = until switched back)
    AutoAwakeSince  = $null       # start of the current Auto keep-awake stretch
    AutoLastBusy    = $null       # last poll with a busy signal
    AutoCapped      = $false      # cap reached; stays Away until signals go quiet
    AutoReason      = ''
    PendingHibernate = $false
}

$Activity = New-Object Hibearnate.ClaudeActivity 'claude.exe'
$State.LastDisplayOn = $null
$State.NoBaseline = $false   # true while the originals could not be recorded (no setting is changed)
$State.LastPoll = $null      # time of the last poll, to spot a wake
$State.LastResume = $null    # time of the last wake, caps the idle time

# ---------------------------------------------------------------- tray icon

# A bear face. Green = Away, red = Keep Working, orange = Auto, so switching
# Keep Working to Auto visibly changes the icon even while Auto keeps the
# machine awake. The eyes show what is applied right now: closed (sleeping)
# = the Away settings, open = staying awake. Auto also adds a white badge, so
# the mode never depends on color alone. Drawn at 32 px; Windows scales it.
function New-BearIcon([System.Drawing.Color]$Fur, [bool]$Awake, [bool]$Auto) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $dark = [System.Drawing.Color]::FromArgb(40, 30, 25)
    # Not $fur: PowerShell names ignore case, so that is the typed $Fur parameter.
    $furBrush = New-Object System.Drawing.SolidBrush $Fur
    $ink = New-Object System.Drawing.SolidBrush $dark

    $g.FillEllipse($furBrush, 2, 2, 11, 11)    # ears
    $g.FillEllipse($furBrush, 19, 2, 11, 11)
    $g.FillEllipse($furBrush, 3, 5, 26, 25)    # head
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(245, 236, 222))), 10, 16, 12, 10)  # snout
    $g.FillEllipse($ink, 14, 17, 4, 3)    # nose
    if ($Awake) {
        $g.FillEllipse($ink, 9, 11, 4, 4)
        $g.FillEllipse($ink, 19, 11, 4, 4)
    } else {
        # Sleeping eyes: the lower half of an ellipse, like a closed lid.
        $pen = New-Object System.Drawing.Pen $dark, 2
        $g.DrawArc($pen, 8, 9, 6, 5, 0, 180)
        $g.DrawArc($pen, 18, 9, 6, 5, 0, 180)
    }
    if ($Auto) {
        $g.FillEllipse([System.Drawing.Brushes]::White, 21, 21, 10, 10)
        $g.DrawEllipse((New-Object System.Drawing.Pen $dark, 1.5), 21, 21, 10, 10)
    }
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$Icons = @{
    Away            = New-BearIcon ([System.Drawing.Color]::SeaGreen) $false $false
    KeepWorking     = New-BearIcon ([System.Drawing.Color]::OrangeRed) $true $false
    AutoAway        = New-BearIcon ([System.Drawing.Color]::Orange) $false $true
    AutoKeepWorking = New-BearIcon ([System.Drawing.Color]::Orange) $true $true
}

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $Icons.Away
$Tray.Text = 'Hibearnate: Away'
$Tray.Visible = $true

function Update-Tray {
    $text = switch ($State.Mode) {
        'Away' { 'Hibearnate: Away (lid hibernates)' }
        'KeepWorking' {
            if ($State.KeepUntil) {
                'Hibearnate: Keep Working, {0} left' -f (Format-Span ($State.KeepUntil - (Get-Date)))
            } else {
                'Hibearnate: Keep Working until switched back'
            }
        }
        'Auto' {
            if ($State.Effective -eq 'KeepWorking') { "Hibearnate: Auto, awake ($($State.AutoReason))" }
            elseif ($State.AutoCapped) { 'Hibearnate: Auto, Away (time cap reached)' }
            elseif ($null -ne (Get-LowBattery)) { 'Hibearnate: Auto, Away (battery low)' }
            else { 'Hibearnate: Auto, Away (Claude idle)' }
        }
    }
    if ($State.NoBaseline) { $text = 'Hibearnate: originals not recorded, no changes made' }
    # NotifyIcon throws on tooltip text longer than 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $Tray.Text = $text
    # Effective is 'None' until a profile is applied; show the Away bear then.
    $shown = if ($State.Effective -eq 'KeepWorking') { 'KeepWorking' } else { 'Away' }
    $iconKey = if ($State.Mode -eq 'Auto') { 'Auto' + $shown } else { $shown }
    $Tray.Icon = $Icons[$iconKey]

    $MenuAway.Checked = $State.Mode -eq 'Away'
    $MenuKeep.Checked = $State.Mode -eq 'KeepWorking'
    # Show the chosen duration: a check on its submenu item, and the time left
    # on the parent item, so the open menu answers "which one did I pick?".
    foreach ($item in $MenuKeep.DropDownItems) {
        $item.Checked = $State.Mode -eq 'KeepWorking' -and [int]$item.Tag -eq $State.KeepMinutes
    }
    $MenuKeep.Text = if ($State.Mode -ne 'KeepWorking') { 'Keep Working' }
        elseif ($State.KeepUntil) { 'Keep Working ({0} left)' -f (Format-Span ($State.KeepUntil - (Get-Date))) }
        else { 'Keep Working (until switched back)' }
    $MenuAuto.Checked = $State.Mode -eq 'Auto'
}

function Show-Note([string]$Text) {
    $Tray.ShowBalloonTip(5000, 'Hibearnate', $Text, [System.Windows.Forms.ToolTipIcon]::Info)
}

# ---------------------------------------------------------------- mode changes

function Set-Effective([string]$Name, [string]$Why) {
    # Fail closed: without a record of the original settings, change nothing,
    # so the originals cannot be lost. Invoke-Poll retries the record.
    if ($State.NoBaseline) {
        Write-Log "Skipped $Name ($Why): the original settings are not recorded yet"
        return
    }
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
    $State.KeepMinutes = $Minutes
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
        [Hibearnate.PowerSettings]::Hibernate()
    } catch {
        Write-Log "ERROR: hibernate failed: $_"
        Show-Note 'Hibernate failed. See the log.'
    }
}

# Time since the last keyboard or mouse input, but never more than the time
# since the last wake. GetLastInputInfo keeps counting through a hibernate or
# standby, so right after a wake it reports the whole time the machine was off
# (seen: "idle 4h 25m" one second after the lid opened), and the lid state can
# still say "closed" until Windows sends the lid-open notice.
function Get-EffectiveIdle {
    $idle = [Hibearnate.UserIdle]::Get()
    if ($State.LastResume) {
        $sinceWake = (Get-Date) - $State.LastResume
        if ($sinceWake -lt $idle) { return $sinceWake }
    }
    return $idle
}

function Test-PendingHibernate {
    if (-not $State.PendingHibernate -or $State.Effective -ne 'Away') { return }
    $idle = Get-EffectiveIdle
    $lidClosed = $Window.LidOpen -eq $false
    if ($idle.TotalSeconds -lt 60) {
        # Someone is at the keyboard (for example docked with the lid shut), or
        # the machine just woke. After a wake with nobody there, the Away
        # timers still put it into standby and then hibernate.
        $State.PendingHibernate = $false
        Write-Log 'Pending hibernate canceled: user active or just woke'
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
        if ($null -ne (Get-LowBattery)) { return }  # Test-Battery would only end it again
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

# Returns the battery percent (0-100) when on battery at or below the floor,
# otherwise $null. BatteryLifePercent is a float, and 0.15f widens to
# 0.15000000596, so compare whole percents rather than fractions.
function Get-LowBattery {
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ($power.PowerLineStatus -ne 'Offline') { return $null }
    $percent = [int][math]::Round($power.BatteryLifePercent * 100)
    if ($percent -le $Config.BatteryFloorPercent) { return $percent }
    return $null
}

# Low battery ends Keep Working the same way a timer does: back to Away, then
# hibernate once nobody is using the machine (after 2 idle minutes with the lid
# shut). Not an immediate hibernate: that path had no idle check, and in Auto
# it looped (wake, card still busy, Keep Working again, hibernate again).
# Windows still hibernates on its own at the critical level (2% on this machine).
function Test-Battery {
    if ($State.Effective -ne 'KeepWorking') { return }
    $percent = Get-LowBattery
    if ($null -eq $percent) { return }
    if ($State.Mode -eq 'Auto') {
        Set-Effective 'Away' "Auto: battery at $percent%"
    } else {
        Enter-Away "battery at $percent%"
    }
    Complete-Work "Battery at $percent%"
}

function Invoke-Poll {
    if ($ExitEvent.WaitOne(0)) {
        Stop-App 'exit requested by Uninstall.ps1'
        return
    }
    # The poll timer does not run while the machine hibernates or sits in
    # standby (Windows pauses desktop apps there), so a long gap since the last
    # poll means the machine just woke. Note it before anything below decides
    # on idle time.
    $now = Get-Date
    if ($State.LastPoll -and ($now - $State.LastPoll).TotalSeconds -gt 3 * $Config.PollSeconds) {
        $State.LastResume = $now
        Write-Log "Woke after $(Format-Span ($now - $State.LastPoll)) without a poll"
    }
    $State.LastPoll = $now
    if ($State.NoBaseline) {
        try {
            Save-Baseline
            $State.NoBaseline = $false
            Write-Log 'Original settings recorded on retry'
            Set-Effective $(if ($State.Mode -eq 'KeepWorking') { 'KeepWorking' } else { 'Away' }) 'original settings recorded'
        } catch {
            # Logged once at launch; stay quiet until it works.
        }
    }
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

# Keep Working writes "lid does nothing" and "never sleep" into the power
# scheme, and those values outlive the process. Every way out of the app that
# runs code puts Away back: this function, the session-end handler, and the
# finally block around Application.Run. Only a hard kill or a crash of the
# process itself skips all three; the next launch (at login) applies Away.
function Stop-App([string]$Why) {
    try { Set-Effective 'Away' 'exit'; Write-Log "Exit: $Why" } catch { Write-Log "ERROR on exit: $_" }
    $Timer.Stop()
    $Window.Dispose()
    $Tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

$MenuExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit (sets Away)'
$MenuExit.add_Click({ Stop-App 'menu' })

[void]$Menu.Items.AddRange(@(
    $MenuAway, $MenuKeep, $MenuAuto,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $MenuExplorer, $MenuLog,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $MenuExit
))
$Tray.ContextMenuStrip = $Menu
$Menu.add_Opening({ try { Update-Tray } catch { Write-Log "ERROR: $_" } })  # fresh "time left" when the menu opens

# Left click opens the same menu as right click. NotifyIcon only exposes this
# through a private method.
$ShowMenu = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance, NonPublic')
$Tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $ShowMenu.Invoke($Tray, $null) }
})

# ---------------------------------------------------------------- hotkey, lid, display

$Window = New-Object Hibearnate.MessageWindow
$mods = [Hibearnate.MessageWindow]::MOD_CONTROL -bor [Hibearnate.MessageWindow]::MOD_ALT -bor [Hibearnate.MessageWindow]::MOD_SHIFT
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
$Window.add_SessionEnding({
    # Without this, a restart in Keep Working boots to a lock screen with the
    # lid ignored until the next login starts the app. Write the profile
    # directly: Windows gives this handler little time.
    try {
        # Only undo what the app applied; 'None' means nothing was written.
        if ($State.Effective -eq 'KeepWorking') {
            $failed = Set-PowerProfile 'Away'
            $State.Effective = 'Away'
            if ($failed) { Write-Log "WARNING: session ending, Away applied with errors: $($failed -join '; ')" }
            else { Write-Log 'Session ending: Away applied' }
        }
    } catch { Write-Log "ERROR on session end: $_" }
})
$Window.RegisterPowerNotifications()

# ---------------------------------------------------------------- run

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = $Config.PollSeconds * 1000
$Timer.add_Tick({ try { Invoke-Poll } catch { Write-Log "ERROR in poll: $_" } })

$null = $Activity.Sample($Config.ClaudeBusyCpuMs)  # baseline for the first Auto poll
Write-Log "Started (pid $PID)"
try {
    Save-Baseline
} catch {
    # Fail closed: change no setting until the originals are on record, or a
    # later start would record the app's own values as the originals.
    # Invoke-Poll retries. The tray, menu and hotkey keep working.
    $State.NoBaseline = $true
    $State.Effective = 'None'
    Write-Log "WARNING: could not record the original settings, so no setting was changed: $_"
    Show-Note 'Could not record the original power settings, so Hibearnate changed nothing. It will retry. See the log.'
}
Set-Effective 'Away' 'launch'
Update-Tray
$Timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($State.Effective -eq 'KeepWorking') {
        try {
            $failed = Set-PowerProfile 'Away'
            if ($failed) { Write-Log "WARNING: unexpected exit, Away applied with errors: $($failed -join '; ')" }
            else { Write-Log 'Away applied on unexpected exit' }
        } catch { Write-Log "ERROR: $_" }
    }
    [Hibearnate.PowerSettings]::KeepSystemAwake($false)
    $Tray.Visible = $false
    $Tray.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
