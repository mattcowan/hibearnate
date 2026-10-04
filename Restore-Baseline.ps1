<#
.SYNOPSIS
    Puts the power settings that Hibearnate changes back to the values they had
    before its first run on this machine.

.DESCRIPTION
    Hibearnate.ps1 records those values to %LOCALAPPDATA%\Hibearnate\baseline.json
    the first time it starts, before it changes anything, and never overwrites
    that file. This script writes them back into the power plan they came from.

    Uses powercfg directly, so it works even if Hibearnate.ps1 or its C#
    helper is broken. Does not need admin rights.

    If no baseline file exists, it changes nothing and exits with code 1.
    Exits with code 1 and names each failed setting if powercfg reports an error.

.PARAMETER Path
    The baseline file to restore. Defaults to the one Hibearnate.ps1 records.
#>
param([string]$Path = (Join-Path $env:LOCALAPPDATA 'Hibearnate\baseline.json'))

if (-not (Test-Path $Path)) {
    Write-Warning "No baseline at $Path, so nothing was changed. Hibearnate records it on its first start."
    exit 1
}

$baseline = Get-Content -Path $Path -Raw | ConvertFrom-Json
"Restoring the settings recorded on $($baseline.RecordedAt) for power plan $($baseline.Scheme)."

$failed = @()
foreach ($s in $baseline.Settings) {
    powercfg /setacvalueindex $baseline.Scheme $s.Subgroup $s.Setting $s.AC
    $acCode = $LASTEXITCODE
    powercfg /setdcvalueindex $baseline.Scheme $s.Subgroup $s.Setting $s.DC
    $dcCode = $LASTEXITCODE
    if ($acCode -ne 0 -or $dcCode -ne 0) {
        $failed += "$($s.Name) (powercfg exit codes AC=$acCode DC=$dcCode)"
    } else {
        "Restored $($s.Name): AC=$($s.AC) DC=$($s.DC)"
    }
}
# Re-activate the current plan so Windows applies the values. If the recorded
# plan is not the active one, its values are stored and apply when it is selected.
powercfg /setactive SCHEME_CURRENT
if ($LASTEXITCODE -ne 0) { $failed += "Re-activate the scheme (powercfg exit code $LASTEXITCODE)" }

if ($failed) {
    Write-Warning ("Not restored:`n  " + ($failed -join "`n  "))
    exit 1
}
'Done. Check with: powercfg /qh SCHEME_CURRENT'
