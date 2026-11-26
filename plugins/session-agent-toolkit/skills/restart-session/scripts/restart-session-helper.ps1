<#
.SYNOPSIS
  Internal second stage of restart-session.ps1. Do not call directly and do not allow-list.

.DESCRIPTION
  Runs detached from the agent (Windows PowerShell 5.1, started through WMI). After the delay it
  kills the agent process tree and types the restart command into the shell that launched it.

  This file owns everything that ends up on the user's command line, so that the typed text is
  never caller-controlled: a fixed template per CLI and mode, plus a UUID (restart) or a random
  file id (new). A new session's activation prompt is read from a file by the typed command
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
# First message of a resumed session. Fixed text: the resumed session can already see, in its own
# history, that it asked for the restart. Must stay free of quote characters (it is typed inside '...').
$restartMessage = '[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'

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
    if ($mode -eq 'restart' -and "$($job.sessionId)" -notmatch '\A[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z') {
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
        $commandLine = ($templates.restart[$kind] -f $job.sessionId) + " '" + $restartMessage + "'"
    }
    else {
        # The activation prompt is loaded by the user's shell from a file and handed over as ONE argument:
        #  - the fixed prefix means it can never start with '-' and be parsed as a CLI option;
        #  - double quotes become single quotes, so it cannot split into extra arguments even where
        #    PowerShell passes native arguments the legacy way (Windows PowerShell 5.1).
        $promptPath = '$env:LOCALAPPDATA\restart-session\' + $job.jobId + '.prompt.txt'
        $commandLine = $templates.new[$kind] +
            " ('[restart-session] ' + (Get-Content -Raw -Encoding UTF8 -LiteralPath `"$promptPath`")).Replace('`"', `"'`")"
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

    $plan = Get-Plan
    Write-Log ("taskkill: " + ((cmd.exe /c "taskkill /PID $($plan.agentPid) /T /F 2>&1") -join ' | '))

    $deadline = (Get-Date).AddSeconds(15)
    while (Get-Proc $plan.agentPid) {
        if ((Get-Date) -gt $deadline) { throw "agent pid $($plan.agentPid) did not exit" }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Get-Proc $plan.shellPid)) { throw "shell pid $($plan.shellPid) is gone; nothing typed" }
    Start-Sleep -Milliseconds 1500   # let the shell get back to its prompt

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
    # Escape first: clears anything already sitting on the shell's input line.
    [RestartSessionConsole]::Type([uint32]$plan.shellPid, [string][char]27 + $plan.commandLine + "`r")
    Write-Log "typed: $($plan.commandLine)"
}
catch {
    Write-Log "FAILED: $_"
    exit 1
}
exit 0
