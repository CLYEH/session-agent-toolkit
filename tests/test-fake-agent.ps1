# Plays the agent's shell tool in test-restart-session.ps1: it runs as a child of a stand-in
# claude.exe / codex.exe / agy.exe and calls restart-session.ps1 the way a real agent would.
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -Encoding UTF8 -LiteralPath $env:RS_TEST_CONFIG | ConvertFrom-Json
$me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$common = @{ Mode = $cfg.mode; DelaySeconds = 1 }
if ($cfg.prompt) { $common.ActivationPrompt = $cfg.prompt }
if ($cfg.sessionId) { $common.SessionId = $cfg.sessionId }

try { $dry = (& $cfg.script @common -DryRun | Out-String).Trim() }
catch { $dry = @{ error = "$_" } | ConvertTo-Json }
Set-Content -Encoding UTF8 -LiteralPath $cfg.dryOut -Value $dry

# Safety: go on only if the script targets the stand-in that launched us. If the stand-in were
# somehow missed, auto-detection would climb to the real agent session running this test.
if ($cfg.restart -and ($dry | ConvertFrom-Json).agentPid -eq $me.ParentProcessId) {
    & $cfg.script @common | Out-Host
    Start-Sleep -Seconds 600
}
