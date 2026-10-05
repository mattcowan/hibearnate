# Hibearnate — notes for Claude

A Windows tray app (`Hibearnate.ps1` plus the C# helper `Hibearnate.cs`) that switches power settings between Away, Keep Working and Auto, and restarts Explorer on Ctrl+Alt+Shift+E. `readme.md` describes the behavior; this file lists the constraints a change or a review must respect.

## Runtime constraints

- **Windows PowerShell 5.1 only** (`powershell.exe`, not `pwsh`). The Startup shortcut launches it through `conhost.exe --headless`. Do not suggest PowerShell 7 syntax (`??`, `?.`, ternary, `-Parallel`).
- **`Hibearnate.cs` must compile as C# 5.** `Add-Type` in Windows PowerShell 5.1 uses the .NET Framework compiler. No expression-bodied members, `?.`, `$"..."` interpolation, `out var`, tuples, or `nameof`.
- **No admin rights.** Every setting the app writes works unelevated (verified). A change that needs elevation is a design change, not a fix.
- **Power settings go through the powrprof API** (`PowerReadACValueIndex` and friends), never by parsing `powercfg` output. On this hardware `powercfg /query` hides the lid close action (only `/qh` shows it), and the text is localized. `Restore-Baseline.ps1` is the deliberate exception: it uses `powercfg` so it still works when the C# helper is broken.

## Invariants

- **Keep Working writes values that outlive the process** (lid action 0, sleep-after 0). Every exit path that runs code must put Away back: the Exit menu item, the `WM_ENDSESSION` handler, the `finally` around `Application.Run`, and the exit event that `Uninstall.ps1` sets. A new exit path must do the same.
- **The single-instance check uses `Mutex.WaitOne(0)`, not the constructor's `createdNew`.** `createdNew` only reports whether the name already existed, so a leaked handle would block every later start.
- **All UI and power work runs on the tray's UI thread.** PowerShell scriptblocks cannot run on a thread pool or `SystemEvents` thread; events reach PowerShell through `MessageWindow.WndProc` for that reason.
- **The tray tooltip must stay at 63 characters or fewer.** `NotifyIcon.Text` throws above that; `Update-Tray` truncates.

## PowerShell traps already hit here

- Variable names are case-insensitive: `$fur` and a `[Color]$Fur` parameter are the same variable.
- `$ErrorActionPreference = 'Stop'` turns `Write-Error` into a terminating error, so code after it does not run.
- `SystemInformation.PowerStatus.BatteryLifePercent` is a `float`; `0.15f` widens to `0.15000000596`. Compare whole percents.

## Review notes

- The review runner is Linux, so nothing here can be executed in CI. Review by reading. On a Windows machine, `.\Hibearnate.ps1 -SelfTest` round-trips both profiles (exit the tray first; the self-test refuses while it runs).
- The original settings live in `%LOCALAPPDATA%\Hibearnate\baseline.json`, written by `Save-Baseline` on the first start and never overwritten (a later write would record the app's own Away values). It is written to a `.tmp` file, validated, then moved into place with `File.Move` (atomic, fails if the target exists). `Restore-Baseline.ps1` validates it with its own copy of `Test-BaselineFile` and refuses to write anything when it is missing or damaged; a damaged file once produced "Done" and exit 0, after which `Uninstall.ps1` deleted the record. Keep all of these properties.
- `readme.md` is written in ASD-STE100 Simplified Technical English with American spelling. Code comments are plain technical English.
