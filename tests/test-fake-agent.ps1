# Plays the agent's shell tool in test-restart-session.ps1: it runs as a child of a stand-in
# claude.exe / codex.exe / agy.exe and calls restart-session.ps1 the way a real agent would.
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $env:RS_TEST_CONFIG | ConvertFrom-Json
$me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"

# Optionally play Claude Code's own bookkeeping (in the test's CLAUDE_CONFIG_DIR): the per-process
# record of which session the stand-in is, and transcripts of sessions that exist in its project.
if ($cfg.ownSession) {
    New-Item -ItemType Directory -Force -Path "$env:CLAUDE_CONFIG_DIR\sessions" | Out-Null
    @{ sessionId = $cfg.ownSession } | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath "$env:CLAUDE_CONFIG_DIR\sessions\$($me.ParentProcessId).json"
}
foreach ($t in @($cfg.transcripts)) {
    if ($t) {
        New-Item -ItemType Directory -Force -Path "$env:CLAUDE_CONFIG_DIR\projects\proj" | Out-Null
        Set-Content -LiteralPath "$env:CLAUDE_CONFIG_DIR\projects\proj\$t.jsonl" -Value '{}'
    }
}
# Variables a CLI hands to its tools (codex and agy report the current session this way).
if ($cfg.env) { foreach ($p in $cfg.env.PSObject.Properties) { Set-Item -Path "env:$($p.Name)" -Value $p.Value } }

# Optionally play a misled agent: point OUR environment (the script's caller) at a decoy record
# that claims the stand-in is a different session.
if ($cfg.decoySession) {
    $decoy = "$env:CLAUDE_CONFIG_DIR-decoy"
    New-Item -ItemType Directory -Force -Path "$decoy\sessions", "$decoy\projects\proj" | Out-Null
    @{ sessionId = $cfg.decoySession } | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath "$decoy\sessions\$($me.ParentProcessId).json"
    Set-Content -LiteralPath "$decoy\projects\proj\$($cfg.decoySession).jsonl" -Value '{}'
    $env:CLAUDE_CONFIG_DIR = $decoy
}

$common = @{ Mode = $cfg.mode; DelaySeconds = 1 }
if ($cfg.prompt) { $common.ActivationPrompt = $cfg.prompt }
if ($cfg.sessionId) { $common.SessionId = $cfg.sessionId }

try { $dry = (& $cfg.script @common -DryRun | Out-String).Trim() }
catch { $dry = @{ error = "$_" } | ConvertTo-Json }
Set-Content -Encoding UTF8 -LiteralPath $cfg.dryOut -Value $dry

# Safety: go on only if the script targets the stand-in that launched us. If the stand-in were
# somehow missed, auto-detection would climb to the real agent session running this test.
if ($cfg.restart -and ($dry | ConvertFrom-Json).agentPid -eq $me.ParentProcessId) {
    # What the script prints is what the calling session would see in its tool output.
    & $cfg.script @common | Tee-Object -FilePath "$($cfg.dryOut).run" | Out-Host
    Start-Sleep -Seconds 600
}
