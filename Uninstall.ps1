<#
.SYNOPSIS
    Stops the tray app, removes it from Startup, and restores the power
    settings recorded before install.

.DESCRIPTION
    Asks the tray app to exit through a named event, so it puts the Away
    settings back first. If the app does not exit within 20 seconds, the
    script stops it by force and says so; in that case the lid and sleep
    settings can still be the Keep Working ones, which the restore below
    then overwrites (unless -KeepSettings is given).

.PARAMETER KeepSettings
    Do not restore the baseline. After a clean exit, the Away settings stay.
#>
param([switch]$KeepSettings)

$ErrorActionPreference = 'Stop'

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Windows Power Profiles.lnk'
if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath
    "Removed $shortcutPath"
}

$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfiles.ps1*' -and $_.ProcessId -ne $PID })

if ($running) {
    $exitEvent = $null
    $asked = [System.Threading.EventWaitHandle]::TryOpenExisting('Local\WindowsPowerProfiles.Exit', [ref]$exitEvent)
    if ($asked) {
        [void]$exitEvent.Set()
        'Asked the tray app to exit (it checks every 10 seconds)...'
    }
    $waitMs = if ($asked) { 20000 } else { 0 }  # a copy without the event cannot exit cleanly
    foreach ($p in $running) {
        $process = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($process -and -not $process.WaitForExit($waitMs)) {
            Stop-Process -Id $p.ProcessId -Force
            Write-Warning "Tray app (pid $($p.ProcessId)) did not exit; stopped it by force. Its Away settings were not applied."
        } else {
            "Tray app (pid $($p.ProcessId)) exited and applied Away."
        }
    }
}

if (-not $KeepSettings) {
    & (Join-Path $PSScriptRoot 'Restore-Baseline.ps1')
}
