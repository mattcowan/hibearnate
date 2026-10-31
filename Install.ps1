<#
.SYNOPSIS
    Starts the power-profile tray app at every login, adds it to the Start
    menu, and starts it now.

.DESCRIPTION
    Creates two shortcuts with the same command line: one in the Startup
    folder, and one named Hibearnate in the per-user Start menu, so Windows
    search finds it. Each runs PowerShell through `conhost.exe --headless`, so
    no console window flashes (a plain -WindowStyle Hidden still flashes, and
    on Windows 11 it can open a Windows Terminal tab instead). Both show the
    bear, written to %LOCALAPPDATA%\Hibearnate\hibearnate.ico. Running the
    script again replaces both shortcuts. Does not need admin rights.

.PARAMETER NoStart
    Create the shortcuts but do not start the app now.
#>
param([switch]$NoStart)

# Stop at the first failure, so "Created" never prints after a failed Save().
$ErrorActionPreference = 'Stop'

$app = Join-Path $PSScriptRoot 'Hibearnate.ps1'
$startupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hibearnate.lnk'
# The per-user Start menu, which Windows search indexes. The Startup folder
# above is a subfolder of it.
$startMenuPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hibearnate.lnk'
$conhost = Join-Path $env:windir 'System32\conhost.exe'
$arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app`""

# The bear is drawn at run time and the repo has no .ico, so draw one here.
# Without it the shortcuts show the conhost icon; that is no reason to fail.
$iconDir = Join-Path $env:LOCALAPPDATA 'Hibearnate'
$iconPath = Join-Path $iconDir 'hibearnate.ico'
try {
    . (Join-Path $PSScriptRoot 'BearIcon.ps1')
    $null = New-Item -ItemType Directory -Path $iconDir -Force
    Save-BearIco $iconPath
    "Created $iconPath"
} catch {
    Write-Warning "Could not write the bear icon, so the shortcuts show the conhost icon: $_"
    $iconPath = $null
}

$shell = New-Object -ComObject WScript.Shell
# CreateShortcut opens an existing .lnk, and Save() overwrites it, so a second
# install replaces each shortcut instead of adding another.
foreach ($shortcutPath in $startupPath, $startMenuPath) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $conhost
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Hibearnate: power profiles for Windows (Away / Keep Working / Auto) and an Explorer restart hotkey'
    if ($iconPath) { $shortcut.IconLocation = "$iconPath,0" }
    $shortcut.Save()
    "Created $shortcutPath"
}

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
