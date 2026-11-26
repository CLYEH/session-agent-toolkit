#!/usr/bin/env bash
# Restart the agent CLI session (claude / codex / agy) that calls this script, or replace it with a
# brand-new session, in the same terminal. macOS/Linux version; see restart-session.ps1 for Windows.
#
#   restart-session.sh                                   # claude: resume this conversation
#   restart-session.sh --session-id <uuid>               # codex / agy: resume this conversation
#   restart-session.sh --mode new --activation-prompt "Read HANDOFF.md and continue the migration."
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
#
# Safe to run without a permission prompt, because the caller controls very little:
#   - it can only replace the session it is running inside (found by walking up the process tree);
#   - the typed command is a fixed template per CLI and mode; the only variable part is a session id
#     that must be a plain UUID (for claude it is read from claude's own session record);
#   - an activation prompt is never typed. It is written to a file and loaded by the typed command
#     as a single, prefixed argument, so its content cannot become shell syntax or CLI options.
# The typing itself lives in restart-session-helper.sh; do not allow-list that file.
#
# Requires the session to be running inside tmux (see the helper for why).
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

case "$mode" in
    new)
        [ -n "$prompt" ] || die "--mode new requires --activation-prompt (the first message of the new session)"
        [ "${#prompt}" -le 4000 ] || die "--activation-prompt is longer than 4000 characters"
        [ -z "$session_id" ] || die "--session-id only applies to --mode restart"
        ;;
    restart)
        [ -z "$prompt" ] || die "--mode restart takes no prompt: the resumed session gets a fixed restart notice. Use --mode new to start a fresh session with a prompt."
        ;;
    *) die "--mode must be restart or new" ;;
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
own_session=""
case "$kind" in
    claude)
        if [ -f "$HOME/.claude/sessions/$agent_pid.json" ]; then
            own_session=$(sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.claude/sessions/$agent_pid.json" | head -n 1)
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
if [ "$mode" = new ]; then
    # Tell the new session where it came from. This continues the fixed notice the helper types in
    # front (which says an agent, not the user, wrote what follows).
    uuid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if [[ $own_session =~ $uuid_re ]]; then origin="$kind session $own_session"; else origin="$kind session (id unknown)"; fi
    printf '\n\nStarted by: %s\nTool: %s --mode new\nHandoff note from that agent:\n\n%s' \
        "$origin" "$here/restart-session.sh" "$prompt" > "$prompt_file"
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

if [ "$mode" = new ]; then
    echo "A new session replaces this one in $delay s. End your turn now - do not start more work."
else
    echo "This session restarts in $delay s. End your turn now - do not start more work."
fi
printf '%s\n' "$plan"
echo "log: $state_dir/$job_id.log"
