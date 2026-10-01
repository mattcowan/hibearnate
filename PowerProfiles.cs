// Native helpers for PowerProfiles.ps1. Compiled at launch with Add-Type, so this
// file stays within C# 5 (the compiler that ships with Windows PowerShell 5.1).

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WindowsPowerProfiles
{
    // Reads and writes power settings on the active scheme through the powrprof
    // API. Unlike `powercfg /query`, this sees settings Windows marks hidden (the
    // lid close action is hidden on this machine) and never parses localized text.
    public static class PowerSettings
    {
        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);
        [DllImport("powrprof.dll")]
        private static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid schemeGuid);
        [DllImport("powrprof.dll")]
        private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")]
        private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")]
        private static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroup, ref Guid setting, uint value);
        [DllImport("powrprof.dll")]
        private static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroup, ref Guid setting, uint value);
        // Returns BOOLEAN (1 byte), not BOOL (4 bytes); without I1 the upper bytes
        // of the register are read too and a failure can look like success.
        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.I1)]
        private static extern bool SetSuspendState(
            [MarshalAs(UnmanagedType.I1)] bool hibernate,
            [MarshalAs(UnmanagedType.I1)] bool forceCritical,
            [MarshalAs(UnmanagedType.I1)] bool disableWakeEvent);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr mem);
        [DllImport("kernel32.dll")]
        private static extern uint SetThreadExecutionState(uint flags);

        private const uint ES_CONTINUOUS = 0x80000000;
        private const uint ES_SYSTEM_REQUIRED = 0x00000001;

        private static void Check(uint result, string call)
        {
            if (result != 0)
            {
                throw new Win32Exception((int)result, call + " failed with error " + result);
            }
        }

        private static Guid GetActiveScheme()
        {
            IntPtr ptr;
            Check(PowerGetActiveScheme(IntPtr.Zero, out ptr), "PowerGetActiveScheme");
            try
            {
                return (Guid)Marshal.PtrToStructure(ptr, typeof(Guid));
            }
            finally
            {
                LocalFree(ptr);
            }
        }

        // Returns { AC value, DC value } for one setting on the active scheme.
        public static uint[] Read(Guid subGroup, Guid setting)
        {
            Guid scheme = GetActiveScheme();
            uint ac, dc;
            Check(PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subGroup, ref setting, out ac), "PowerReadACValueIndex");
            Check(PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subGroup, ref setting, out dc), "PowerReadDCValueIndex");
            return new uint[] { ac, dc };
        }

        // Writes AC and DC together so they never drift apart. Call Commit()
        // afterwards; Windows only applies scheme edits on re-activation.
        public static void Write(Guid subGroup, Guid setting, uint ac, uint dc)
        {
            Guid scheme = GetActiveScheme();
            Check(PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subGroup, ref setting, ac), "PowerWriteACValueIndex");
            Check(PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subGroup, ref setting, dc), "PowerWriteDCValueIndex");
        }

        public static void Commit()
        {
            Guid scheme = GetActiveScheme();
            Check(PowerSetActiveScheme(IntPtr.Zero, ref scheme), "PowerSetActiveScheme");
        }

        public static void Hibernate()
        {
            if (!SetSuspendState(true, false, false))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        // Holds a "system required" request on the calling thread, which blocks
        // idle sleep for as long as this process lives. Windows drops the request
        // automatically if the process dies, so a crash cannot leave it stuck on.
        public static void KeepSystemAwake(bool on)
        {
            SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
        }
    }

    public static class UserIdle
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        // Time since the last keyboard or mouse input in this session.
        public static TimeSpan Get()
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            if (!GetLastInputInfo(ref info))
            {
                return TimeSpan.Zero;
            }
            uint now = unchecked((uint)Environment.TickCount);
            return TimeSpan.FromMilliseconds(unchecked(now - info.dwTime));
        }
    }

    // Invisible window that receives the global hotkey and the lid and display
    // power notifications. Its WndProc runs on the thread that created it, so
    // PowerShell event handlers attached here run on the tray's UI thread.
    public class MessageWindow : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll")]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
        [DllImport("user32.dll")]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        public const uint MOD_ALT = 0x1;
        public const uint MOD_CONTROL = 0x2;
        public const uint MOD_SHIFT = 0x4;
        private const uint MOD_NOREPEAT = 0x4000;
        private const int WM_HOTKEY = 0x0312;
        private const int WM_ENDSESSION = 0x0016;
        private const int WM_POWERBROADCAST = 0x0218;
        private const int PBT_POWERSETTINGCHANGE = 0x8013;
        private const int HOTKEY_ID = 1;

        private static readonly Guid GUID_LIDSWITCH_STATE_CHANGE = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
        private static readonly Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

        private IntPtr lidNotify = IntPtr.Zero;
        private IntPtr displayNotify = IntPtr.Zero;
        private bool hotkeyRegistered;

        public event EventHandler HotkeyPressed;
        public event EventHandler LidChanged;
        public event EventHandler DisplayChanged;

        // Sign-out, restart or shutdown is in progress (WM_ENDSESSION with
        // wParam TRUE). Handlers must finish fast; Windows does not wait long.
        public event EventHandler SessionEnding;

        // Null until Windows sends the first lid notification (it sends one
        // right after registration on hardware that has a lid).
        public bool? LidOpen { get; private set; }

        // 0 = off, 1 = on, 2 = dimmed, -1 = not reported yet.
        public int DisplayState { get; private set; }

        public MessageWindow()
        {
            DisplayState = -1;
            CreateHandle(new CreateParams());
        }

        public bool RegisterHotkey(uint modifiers, Keys key)
        {
            hotkeyRegistered = RegisterHotKey(Handle, HOTKEY_ID, modifiers | MOD_NOREPEAT, (uint)key);
            return hotkeyRegistered;
        }

        public void RegisterPowerNotifications()
        {
            Guid lid = GUID_LIDSWITCH_STATE_CHANGE;
            Guid display = GUID_CONSOLE_DISPLAY_STATE;
            lidNotify = RegisterPowerSettingNotification(Handle, ref lid, 0);
            displayNotify = RegisterPowerSettingNotification(Handle, ref display, 0);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID)
            {
                Raise(HotkeyPressed);
            }
            else if (m.Msg == WM_ENDSESSION && m.WParam != IntPtr.Zero)
            {
                Raise(SessionEnding);
            }
            else if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE)
            {
                // POWERBROADCAST_SETTING: GUID (16 bytes), DWORD DataLength, then the data.
                Guid setting = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                int data = Marshal.ReadInt32(m.LParam, 20);
                if (setting == GUID_LIDSWITCH_STATE_CHANGE)
                {
                    LidOpen = data != 0;
                    Raise(LidChanged);
                }
                else if (setting == GUID_CONSOLE_DISPLAY_STATE)
                {
                    DisplayState = data;
                    Raise(DisplayChanged);
                }
                m.Result = new IntPtr(1);
                return;
            }
            base.WndProc(ref m);
        }

        private void Raise(EventHandler handler)
        {
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        public void Dispose()
        {
            if (hotkeyRegistered)
            {
                UnregisterHotKey(Handle, HOTKEY_ID);
                hotkeyRegistered = false;
            }
            if (lidNotify != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(lidNotify);
                lidNotify = IntPtr.Zero;
            }
            if (displayNotify != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(displayNotify);
                displayNotify = IntPtr.Zero;
            }
            DestroyHandle();
        }
    }

    public class ClaudeSample
    {
        public int Sessions;
        public int BusySessions;
        public double MaxCpuMs;
        public int Spawns;
        public string Detail;
    }

    // Measures what each Claude Code session did between two calls. A session is
    // one Claude process that is not itself a child of another Claude process,
    // plus every process below it (tool commands, test runs, MCP servers).
    //
    // A Claude process is either claude.exe (the native binary that the VS Code
    // extension and the native installer use) or node.exe running the npm
    // package's cli.js (what the `claude` command from `npm i -g` starts).
    //
    // A session counts as busy when either:
    //  - a process appeared in its tree since the last call. Idle sessions spawn
    //    nothing (measured: 18 idle sessions, 0 spawns in 90 s), while a session
    //    running tools spawns bash, git and the like constantly; or
    //  - its tree used at least busyThresholdMs of CPU, which catches one long
    //    build or test run that started before the last call.
    // claude.exe itself uses about as little CPU while the model generates as it
    // does idle, so neither signal sees pure model time. Pair this with another
    // signal (the dashboard) for that.
    public class ClaudeActivity
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")]
        private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")]
        private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32W entry);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr process, int infoClass, IntPtr buffer, int length, out int returnLength);

        private const uint TH32CS_SNAPPROCESS = 0x2;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const int ProcessCommandLineInformation = 60;  // Windows 8.1 and later
        private const string NodeExe = "node.exe";
        private const string NodeMarker = "claude-code/cli";   // matched after \ -> /

        private readonly string exeName;
        private Dictionary<int, double> lastCpu = new Dictionary<int, double>();
        private HashSet<int> lastSeen = new HashSet<int>();
        // node.exe PID -> runs Claude Code. Reading a command line costs a
        // handle and two syscalls, so each node.exe is checked once while it lives.
        private Dictionary<int, bool> nodeIsClaude = new Dictionary<int, bool>();
        private bool primed;

        public ClaudeActivity(string exeName)
        {
            this.exeName = exeName;
        }

        // The first call only records a baseline and reports zero CPU.
        public ClaudeSample Sample(double busyThresholdMs)
        {
            Dictionary<int, int> parentOf = new Dictionary<int, int>();
            Dictionary<int, string> nameOf = new Dictionary<int, string>();
            Snapshot(parentOf, nameOf);
            ClassifyNodeProcesses(nameOf);

            Dictionary<int, List<int>> children = new Dictionary<int, List<int>>();
            foreach (KeyValuePair<int, int> pair in parentOf)
            {
                List<int> list;
                if (!children.TryGetValue(pair.Value, out list))
                {
                    list = new List<int>();
                    children[pair.Value] = list;
                }
                list.Add(pair.Key);
            }

            ClaudeSample result = new ClaudeSample();
            Dictionary<int, double> nowCpu = new Dictionary<int, double>();
            HashSet<int> nowSeen = new HashSet<int>();
            List<string> detail = new List<string>();

            foreach (KeyValuePair<int, string> pair in nameOf)
            {
                if (!IsClaude(pair.Key, nameOf))
                {
                    continue;
                }
                int parent;
                if (parentOf.TryGetValue(pair.Key, out parent) && IsClaude(parent, nameOf))
                {
                    continue; // counted as part of its parent session
                }

                // Parent IDs can point at a reused PID, so guard against cycles.
                double sessionDelta = 0;
                int sessionSpawns = 0;
                HashSet<int> seen = new HashSet<int>();
                Queue<int> queue = new Queue<int>();
                queue.Enqueue(pair.Key);
                while (queue.Count > 0)
                {
                    int pid = queue.Dequeue();
                    if (!seen.Add(pid))
                    {
                        continue;
                    }
                    nowSeen.Add(pid);
                    if (primed && !lastSeen.Contains(pid))
                    {
                        sessionSpawns++;
                    }
                    double cpu = CpuMs(pid);
                    if (cpu >= 0)
                    {
                        nowCpu[pid] = cpu;
                        double previous;
                        if (lastCpu.TryGetValue(pid, out previous))
                        {
                            sessionDelta += Math.Max(0, cpu - previous);
                        }
                        else if (primed)
                        {
                            sessionDelta += cpu; // started since the last sample
                        }
                    }
                    List<int> kids;
                    if (children.TryGetValue(pid, out kids))
                    {
                        foreach (int kid in kids)
                        {
                            queue.Enqueue(kid);
                        }
                    }
                }

                result.Sessions++;
                result.Spawns += sessionSpawns;
                if (sessionSpawns > 0 || sessionDelta >= busyThresholdMs)
                {
                    result.BusySessions++;
                }
                result.MaxCpuMs = Math.Max(result.MaxCpuMs, sessionDelta);
                detail.Add(pair.Key + ":" + Math.Round(sessionDelta) + "ms+" + sessionSpawns);
            }

            lastCpu = nowCpu;
            lastSeen = nowSeen;
            primed = true;
            result.Detail = string.Join(" ", detail.ToArray());
            return result;
        }

        private bool IsClaude(int pid, Dictionary<int, string> nameOf)
        {
            string name;
            if (!nameOf.TryGetValue(pid, out name))
            {
                return false;
            }
            if (string.Equals(name, exeName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            bool isClaude;
            return nodeIsClaude.TryGetValue(pid, out isClaude) && isClaude;
        }

        // Checks each node.exe not seen before, and forgets PIDs that exited so
        // a reused PID is checked again.
        private void ClassifyNodeProcesses(Dictionary<int, string> nameOf)
        {
            List<int> gone = new List<int>();
            foreach (int pid in nodeIsClaude.Keys)
            {
                string name;
                if (!nameOf.TryGetValue(pid, out name) || !string.Equals(name, NodeExe, StringComparison.OrdinalIgnoreCase))
                {
                    gone.Add(pid);
                }
            }
            foreach (int pid in gone)
            {
                nodeIsClaude.Remove(pid);
            }

            foreach (KeyValuePair<int, string> pair in nameOf)
            {
                if (string.Equals(pair.Value, NodeExe, StringComparison.OrdinalIgnoreCase) && !nodeIsClaude.ContainsKey(pair.Key))
                {
                    string commandLine = CommandLine(pair.Key);
                    nodeIsClaude[pair.Key] = commandLine != null &&
                        commandLine.Replace('\\', '/').IndexOf(NodeMarker, StringComparison.OrdinalIgnoreCase) >= 0;
                }
            }
        }

        // Returns null if the process exited or denies access.
        private static string CommandLine(int pid)
        {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (process == IntPtr.Zero)
            {
                return null;
            }
            try
            {
                int length;
                NtQueryInformationProcess(process, ProcessCommandLineInformation, IntPtr.Zero, 0, out length);
                if (length <= 0)
                {
                    return null;
                }
                IntPtr buffer = Marshal.AllocHGlobal(length);
                try
                {
                    if (NtQueryInformationProcess(process, ProcessCommandLineInformation, buffer, length, out length) != 0)
                    {
                        return null;
                    }
                    // UNICODE_STRING: USHORT Length (bytes), USHORT MaximumLength, then a
                    // pointer aligned to pointer size; the text follows in the same buffer.
                    int bytes = Marshal.ReadInt16(buffer) & 0xFFFF;
                    IntPtr text = Marshal.ReadIntPtr(buffer, IntPtr.Size);
                    return text == IntPtr.Zero ? null : Marshal.PtrToStringUni(text, bytes / 2);
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseHandle(process);
            }
        }

        private static double CpuMs(int pid)
        {
            try
            {
                using (Process p = Process.GetProcessById(pid))
                {
                    return p.TotalProcessorTime.TotalMilliseconds;
                }
            }
            catch (Exception)
            {
                return -1; // exited, or protected process
            }
        }

        private static void Snapshot(Dictionary<int, int> parentOf, Dictionary<int, string> nameOf)
        {
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == new IntPtr(-1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                PROCESSENTRY32W entry = new PROCESSENTRY32W();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                bool ok = Process32First(snap, ref entry);
                while (ok)
                {
                    int pid = (int)entry.th32ProcessID;
                    parentOf[pid] = (int)entry.th32ParentProcessID;
                    nameOf[pid] = entry.szExeFile;
                    ok = Process32Next(snap, ref entry);
                }
            }
            finally
            {
                CloseHandle(snap);
            }
        }
    }
}
