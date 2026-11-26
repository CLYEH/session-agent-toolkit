<#
.SYNOPSIS
  Internal second stage of restart-session.ps1. Do not call directly and do not allow-list.

.DESCRIPTION
  Runs detached from the agent (Windows PowerShell 5.1, started through WMI). After the delay it
  kills the agent process tree and types the restart command into the shell that launched it.

  This file owns everything that ends up on the user's command line, so that the typed text is
  never caller-controlled: a fixed template per CLI and mode, plus a UUID (restart, switch) and/or
  a random file id (new, switch). An activation prompt is read from a file by the typed command
  itself; it is never typed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobFile,
    [switch]$PlanOnly   # validate and print the plan as JSON; kill nothing, type nothing
)
$ErrorActionPreference = 'Stop'

$dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'restart-session'
$job = Get-Content -Raw -Encoding UTF8 -LiteralPath $JobFile | ConvertFrom-Json

function Get-Proc([int]$Id) {
    Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
}

# Parent of a process, or $null if the recorded parent pid is dead or was reused by a younger process.
function Get-ParentProc($Proc) {
    $parent = Get-Proc $Proc.ParentProcessId
    if ($parent -and $parent.CreationDate -le $Proc.CreationDate) { $parent }
}

$processNames = @{ claude = @('claude.exe'); codex = @('codex.exe', 'node.exe'); agy = @('agy.exe') }
$templates = @{
    restart = @{ claude = 'claude --resume {0}'; codex = 'codex resume {0}'; agy = 'agy --conversation {0} -i' }
    new     = @{ claude = 'claude'; codex = 'codex'; agy = 'agy -i' }
}
$templates.switch = $templates.restart   # same resume command, aimed at another session
# First message of a restarted session. Fixed text plus the job id as a token: the launcher printed
# the same token into the tool output of the session that asked, so a session resumed by mistake
# (any other conversation) can tell that it did not ask. Must stay free of quote characters (typed inside '...').
$restartMessage = '[restart-session] Restart token {0}. This session ran the restart-session tool and was restarted at its own request; the user did not type this message. Look for the same token in your own most recent tool output. If it is there, continue where you left off. If it is not, you are not the session that asked for this restart: do not continue any work, and tell the user what happened.'
# First words of the message a new or switched-to session receives. Fixed text, typed as part of
# the command, so the caller cannot remove or reword it: the receiving session must not mistake
# an agent's note for something the user typed. Must stay free of quote characters (typed inside '...').
$notices = @{
    new    = '[restart-session] This session was started by an AI agent through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
    switch = '[restart-session] An AI agent switched this terminal to this session through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
}

function Get-Delay {
    $delay = [int]$job.delaySeconds
    if ($delay -lt 1 -or $delay -gt 600) { throw 'delay must be between 1 and 600 seconds' }
    $delay
}

function Get-Plan {
    $mode = "$($job.mode)"
    if (-not $templates.ContainsKey($mode)) { throw "unknown mode '$mode'" }
    $kind = "$($job.kind)"
    if (-not $templates[$mode].ContainsKey($kind)) { throw "unknown agent kind '$kind'" }
    # \A..\z, not ^..$: '$' would accept a trailing newline, and a newline typed into a shell is Enter.
    if ("$($job.jobId)" -notmatch '\A[0-9a-f]{32}\z') { throw 'job id rejected' }
    if ($mode -ne 'new' -and "$($job.sessionId)" -notmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') {
        throw 'session id rejected: it must be a plain UUID'
    }

    $agent = Get-Proc ([int]$job.agentPid)
    if (-not $agent -or "$($agent.CreationDate.Ticks)" -ne "$($job.agentCreated)") {
        throw "agent pid $($job.agentPid) is gone or is no longer the same process"
    }
    if ($processNames[$kind] -notcontains $agent.Name) { throw "pid $($job.agentPid) is $($agent.Name), not a $kind session" }

    $shell = Get-ParentProc $agent
    if (-not $shell) { throw "the process that launched $($agent.Name) is gone; nowhere to type the restart command" }
    if ('pwsh.exe', 'powershell.exe' -notcontains $shell.Name) {
        throw "$($agent.Name) was launched by $($shell.Name), not by PowerShell; only PowerShell shells are supported"
    }

    if ($mode -eq 'restart') {
        $commandLine = ($templates.restart[$kind] -f $job.sessionId) + " '" + ($restartMessage -f $job.jobId) + "'"
    }
    else {
        # The activation prompt is loaded by the user's shell from a file and handed over as ONE argument:
        #  - the fixed notice in front means it can never start with '-' and be parsed as a CLI option;
        #  - double quotes become single quotes, so it cannot split into extra arguments even where
        #    PowerShell passes native arguments the legacy way (Windows PowerShell 5.1).
        $promptPath = '$env:LOCALAPPDATA\restart-session\' + $job.jobId + '.prompt.txt'
        $commandLine = ($templates[$mode][$kind] -f $job.sessionId) +
            " ('$($notices[$mode])' + (Get-Content -Raw -Encoding UTF8 -LiteralPath `"$promptPath`")).Replace('`"', `"'`")"
    }

    [ordered]@{
        mode        = $mode
        kind        = $kind
        agent       = $agent.Name
        agentPid    = $agent.ProcessId
        shell       = $shell.Name
        shellPid    = $shell.ProcessId
        commandLine = $commandLine
    }
}

if ($PlanOnly) {
    try { $null = Get-Delay; Get-Plan | ConvertTo-Json; exit 0 }
    catch { "$_"; exit 1 }
}

$log = Join-Path $dir ("{0}.log" -f ($job.jobId -replace '[^0-9a-f]', ''))
function Write-Log($Message) {
    Add-Content -Encoding UTF8 -LiteralPath $log -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $Message)
}
try {
    $delay = Get-Delay
    Write-Log "helper started; waiting ${delay}s"
    Start-Sleep -Seconds $delay

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class RestartSessionConsole
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct KEY_EVENT_RECORD
    {
        public int bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInputW(IntPtr h, [In] INPUT_RECORD[] buffer, uint length, out uint written);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char ch);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleW(IntPtr h, string text, uint length, out uint written, IntPtr reserved);

    // Attach to the console of process `pid` and open its input ("CONIN$") or output ("CONOUT$").
    static IntPtr Attach(uint pid, string device)
    {
        FreeConsole();
        if (!AttachConsole(pid))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole(" + pid + ") failed");
        IntPtr h = CreateFileW(device, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1))
        {
            int error = Marshal.GetLastWin32Error();
            FreeConsole();
            throw new Win32Exception(error, "opening " + device + " failed");
        }
        return h;
    }

    // Put the console input back in the mode a shell expects to find (the Windows default, 0x1F7:
    // line input, echo, Ctrl+C processing, quick edit...). A TUI switches it to raw VT input and,
    // when killed, leaves it that way for every program started afterwards.
    public static void RestoreInputMode(uint pid)
    {
        IntPtr h = Attach(pid, "CONIN$");
        try
        {
            if (!SetConsoleMode(h, 0x1F7))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetConsoleMode failed");
        }
        finally { CloseHandle(h); FreeConsole(); }
    }

    // Turn off the terminal modes a killed TUI leaves on: focus reporting and bracketed paste
    // (both measured after killing Claude Code), plus mouse tracking, the alternate screen and a
    // hidden cursor, which other TUIs or renderers use.
    public static void ResetTerminalModes(uint pid)
    {
        IntPtr h = Attach(pid, "CONOUT$");
        try
        {
            uint mode, written;
            if (!GetConsoleMode(h, out mode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetConsoleMode failed");
            SetConsoleMode(h, mode | 0x4); // ENABLE_VIRTUAL_TERMINAL_PROCESSING
            string reset = "\u001b[?1004l\u001b[?2004l\u001b[?1000l\u001b[?1002l\u001b[?1003l\u001b[?1006l\u001b[?1049l\u001b[?25h";
            WriteConsoleW(h, reset, (uint)reset.Length, out written, IntPtr.Zero);
            SetConsoleMode(h, mode);
        }
        finally { CloseHandle(h); FreeConsole(); }
    }

    // Type text into the console that process `pid` is attached to, as if on its keyboard.
    public static void Type(uint pid, string text)
    {
        FreeConsole();
        if (!AttachConsole(pid))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "AttachConsole(" + pid + ") failed");
        try
        {
            IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "opening CONIN$ failed");
            try
            {
                INPUT_RECORD[] records = new INPUT_RECORD[text.Length * 2];
                for (int i = 0; i < text.Length; i++)
                {
                    char c = text[i];
                    ushort vk = 0;
                    uint state = 0;
                    if (c == '\r') vk = 0x0D;
                    else if (c == (char)27) vk = 0x1B;
                    else
                    {
                        short scan = VkKeyScanW(c);
                        if (scan != -1)
                        {
                            vk = (ushort)(scan & 0xFF);
                            if ((scan & 0x100) != 0) state = 0x10; // SHIFT_PRESSED
                        }
                    }
                    for (int up = 0; up < 2; up++)
                    {
                        INPUT_RECORD r = new INPUT_RECORD();
                        r.EventType = 1; // KEY_EVENT
                        r.KeyEvent.bKeyDown = up == 0 ? 1 : 0;
                        r.KeyEvent.wRepeatCount = 1;
                        r.KeyEvent.wVirtualKeyCode = vk;
                        r.KeyEvent.UnicodeChar = c;
                        r.KeyEvent.dwControlKeyState = state;
                        records[i * 2 + up] = r;
                    }
                }
                uint written;
                if (!WriteConsoleInputW(h, records, (uint)records.Length, out written))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteConsoleInput failed");
                if (written != records.Length)
                    throw new InvalidOperationException("only " + written + " of " + records.Length + " key events written");
            }
            finally { CloseHandle(h); }
        }
        finally { FreeConsole(); }
    }
}
'@
    $plan = Get-Plan

    # The agent is killed outright, so it cannot put the terminal back the way it found it; do that
    # for it. The input mode has to be restored BEFORE the kill: the shell notes "the mode to give
    # the next program" the moment it gets its prompt back.
    [RestartSessionConsole]::RestoreInputMode([uint32]$plan.shellPid)
    Write-Log ("taskkill: " + ((cmd.exe /c "taskkill /PID $($plan.agentPid) /T /F 2>&1") -join ' | '))

    $deadline = (Get-Date).AddSeconds(15)
    while (Get-Proc $plan.agentPid) {
        if ((Get-Date) -gt $deadline) { throw "agent pid $($plan.agentPid) did not exit" }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Get-Proc $plan.shellPid)) { throw "shell pid $($plan.shellPid) is gone; nothing typed" }
    try { [RestartSessionConsole]::ResetTerminalModes([uint32]$plan.shellPid) }
    catch { Write-Log "could not reset terminal modes: $_" }
    Start-Sleep -Milliseconds 1500   # let the shell get back to its prompt

    # Escape first: clears anything already sitting on the shell's input line.
    [RestartSessionConsole]::Type([uint32]$plan.shellPid, [string][char]27 + $plan.commandLine + "`r")
    Write-Log "typed: $($plan.commandLine)"
}
catch {
    Write-Log "FAILED: $_"
    exit 1
}
exit 0
