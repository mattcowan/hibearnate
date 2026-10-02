<#
.SYNOPSIS
    Starts the power-profile tray app at every login, and starts it now.

.DESCRIPTION
    Creates a shortcut in the Startup folder. The shortcut runs PowerShell
    through `conhost.exe --headless`, so no console window flashes at login
    (a plain -WindowStyle Hidden still flashes, and on Windows 11 it can open
    a Windows Terminal tab instead). Does not need admin rights.

.PARAMETER NoStart
    Create the shortcut but do not start the app now.
#>
param([switch]$NoStart)

# Stop at the first failure, so "Created" never prints after a failed Save().
$ErrorActionPreference = 'Stop'

$app = Join-Path $PSScriptRoot 'Hibearnate.ps1'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hibearnate.lnk'
$conhost = Join-Path $env:windir 'System32\conhost.exe'
$arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app`""

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $conhost
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Hibearnate: power profiles for Windows (Away / Keep Working / Auto) and an Explorer restart hotkey'
$shortcut.Save()
"Created $shortcutPath"

if (-not $NoStart) {
    # A second copy exits at once, so say so rather than claim a start.
    $running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*Hibearnate.ps1*' -and $_.CommandLine -notlike '*-SelfTest*' -and $_.ProcessId -ne $PID }
    if ($running) {
        "The tray app is already running (pid $(@($running)[0].ProcessId)). Not started again."
    } else {
        Start-Process -FilePath $conhost -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
        'Started. Look for the green bear face in the notification area.'
    }
}
