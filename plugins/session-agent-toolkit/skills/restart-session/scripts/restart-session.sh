#!/usr/bin/env bash
# Restart the agent CLI session (claude / codex / agy) that calls this script, replace it with a
# brand-new session, or switch to another existing session - in the same terminal.
# macOS/Linux version; see restart-session.ps1 for Windows.
#
#   restart-session.sh                                   # claude: resume this conversation
#   restart-session.sh --session-id <uuid>               # codex / agy: resume this conversation
#   restart-session.sh --mode new --activation-prompt "Read HANDOFF.md and continue the migration."
#   restart-session.sh --mode switch --session-id <uuid> --activation-prompt "Subtask done; results are in RESULT.md."
#   ... --delay-seconds N   seconds to wait before stopping the agent (default 5)
#   ... --dry-run           print the plan (what would be stopped and typed) and do nothing
#
# Called BY the agent, from its shell tool. Returns immediately; a detached helper then waits so the
# agent can finish its turn, stops the agent, and types a command into the shell that launched it,
# so the next session starts in the same terminal.
#
#   --mode restart (default): resumes the SAME conversation. Its first message is a fixed notice;
#                             no prompt is accepted.
#   --mode new:               starts a FRESH conversation whose first message is --activation-prompt.
#   --mode switch:            resumes ANOTHER existing conversation (--session-id) and gives it
#                             --activation-prompt as its next message.
#
# Safe to run without a permission prompt, because the caller controls very little:
#   - it can only replace the session it is running inside (found by walking up the process tree);
#   - the typed command is a fixed template per CLI and mode; the only variable part is a session id
#     that must be a plain UUID (in restart mode claude's id is read from its own session record);
#   - an activation prompt is never typed. It is written to a file and loaded by the typed command
#     as a single argument behind a fixed notice, so its content cannot become shell syntax or CLI
#     options, and the receiving session is told that an agent, not the user, wrote it.
# The typing itself lives in restart-session-helper.sh; do not allow-list that file.
#
# The session must be running inside tmux or, on macOS, in Terminal.app (see the helper for why).
# The next session starts with the CLI's default options (launch flags are not replayed).
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

mode=restart; prompt=""; session_id=""; delay=5; dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)              [ $# -ge 2 ] || die "--mode needs a value"; mode=$2; shift 2 ;;
        --activation-prompt) [ $# -ge 2 ] || die "--activation-prompt needs a value"; prompt=$2; shift 2 ;;
        --session-id)        [ $# -ge 2 ] || die "--session-id needs a value"; session_id=$2; shift 2 ;;
        --delay-seconds)     [ $# -ge 2 ] || die "--delay-seconds needs a value"; delay=$2; shift 2 ;;
        --dry-run)           dry_run=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

uuid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

case "$mode" in
    restart)
        [ -z "$prompt" ] || die "--mode restart takes no prompt: the resumed session gets a fixed restart notice. Use --mode new to start a fresh session with a prompt."
        ;;
    new|switch)
        [ -n "$prompt" ] || die "--mode $mode requires --activation-prompt (the first message the next session receives)"
        [ "${#prompt}" -le 4000 ] || die "--activation-prompt is longer than 4000 characters"
        if [ "$mode" = new ]; then
            [ -z "$session_id" ] || die "--session-id does not apply to --mode new"
        else
            [ -n "$session_id" ] || die "--mode switch requires --session-id (the session to switch to)"
            [[ $session_id =~ $uuid_re ]] || die "session id rejected: it must be a plain UUID"
        fi
        ;;
    *) die "--mode must be restart, new or switch" ;;
esac

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
proc_name() {
    local n; n=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    n=$(trim "$n"); [ -n "$n" ] || return 1
    n=${n##*/}; printf '%s' "${n#-}"
}
proc_arg0() {
    local a; a=$(ps -o args= -p "$1" 2>/dev/null) || return 1
    a=$(trim "$a"); a=${a%% *}; a=${a##*/}; printf '%s' "${a#-}"
}
# Which agent CLI a process is, if any (executable name or argv[0]; see the helper for why both).
agent_kind() {
    local n
    for n in "$(proc_name "$1" || true)" "$(proc_arg0 "$1" || true)"; do
        case "$n" in claude|codex|agy) printf '%s' "$n"; return 0 ;; esac
    done
    return 1
}
proc_ppid()  { trim "$(ps -o ppid= -p "$1" 2>/dev/null)"; }
proc_start() { trim "$(ps -o lstart= -p "$1" 2>/dev/null)"; }

# Only the session this script is running inside can be replaced.
agent_pid=$$; kind=""
while [ -n "$agent_pid" ] && [ "$agent_pid" -gt 1 ]; do
    if kind=$(agent_kind "$agent_pid"); then break; fi
    kind=""; agent_pid=$(proc_ppid "$agent_pid")
done
[ -n "$kind" ] || die "not running inside a claude / codex / agy session (no such ancestor process)"

# What the CLI itself says the current session is, when it says so.
claude_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
own_session=""
case "$kind" in
    claude)
        if [ -f "$claude_dir/sessions/$agent_pid.json" ]; then
            own_session=$(sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$claude_dir/sessions/$agent_pid.json" | head -n 1)
        fi ;;
    codex) own_session=${CODEX_THREAD_ID:-${CODEX_SESSION_ID-}} ;;
    agy)   own_session=${ANTIGRAVITY_CONVERSATION_ID-} ;;
esac

if [ "$mode" = restart ]; then
    # claude keeps a per-process record, which beats what the caller passed; for the others the
    # environment is only a fallback.
    if [ "$kind" = claude ] && [ -n "$own_session" ]; then session_id=$own_session; fi
    [ -n "$session_id" ] || session_id=$own_session
    [ -n "$session_id" ] || die "--session-id is required: could not determine the current $kind session id"
elif [ "$mode" = switch ]; then
    # Switching to yourself would be a restart with a prompt, which restart mode deliberately has not.
    if [ -n "$own_session" ] && [ "$session_id" = "$own_session" ]; then
        die "--mode switch needs another session: that id is the session you are in. Use --mode restart to restart it."
    fi
    if [ "$kind" = claude ]; then
        # claude can only resume a session from the project it belongs to. Refuse now, while this
        # session is still alive, rather than leave the terminal with a failed command and no agent.
        found=0; own_project=""
        if [ -n "$own_session" ]; then
            for d in "$claude_dir"/projects/*/; do
                if [ -f "$d$own_session.jsonl" ]; then own_project=$d; break; fi
            done
        fi
        for d in "$claude_dir"/projects/*/; do
            if [ -n "$own_project" ] && [ "$d" != "$own_project" ]; then continue; fi
            if [ -f "$d$session_id.jsonl" ]; then found=1; break; fi
        done
        [ "$found" = 1 ] || die "no claude session $session_id to switch to in this project"
    fi
fi

if [ "$kind" = codex ]; then
    # npm-installed codex runs as node -> codex; the node shim is the process the shell waits on.
    wrapper=$(proc_ppid "$agent_pid")
    if [ "$(proc_name "$wrapper" || true)" = node ]; then agent_pid=$wrapper; fi
fi

state_dir="$HOME/.local/state/restart-session"
mkdir -p "$state_dir"; chmod 700 "$state_dir"
find "$state_dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null || true

job_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
prompt_file="$state_dir/$job_id.prompt.txt"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$mode" != restart ]; then
    # Tell the receiving session where this came from. It continues the fixed notice the helper
    # types in front (which says an agent, not the user, wrote what follows).
    if [[ $own_session =~ $uuid_re ]]; then origin="$kind session $own_session"; else origin="$kind session (id unknown)"; fi
    if [ "$mode" = new ]; then
        printf '\n\nStarted by: %s\nTool: %s --mode new\nHandoff note from that agent:\n\n%s' \
            "$origin" "$here/restart-session.sh" "$prompt" > "$prompt_file"
    else
        printf '\n\nSwitched from: %s\nTool: %s --mode switch\nNote from that agent:\n\n%s' \
            "$origin" "$here/restart-session.sh" "$prompt" > "$prompt_file"
    fi
fi

# The helper validates everything and builds the command line; ask it for the plan before committing.
helper="$here/restart-session-helper.sh"
set -- "$mode" "$kind" "$agent_pid" "$(proc_start "$agent_pid")" "$session_id" "$job_id" "$delay"
if ! plan=$(bash "$helper" --plan-only "$@" 2>&1); then
    rm -f "$prompt_file"
    die "refused: $plan"
fi
if [ "$dry_run" = 1 ]; then
    rm -f "$prompt_file"
    printf '%s\n' "$plan"
    exit 0
fi

# Detach the helper into its own session: it must outlive the agent and whatever the agent cleans up on exit.
if command -v setsid >/dev/null 2>&1; then
    ( setsid bash "$helper" "$@" </dev/null >/dev/null 2>&1 & )
elif command -v perl >/dev/null 2>&1; then
    ( perl -MPOSIX -e 'setsid(); exec @ARGV or die' bash "$helper" "$@" </dev/null >/dev/null 2>&1 & )
else
    rm -f "$prompt_file"
    die "cannot detach the helper: neither setsid nor perl is available"
fi

case "$mode" in
    new)    echo "A new session replaces this one in $delay s. End your turn now - do not start more work." ;;
    switch) echo "This terminal switches to session $session_id in $delay s. End your turn now - do not start more work." ;;
    *)      echo "This session restarts in $delay s. End your turn now - do not start more work." ;;
esac
printf '%s\n' "$plan"
echo "log: $state_dir/$job_id.log"
