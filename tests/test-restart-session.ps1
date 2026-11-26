# Tests for restart-session.ps1, run against stand-in agents (tiny exes named claude / codex / agy).
#
# Why these assertions. The script lets an unattended agent replace ITS OWN session, so it will be
# run without a permission prompt. Three things therefore have to hold:
#
#  A. It cannot be turned into "run anything in the user's terminal". Whatever the caller passes -
#     a hostile activation prompt, a hostile session id - the line typed into the shell must be the
#     fixed template and nothing else, and an activation prompt must arrive as exactly one argument
#     that cannot be read as a CLI option (e.g. --dangerously-skip-permissions).
#  B. A session that receives an agent-written prompt (new, switch) is told so, in fixed words the
#     caller cannot remove; and a plain restart cannot carry a prompt or be aimed at another session.
#  C. It actually works: old agent gone, next one started by the SAME interactive shell (= same
#     terminal tab), with the right arguments for the mode, and the helper survives the death of
#     the agent that launched it.
$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$launcher = Join-Path $root 'plugins\session-agent-toolkit\skills\restart-session\scripts\restart-session.ps1'
$fake     = Join-Path $root 'tests\test-fake-agent.ps1'
$work     = Join-Path ([IO.Path]::GetTempPath()) ("restart-session-test-" + [guid]::NewGuid().ToString('N'))
$bin      = Join-Path $work 'bin'
New-Item -ItemType Directory -Path $bin | Out-Null
# Claude Code's own records are faked under here; the real ~/.claude is never read or written.
$env:CLAUDE_CONFIG_DIR = Join-Path $work 'claude'

$failures = @()
function Check($name, $ok, $detail) {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  -- $detail"; $script:failures += $name }
}
function Wait-ForJson($path, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            Start-Sleep -Milliseconds 300   # let the writer finish
            return Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        }
        Start-Sleep -Milliseconds 250
    }
}

# --- stand-in agent exe: records its pid + argv, then runs the fake shell tool or idles like a TUI ---
Set-Content -Encoding ASCII -LiteralPath (Join-Path $work 'stub.cs') -Value @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
static class Stub {
    static string Json(string s) {
        StringBuilder b = new StringBuilder("\"");
        foreach (char c in s) {
            if (c == '"' || c == '\\') b.Append('\\').Append(c);
            else if (c < 32 || c > 126) b.Append("\\u").Append(((int)c).ToString("x4"));
            else b.Append(c);
        }
        return b.Append('"').ToString();
    }
    static int Main(string[] args) {
        string outPath = Environment.GetEnvironmentVariable("RS_TEST_OUT");
        if (!string.IsNullOrEmpty(outPath)) {
            StringBuilder j = new StringBuilder("{\"pid\":" + Process.GetCurrentProcess().Id + ",\"args\":[");
            for (int i = 0; i < args.Length; i++) { if (i > 0) j.Append(','); j.Append(Json(args[i])); }
            File.WriteAllText(outPath, j.Append("]}").ToString());
        }
        string child = Environment.GetEnvironmentVariable("RS_TEST_CHILD");
        if (!string.IsNullOrEmpty(child)) {
            ProcessStartInfo si = new ProcessStartInfo("pwsh.exe", "-NoProfile -File \"" + child + "\"");
            si.UseShellExecute = false;
            Process p = Process.Start(si);
            p.WaitForExit();
            return p.ExitCode;
        }
        Thread.Sleep(600000);
        return 0;
    }
}
'@
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command `
    "Add-Type -TypeDefinition (Get-Content -Raw '$work\stub.cs') -OutputAssembly '$bin\claude.exe' -OutputType ConsoleApplication"
if (-not (Test-Path "$bin\claude.exe")) { throw 'could not build the stand-in agent exe' }
Copy-Item "$bin\claude.exe" "$bin\codex.exe"
Copy-Item "$bin\claude.exe" "$bin\agy.exe"

$own    = [guid]::NewGuid().ToString()   # the session the stand-in "is"
$other  = [guid]::NewGuid().ToString()   # another session in the same project
$canary = Join-Path $work 'pwned'
# Everything an attacker would try to smuggle through the prompt: an option name, a newline (Enter),
# quote break-outs for both quote styles, a subexpression, Escape (clears the line), Backspace.
$hostile = "--dangerously-skip-permissions`n'; New-Item '$canary'; '`"; New-Item `"$canary`"; `" `$(New-Item '$canary') " +
    [char]27 + [char]8 + ' ' + [char]0x91CD + [char]0x555F
$restartMessage = '[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'
$notices = @{
    new    = '[restart-session] This session was started by an AI agent through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
    switch = '[restart-session] An AI agent switched this terminal to this session through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
}
function Get-ResumeCommand($kind, $id) {
    @{ claude = "claude --resume $id"; codex = "codex resume $id"; agy = "agy --conversation $id -i" }[$kind]
}
# The only thing that may ever be typed after the per-CLI template in new / switch mode:
# the fixed notice, then "load <random id>.prompt.txt".
function Get-PromptExprPattern($mode) {
    [regex]::Escape("('$($notices[$mode])' + (Get-Content -Raw -Encoding UTF8 -LiteralPath `"`$env:LOCALAPPDATA\restart-session\") +
        '[0-9a-f]{32}' + [regex]::Escape('.prompt.txt")).Replace(''"'', "''")')
}

$n = 0
function New-Config($o, [bool]$restart) {
    $script:n++
    $cfg = Join-Path $work "cfg$n.json"
    $dryOut = Join-Path $work "dry$n.json"
    @{ script = $launcher; mode = $o.mode; prompt = $o.prompt; sessionId = $o.sessionId; ownSession = $o.ownSession
       transcripts = @($o.transcripts); restart = $restart; dryOut = $dryOut } |
        ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $cfg
    @{ cfg = $cfg; dryOut = $dryOut }
}
# Run a stand-in agent of the given kind whose shell tool asks for a dry run; return the plan (or error).
# $o: mode, sessionId, prompt, ownSession (the stand-in's own session record), transcripts (sessions that exist).
function Get-DryRunPlan($kind, $o) {
    $c = New-Config $o $false
    $env:RS_TEST_OUT = ''; $env:RS_TEST_CHILD = $fake; $env:RS_TEST_CONFIG = $c.cfg
    & "$bin\$kind.exe" | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $c.dryOut | ConvertFrom-Json
}
# Really replace a stand-in claude in its own console window; return what the next one was started with.
function Invoke-EndToEnd($o) {
    $mode = $o.mode
    $c = New-Config $o $true
    $out1 = Join-Path $work "before$n.json"
    $out2 = Join-Path $work "after$n.json"
    # Stand-in is first on PATH, so the typed "claude ..." starts it again; after the first one is
    # killed the shell switches the stand-in to "record argv and idle".
    $inner = "`$env:PATH='$bin;'+`$env:PATH; `$env:RS_TEST_CONFIG='$($c.cfg)'; `$env:RS_TEST_OUT='$out1'; " +
             "`$env:RS_TEST_CHILD='$fake'; claude; `$env:RS_TEST_OUT='$out2'; `$env:RS_TEST_CHILD=''"
    Start-Process pwsh -WindowStyle Minimized -ArgumentList "-NoProfile -NoExit -Command `"$inner`"" | Out-Null

    $before = Wait-ForJson $out1 30
    if (-not $before) { throw "stand-in agent never started (no $out1)" }
    $shellPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($before.pid)").ParentProcessId
    $script:shells += $shellPid

    # Out-Host: this function's only pipeline output must be $after.
    $after = Wait-ForJson $out2 60
    Check "$mode`: next agent started" ([bool]$after) "no $out2 after 60s; dry run: $(Get-Content -Raw $c.dryOut -ErrorAction SilentlyContinue)" | Out-Host
    if ($after) {
        $newParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($after.pid)").ParentProcessId
        Check "$mode`: old agent process is gone"  (-not (Get-Process -Id $before.pid -ErrorAction SilentlyContinue)) "pid $($before.pid) still alive" | Out-Host
        Check "$mode`: next agent is a new process" ($after.pid -ne $before.pid) "same pid $($after.pid)" | Out-Host
        Check "$mode`: started by the same shell"   ($newParent -eq $shellPid) "before shell $shellPid, after shell $newParent" | Out-Host
    }
    $after
}
function Show($plan) { "commandLine <$($plan.commandLine)> error <$($plan.error)>" }

$shells = @()
try {
    # ---- A. what gets typed is the fixed template, whatever the caller passes ----
    $newTemplates = @{ claude = 'claude'; codex = 'codex'; agy = 'agy -i' }
    foreach ($kind in 'claude', 'codex', 'agy') {
        $plan = Get-DryRunPlan $kind @{ mode = 'restart'; sessionId = $own }
        Check "$kind restart: typed line is exactly the fixed resume command" `
            ($plan.commandLine -ceq ((Get-ResumeCommand $kind $own) + " '" + $restartMessage + "'")) (Show $plan)

        $plan = Get-DryRunPlan $kind @{ mode = 'new'; prompt = $hostile }
        Check "$kind new: typed line is the fixed template and notice, with nothing from the prompt" `
            ($plan.commandLine -cmatch ('\A' + [regex]::Escape($newTemplates[$kind]) + ' ' + (Get-PromptExprPattern 'new') + '\z')) (Show $plan)

        $plan = Get-DryRunPlan $kind @{ mode = 'switch'; sessionId = $other; prompt = $hostile; ownSession = $own; transcripts = $own, $other }
        Check "$kind switch: typed line is the fixed resume command and notice, with nothing from the prompt" `
            ($plan.commandLine -cmatch ('\A' + [regex]::Escape((Get-ResumeCommand $kind $other)) + ' ' + (Get-PromptExprPattern 'switch') + '\z')) (Show $plan)
    }
    $badIds = [ordered]@{
        'an option'              = '--dangerously-skip-permissions'
        'a command after the id' = "$own; New-Item '$canary'"
        'a trailing newline'     = "$own`n"
        'a subexpression'        = "`$(New-Item '$canary')"
    }
    foreach ($label in $badIds.Keys) {
        foreach ($mode in 'restart', 'switch') {
            $o = @{ mode = $mode; sessionId = $badIds[$label] }
            if ($mode -eq 'switch') { $o.prompt = 'x' }
            $plan = Get-DryRunPlan 'agy' $o
            Check "$mode`: session id that is $label is refused" ($plan.error -match 'session id rejected' -and -not $plan.commandLine) (Show $plan)
        }
    }

    # ---- B. who may say what to which session ----
    $plan = Get-DryRunPlan 'claude' @{ mode = 'restart'; sessionId = $own; prompt = $hostile }
    Check 'restart mode refuses a prompt' ($plan.error -match 'takes no prompt' -and -not $plan.commandLine) (Show $plan)
    # For claude, "restart" must mean this session: its own record wins over whatever id the caller passes.
    $plan = Get-DryRunPlan 'claude' @{ mode = 'restart'; sessionId = $other; ownSession = $own; transcripts = $own, $other }
    Check 'claude restart resumes its own session, not the id the caller passed' `
        ($plan.commandLine -ceq ((Get-ResumeCommand 'claude' $own) + " '" + $restartMessage + "'")) (Show $plan)
    $plan = Get-DryRunPlan 'claude' @{ mode = 'new' }
    Check 'new mode requires an activation prompt' ($plan.error -match 'requires -ActivationPrompt' -and -not $plan.commandLine) (Show $plan)
    $plan = Get-DryRunPlan 'claude' @{ mode = 'switch'; sessionId = $other; ownSession = $own; transcripts = $own, $other }
    Check 'switch mode requires an activation prompt' ($plan.error -match 'requires -ActivationPrompt' -and -not $plan.commandLine) (Show $plan)
    $plan = Get-DryRunPlan 'claude' @{ mode = 'switch'; prompt = 'x'; ownSession = $own; transcripts = $own, $other }
    Check 'switch mode requires a session id' ($plan.error -match 'requires -SessionId' -and -not $plan.commandLine) (Show $plan)
    # Switching to yourself would be a restart that carries a prompt - exactly what restart mode forbids.
    $plan = Get-DryRunPlan 'claude' @{ mode = 'switch'; sessionId = $own; prompt = 'x'; ownSession = $own; transcripts = $own, $other }
    Check 'switch to the session you are in is refused' ($plan.error -match 'needs another session' -and -not $plan.commandLine) (Show $plan)
    # A wrong id must be refused while the agent is still alive, not after it has been killed.
    $missing = [guid]::NewGuid().ToString()
    $plan = Get-DryRunPlan 'claude' @{ mode = 'switch'; sessionId = $missing; prompt = 'x'; ownSession = $own; transcripts = @($own) }
    Check 'switch to a session that does not exist is refused' ($plan.error -match 'no claude session' -and -not $plan.commandLine) (Show $plan)

    # ---- C. real replacement of a stand-in claude, one console window per mode ----
    $after = Invoke-EndToEnd @{ mode = 'restart'; sessionId = $own }
    if ($after) {
        Check 'restart: resumes the same session with the fixed notice' `
            ($after.args.Count -eq 3 -and $after.args[0] -ceq '--resume' -and $after.args[1] -ceq $own -and $after.args[2] -ceq $restartMessage) `
            "argv <$($after.args -join '> <')>"
    }
    $after = Invoke-EndToEnd @{ mode = 'new'; prompt = $hostile }
    if ($after) {
        $expected = ($notices.new + "`n`nStarted by: claude session (id unknown)`nTool: $launcher -Mode new`nHandoff note from that agent:`n`n" + $hostile).Replace('"', "'")
        Check 'new: starts a fresh session (no resume arguments)' (@($after.args).Count -eq 1) "argv <$($after.args -join '> <')>"
        Check 'new: one inert argument - the notice, where it came from, then the hostile prompt' (@($after.args)[0] -ceq $expected) `
            "expected <$expected> got <$(@($after.args)[0])>"
    }
    $after = Invoke-EndToEnd @{ mode = 'switch'; sessionId = $other; prompt = $hostile; ownSession = $own; transcripts = $own, $other }
    if ($after) {
        $expected = ($notices.switch + "`n`nSwitched from: claude session $own`nTool: $launcher -Mode switch`nNote from that agent:`n`n" + $hostile).Replace('"', "'")
        Check 'switch: resumes the other session' ($after.args.Count -eq 3 -and $after.args[0] -ceq '--resume' -and $after.args[1] -ceq $other) "argv <$($after.args -join '> <')>"
        Check 'switch: one inert argument - the notice, which session it came from, then the hostile prompt' ($after.args[2] -ceq $expected) `
            "expected <$expected> got <$($after.args[2])>"
    }
    Check 'nothing from a prompt or session id was executed' (-not (Test-Path $canary)) "$canary was created"
}
finally {
    foreach ($s in $shells) { cmd.exe /c "taskkill /PID $s /T /F >nul 2>&1" }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count) { "`n$($failures.Count) check(s) failed"; exit 1 }
"`nall checks passed"
