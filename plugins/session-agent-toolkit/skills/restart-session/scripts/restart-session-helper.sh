#!/usr/bin/env bash
# Internal second stage of restart-session.sh. Do not call directly and do not allow-list.
#
# Runs detached from the agent (own session). After the delay it stops the agent and types the
# next command into the shell that launched it.
#
# This file owns everything that ends up on the user's command line, so that the typed text is
# never caller-controlled: a fixed template per CLI and mode, plus a UUID (restart, switch) and/or
# a random file id (new, switch). An activation prompt is read from a file by the typed command
# itself; it is never typed.
#
# Typing into a terminal from outside has no universal mechanism on macOS/Linux. Supported:
# tmux (any OS) and, on macOS, Terminal.app (through AppleScript).
set -euo pipefail

plan_only=0
if [ "${1-}" = "--plan-only" ]; then plan_only=1; shift; fi   # validate and print the plan; stop nothing, type nothing

# First message of a resumed session. Fixed text: the resumed session can already see, in its own
# history, that it asked for the restart. Must stay free of quote characters (it is typed inside '...').
RESTART_MESSAGE='[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'
# First words of a new session's first message. Fixed text, typed as part of the command, so the
# caller cannot remove or reword it: the new session must not mistake an agent's handoff note for
# something the user typed. Must stay free of quote characters, $, ` and ! (it is typed inside "...").
NEW_SESSION_NOTICE='[restart-session] This session was started by an AI agent through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
SWITCH_NOTICE='[restart-session] An AI agent switched this terminal to this session through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
STATE_DIR="$HOME/.local/state/restart-session"
log=""

die() {
    if [ -n "$log" ]; then printf '%s FAILED: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$log"; fi
    printf '%s\n' "$*" >&2
    exit 1
}
logmsg() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$log"; }

[ $# -eq 7 ] || die "usage: restart-session-helper.sh [--plan-only] MODE KIND AGENT_PID AGENT_START SESSION_ID JOB_ID DELAY"
mode=$1; kind=$2; agent_pid=$3; agent_start=$4; session_id=$5; job_id=$6; delay=$7

trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
proc_name() {   # basename of the executable; login shells show up as "-zsh"
    local n; n=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    n=$(trim "$n"); [ -n "$n" ] || return 1
    n=${n##*/}; printf '%s' "${n#-}"
}
proc_arg0() {   # basename of argv[0]
    local a; a=$(ps -o args= -p "$1" 2>/dev/null) || return 1
    a=$(trim "$a"); a=${a%% *}; a=${a##*/}; printf '%s' "${a#-}"
}
# Which agent CLI a process is, if any. The executable name alone is not enough: a CLI installed
# as a versioned binary behind a symlink can report the version as its name, and one that runs on
# node reports "node" unless it renamed itself - so argv[0] is checked as well.
agent_kind() {
    local n
    for n in "$(proc_name "$1" || true)" "$(proc_arg0 "$1" || true)"; do
        case "$n" in claude|codex|agy) printf '%s' "$n"; return 0 ;; esac
    done
    return 1
}
proc_ppid()  { trim "$(ps -o ppid= -p "$1" 2>/dev/null)"; }
proc_start() { trim "$(ps -o lstart= -p "$1" 2>/dev/null)"; }
proc_tty()   { trim "$(ps -o tty= -p "$1" 2>/dev/null)"; }
json_str()   { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# Terminal.app: find the tab that owns tty $1; if $2 is not empty, run it there as if typed.
# Prints "found" or "missing". The timeout keeps an unanswered macOS permission dialog from hanging us.
terminal_app() {
    osascript - "$1" "$2" 2>&1 <<'APPLESCRIPT'
on run argv
    set theTty to item 1 of argv
    set theText to item 2 of argv
    with timeout of 15 seconds
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is theTty then
                        if theText is not "" then do script theText in t
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
    end timeout
    return "missing"
end run
APPLESCRIPT
}

# The regexes have no multi-line mode: a value with a newline in it (= Enter, once typed) never matches.
uuid_re='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
jobid_re='^[0-9a-f]{32}$'
num_re='^[0-9]+$'
pane_re='^%[0-9]+$'

case "$mode" in restart|new|switch) ;; *) die "unknown mode '$mode'" ;; esac
case "$kind" in claude|codex|agy) ;; *) die "unknown agent kind '$kind'" ;; esac
[[ $job_id =~ $jobid_re ]] || die 'job id rejected'
[[ $agent_pid =~ $num_re ]] || die 'agent pid rejected'
{ [[ $delay =~ $num_re ]] && [ "$delay" -ge 1 ] && [ "$delay" -le 600 ]; } || die 'delay must be between 1 and 600 seconds'
if [ "$mode" != new ]; then
    [[ $session_id =~ $uuid_re ]] || die 'session id rejected: it must be a plain UUID'
fi

# Sets shell_pid, shell_name, agent_name, terminal, pane, cmd - or dies.
make_plan() {
    agent_name=$(proc_name "$agent_pid") || die "agent pid $agent_pid is gone"
    [ "$(proc_start "$agent_pid")" = "$agent_start" ] || die "agent pid $agent_pid is no longer the same process"
    if [ "$(agent_kind "$agent_pid" || true)" != "$kind" ] && [ "$kind:$agent_name" != "codex:node" ]; then
        die "pid $agent_pid is $agent_name, not a $kind session"
    fi

    shell_pid=$(proc_ppid "$agent_pid")
    shell_name=$(proc_name "$shell_pid") || die "the process that launched $agent_name is gone; nowhere to type the next command"
    case "$shell_name" in
        bash|zsh|fish|sh|dash|ksh) ;;
        *) die "$agent_name was launched by $shell_name, not by a shell" ;;
    esac

    local tty; tty=$(proc_tty "$shell_pid")
    case "$tty" in ''|'?'|'??') die "the shell that launched $agent_name has no terminal" ;; esac
    tty_dev="/dev/$tty"
    # Where to type is decided by who owns the shell's tty - never by anything the caller passes.
    terminal=""; pane=""
    if command -v tmux >/dev/null 2>&1; then
        pane=$(tmux list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null | awk -v t="$tty_dev" '$1 == t { print $2; exit }') || true
    fi
    if [[ $pane =~ $pane_re ]]; then
        terminal="tmux $pane"
    # pgrep -a: macOS pgrep skips its own ancestors by default, and Terminal.app is one of ours.
    elif [ "$(uname -s)" = Darwin ] && pgrep -a -x Terminal >/dev/null 2>&1; then
        local found; found=$(terminal_app "$tty_dev" "") || true
        case "$found" in
            found) terminal="Terminal.app" ;;
            missing) ;;
            *) die "could not ask Terminal.app for its tabs (is automation permission granted?): $found" ;;
        esac
    fi
    [ -n "$terminal" ] || die "cannot type into this terminal ($tty_dev): supported are tmux and, on macOS, Terminal.app"

    if [ "$mode" = new ]; then
        case "$kind" in
            claude) cmd="claude" ;;
            codex)  cmd="codex" ;;
            agy)    cmd="agy -i" ;;
        esac
    else   # restart and switch: the same resume command, aimed at this session or at another one
        case "$kind" in
            claude) cmd="claude --resume $session_id" ;;
            codex)  cmd="codex resume $session_id" ;;
            agy)    cmd="agy --conversation $session_id -i" ;;
        esac
    fi
    if [ "$mode" = restart ]; then
        cmd="$cmd '$RESTART_MESSAGE'"
    else
        local notice=$NEW_SESSION_NOTICE
        if [ "$mode" = switch ]; then notice=$SWITCH_NOTICE; fi
        # The activation prompt is loaded by the user's shell from a file, inside double quotes, so
        # it is handed over as ONE argument and is never re-read as shell syntax. The fixed notice
        # in front also means it can never start with '-' and be parsed as a CLI option.
        cmd="$cmd \"$notice\$(cat \"\$HOME/.local/state/restart-session/$job_id.prompt.txt\")\""
    fi
}

if [ "$plan_only" = 1 ]; then
    make_plan
    printf '{\n  "mode": %s,\n  "kind": %s,\n  "agent": %s,\n  "agentPid": %s,\n  "shell": %s,\n  "shellPid": %s,\n  "terminal": %s,\n  "commandLine": %s\n}\n' \
        "$(json_str "$mode")" "$(json_str "$kind")" "$(json_str "$agent_name")" "$agent_pid" \
        "$(json_str "$shell_name")" "$shell_pid" "$(json_str "$terminal")" "$(json_str "$cmd")"
    exit 0
fi

mkdir -p "$STATE_DIR"
log="$STATE_DIR/$job_id.log"
logmsg "helper started; waiting ${delay}s"
sleep "$delay"
make_plan

descendants() { local p; for p in $(pgrep -P "$1" 2>/dev/null || true); do printf '%s\n' "$p"; descendants "$p"; done; }
children=$(descendants "$agent_pid")

kill -TERM "$agent_pid" 2>/dev/null || true
waited=0
while kill -0 "$agent_pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -eq 50 ]; then logmsg "agent ignored SIGTERM; sending SIGKILL"; kill -KILL "$agent_pid" 2>/dev/null || true; fi
    [ "$waited" -lt 100 ] || die "agent pid $agent_pid did not exit"
    sleep 0.2
done
for p in $children; do kill -TERM "$p" 2>/dev/null || true; done
logmsg "agent pid $agent_pid stopped"

kill -0 "$shell_pid" 2>/dev/null || die "shell pid $shell_pid is gone; nothing typed"
sleep 1.5   # let the shell get back to its prompt

if [ "$terminal" = "Terminal.app" ]; then
    typed=$(terminal_app "$tty_dev" "$cmd") || true
    [ "$typed" = found ] || die "Terminal.app did not accept the command: $typed"
else
    tmux send-keys -t "$pane" C-u             # clear anything already sitting on the input line
    tmux send-keys -t "$pane" -l -- "$cmd"
    tmux send-keys -t "$pane" Enter
fi
logmsg "typed into $terminal: $cmd"
