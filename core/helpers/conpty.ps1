# PadCode terminal helper for Windows 10 1809+ / 11, run on the desktop as
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File conpty-<hash>.ps1 COLS ROWS
# The VS Code tunnel's `spawn` gives us plain pipes, so this hosts PowerShell on
# a Windows pseudo console (ConPTY) and copies bytes between the pipes and it.
# Resizes arrive in-band on stdin as  ESC ] 7777 ; COLS ; ROWS BEL.
# The C# below is compiled once and cached next to this script.

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace PadCode {
public static class ConPty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr hpc);
    [DllImport("kernel32.dll")] static extern int ResizePseudoConsole(IntPtr hpc, COORD size);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hpc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000;
    const int STARTF_USESTDHANDLES = 0x100;
    static readonly IntPtr PSEUDOCONSOLE_ATTR = (IntPtr)0x20016;
    static readonly Regex Frame = new Regex("\x1b\\]7777;(\\d+);(\\d+)\x07");
    // A lone trailing ESC (the Esc key) passes straight through; only "ESC ]..." is held.
    static readonly Regex Partial = new Regex("\x1b\\](7(7(7(7(;[\\d;]*)?)?)?)?)?$");

    static COORD Size(int cols, int rows) { return new COORD { X = (short)cols, Y = (short)rows }; }

    static string Shell() {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';')) {
            try { if (dir.Length > 0 && File.Exists(Path.Combine(dir, "pwsh.exe"))) return "pwsh.exe -NoLogo"; } catch { }
        }
        return "powershell.exe -NoLogo";
    }

    public static int Run(int cols, int rows) {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) {
            Console.Error.WriteLine("CreatePipe failed"); return 1;
        }
        IntPtr hpc;
        int hr = CreatePseudoConsole(Size(cols, rows), inRead, outWrite, 0, out hpc);
        if (hr != 0) { Console.Error.WriteLine("CreatePseudoConsole failed: 0x" + hr.ToString("x8")); return 1; }
        inRead.Dispose(); outWrite.Dispose(); // the pseudo console keeps its own copies

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // Our own stdio is redirected; without this the child would grab it instead of the console.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        IntPtr attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        si.lpAttributeList = Marshal.AllocHGlobal(attrSize);
        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref attrSize) ||
            !UpdateProcThreadAttribute(si.lpAttributeList, 0, PSEUDOCONSOLE_ATTR, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) {
            Console.Error.WriteLine("proc thread attribute failed: " + Marshal.GetLastWin32Error()); return 1;
        }
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(Shell()), IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT,
                            IntPtr.Zero, Environment.CurrentDirectory, ref si, out pi)) {
            Console.Error.WriteLine("CreateProcess failed: " + Marshal.GetLastWin32Error()); return 1;
        }

        var stdout = Console.OpenStandardOutput();
        var conOut = new FileStream(outRead, FileAccess.Read);
        var pump = new Thread(() => {
            var buf = new byte[65536];
            try { int n; while ((n = conOut.Read(buf, 0, buf.Length)) > 0) { stdout.Write(buf, 0, n); stdout.Flush(); } } catch { }
        });
        pump.IsBackground = true;
        pump.Start();

        var conIn = new FileStream(inWrite, FileAccess.Write);
        var gate = new object();
        string pending = "";
        // Latin-1 maps bytes 1:1 to chars so regexes can run over raw input.
        Encoding raw = Encoding.GetEncoding(28591);
        Action<string> send = s => { if (s.Length > 0) { var b = raw.GetBytes(s); conIn.Write(b, 0, b.Length); conIn.Flush(); } };
        // A possible partial resize frame waits at most 50 ms for its tail; then it was typed input.
        var flush = new Timer(_ => { lock (gate) { try { send(pending); } catch { } pending = ""; } });

        var input = new Thread(() => {
            var stdin = Console.OpenStandardInput();
            var buf = new byte[65536];
            try {
                int n;
                while ((n = stdin.Read(buf, 0, buf.Length)) > 0) {
                    lock (gate) {
                        string s = pending + raw.GetString(buf, 0, n);
                        pending = "";
                        int pos = 0;
                        var sb = new StringBuilder();
                        foreach (Match m in Frame.Matches(s)) {
                            sb.Append(s, pos, m.Index - pos);
                            ResizePseudoConsole(hpc, Size(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value)));
                            pos = m.Index + m.Length;
                        }
                        string rest = s.Substring(pos);
                        var p = Partial.Match(rest);
                        if (p.Success) { pending = rest.Substring(p.Index); rest = rest.Substring(0, p.Index); flush.Change(50, Timeout.Infinite); }
                        sb.Append(rest);
                        send(sb.ToString());
                    }
                }
            } catch { }
            TerminateProcess(pi.hProcess, 0); // client closed the terminal
        });
        input.IsBackground = true;
        input.Start();

        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        uint code;
        GetExitCodeProcess(pi.hProcess, out code);
        ClosePseudoConsole(hpc); // flushes and closes the output pipe
        pump.Join(2000);
        return (int)code;
    }
}
}
'@

$dll = [IO.Path]::ChangeExtension($PSCommandPath, '.dll')
if (-not (Test-Path $dll)) {
    $tmp = "$dll.$PID.tmp"
    try {
        Add-Type -TypeDefinition $src -OutputAssembly $tmp -OutputType Library
        Move-Item -Force $tmp $dll
    } catch { Remove-Item -ErrorAction SilentlyContinue $tmp }
}
if (Test-Path $dll) { Add-Type -Path $dll } else { Add-Type -TypeDefinition $src }
exit ([PadCode.ConPty]::Run([int]$args[0], [int]$args[1]))
