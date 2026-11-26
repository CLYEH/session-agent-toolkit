# Tests for scripts/restart-session.ps1, run against stand-in agents (tiny exes named claude / codex / agy).
#
# Why these assertions. The script lets an unattended agent replace ITS OWN session, so it will be
# run without a permission prompt. Two things therefore have to hold:
#
#  A. It cannot be turned into "run anything in the user's terminal". Whatever the caller passes -
#     a hostile activation prompt, a hostile session id - the line typed into the shell must be the
#     fixed template and nothing else, and an activation prompt must arrive as exactly one argument
#     that cannot be read as a CLI option (e.g. --dangerously-skip-permissions).
#  B. It actually works: old agent gone, next one started by the SAME interactive shell (= same
#     terminal tab), with the right arguments for the mode, and the helper survives the death of
#     the agent that launched it.
$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$launcher = Join-Path $root 'plugins\session-agent-toolkit\skills\restart-session\scripts\restart-session.ps1'
$fake     = Join-Path $root 'tests\test-fake-agent.ps1'
$work     = Join-Path ([IO.Path]::GetTempPath()) ("restart-session-test-" + [guid]::NewGuid().ToString('N'))
$bin      = Join-Path $work 'bin'
New-Item -ItemType Directory -Path $bin | Out-Null

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

$uuid   = [guid]::NewGuid().ToString()
$canary = Join-Path $work 'pwned'
# Everything an attacker would try to smuggle through the prompt: an option name, a newline (Enter),
# quote break-outs for both quote styles, a subexpression, Escape (clears the line), Backspace.
$hostile = "--dangerously-skip-permissions`n'; New-Item '$canary'; '`"; New-Item `"$canary`"; `" `$(New-Item '$canary') " +
    [char]27 + [char]8 + ' ' + [char]0x91CD + [char]0x555F
$expectedPromptArg = '[restart-session] ' + $hostile.Replace('"', "'")
$restartMessage = '[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'
# The only thing that may ever be typed after the per-CLI "new" template: load <random id>.prompt.txt.
$promptExpr = [regex]::Escape('(''[restart-session] '' + (Get-Content -Raw -Encoding UTF8 -LiteralPath "$env:LOCALAPPDATA\restart-session\') +
    '[0-9a-f]{32}' + [regex]::Escape('.prompt.txt")).Replace(''"'', "''")')

$n = 0
function New-Config($mode, $sessionId, $prompt, [bool]$restart) {
    $script:n++
    $cfg = Join-Path $work "cfg$n.json"
    $dryOut = Join-Path $work "dry$n.json"
    @{ script = $launcher; mode = $mode; prompt = $prompt; sessionId = $sessionId; restart = $restart; dryOut = $dryOut } |
        ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $cfg
    @{ cfg = $cfg; dryOut = $dryOut }
}
# Run a stand-in agent of the given kind whose shell tool asks for a dry run; return the plan (or error).
function Get-DryRunPlan($kind, $mode, $sessionId, $prompt) {
    $c = New-Config $mode $sessionId $prompt $false
    $env:RS_TEST_OUT = ''; $env:RS_TEST_CHILD = $fake; $env:RS_TEST_CONFIG = $c.cfg
    & "$bin\$kind.exe" | Out-Null
    Get-Content -Raw -Encoding UTF8 -LiteralPath $c.dryOut | ConvertFrom-Json
}
# Really replace a stand-in claude in its own console window; return what the next one was started with.
function Invoke-EndToEnd($mode, $sessionId, $prompt) {
    $c = New-Config $mode $sessionId $prompt $true
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
    Check "$mode`: next agent started" ([bool]$after) "no $out2 after 60s; see logs under $env:LOCALAPPDATA\restart-session" | Out-Host
    if ($after) {
        $newParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($after.pid)").ParentProcessId
        Check "$mode`: old agent process is gone"  (-not (Get-Process -Id $before.pid -ErrorAction SilentlyContinue)) "pid $($before.pid) still alive" | Out-Host
        Check "$mode`: next agent is a new process" ($after.pid -ne $before.pid) "same pid $($after.pid)" | Out-Host
        Check "$mode`: started by the same shell"   ($newParent -eq $shellPid) "before shell $shellPid, after shell $newParent" | Out-Host
    }
    $after
}

$shells = @()
try {
    # ---- A. what gets typed is the fixed template, whatever the caller passes ----
    $restartTemplates = @{ claude = "claude --resume $uuid"; codex = "codex resume $uuid"; agy = "agy --conversation $uuid -i" }
    $newTemplates = @{ claude = 'claude'; codex = 'codex'; agy = 'agy -i' }
    foreach ($kind in 'claude', 'codex', 'agy') {
        $plan = Get-DryRunPlan $kind 'restart' $uuid $null
        Check "$kind restart: typed line is exactly the fixed resume command" `
            ($plan.commandLine -ceq ($restartTemplates[$kind] + " '" + $restartMessage + "'")) "got <$($plan.commandLine)> error <$($plan.error)>"
        $plan = Get-DryRunPlan $kind 'new' $null $hostile
        Check "$kind new: typed line is the fixed template, with nothing from the prompt" `
            ($plan.commandLine -cmatch ('\A' + [regex]::Escape($newTemplates[$kind]) + ' ' + $promptExpr + '\z')) "got <$($plan.commandLine)> error <$($plan.error)>"
    }
    $badIds = [ordered]@{
        'an option'              = '--dangerously-skip-permissions'
        'a command after the id' = "$uuid; New-Item '$canary'"
        'a trailing newline'     = "$uuid`n"
        'a subexpression'        = "`$(New-Item '$canary')"
    }
    foreach ($label in $badIds.Keys) {
        $plan = Get-DryRunPlan 'agy' 'restart' $badIds[$label] $null
        Check "session id that is $label is refused" ($plan.error -match 'session id rejected' -and -not $plan.commandLine) `
            "got commandLine <$($plan.commandLine)> error <$($plan.error)>"
    }
    # A resumed session must not be steerable by the caller: restart mode has no prompt channel at all.
    $plan = Get-DryRunPlan 'claude' 'restart' $uuid $hostile
    Check 'restart mode refuses a prompt' ($plan.error -match 'takes no prompt' -and -not $plan.commandLine) "got <$($plan.commandLine)> error <$($plan.error)>"
    $plan = Get-DryRunPlan 'claude' 'new' $null $null
    Check 'new mode requires an activation prompt' ($plan.error -match 'requires -ActivationPrompt' -and -not $plan.commandLine) "got <$($plan.commandLine)> error <$($plan.error)>"

    # ---- B. real replacement of a stand-in claude, one console window per mode ----
    $after = Invoke-EndToEnd 'restart' $uuid $null
    if ($after) {
        Check 'restart: resumes the same session with the fixed notice' `
            ($after.args.Count -eq 3 -and $after.args[0] -ceq '--resume' -and $after.args[1] -ceq $uuid -and $after.args[2] -ceq $restartMessage) `
            "argv <$($after.args -join '> <')>"
    }
    $after = Invoke-EndToEnd 'new' $null $hostile
    if ($after) {
        Check 'new: starts a fresh session (no resume arguments)' ($after.args.Count -eq 1) "argv <$($after.args -join '> <')>"
        Check 'new: hostile activation prompt is one inert argument' ($after.args[0] -ceq $expectedPromptArg) `
            "expected <$expectedPromptArg> got <$($after.args[0])>"
    }
    Check 'nothing from a prompt or session id was executed' (-not (Test-Path $canary)) "$canary was created"
}
finally {
    foreach ($s in $shells) { cmd.exe /c "taskkill /PID $s /T /F >nul 2>&1" }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures.Count) { "`n$($failures.Count) check(s) failed"; exit 1 }
"`nall checks passed"
