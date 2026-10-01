<#
.SYNOPSIS
    Stops the tray app, removes it from Startup, and restores the power
    settings recorded before install.

.PARAMETER KeepSettings
    Leave the current power settings as they are instead of restoring the baseline.
#>
param([switch]$KeepSettings)

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Windows Power Profiles.lnk'
if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath
    "Removed $shortcutPath"
}

$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfiles.ps1*' -and $_.ProcessId -ne $PID }
foreach ($p in $running) {
    Stop-Process -Id $p.ProcessId -Force
    "Stopped tray app (pid $($p.ProcessId))"
}

if (-not $KeepSettings) {
    & (Join-Path $PSScriptRoot 'Restore-Baseline.ps1')
}
