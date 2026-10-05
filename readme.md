# Hibearnate

Power profiles for Windows. A bear hibernates in winter and goes out to find food in spring. Hibearnate makes a Windows laptop do the same: the laptop hibernates when nobody uses it, and it stays awake while there is work.

Hibearnate is a tray app for a Windows laptop. It switches the power settings between "hibernate when I leave" and "stay awake while Claude Code works". It also restarts Explorer with one hotkey.

## Why it exists

Many Windows laptops have no classic sleep (S3). Their only sleep state is Modern Standby, which keeps the system partly awake. To find out if a laptop uses it, run `powercfg /a` and look for "Standby (S0 Low Power Idle)".

On the laptop where this app started, standby began after 60 minutes on AC power and never moved to hibernate. The network stayed on in standby. Background work continued, the fan ran, and the laptop was slow after it woke.

Hibernate stops all of this. But a long Claude Code task needs the laptop fully awake, even with the lid closed. This app gives one click for each case, plus an Auto mode that follows the Claude Code sessions.

## Requirements

- Windows 11. The app was tested on build 26200.
- Windows PowerShell 5.1 (`powershell.exe`). The app compiles its C# helper with the compiler that comes with it.
- Hibernate must be available. Run `powercfg /a` and look for "Hibernate" in the available states. If it is not there, run `powercfg /hibernate on` in an administrator terminal.
- Admin rights are not necessary for the app.

## Install

1. Open PowerShell in this directory.
2. Run `.\Install.ps1`.
3. Look for a green bear face in the notification area.

`Install.ps1` puts a shortcut in the Startup folder, so the app starts at every login. The shortcut runs PowerShell through `conhost.exe --headless`, so no console window opens. Use `.\Install.ps1 -NoStart` to add the shortcut without a start now.

## Use

Click the tray icon with the left or the right mouse button to open the menu.

| Menu item | What it does |
| --- | --- |
| Away (lid hibernates) | Closing the lid hibernates. Idle standby turns into hibernate after 20 minutes. The network is off in standby. |
| Keep Working > For 20 minutes, 1 hour, 2 hours, 3 hours | Closing the lid does nothing. The laptop does not go to sleep. The screen still turns off on its normal timer. |
| Keep Working > Until I switch back | The same as above, with no time limit. |
| Auto (follow Claude sessions) | Keep Working while a Claude Code session is busy. Away when all sessions are quiet. |
| Restart Explorer | Restarts Explorer, the Start menu, and search. The hotkey is Ctrl+Alt+Shift+E. |
| Open log | Opens the log in Notepad. |
| Exit (sets Away) | Puts the Away settings back and stops the app. |

The app always starts in Away. Keep Working and Auto last only until the next login.

In Keep Working, the menu marks the time that you chose, and the Keep Working item shows the time that is left.

The tooltip shows the mode in words. The icon also shows the mode:

- Green bear with closed eyes: Away. The bear sleeps, so the laptop hibernates when you leave.
- Red bear with open eyes: Keep Working.
- Orange bear: Auto. Its eyes are closed while Auto applies the Away settings, and open while Auto keeps the laptop awake.

A white badge in the lower right corner also marks Auto, so you can tell the modes apart without color.

### When Keep Working ends

When the timer ends, the app goes back to Away. When Auto sees that the work is done, it does the same. Then the app hibernates the laptop when nobody uses it:

- If the lid is closed, the app hibernates after 2 minutes with no keyboard or mouse input.
- If the lid is open, the app hibernates after 10 minutes with no input.
- If somebody uses the keyboard or the mouse first, the app cancels the hibernate. This prevents a hibernate when the lid is closed on a dock.
- If the laptop wakes from hibernate or standby, the app does not hibernate it again at once. The Away timers apply instead.

On battery, the charge can fall to 15% or less in Keep Working. Then the app goes back to Away and hibernates the laptop with the same idle rules. Auto does not go back to Keep Working while the charge stays at 15% or less. Windows also hibernates the laptop at 2% by itself.

### How Auto decides

Auto checks every 10 seconds. A session is busy if one of these is true:

- Optional: a [claude-status-dashboard](https://github.com/mattcowan/claude-status-dashboard) board at `http://127.0.0.1:4787` has a card in the Working column with activity in the last 6 hours. If no dashboard runs, Auto uses the other two signals. To turn this signal off, set `DashboardUrl` to `$null` in `$Config`.
- The process tree of a Claude session started a new process since the last check. A session that runs tools starts `bash`, `git`, and similar processes all the time. A quiet session starts none.
- The process tree of a Claude session used 2 seconds of CPU in the last 10 seconds. This catches a long build or test run.

A Claude session is a `claude.exe` process or a `node.exe` process that runs the Claude Code `cli.js`. The VS Code extension uses `claude.exe`. The `claude` command from `npm install -g` uses `node.exe`.

One signal is enough. Auto goes back to Away after 10 minutes with no signal. Auto stays awake for a maximum of 3 hours at a time. After that, it stays in Away until all signals are quiet.

Each signal has a gap:

- A dashboard card can stay in Working after its session stops.
- A Claude session uses almost no CPU while the model writes a reply. The process checks see only tool runs.
- A tool command that starts and stops between two checks is not seen.

The 10-minute quiet period and the dashboard card cover most of these gaps.

### The Explorer hotkey

Press Ctrl+Alt+Shift+E to restart Explorer. The app owns the hotkey, so the hotkey works when the taskbar and the Start menu do not respond.

The restart closes all open File Explorer windows. The tray icon comes back by itself.

Each restart writes a line to the log. The line gives the Explorer uptime and memory, the time since the last wake from standby, and the time since the display came on. Use these lines to find out if the freezes follow standby or the display timer.

## How it works

The app changes four settings on the active power plan. It changes the AC value and the DC value together.

| Setting | Away | Keep Working | Example: before install |
| --- | --- | --- | --- |
| Lid close action | Hibernate | Do nothing | Hibernate |
| Sleep after | 15 min AC, 5 min DC | Never | 60 min AC, 5 min DC |
| Hibernate after standby | 20 min | 20 min | Never |
| Network in standby | Off | Off | On AC, managed DC |

The last column shows the values on the laptop where this app started. They are different on other laptops. The app records the real values on its first start (see [Remove](#remove)).

In Keep Working, the app also holds a "system required" request. This request stops idle sleep. Windows removes the request when the app stops.

The Keep Working values for the lid and for sleep stay in the power plan after the app stops. So the app puts the Away values back when it stops:

- When you use Exit in the tray menu.
- When `Uninstall.ps1` asks the app to stop.
- When Windows signs you out, restarts, or shuts down.
- When the app stops because of an error in the script.

If something stops the app by force in Keep Working, the lid stays ignored. This includes Task Manager and a crash of PowerShell itself. The next start of the app puts Away back, and the app starts at each login. To fix it at once, start the app again or run `.\Restore-Baseline.ps1`.

The app reads and writes the settings through the `powrprof` API in `Hibearnate.cs`. It does not parse the output of `powercfg`. On some laptops, `powercfg /query` hides the lid close action, and only `powercfg /qh` shows it. The API sees hidden settings, and it does not depend on the display language.

After each change, the app reads every value back. If a value did not change, the app writes a warning to the log and shows a notification.

The log is at `%LOCALAPPDATA%\Hibearnate\power-profiles.log`. When the log is larger than 1 MB, the app renames it to `power-profiles.log.old` and starts a new one.

## Configure

Change the values in the `$Config` block at the top of `Hibearnate.ps1`. Then use Exit in the tray menu and start the app again.

To tune Auto, start the app with `-TraceAuto`. The app then writes the Auto inputs to the log at every check.

To test the settings without the tray, run `.\Hibearnate.ps1 -SelfTest`. It applies both profiles, reads them back, samples the Claude Code sessions, and reads the dashboard. It leaves the laptop in Away. If the tray app runs, the self-test stops with an error. Use Exit in the tray menu first.

## Remove

1. Run `.\Uninstall.ps1`.

This removes the Startup shortcut and asks the app to stop. The app puts the Away values back before it stops. If the app does not stop in 20 seconds, the script stops it by force and shows a warning. Then the script puts back the settings that the app recorded before its first start, and removes the record. Use `.\Uninstall.ps1 -KeepSettings` to keep the Away values and the record.

To put back only the settings, run `.\Restore-Baseline.ps1`. This script uses `powercfg` directly, so it works if the app does not. If `powercfg` fails, the script names each setting that it did not restore.

The app records the original values to `%LOCALAPPDATA%\Hibearnate\baseline.json` the first time it starts, before it changes a setting. The app writes the file completely or not at all, and it never overwrites the file. If the file does not exist or is damaged, `Restore-Baseline.ps1` changes nothing and shows a warning. If the app finds a damaged file when it starts, it shows a notification. If the app cannot write the file, it changes no setting and shows a notification. It tries again every 10 seconds, and it applies Away when the file is written.

## Files

| File | Purpose |
| --- | --- |
| `Hibearnate.ps1` | The tray app. |
| `Hibearnate.cs` | Native helpers: power settings, hotkey, lid and display events, Claude Code activity. |
| `Install.ps1` | Adds the Startup shortcut and starts the app. |
| `Uninstall.ps1` | Removes the shortcut, stops the app, and restores the settings. |
| `Restore-Baseline.ps1` | Puts back the settings that the app recorded before its first start. |
| `LICENSE` | The MIT License. |

## License

Hibearnate is available under the [MIT License](LICENSE).
