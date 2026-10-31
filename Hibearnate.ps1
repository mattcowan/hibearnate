<#
.SYNOPSIS
    Tray app that switches Windows power settings between Away, Keep Working
    and Auto, restarts Explorer on Ctrl+Alt+Shift+E, and restarts other apps
    from a list in restart-commands.json.

.DESCRIPTION
    Away (applied at every launch): closing the lid hibernates, idle standby
    turns into hibernate, and the network is off during standby.

    Keep Working: closing the lid does nothing and the system does not idle
    sleep, for a fixed time or until switched back. When it ends (or the
    battery falls to the floor), the machine returns to Away and hibernates
    once nobody is using it. Every clean way out of the app puts Away back.

    Auto: Keep Working while a Claude Code session or another tool looks busy,
    Away otherwise. "Busy" is a lease that a tool wrote with Busy.ps1 (or
    by itself, as the status dashboard does) and that has not ended, OR a
    Claude session's process tree (claude.exe, or node.exe running Claude
    Code's cli.js) that started a new process or used CPU since the last poll.
    Any signal alone is enough, because none covers every case: a lease needs
    a tool that reports, and a Claude session uses about as little CPU while
    the model generates as it does idle (only tool runs show up).

    The tray's "Dashboard columns" submenu edits which dashboard columns
    count as busy. The dashboard stores that choice and makes the decision;
    this app only reads the column list and writes the setting.

    See readme.md for install steps and the reason behind each setting.

.PARAMETER SelfTest
    Run the checks that need no tray (settings round trip, Claude activity
    sample, busy leases, the dashboard's watched columns, restart-command list
    with its problems), print the results and exit. Leaves the machine in the
    Away profile.

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
. (Join-Path $PSScriptRoot 'BearIcon.ps1')

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
    # Optional: the base URL of an agent-status-dashboard (github.com/mattcowan/agent-status-dashboard),
    # for the "Dashboard columns" submenu. The dashboard tells Auto that a session is busy
    # through its own lease file, so Auto does not need this. Set to $null to hide the submenu.
    DashboardBase           = 'http://127.0.0.1:4787'
    HibernateIdleLidClosed  = 2        # minutes idle before hibernating with the lid closed
    HibernateIdleLidOpen    = 10       # minutes idle before hibernating with the lid open
    BatteryFloorPercent     = 15       # at or below this on battery, Keep Working ends (Away, then idle hibernate)
    LogDir                  = Join-Path $env:LOCALAPPDATA 'Hibearnate'
}
$LogPath = Join-Path $Config.LogDir 'power-profiles.log'
$BaselinePath = Join-Path $Config.LogDir 'baseline.json'
# Per user and outside the repo, so a pull never overwrites it. "Edit the
# list" creates it from restart-commands.example.json.
$CommandsPath = Join-Path $Config.LogDir 'restart-commands.json'
# Busy.ps1, or a tool that writes the file itself, puts one lease per tool
# here as <Name>.json. Busy.ps1 carries its own copy of the name rule.
$LeaseDir = Join-Path $Config.LogDir 'leases'
$LeaseNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,23}\z'  # \z: $ also matches before a final newline

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

# Writes a profile, re-activates the scheme, and reads every value back.
# Returns the names of settings that did not take, so callers can report them.
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

$NotHotkeyKeys = @(
    'ShiftKey', 'LShiftKey', 'RShiftKey', 'ControlKey', 'LControlKey', 'RControlKey',
    'Menu', 'LMenu', 'RMenu', 'LWin', 'RWin',
    'LButton', 'RButton', 'MButton', 'XButton1', 'XButton2'
)
# A stop of the console host that runs this app would end the app without any
# exit path (see Get-ProtectedPids), so no restart command may name one.
$ConsoleHostNames = @('conhost', 'OpenConsole')

# Turns "Ctrl+Alt+Shift+L" into @{ Modifiers; Key; Text }, or $null when the
# text is not one key plus at least one modifier. A bare key is refused: as a
# global hotkey it would stop working in every other app.
function ConvertTo-Hotkey([string]$Text) {
    $mods = 0
    $key = $null
    foreach ($part in ($Text -split '\+')) {
        $part = $part.Trim()
        if ($part -match '^(ctrl|control)$') { $mods = $mods -bor [Hibearnate.MessageWindow]::MOD_CONTROL }
        elseif ($part -eq 'alt') { $mods = $mods -bor [Hibearnate.MessageWindow]::MOD_ALT }
        elseif ($part -eq 'shift') { $mods = $mods -bor [Hibearnate.MessageWindow]::MOD_SHIFT }
        elseif ($part -match '^win(dows)?$') { $mods = $mods -bor [Hibearnate.MessageWindow]::MOD_WIN }
        elseif ($null -eq $key -and $part -match '^([a-z]\w*|\d)$') {
            # A lone digit is the number row (Keys.D1); casting '1' itself
            # would give the enum value 1, the left mouse button.
            $name = if ($part -match '^\d$') { "D$part" } else { $part }
            # Enum.Parse with ignoreCase: a plain [Keys] cast rejects 'f11'.
            try { $key = [System.Enum]::Parse([System.Windows.Forms.Keys], $name, $true) } catch { return $null }
            if ([int]($key -band [System.Windows.Forms.Keys]::Modifiers) -ne 0) { return $null }
            # Virtual-key codes only, and no modifier or mouse button as the
            # key: "Ctrl+ShiftKey" would take Ctrl+Shift from every other app.
            if ([int]$key -lt 1 -or [int]$key -gt 254) { return $null }
            if ($NotHotkeyKeys -contains "$key") { return $null }
        }
        else { return $null }
    }
    if ($null -eq $key -or $mods -eq 0) { return $null }
    $label = @()
    if ($mods -band [Hibearnate.MessageWindow]::MOD_CONTROL) { $label += 'Ctrl' }
    if ($mods -band [Hibearnate.MessageWindow]::MOD_ALT) { $label += 'Alt' }
    if ($mods -band [Hibearnate.MessageWindow]::MOD_SHIFT) { $label += 'Shift' }
    if ($mods -band [Hibearnate.MessageWindow]::MOD_WIN) { $label += 'Win' }
    $label += "$key" -replace '^D(\d)$', '$1'
    return @{ Modifiers = [uint32]$mods; Key = $key; Text = $label -join '+' }
}

# True when a restart command's Start cannot be a program that Start-Process
# runs: a full path with no file there (a folder only opens File Explorer), a
# variable that ExpandEnvironmentVariables left as text because it is not
# set, a relative path with a folder part (it would depend on this app's
# working directory), or text that is not a valid path at all (a pasted
# command line in quotes makes IsPathRooted throw). A bare name such as
# notepad.exe, and a URI such as ms-settings:display, are never "missing":
# Windows finds those itself, and PATH or App Paths cannot be checked here.
function Test-StartMissing([string]$Start) {
    if (-not $Start) { return $false }
    if ($Start -match '^[a-z][a-z0-9+.-]+:') { return $false }  # a URI scheme; "C:" has one letter
    if ($Start -match '%[^%\\/]+%') { return $true }
    try {
        if ([System.IO.Path]::IsPathRooted($Start)) {
            return -not (Test-Path -LiteralPath $Start -PathType Leaf)
        }
        return $Start -match '[\\/]'
    } catch {
        return $true
    }
}

# Reads restart-commands.json. Returns @{ Commands; Problems; Warnings }. A
# missing file is not a problem: it only means no commands yet. An entry with
# a problem is left out (a bad hotkey only drops the hotkey, a bad WaitSeconds
# becomes 2), and the others still load. Warnings are for log only (a Start
# program that is not installed yet). An "Examples" list is ignored.
function Read-RestartCommands {
    $result = @{ Commands = @(); Problems = @(); Warnings = @() }
    if (-not (Test-Path -LiteralPath $CommandsPath)) { return $result }
    try {
        # -Encoding UTF8 reads the file with or without a BOM; Notepad saves without one.
        $data = Get-Content -LiteralPath $CommandsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Problems += "cannot read the file: $($_.Exception.Message)"
        return $result
    }
    if ($null -eq $data -or $null -eq $data.PSObject.Properties['Commands']) {
        $result.Problems += 'the file has no "Commands" list'
        return $result
    }
    $index = 0
    foreach ($entry in @($data.Commands)) {
        $index++
        $name = "$($entry.Name)".Trim()
        if (-not $name) {
            $result.Problems += "command $index has no Name"
            continue
        }
        # Exact image names only. A wildcard could reach far more than meant,
        # for example a SYSTEM service that shares the prefix.
        $stop = @(@($entry.Stop) | ForEach-Object { "$_".Trim() -replace '\.exe$', '' } | Where-Object { $_ })
        if (-not $stop) {
            $result.Problems += "'$name' has no process names in Stop"
            continue
        }
        $bad = @($stop | Where-Object { $_ -match '[\\/:*?"<>|\[\]]' })
        if ($bad) {
            $result.Problems += "'$name' has a path or a wildcard in Stop: $($bad -join ', ')"
            continue
        }
        $consoles = @($stop | Where-Object { $ConsoleHostNames -contains $_ })
        if ($consoles) {
            $result.Problems += "'$name' names a console host in Stop ($($consoles -join ', ')); stopping it could end Hibearnate"
            continue
        }
        $wait = 2
        if ($null -ne $entry.WaitSeconds) {
            if ($entry.WaitSeconds -is [ValueType] -and $entry.WaitSeconds -isnot [bool] -and
                $entry.WaitSeconds -ge 0 -and $entry.WaitSeconds -le 30) {
                $wait = [double]$entry.WaitSeconds
            } else {
                $result.Problems += "'$name' has a WaitSeconds that is not a number from 0 to 30; using 2"
            }
        }
        $hotkey = $null
        if ("$($entry.Hotkey)".Trim()) {
            $hotkey = ConvertTo-Hotkey $entry.Hotkey
            if (-not $hotkey) { $result.Problems += "'$name' has a Hotkey that is not valid: $($entry.Hotkey)" }
        }
        $start = [Environment]::ExpandEnvironmentVariables("$($entry.Start)".Trim())
        # Kept in the menu and logged only, with no notification: the program
        # may be installed later, and a note on every edit of the file until
        # then would be noise. The restart itself stops nothing meanwhile.
        if (Test-StartMissing $start) { $result.Warnings += "'$name' has a Start that is not a program file: $start" }
        $result.Commands += [pscustomobject]@{
            Name        = $name
            Stop        = $stop
            Start       = $start
            Arguments   = "$($entry.Arguments)".Trim()
            WaitSeconds = $wait
            Hotkey      = $hotkey
        }
    }
    return $result
}

# The dashboard's columns and the ones it watches for its busy lease (#12,
# agent-status-dashboard#42). Returns @{ Ok; Columns; Watched; Error }, where
# Columns holds @{ Key; Label } for every column except Done, in board order,
# and Watched holds the stored keys. Never the cards: the dashboard decides
# what is busy (#6), so this app does not learn the card format again.
#
# Runs on the UI thread when the menu opens, as Read-RestartCommands does, so
# each request has a 1-second limit, and the port is probed first. A refused
# connection is not instant on Windows, even on loopback: TCP retries the SYN,
# and Invoke-RestMethod took about 1 s to fail (measured), on every menu open
# for anyone who runs no dashboard. The probe bounds that to 300 ms; a
# listening loopback port answers in well under 1 ms. No retry and no
# Start-Sleep. The second request is skipped when the first fails.
function Test-DashboardPort([string]$Base) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $uri = [uri]$Base
        $async = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(300)) { return $false }
        $client.EndConnect($async)  # throws when the connection was refused
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Reason says why a read failed, for the menu text; Error holds the detail,
# for the log. 'Down': nothing accepts a connection on the port. 'Failed': the
# port answers but a request did not succeed (a timeout, an HTTP error, or a
# program on the port that is not the dashboard), so "not running" would be
# wrong. 'Old': a dashboard without the column setting.
function Read-DashboardColumns {
    $result = @{ Ok = $false; Columns = @(); Watched = @(); Reason = ''; Error = '' }
    if (-not $Config.DashboardBase) { $result.Reason = 'Off'; $result.Error = 'turned off'; return $result }
    $base = "$($Config.DashboardBase)".TrimEnd('/')
    if (-not (Test-DashboardPort $base)) {
        $result.Reason = 'Down'
        $result.Error = "nothing answers at $base"
        return $result
    }
    try {
        $cols = Invoke-RestMethod -Uri "$base/api/columns" -TimeoutSec 1 -UseBasicParsing
        $settings = Invoke-RestMethod -Uri "$base/api/settings" -TimeoutSec 1 -UseBasicParsing
    } catch {
        $result.Reason = 'Failed'
        $result.Error = $_.Exception.Message
        return $result
    }
    # Something on the port answered with JSON, but not with a column list.
    if ($null -eq $cols -or $null -eq $cols.columns) {
        $result.Reason = 'Failed'
        $result.Error = "$base/api/columns did not return a column list"
        return $result
    }
    # An older dashboard has no hibearnate setting; it watches Working only.
    if (-not $settings.hibearnate -or $null -eq $settings.hibearnate.columns) {
        $result.Reason = 'Old'
        $result.Error = 'this dashboard version has no column setting'
        return $result
    }
    $result.Columns = @(@($cols.columns) | Where-Object { $_ -and $_.kind -ne 'done' -and $_.key } | ForEach-Object {
        [pscustomobject]@{ Key = [string]$_.key; Label = [string]$_.label }
    })
    $result.Watched = @(@($settings.hibearnate.columns) | ForEach-Object { [string]$_ })
    $result.Ok = $true
    return $result
}

# Saves the whole list of watched keys, not a toggle, so two quick clicks
# cannot cross. Returns the list the dashboard saved: it drops keys that are
# no longer columns, so the caller compares the answer with its request.
# Throws when the dashboard cannot be reached or refuses the write.
function Save-DashboardColumns([string[]]$Keys) {
    $base = "$($Config.DashboardBase)".TrimEnd('/')
    # [string[]] keeps an empty or one-item list a JSON array in 5.1.
    $body = @{ hibearnate = @{ columns = [string[]]@($Keys) } } | ConvertTo-Json -Depth 4 -Compress
    # No Origin header and a loopback Host, so the dashboard's write gate
    # lets this through, as it does for its own CLI.
    $saved = Invoke-RestMethod -Uri "$base/api/settings" -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 2 -UseBasicParsing
    if (-not $saved.hibearnate -or $null -eq $saved.hibearnate.columns) {
        throw 'the dashboard did not return the column setting'
    }
    return ,@(@($saved.hibearnate.columns) | ForEach-Object { [string]$_ })
}

# Reads the busy leases in $LeaseDir. Returns @{ Active; Problems }, where
# Active holds @{ Name; Until (UTC) } for each lease that has not ended,
# sorted by name. A lease counts for at most AutoMaxMinutes after its file
# was last written, whatever its Until says: tools may write the file
# directly, and one that wrote a far Until and then crashed must not keep the
# machine awake. Ended leases are deleted. A file that vanishes or is locked
# during the read (a tool renewing or releasing it) is skipped without a
# problem; the next poll reads it again. Temp files that a killed writer
# (or an interrupted removal here) left behind are deleted after 10 minutes.
function Read-Leases {
    $result = @{ Active = @(); Problems = @() }
    if (-not (Test-Path -LiteralPath $LeaseDir)) { return $result }
    $now = (Get-Date).ToUniversalTime()
    $all = @(Get-ChildItem -LiteralPath $LeaseDir -File -ErrorAction SilentlyContinue)
    foreach ($stale in @($all | Where-Object {
            ($_.Extension -eq '.tmp' -or $_.Extension -eq '.ended') -and
            $_.LastWriteTimeUtc -lt $now.AddMinutes(-10) })) {
        try { [System.IO.File]::Delete($stale.FullName) } catch { }
    }
    # The extension test also skips the .tmp files of a write in progress.
    $files = @($all | Where-Object { $_.Extension -eq '.json' })
    foreach ($file in $files) {
        try {
            $text = [System.IO.File]::ReadAllText($file.FullName)  # UTF-8, with or without a BOM
        } catch {
            continue
        }
        try {
            $data = $text | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $result.Problems += "$($file.Name): not valid JSON"
            continue
        }
        $name = [string]$data.Name
        if ($name -notmatch $LeaseNamePattern -or $name -ne $file.BaseName) {
            $result.Problems += "$($file.Name): Name must match the file name and be 1 to 24 letters, digits, '.', '_' or '-'"
            continue
        }
        # Windows PowerShell 5.1 leaves ISO 8601 dates as strings. Require an
        # offset or Z: without one, the time would silently mean local time.
        $untilText = [string]$data.Until
        $parsed = [DateTimeOffset]::MinValue
        if ($untilText -notmatch '(Z|[+-]\d\d:\d\d)$' -or
            -not [DateTimeOffset]::TryParse($untilText, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $result.Problems += "$($file.Name): Until is not an ISO 8601 time with Z or an offset"
            continue
        }
        $until = $parsed.UtcDateTime
        # A write time in the future (a copied or restored file, a clock
        # stepped back) would carry the cap with it. Clamping the limit to
        # now + AutoMaxMinutes would not help, since now moves on each poll,
        # so ignore the file instead. One minute allows for small clock fixes.
        if ($file.LastWriteTimeUtc -gt $now.AddMinutes(1)) {
            $result.Problems += "$($file.Name): the file's write time is in the future"
            continue
        }
        $limit = $file.LastWriteTimeUtc.AddMinutes($Config.AutoMaxMinutes)
        if ($until -gt $limit) { $until = $limit }
        if ($until -le $now) {
            # A tool may renew the lease at any moment, so check and delete
            # the same file: move it out of the way (atomic; a renewal after
            # this lands as a new .json), then compare the moved file's write
            # time with the one read. A renewal that landed before the move is
            # put back, unless a newer renewal already took its place.
            $ended = "$($file.FullName).$([guid]::NewGuid().ToString('N')).ended"
            try {
                [System.IO.File]::Move($file.FullName, $ended)
                if ([System.IO.File]::GetLastWriteTimeUtc($ended) -eq $file.LastWriteTimeUtc) {
                    [System.IO.File]::Delete($ended)
                } else {
                    try { [System.IO.File]::Move($ended, $file.FullName) } catch { [System.IO.File]::Delete($ended) }
                }
            } catch { }
            continue
        }
        $result.Active += [pscustomobject]@{ Name = $name; Until = $until }
    }
    $result.Active = @($result.Active | Sort-Object Name)
    return $result
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
    # Say so: a start from the Start menu otherwise does nothing visible. A
    # TopMost owner keeps the box in front, because this process has no
    # window of its own.
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
    try {
        [void][System.Windows.Forms.MessageBox]::Show($owner,
            'Hibearnate is already running. Look for the bear face in the notification area (click ^ next to the clock if it is hidden).',
            'Hibearnate', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } finally {
        $owner.Dispose()
    }
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
        $leases = Read-Leases
        "Busy leases: $(@($leases.Active).Count) in $LeaseDir"
        foreach ($l in $leases.Active) { '  {0}: until {1:yyyy-MM-dd HH:mm:ss}' -f $l.Name, $l.Until.ToLocalTime() }
        foreach ($p in $leases.Problems) { "  PROBLEM: $p" }
        # Next to the leases: the dashboard's lease follows these columns.
        $dash = Read-DashboardColumns
        if ($dash.Ok) {
            $watchedLabels = @($dash.Columns | Where-Object { $dash.Watched -contains $_.Key } | ForEach-Object { $_.Label })
            "Dashboard watched columns: $(if ($watchedLabels) { $watchedLabels -join ', ' } else { '(none; the dashboard never keeps Auto awake)' })"
        } else {
            "Dashboard watched columns: unknown ($($dash.Error))"
        }
        "Idle for: $(Format-Span ([Hibearnate.UserIdle]::Get()))"
        $restart = Read-RestartCommands
        "Restart commands: $(@($restart.Commands).Count) in $CommandsPath"
        foreach ($c in $restart.Commands) {
            '  {0}: stop {1}; start {2}; hotkey {3}' -f $c.Name, ($c.Stop -join ', '),
                $(if ($c.Start) { "$($c.Start) $($c.Arguments)".Trim() } else { '(none)' }),
                $(if ($c.Hotkey) { $c.Hotkey.Text } else { '(none)' })
        }
        foreach ($p in $restart.Problems) { "  PROBLEM: $p" }
        foreach ($w in $restart.Warnings) { "  WARNING: $w" }
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
    LeaseNames      = ''          # active lease names at the last Auto poll, to log changes
    LeaseProblems   = ''          # lease file problems at the last Auto poll, to log changes
    DashboardError  = ''          # why the last column read failed, to log changes
    PendingHibernate = $false
}

$Activity = New-Object Hibearnate.ClaudeActivity 'claude.exe'
$State.LastDisplayOn = $null
$State.NoBaseline = $false   # true while the originals could not be recorded (no setting is changed)
$State.LastPoll = $null      # time of the last wake check (poll or lid event), to spot a wake
$State.LastResume = $null    # time of the last wake, caps the idle time

# ---------------------------------------------------------------- tray icon

# The bear face from BearIcon.ps1. Green = Away, red = Keep Working, orange
# = Auto, so switching Keep Working to Auto visibly changes the icon even
# while Auto keeps the machine awake. The eyes show what is applied right
# now: closed (sleeping) = the Away settings, open = staying awake. Drawn at
# 32 px; Windows scales it.
function New-BearIcon([System.Drawing.Color]$Fur, [bool]$Awake, [bool]$Auto) {
    $bmp = New-BearBitmap $Fur $Awake $Auto
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
            else { 'Hibearnate: Auto, Away (all quiet)' }
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
    # Leases are read only in Auto, so log the current set again on entry.
    $State.LeaseNames = ''
    $State.LeaseProblems = ''
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
    # The dashboard is not read here: it reports its busy cards as a lease
    # (agent-dashboard-<port>), like any other tool (#6).
    $leases = Read-Leases
    $names = @($leases.Active | ForEach-Object { $_.Name })
    $now = Get-Date

    # The tooltip shows only the first lease; the log names them all.
    $nameText = $names -join ', '
    if ($nameText -ne $State.LeaseNames) {
        Write-Log $(if ($names.Count -gt 0) { "Busy leases: $nameText" } else { 'Busy leases: none' })
        $State.LeaseNames = $nameText
    }
    $problemText = $leases.Problems -join '; '
    if ($problemText -ne $State.LeaseProblems) {
        if ($problemText) { Write-Log "WARNING: lease files ignored: $problemText" }
        $State.LeaseProblems = $problemText
    }

    $busy = ($names.Count -gt 0) -or ($sample.BusySessions -gt 0)
    $reasons = @()
    # The lease name first, so the tooltip still names the tool when it is truncated.
    if ($names.Count -gt 0) { $reasons += $names[0] + $(if ($names.Count -gt 1) { " +$($names.Count - 1)" }) }
    if ($sample.BusySessions -gt 0) { $reasons += "$($sample.BusySessions) busy" }
    if ($busy) {
        $State.AutoLastBusy = $now
        $State.AutoReason = $reasons -join ', '
    }

    if ($TraceAuto) {
        Write-Log ('Auto poll: leases={0} sessions={1} busy={2} spawns={3} maxCpuMs={4:N0} [{5}]' -f $names.Count, $sample.Sessions, $sample.BusySessions, $sample.Spawns, $sample.MaxCpuMs, $sample.Detail)
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
            Set-Effective 'Away' 'Auto: all quiet'
            Complete-Work 'Claude sessions and busy tools went quiet'
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

# The poll timer does not run while the machine hibernates or sits in standby
# (Windows pauses desktop apps there), so a long gap since the last check means
# the machine just woke. Called before anything decides on idle time: by every
# poll, and by the lid handler, whose lid-closed notice can arrive before the
# first poll after a wake.
#
# The 3-poll threshold is a heuristic. A UI-thread stall longer than that also
# counts as a wake. That fails safe: the only effect is that one pending
# hibernate is canceled and the Away timers apply instead.
function Update-WakeState {
    $now = Get-Date
    if ($State.LastPoll -and ($now - $State.LastPoll).TotalSeconds -gt 3 * $Config.PollSeconds) {
        $State.LastResume = $now
        Write-Log "Woke after $(Format-Span ($now - $State.LastPoll)) without a check"
    }
    $State.LastPoll = $now
}

function Invoke-Poll {
    if ($ExitEvent.WaitOne(0)) {
        Stop-App 'exit requested by Uninstall.ps1'
        return
    }
    Update-WakeState
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
    # Not while the menu is open: the rebuild disposes the submenu items under
    # the pointer. The menu's Opening event and the next poll pick it up.
    if (-not $Menu.Visible) { Sync-RestartCommands }
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

# ---------------------------------------------------------------- app restarts

$ExplorerHotkeyId = 1
$RestartHotkeyBase = 100  # restart command N gets hotkey id 100 + N
$RestartList = @{
    Loaded   = $false
    Stamp    = $null  # LastWriteTimeUtc of the file when it was last read
    ByHotkey = @{}    # registered hotkey id -> command
}

# This app and the process that started it. Stopping the console that runs
# this app would end it without any exit path, so Read-RestartCommands also
# refuses console host names outright; this covers a parent with another
# name (a terminal window). If the lookup fails, only $PID is protected, and
# the name check still holds.
function Get-ProtectedPids {
    $ids = @($PID)
    try {
        $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
        $parent = Get-Process -Id $parentId -ErrorAction Stop
        # A parent ID can be reused after the parent exits. Only a process
        # that started before this one can be the real parent.
        if ($parent.StartTime -lt (Get-Process -Id $PID).StartTime) { $ids += $parent.Id }
    } catch {
        # The parent exited or denies access; it cannot be our console then.
    }
    return $ids
}

# The restart in progress, or $null. A restart runs as a chain of ticks of
# its own timer, never as one blocking call: the stop can take 10 seconds and
# the pause 30 more, and a blocked UI thread would miss the exit event
# (Uninstall.ps1 kills the app by force after 20 seconds) and WM_ENDSESSION,
# leaving Keep Working values in the plan.
$Restart = @{ Run = $null }
$RestartTimer = New-Object System.Windows.Forms.Timer
$RestartTimer.add_Tick({
    $RestartTimer.Stop()
    Invoke-RestartStep
})

# Runs one Step-RestartCommand and ends the restart cleanly if it throws. The
# first step (from Invoke-RestartCommand) and every tick go through here, so a
# failure can never leave $Restart.Run set with no timer running, which would
# refuse every later restart. The name is read before the step, because the
# last step clears $Restart.Run before it calls Complete-RestartCommand.
function Invoke-RestartStep {
    $name = if ($Restart.Run) { $Restart.Run.Command.Name } else { 'An app' }
    try {
        Step-RestartCommand
    } catch {
        $RestartTimer.Stop()
        $Restart.Run = $null
        Write-Log "ERROR in restart of ${name}: $_"
        Show-Note "Restart of $name failed. See the log."
    }
}

# Starts a restart: stop every process of the command, wait until no process
# with a listed name is left, pause WaitSeconds, then start the program (only
# when every listed process stopped). One
# restart at a time; a second request while one runs only shows a note.
function Invoke-RestartCommand($Command) {
    if ($Restart.Run) {
        Show-Note "$($Restart.Run.Command.Name) is still restarting."
        return
    }
    # Stop nothing when the program cannot start: a stop followed by a failed
    # start leaves the app down.
    if (Test-StartMissing $Command.Start) {
        Write-Log "Restart $($Command.Name): not run, because Start is not a program file: $($Command.Start)"
        Show-Note "$($Command.Name) was not restarted, because its Start program was not found. See the log."
        return
    }
    $Restart.Run = @{
        Command      = $Command
        Protected    = Get-ProtectedPids
        Killed       = @{}     # pid -> Process, stopped by this run
        Refused      = @{}     # pid -> why Kill failed; not tried again
        StoppedNames = @()
        Left         = @()     # still running when the stop phase ended
        Deadline     = (Get-Date).AddSeconds(10)
        Paused       = $false
    }
    Invoke-RestartStep
}

# One tick of the restart in $Restart.Run. A stop pass stops the names in the
# listed order, so a launcher listed first cannot start its children again in
# between; a process that appears anyway (restarted by a parent that was not
# listed) is caught by the next pass, 250 ms later. When none is left, or after
# 10 seconds, the next tick comes after WaitSeconds: the pause gives the app
# time to let go of its devices (LG HUB started at once after the stop
# sometimes left the mouse buttons dead). The tick after that completes it.
function Step-RestartCommand {
    $run = $Restart.Run
    if (-not $run) { return }
    if (-not $run.Paused) {
        $left = @(foreach ($name in $run.Command.Stop) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
                $id = $_.Id
                $run.Protected -notcontains $id -and -not $run.Refused.ContainsKey($id) -and
                    -not ($run.Killed.ContainsKey($id) -and $(try { $run.Killed[$id].HasExited } catch { $false }))
            }
        })
        if ($left -and (Get-Date) -lt $run.Deadline) {
            foreach ($p in $left) {
                if ($run.Killed.ContainsKey($p.Id)) { continue }  # stopping; wait for it
                try {
                    $p.Kill()
                    $run.Killed[$p.Id] = $p
                    $run.StoppedNames += $p.ProcessName
                } catch {
                    # Kill also throws when the process exited on its own (for
                    # example a child of a launcher stopped just before).
                    $gone = try { $p.HasExited } catch { $false }
                    if (-not $gone) {
                        $run.Refused[$p.Id] = '{0} ({1}) not stopped: {2}' -f $p.ProcessName, $p.Id, $_.Exception.GetBaseException().Message
                    }
                }
            }
            $RestartTimer.Interval = 250
            $RestartTimer.Start()
            return
        }
        $run.Left = $left
        $run.Paused = $true
        # No pause when a process did not stop: Complete-RestartCommand then
        # skips the start, so there is nothing to wait for.
        $stuck = $left -or $run.Refused.Count -gt 0
        if ($run.StoppedNames -and $run.Command.Start -and $run.Command.WaitSeconds -gt 0 -and -not $stuck) {
            # Ceiling, not [int]: 0.0004 s would round to 0 ms, and Interval throws on 0.
            $RestartTimer.Interval = [int][math]::Ceiling($run.Command.WaitSeconds * 1000)
            $RestartTimer.Start()
            return
        }
    }
    $Restart.Run = $null
    Complete-RestartCommand $run
}

# The start, the log line and the note at the end of a restart. Fails closed:
# when a listed process refused to stop or still runs, the program is not
# started, so a second copy never runs beside a stuck one.
function Complete-RestartCommand($Run) {
    $Command = $Run.Command
    $failed = @($Run.Refused.Values)
    if ($Run.Left) {
        $failed += 'still running after 10 s: ' + (($Run.Left | ForEach-Object { '{0} ({1})' -f $_.ProcessName, $_.Id }) -join ', ')
    }
    $stoppedNames = $Run.StoppedNames
    $stopped = $Run.Killed.Count -gt 0

    $parts = @()
    $parts += if ($stoppedNames) {
        'stopped ' + (($stoppedNames | Group-Object | ForEach-Object {
            if ($_.Count -gt 1) { '{0} x{1}' -f $_.Name, $_.Count } else { $_.Name }
        }) -join ', ')
    } else { 'stopped nothing' }

    if ($Command.Start -and $failed) {
        $parts += 'not started, because a process did not stop'
    } elseif ($Command.Start) {
        try {
            $startArgs = @{ FilePath = $Command.Start }
            if ($Command.Arguments) { $startArgs.ArgumentList = $Command.Arguments }
            # Many apps expect to start in their own directory.
            if ([System.IO.Path]::IsPathRooted($Command.Start)) {
                $dir = Split-Path -Parent $Command.Start
                if ($dir -and (Test-Path -LiteralPath $dir)) { $startArgs.WorkingDirectory = $dir }
            }
            Start-Process @startArgs
            $parts += "started $($Command.Start) $($Command.Arguments)".Trim()
        } catch {
            $failed += "start failed: $($_.Exception.Message)"
        }
    }

    Write-Log ("Restart $($Command.Name): " + ((@($parts) + @($failed)) -join '; '))
    if ($Command.Start -and $parts -contains 'not started, because a process did not stop') {
        Show-Note "$($Command.Name) was not started, because a process did not stop. See the log."
    } elseif ($failed) {
        Show-Note "Restart $($Command.Name): something did not work. See the log."
    } elseif ($Command.Start) {
        Show-Note "Restarted $($Command.Name)."
    } elseif ($stopped) {
        Show-Note "Stopped $($Command.Name)."
    } else {
        Show-Note "$($Command.Name) was not running."
    }
}

# Creates the list from restart-commands.example.json the first time. The
# example keeps its commands under "Examples", which Read-RestartCommands
# ignores, so a new list registers no hotkey until the user moves a command
# into "Commands" and saves.
function Edit-RestartCommands {
    if (-not (Test-Path -LiteralPath $CommandsPath)) {
        if (-not (Test-Path $Config.LogDir)) {
            New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
        }
        $example = Join-Path $PSScriptRoot 'restart-commands.example.json'
        if (Test-Path -LiteralPath $example) {
            Copy-Item -LiteralPath $example -Destination $CommandsPath
        } else {
            Set-Content -LiteralPath $CommandsPath -Value '{ "Commands": [] }' -Encoding UTF8
        }
        Write-Log "Created $CommandsPath"
    }
    Start-Process notepad.exe -ArgumentList "`"$CommandsPath`""
}

# Reads the file again when it changed since the last read, then rebuilds the
# submenu and the hotkeys. Called on every poll and when the menu opens, so
# an edit takes effect without a restart of the app. Problems are reported
# once per change of the file, not on every call.
function Sync-RestartCommands {
    $stamp = if (Test-Path -LiteralPath $CommandsPath) { (Get-Item -LiteralPath $CommandsPath).LastWriteTimeUtc } else { $null }
    if ($RestartList.Loaded -and $stamp -eq $RestartList.Stamp) { return }
    $RestartList.Loaded = $true
    $RestartList.Stamp = $stamp

    $read = Read-RestartCommands
    $problems = @($read.Problems)

    foreach ($id in @($RestartList.ByHotkey.Keys)) { $Window.UnregisterHotkey($id) }
    $RestartList.ByHotkey = @{}
    $old = @($MenuRestart.DropDownItems)
    $MenuRestart.DropDownItems.Clear()
    foreach ($item in $old) { if ($item -ne $MenuEditList) { $item.Dispose() } }

    $i = 0
    foreach ($command in $read.Commands) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $command.Name
        $item.Tag = $command
        $item.add_Click({ param($s, $e) try { Invoke-RestartCommand $s.Tag } catch { Write-Log "ERROR: $_" } })
        if ($command.Hotkey) {
            $id = $RestartHotkeyBase + $i
            if ($Window.RegisterHotkey($id, $command.Hotkey.Modifiers, $command.Hotkey.Key)) {
                $RestartList.ByHotkey[$id] = $command
                $item.ShortcutKeyDisplayString = $command.Hotkey.Text
            } else {
                $problems += "$($command.Hotkey.Text) for '$($command.Name)' is taken by another app or command"
                $item.ShortcutKeyDisplayString = '(hotkey unavailable)'
            }
        }
        [void]$MenuRestart.DropDownItems.Add($item)
        $i++
    }
    if ($read.Commands) { [void]$MenuRestart.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
    [void]$MenuRestart.DropDownItems.Add($MenuEditList)

    if ($null -ne $stamp) { Write-Log "Restart commands: $(@($read.Commands).Count) loaded from $CommandsPath" }
    foreach ($p in $problems) { Write-Log "WARNING: restart commands: $p" }
    foreach ($w in $read.Warnings) { Write-Log "WARNING: restart commands: $w" }  # no note; see Read-RestartCommands
    if ($problems) { Show-Note 'A restart command has a problem. See the log.' }
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

$MenuAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto (follow Claude and busy tools)'
$MenuAuto.add_Click({ try { Enter-Auto } catch { Write-Log "ERROR: $_" } })

# Which dashboard columns keep Auto awake (#12). Filled by Sync-DashboardMenu
# each time the menu opens, so a new or renamed column shows without a
# restart. The dashboard holds the setting and decides what is busy; this
# menu is only a second place to edit it (the first is the dashboard's own
# Settings dialog). Not in the menu when DashboardBase is $null.
$MenuDashboard = New-Object System.Windows.Forms.ToolStripMenuItem 'Dashboard columns'

# Labels come from the dashboard, so they are text only: never a file name, a
# command line or a format string. '&' is the mnemonic prefix in a menu
# item's Text, so it is doubled. A long label is cut so the menu stays narrow.
function Format-MenuLabel([string]$Label) {
    $text = $Label.Trim()
    if (-not $text) { $text = '(no name)' }
    if ($text.Length -gt 60) { $text = $text.Substring(0, 59) + [char]0x2026 }
    return $text.Replace('&', '&&')
}

function Sync-DashboardMenu {
    if (-not $Config.DashboardBase) { return }
    $old = @($MenuDashboard.DropDownItems)
    $MenuDashboard.DropDownItems.Clear()
    foreach ($item in $old) { $item.Dispose() }

    $read = Read-DashboardColumns
    if (-not $read.Ok) {
        # One disabled item, so the submenu still opens and says why. The
        # reason is in the log only when it changes, not on every open.
        $text = switch ($read.Reason) {
            'Old'    { 'Update the dashboard to choose columns' }
            'Failed' { 'Dashboard not reachable. See the log.' }
            default  { 'Dashboard not running' }
        }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
        $item.Enabled = $false
        [void]$MenuDashboard.DropDownItems.Add($item)
        if ($read.Error -ne $State.DashboardError) {
            Write-Log "Dashboard columns: not read: $($read.Error)"
            $State.DashboardError = $read.Error
        }
        return
    }
    $State.DashboardError = ''
    foreach ($col in $read.Columns) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem (Format-MenuLabel $col.Label)
        $item.Tag = $col.Key
        $item.Checked = $read.Watched -contains $col.Key
        $item.add_Click({ param($s, $e) try { Switch-DashboardColumn $s } catch { Write-Log "ERROR: $_" } })
        [void]$MenuDashboard.DropDownItems.Add($item)
    }
}

# Ticks or clears one column. The list sent is built from every item's tick,
# with only the clicked one flipped, and the ticks change only after the
# dashboard answers, to what it saved. If the save fails, or the dashboard
# did not keep the change (the column was deleted after the menu opened),
# the tick stays as it was, and the log and a note say so.
#
# The list comes from the ticks drawn when the menu opened. A change made in
# the dashboard's own Settings dialog while the menu was open is therefore
# replaced by this click. That is accepted: the ticks are then set from the
# list the dashboard saved, so the result shows at once, and a re-read before
# each save would add a second wait on the UI thread for a rare case.
function Switch-DashboardColumn($Item) {
    $want = -not $Item.Checked
    $items = @($MenuDashboard.DropDownItems | Where-Object { $_.Tag -is [string] })
    $keys = @(foreach ($i in $items) {
        $on = if ([object]::ReferenceEquals($i, $Item)) { $want } else { $i.Checked }
        if ($on) { [string]$i.Tag }
    })
    try {
        $saved = Save-DashboardColumns $keys
    } catch {
        Write-Log "WARNING: dashboard columns not saved: $($_.Exception.Message)"
        Show-Note 'Could not save the dashboard columns. See the log.'
        return
    }
    if (($saved -contains [string]$Item.Tag) -ne $want) {
        Write-Log "WARNING: dashboard columns: the dashboard did not keep the change to '$($Item.Tag)'; saved: $($saved -join ', ')"
        Show-Note 'The dashboard did not keep that change. See the log.'
    }
    foreach ($i in $items) { $i.Checked = $saved -contains [string]$i.Tag }
    Write-Log "Dashboard columns watched: $(if ($saved) { $saved -join ', ' } else { 'none' })"
}

$MenuExplorer = New-Object System.Windows.Forms.ToolStripMenuItem 'Restart Explorer'
$MenuExplorer.ShortcutKeyDisplayString = 'Ctrl+Alt+Shift+E'
$MenuExplorer.add_Click({ try { Restart-Explorer } catch { Write-Log "ERROR: $_" } })

# Filled from restart-commands.json by Sync-RestartCommands.
$MenuRestart = New-Object System.Windows.Forms.ToolStripMenuItem 'Restart an app'
$MenuEditList = New-Object System.Windows.Forms.ToolStripMenuItem 'Edit the list...'
$MenuEditList.add_Click({ try { Edit-RestartCommands } catch { Write-Log "ERROR: $_" } })

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
    $RestartTimer.Stop()
    if ($Restart.Run) { Write-Log "Restart $($Restart.Run.Command.Name) canceled by exit" }
    $Window.Dispose()
    $Tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

$MenuExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit (sets Away)'
$MenuExit.add_Click({ Stop-App 'menu' })

[void]$Menu.Items.AddRange(@(
    $MenuAway, $MenuKeep, $MenuAuto,
    (New-Object System.Windows.Forms.ToolStripSeparator)))
if ($Config.DashboardBase) {
    [void]$Menu.Items.AddRange(@($MenuDashboard, (New-Object System.Windows.Forms.ToolStripSeparator)))
}
[void]$Menu.Items.AddRange(@(
    $MenuExplorer, $MenuRestart, $MenuLog,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $MenuExit
))
$Tray.ContextMenuStrip = $Menu
$Menu.add_Opening({
    # Fresh "time left", restart commands saved since the last poll, and the
    # dashboard's current columns and ticks.
    try { Sync-RestartCommands } catch { Write-Log "ERROR: $_" }
    try { Sync-DashboardMenu } catch { Write-Log "ERROR: $_" }
    try { Update-Tray } catch { Write-Log "ERROR: $_" }
})

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
if (-not $Window.RegisterHotkey($ExplorerHotkeyId, $mods, [System.Windows.Forms.Keys]::E)) {
    Write-Log 'WARNING: Ctrl+Alt+Shift+E is taken by another app; the hotkey is off. Use the tray menu.'
    $MenuExplorer.ShortcutKeyDisplayString = '(hotkey unavailable)'
}
$Window.add_HotkeyPressed({
    param($s, $e)
    try {
        if ($e.Id -eq $ExplorerHotkeyId) { Restart-Explorer }
        elseif ($RestartList.ByHotkey.ContainsKey($e.Id)) { Invoke-RestartCommand $RestartList.ByHotkey[$e.Id] }
    } catch { Write-Log "ERROR: $_" }
})
$Window.add_LidChanged({
    try {
        Write-Log $(if ($Window.LidOpen) { 'Lid opened' } else { 'Lid closed' })
        Update-WakeState
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
try { Sync-RestartCommands } catch { Write-Log "ERROR loading restart commands: $_" }
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
