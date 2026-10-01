<#
.SYNOPSIS
    Puts the four power settings this tool changes back to the values recorded
    on this machine on 2026-10-01, before the tool was installed.

.DESCRIPTION
    Uses powercfg directly, so it works even if PowerProfiles.ps1 or its C#
    helper is broken. Does not need admin rights.

    The values are this machine's, typed in from `powercfg /qh` output. They
    are not right for a different machine. The DC "Hibernate after" value of
    2147483647 is what this machine had; it means "never" in practice.

    Exits with code 1 and names each failed setting if powercfg reports an error.
#>

$baseline = @(
    # Subgroup, setting, AC, DC, label
    @('4f971e89-eebd-4455-a8de-9e59040e7347', '5ca83367-6e45-459f-a27b-476b1d01c936', 2, 2, 'Lid close action: Hibernate')
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 3600, 300, 'Sleep after: 60 min AC, 5 min DC')
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364', 0, 2147483647, 'Hibernate after: never')
    @('fea3413e-7e05-4911-9a71-700331f1c294', 'f15576e8-98b7-4186-b944-eafa664402d9', 1, 2, 'Network in standby: on AC, managed DC')
)

$failed = @()
foreach ($b in $baseline) {
    powercfg /setacvalueindex SCHEME_CURRENT $b[0] $b[1] $b[2]
    $acCode = $LASTEXITCODE
    powercfg /setdcvalueindex SCHEME_CURRENT $b[0] $b[1] $b[3]
    $dcCode = $LASTEXITCODE
    if ($acCode -ne 0 -or $dcCode -ne 0) {
        $failed += "$($b[4]) (powercfg exit codes AC=$acCode DC=$dcCode)"
    } else {
        "Restored $($b[4])"
    }
}
powercfg /setactive SCHEME_CURRENT
if ($LASTEXITCODE -ne 0) { $failed += "Re-activate the scheme (powercfg exit code $LASTEXITCODE)" }

if ($failed) {
    Write-Warning ("Not restored:`n  " + ($failed -join "`n  "))
    exit 1
}
'Done. Check with: powercfg /qh SCHEME_CURRENT'
