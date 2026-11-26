#!/usr/bin/env bash
# Tests for scripts/restart-session.sh, run against stand-in agents (scripts named claude / codex / agy).
# Must run inside a terminal the script can type into: a tmux pane (tests/run-in-tmux.sh) or, with
# RS_TEST_TERMINAL=terminal-app, a macOS Terminal.app tab (tests/run-in-terminal-app.sh).
#
# Why these assertions. The script lets an unattended agent replace ITS OWN session, so it will be
# run without a permission prompt. Two things therefore have to hold:
#
#  A. It cannot be turned into "run anything in the user's terminal". Whatever the caller passes -
#     a hostile activation prompt, a hostile session id - the line typed into the shell must be the
#     fixed template and nothing else, and an activation prompt must arrive as exactly one argument
#     that cannot be read as a CLI option (e.g. --dangerously-skip-permissions).
#  B. It actually works: old agent gone, next one started by the SAME interactive shell (= same
#     terminal), with the right arguments for the mode, and the helper survives the death of the
#     agent that launched it.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$root/plugins/session-agent-toolkit/skills/restart-session/scripts/restart-session.sh"
fake="$root/tests/test-fake-agent.sh"
work=$(mktemp -d)
bin="$work/bin"; mkdir -p "$bin"
failures=0
check() { if [ "$2" = 0 ]; then echo "PASS  $1"; else echo "FAIL  $1  -- $3"; failures=$((failures + 1)); fi; }
json_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# --- stand-in agent: records its pid + argv, then runs the fake shell tool or idles like a TUI ---
cat > "$bin/claude" <<'EOF'
#!/bin/bash
if [ -n "${RS_TEST_OUT-}" ]; then
    printf '%s\0' "$@" > "$RS_TEST_OUT.args"
    echo $$ > "$RS_TEST_OUT"
fi
if [ -n "${RS_TEST_CHILD-}" ]; then bash "$RS_TEST_CHILD"; else sleep 600; fi
EOF
chmod +x "$bin/claude"; cp "$bin/claude" "$bin/codex"; cp "$bin/claude" "$bin/agy"

uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z')
canary="$work/pwned"
# Everything an attacker would try to smuggle through the prompt: an option name, a newline (Enter),
# quote break-outs for both quote styles, command substitutions, Escape, Backspace, a backslash.
hostile=$(printf -- "--dangerously-skip-permissions\n'; touch '%s'; '\"; touch \"%s\"; \" \$(touch '%s') \`touch %s\` \033\010 \\\\ \xe9\x87\x8d\xe5\x95\x9f" "$canary" "$canary" "$canary" "$canary")
printf '%s' "$hostile" > "$work/hostile.txt"
restart_message='[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'

# Run a stand-in agent of the given kind whose shell tool asks for a dry run; the output lands in $dry.
n=0
dry_run() {   # kind mode sid_file prompt_file
    n=$((n + 1)); dry="$work/dry$n.txt"
    RS_TEST_SCRIPT="$launcher" RS_TEST_MODE="$2" RS_TEST_SID_FILE="$3" RS_TEST_PROMPT_FILE="$4" \
        RS_TEST_DRYOUT="$dry" RS_TEST_CHILD="$fake" RS_TEST_OUT="" "$bin/$1" > /dev/null 2>&1
}
wait_for() { local i=0; while [ ! -s "$1" ] && [ $i -lt "$2" ]; do sleep 0.25; i=$((i + 1)); done; [ -s "$1" ]; }

# ---- A. what gets typed is the fixed template, whatever the caller passes ----
printf '%s' "$uuid" > "$work/sid.txt"
for kind in claude codex agy; do
    case "$kind" in
        claude) resume="claude --resume $uuid"; fresh="claude" ;;
        codex)  resume="codex resume $uuid";    fresh="codex" ;;
        agy)    resume="agy --conversation $uuid -i"; fresh="agy -i" ;;
    esac
    dry_run "$kind" restart "$work/sid.txt" ""
    grep -qF -- "\"commandLine\": $(json_str "$resume '$restart_message'")" "$dry"
    check "$kind restart: typed line is exactly the fixed resume command" $? "got: $(cat "$dry")"

    dry_run "$kind" new "" "$work/hostile.txt"
    # The only thing that may follow the template: load <random id>.prompt.txt inside double quotes.
    expected_re="^  \"commandLine\": \"$fresh \\\\\"\\[restart-session\\] \\\$\\(cat \\\\\"\\\$HOME/\\.local/state/restart-session/[0-9a-f]{32}\\.prompt\\.txt\\\\\"\\)\\\\\"\"\$"
    grep -qE -- "$expected_re" "$dry"
    check "$kind new: typed line is the fixed template, with nothing from the prompt" $? "got: $(cat "$dry")"
done

bad_id() {   # label, session id bytes (printf format)
    printf -- "$2" > "$work/bad.txt"
    dry_run agy restart "$work/bad.txt" ""
    grep -q 'session id rejected' "$dry" && ! grep -q commandLine "$dry"
    check "session id that is $1 is refused" $? "got: $(cat "$dry")"
}
bad_id 'an option'              '--dangerously-skip-permissions'
bad_id 'a command after the id' "$uuid; touch '$canary'"
bad_id 'a trailing newline'     "$uuid\n"
bad_id 'a substitution'         "\$(touch '$canary')"

# A resumed session must not be steerable by the caller: restart mode has no prompt channel at all.
dry_run claude restart "$work/sid.txt" "$work/hostile.txt"
grep -q 'takes no prompt' "$dry" && ! grep -q commandLine "$dry"
check 'restart mode refuses a prompt' $? "got: $(cat "$dry")"
dry_run claude new "" ""
grep -q 'requires --activation-prompt' "$dry" && ! grep -q commandLine "$dry"
check 'new mode requires an activation prompt' $? "got: $(cat "$dry")"

# ---- B. real replacement of a stand-in claude, one new interactive shell per mode ----
terminal=${RS_TEST_TERMINAL:-tmux}
# Open a new interactive shell in the terminal under test and type one line into it.
open_shell() {   # name line
    if [ "$terminal" = terminal-app ]; then
        osascript - "$2" > /dev/null <<'APPLESCRIPT'
on run argv
    tell application "Terminal" to do script (item 1 of argv)
end run
APPLESCRIPT
    else
        tmux new-window -d -n "$1" "exec bash --norc --noprofile -i"
        tmux send-keys -t "$1" -l -- "$2"
        tmux send-keys -t "$1" Enter
    fi
}
end_to_end() {   # mode sid_file prompt_file
    n=$((n + 1)); local out1="$work/before$n" out2="$work/after$n" win="rs-test-$n"
    after_args="$out2.args"
    # Stand-in is first on PATH, so the typed "claude ..." starts it again; once the first one has been
    # stopped, the shell switches the stand-in to "record argv and idle".
    open_shell "$win" "export PATH='$bin':\"\$PATH\"; RS_TEST_SCRIPT='$launcher' RS_TEST_MODE=$1 RS_TEST_SID_FILE='$2' RS_TEST_PROMPT_FILE='$3' RS_TEST_DRYOUT='$work/dry-e2e-$n.txt' RS_TEST_RESTART=1 RS_TEST_CHILD='$fake' RS_TEST_OUT='$out1' claude; export RS_TEST_OUT='$out2'"

    wait_for "$out1" 80 || { check "$1: stand-in agent started" 1 "no $out1"; return 1; }
    local old_pid shell_pid new_pid
    old_pid=$(cat "$out1"); shell_pid=$(ps -o ppid= -p "$old_pid" | tr -d ' ')

    wait_for "$out2" 160
    check "$1: next agent started" $? "no $out2; logs: $(cat "$HOME"/.local/state/restart-session/*.log 2>/dev/null | tail -n 5)" || return 1
    [ -s "$out2" ] || return 1
    new_pid=$(cat "$out2")
    ! kill -0 "$old_pid" 2>/dev/null;                                   check "$1: old agent process is gone" $? "pid $old_pid still alive"
    [ "$new_pid" != "$old_pid" ];                                       check "$1: next agent is a new process" $? "same pid $new_pid"
    [ "$(ps -o ppid= -p "$new_pid" | tr -d ' ')" = "$shell_pid" ];      check "$1: started by the same shell" $? "before shell $shell_pid, after $(ps -o ppid= -p "$new_pid")"
    if [ "$terminal" = tmux ]; then tmux kill-window -t "$win"; fi
}

if end_to_end restart "$work/sid.txt" ""; then
    printf '%s\0' --resume "$uuid" "$restart_message" | cmp -s - "$after_args"
    check 'restart: resumes the same session with the fixed notice' $? "argv: $(tr '\0' '|' < "$after_args")"
fi
if end_to_end new "" "$work/hostile.txt"; then
    printf '%s\0' "[restart-session] $hostile" | cmp -s - "$after_args"
    check 'new: fresh session whose only argument is the inert hostile prompt' $? "argv: $(tr '\0' '|' < "$after_args" | od -c | head -n 12)"
fi
[ ! -e "$canary" ]; check 'nothing from a prompt or session id was executed' $? "$canary was created"

rm -rf "$work"
if [ "$failures" -gt 0 ]; then printf '\n%s check(s) failed\n' "$failures"; exit 1; fi
printf '\nall checks passed\n'
