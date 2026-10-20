<#
.SYNOPSIS
    Tells Hibearnate's Auto mode that a tool is busy, for a limited time.

.DESCRIPTION
    Writes a lease to %LOCALAPPDATA%\Hibearnate\leases\<Name>.json. While a
    lease has not ended, Auto keeps the machine awake. A report with the same
    name replaces the lease, so a tool renews by reporting again before it
    ends. A tool that crashes stops renewing, and its lease ends by itself.

    Loads neither Hibearnate.ps1 nor its C# helper, so a call costs only the
    PowerShell startup. It only reads AutoMaxMinutes from the text of
    Hibearnate.ps1. The checks here repeat the tray's own (Read-Leases in
    Hibearnate.ps1). The tray enforces them again, because a tool may also
    write the file directly in the format that readme.md documents.

.PARAMETER Name
    The tool's name: 1 to 24 letters, digits, '.', '_' or '-', starting with
    a letter or digit. The tooltip and the log show it.

.PARAMETER For
    How long the lease lasts: a whole number with s, m or h (30s, 10m, 2h),
    from 30 seconds to AutoMaxMinutes in Hibearnate.ps1 (3 hours by default).

.PARAMETER Done
    Remove this tool's lease instead. Auto still waits its quiet period.

.EXAMPLE
    .\Busy.ps1 -Name pytest -For 10m

.EXAMPLE
    .\Busy.ps1 -Name pytest -Done
#>
param(
    [string]$Name,
    [string]$For,
    [switch]$Done
)

$ErrorActionPreference = 'Stop'

$LeaseDir = Join-Path $env:LOCALAPPDATA 'Hibearnate\leases'
# \z, not $: in .NET, $ also matches before a trailing newline.
$NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,23}\z'  # $LeaseNamePattern in Hibearnate.ps1
$MinSeconds = 30
# The tray caps every lease at its AutoMaxMinutes, so take the limit from
# there. A regex over the text, not a dot-source: the script would start the
# tray. 180 is the shipped value, for a file that cannot be read.
$MaxMinutes = 180
try {
    $trayText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Hibearnate.ps1'))
    if ($trayText -match '(?m)^\s*AutoMaxMinutes\s*=\s*(\d{1,5})\b' -and [int]$Matches[1] -ge 1) {
        $MaxMinutes = [int]$Matches[1]
    }
} catch { }

# No Mandatory parameters: a missing one would prompt, and a tool that runs
# this without a console would hang on the prompt instead of getting exit 1.
function Stop-WithError([string]$Message) {
    $Host.UI.WriteErrorLine($Message)
    exit 1
}

if ($Name -notmatch $NamePattern) {
    Stop-WithError "-Name must be 1 to 24 letters, digits, '.', '_' or '-', starting with a letter or digit (got '$Name')."
}
# Windows reserves these names in every folder, with any extension.
if ($Name -match '^(con|prn|aux|nul|com\d|lpt\d)(\.|$)') {
    Stop-WithError "-Name '$Name' is a reserved Windows device name."
}
$path = Join-Path $LeaseDir "$Name.json"

if ($Done) {
    if ($For) { Stop-WithError 'Use -For or -Done, not both.' }
    # File.Delete ignores a missing file but throws on a missing folder. Retry,
    # because the delete fails while the tray reads the file.
    if (Test-Path -LiteralPath $LeaseDir) {
        for ($try = 1; $try -le 3; $try++) {
            try {
                [System.IO.File]::Delete($path)
                break
            } catch {
                if ($try -eq 3) { Stop-WithError "Could not remove ${path}: $($_.Exception.GetBaseException().Message)" }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    "Done: $Name"
    exit 0
}

if ($For -notmatch '^(\d{1,6})([smh])\z') {
    Stop-WithError "-For must be a whole number with s, m or h, for example 30s, 10m or 2h (got '$For')."
}
$seconds = [int]$Matches[1] * @{ s = 1; m = 60; h = 3600 }[$Matches[2].ToLowerInvariant()]
if ($seconds -lt $MinSeconds -or $seconds -gt $MaxMinutes * 60) {
    $maxText = if ($MaxMinutes % 60 -eq 0) { "$($MaxMinutes / 60) hours" } else { "$MaxMinutes minutes" }
    Stop-WithError "-For must be from $MinSeconds seconds to $maxText (got '$For')."
}

$until = (Get-Date).ToUniversalTime().AddSeconds($seconds)
$json = '{{ "Name": "{0}", "Until": "{1}" }}' -f $Name, $until.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)

if (-not (Test-Path -LiteralPath $LeaseDir)) {
    New-Item -ItemType Directory -Path $LeaseDir -Force | Out-Null
}
# Write a temp file, then rename it into place, so the tray never reads half a
# lease. The temp name does not end in .json, so the tray skips it. Delete and
# Move rather than File.Replace: the tray caps a lease by its file's last
# write time, and the moved file keeps the fresh time of the temp file. The
# short gap between the two only looks like one poll with no lease, which
# Auto's quiet period absorbs. Retry, in case another call for the same name
# moves its file in between.
$temp = "$path.$PID.tmp"
[System.IO.File]::WriteAllText($temp, $json)  # UTF-8 without a BOM
$moved = $false
for ($try = 1; -not $moved -and $try -le 3; $try++) {
    try {
        [System.IO.File]::Delete($path)
        [System.IO.File]::Move($temp, $path)
        $moved = $true
    } catch {
        if ($try -eq 3) {
            # The tray removes a temp file that is left over, so a failure here is not fatal.
            try { [System.IO.File]::Delete($temp) } catch { }
            Stop-WithError "Could not write ${path}: $($_.Exception.GetBaseException().Message)"
        }
        Start-Sleep -Milliseconds 100
    }
}

'Busy: {0} until {1:HH:mm:ss}' -f $Name, $until.ToLocalTime()

# The tray holds this mutex while it runs. Opening it does not take it, so
# this check never blocks a tray start (the tray uses WaitOne, not createdNew).
# TryOpenExisting throws, not returns false, when the mutex exists but belongs
# to another account (this script ran under runas, for example).
$mutex = $null
try {
    if ([System.Threading.Mutex]::TryOpenExisting('Local\Hibearnate', [ref]$mutex)) {
        $mutex.Dispose()
    } else {
        Write-Warning 'Hibearnate is not running, so nothing reads this lease until it starts.'
    }
} catch [System.UnauthorizedAccessException] {
    Write-Warning "Hibearnate runs under another account, so it does not read this lease (written for $env:USERNAME)."
}
