<#
.SYNOPSIS
    Stops the tray app, removes it from Startup and the Start menu, and
    restores the power settings recorded before its first run (see
    Restore-Baseline.ps1).

.DESCRIPTION
    Asks the tray app to exit through a named event, so it puts the Away
    settings back first. If the app does not exit within 20 seconds, the
    script stops it by force and says so; in that case the lid and sleep
    settings can still be the Keep Working ones, which the restore below
    then overwrites (unless -KeepSettings is given).

.PARAMETER KeepSettings
    Do not restore the baseline. After a clean exit, the Away settings stay,
    and the baseline file stays for a later Restore-Baseline.ps1 run.
#>
param([switch]$KeepSettings)

$ErrorActionPreference = 'Stop'

$removePaths = @(
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Hibearnate.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Hibearnate.lnk'),
    (Join-Path $env:LOCALAPPDATA 'Hibearnate\hibearnate.ico')  # the shortcuts' icon
)
foreach ($path in $removePaths) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path
        "Removed $path"
    }
}

$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Hibearnate.ps1*' -and $_.ProcessId -ne $PID })

if ($running) {
    $exitEvent = $null
    $asked = [System.Threading.EventWaitHandle]::TryOpenExisting('Local\Hibearnate.Exit', [ref]$exitEvent)
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
    # After a full restore the record has done its job. Remove it, so a later
    # install records the settings as they are then, not as they were now.
    $baselinePath = Join-Path $env:LOCALAPPDATA 'Hibearnate\baseline.json'
    if ($LASTEXITCODE -eq 0 -and (Test-Path $baselinePath)) {
        Remove-Item $baselinePath
        "Removed $baselinePath"
    }
}
