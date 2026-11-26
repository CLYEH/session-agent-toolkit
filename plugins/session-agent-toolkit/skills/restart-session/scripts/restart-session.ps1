<#
.SYNOPSIS
  Restart the agent CLI session (claude / codex / agy) that calls this script, or replace it with
  a brand-new session, in the same terminal. Windows version; see restart-session.sh for macOS/Linux.

.DESCRIPTION
  Called BY the agent, from its shell tool. Returns immediately; a detached helper then
    1. waits -DelaySeconds so the agent can finish its turn,
    2. kills the agent process tree,
    3. types a command into the interactive shell that launched the agent, so the next session
       starts in the same tab.

  -Mode restart (default): resumes the SAME conversation. Its first message is a fixed notice;
                           no prompt is accepted.
  -Mode new:               starts a FRESH conversation whose first message is -ActivationPrompt.

  Safe to run without a permission prompt, because the caller controls very little:
    - it can only replace the session it is running inside (found by walking up the process tree);
    - the typed command is a fixed template per CLI and mode; the only variable part is a session
      id that must be a plain UUID (for claude it is read from claude's own session record);
    - an activation prompt is never typed. It is written to a file and loaded by the typed command
      as a single, prefixed argument, so its content cannot become shell syntax or CLI options.
  The typing itself lives in restart-session-helper.ps1; do not allow-list that file.

  The shell that launched the agent must be PowerShell (pwsh / powershell).
  The next session starts with the CLI's default options (launch flags are not replayed).

.EXAMPLE
  restart-session.ps1                                              # claude: resume this conversation
  restart-session.ps1 -SessionId <uuid>                            # codex / agy: resume this conversation
  restart-session.ps1 -Mode new -ActivationPrompt "Read HANDOFF.md and continue the migration."

.PARAMETER SessionId
  Restart mode only. Session / conversation UUID to resume. Required for codex and agy; ignored
  for claude when its session record is available.

.PARAMETER DryRun
  Print the plan (what would be killed and typed) as JSON and do nothing.
#>
[CmdletBinding()]
param(
    [ValidateSet('restart', 'new')][string]$Mode = 'restart',
    [string]$ActivationPrompt,
    [string]$SessionId,
    [int]$DelaySeconds = 5,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Get-Proc([int]$Id) {
    Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
}

# Parent of a process, or $null if the recorded parent pid is dead or was reused by a younger process.
function Get-ParentProc($Proc) {
    $parent = Get-Proc $Proc.ParentProcessId
    if ($parent -and $parent.CreationDate -le $Proc.CreationDate) { $parent }
}

if ($Mode -eq 'new') {
    if (-not $ActivationPrompt) { throw '-Mode new requires -ActivationPrompt (the first message of the new session)' }
    if ($ActivationPrompt.Length -gt 4000) { throw '-ActivationPrompt is longer than 4000 characters' }
    if ($SessionId) { throw '-SessionId only applies to -Mode restart' }
}
elseif ($ActivationPrompt) {
    throw '-Mode restart takes no prompt: the resumed session gets a fixed restart notice. Use -Mode new to start a fresh session with a prompt.'
}

# Only the session this script is running inside can be replaced.
$agent = Get-Proc $PID
while ($agent -and ('claude.exe', 'codex.exe', 'agy.exe' -notcontains $agent.Name)) { $agent = Get-ParentProc $agent }
if (-not $agent) { throw 'not running inside a claude / codex / agy session (no such ancestor process)' }
$kind = [IO.Path]::GetFileNameWithoutExtension($agent.Name).ToLowerInvariant()

if ($Mode -eq 'restart') {
    # Prefer the CLI's own record of the current session over what the caller passed.
    if ($kind -eq 'claude') {
        $sessionRecord = Join-Path $HOME ".claude\sessions\$($agent.ProcessId).json"
        if (Test-Path -LiteralPath $sessionRecord) {
            $SessionId = (Get-Content -Raw -LiteralPath $sessionRecord | ConvertFrom-Json).sessionId
        }
    }
    elseif (-not $SessionId -and $kind -eq 'codex') { $SessionId = if ($env:CODEX_THREAD_ID) { $env:CODEX_THREAD_ID } else { $env:CODEX_SESSION_ID } }
    elseif (-not $SessionId -and $kind -eq 'agy') { $SessionId = $env:ANTIGRAVITY_CONVERSATION_ID }
    if (-not $SessionId) { throw "-SessionId is required: could not determine the current $kind session id" }
}

if ($kind -eq 'codex') {
    # npm-installed codex runs as node.exe -> codex.exe; the node shim is the process the shell waits on.
    $wrapper = Get-ParentProc $agent
    if ($wrapper -and $wrapper.Name -eq 'node.exe') { $agent = $wrapper }
}

$dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'restart-session'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force

$id = [guid]::NewGuid().ToString('N')
$jobPath = Join-Path $dir "$id.job.json"
$promptPath = Join-Path $dir "$id.prompt.txt"
$written = @($jobPath)
if ($Mode -eq 'new') {
    [IO.File]::WriteAllText($promptPath, $ActivationPrompt, (New-Object Text.UTF8Encoding $false))
    $written += $promptPath
}
@{
    mode         = $Mode
    kind         = $kind
    agentPid     = $agent.ProcessId
    agentCreated = "$($agent.CreationDate.Ticks)"
    sessionId    = $SessionId
    jobId        = $id
    delaySeconds = $DelaySeconds
} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $jobPath

# The helper validates the job and builds the command line; ask it for the plan before committing.
$helper = Join-Path $PSScriptRoot 'restart-session-helper.ps1'
$helperExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$plan = (& $helperExe -NoProfile -NonInteractive -File $helper -JobFile $jobPath -PlanOnly | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $written -Force
    throw "refused: $plan"
}
if ($DryRun) {
    Remove-Item -LiteralPath $written -Force
    $plan
    return
}

# Start the helper through WMI so it is NOT a descendant of the agent: it must survive the tree kill.
$helperCmd = '"{0}" -NoProfile -NonInteractive -File "{1}" -JobFile "{2}"' -f $helperExe, $helper, $jobPath
$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $helperCmd; ProcessStartupInformation = $startup
}
if ($created.ReturnValue -ne 0) { throw "could not start the helper process (Win32_Process.Create returned $($created.ReturnValue))" }

if ($Mode -eq 'new') { "A new session replaces this one in $DelaySeconds s. End your turn now - do not start more work." }
else { "This session restarts in $DelaySeconds s. End your turn now - do not start more work." }
$plan
"log: " + (Join-Path $dir "$id.log")
