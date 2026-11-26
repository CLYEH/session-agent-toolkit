#!/usr/bin/env bash
# Tests for restart-session.sh, run against stand-in agents (scripts named claude / codex / agy).
# Must run inside a terminal the script can type into: a tmux pane (tests/run-in-tmux.sh) or, with
# RS_TEST_TERMINAL=terminal-app, a macOS Terminal.app tab (tests/run-in-terminal-app.sh).
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
#     terminal), with the right arguments for the mode, and the helper survives the death of the
#     agent that launched it.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="$root/plugins/session-agent-toolkit/skills/restart-session/scripts/restart-session.sh"
fake="$root/tests/test-fake-agent.sh"
terminal=${RS_TEST_TERMINAL:-tmux}
work=$(mktemp -d)
bin="$work/bin"; mkdir -p "$bin"
# Claude Code's own records are faked under here; the real ~/.claude is never read or written.
export CLAUDE_CONFIG_DIR="$work/claude"
failures=0
check() { if [ "$2" = 0 ]; then echo "PASS  $1"; else echo "FAIL  $1  -- $3"; failures=$((failures + 1)); fi; }
json_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
new_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-Z' 'a-z'; }

# --- stand-in agent: records its pid + argv, then runs the fake shell tool or idles like a TUI ---
cat > "$bin/stub-impl" <<'EOF'
#!/bin/bash
if [ -n "${RS_TEST_OUT-}" ]; then
    printf '%s\0' "$@" > "$RS_TEST_OUT.args"
    echo $$ > "$RS_TEST_OUT"
fi
if [ -n "${RS_TEST_CHILD-}" ]; then bash "$RS_TEST_CHILD"; else sleep 600; fi
EOF
for k in claude codex agy; do
    if [ "$(uname -s)" = Darwin ]; then
        # macOS lists a "#!" script under its interpreter's name, so the stand-in gets its name through argv[0].
        printf '#!/bin/bash\nexec -a %s /bin/bash "%s/stub-impl" "$@"\n' "$k" "$bin" > "$bin/$k"
    else
        cp "$bin/stub-impl" "$bin/$k"
    fi
    chmod +x "$bin/$k"
done

own=$(new_uuid)     # the session the stand-in "is"
other=$(new_uuid)   # another session in the same project
canary="$work/pwned"
# Everything an attacker would try to smuggle through the prompt: an option name, a newline (Enter),
# quote break-outs for both quote styles, command substitutions, Escape, Backspace, a backslash.
hostile=$(printf -- "--dangerously-skip-permissions\n'; touch '%s'; '\"; touch \"%s\"; \" \$(touch '%s') \`touch %s\` \033\010 \\\\ \xe9\x87\x8d\xe5\x95\x9f" "$canary" "$canary" "$canary" "$canary")
printf '%s' "$hostile" > "$work/hostile.txt"
printf 'x' > "$work/x.txt"
printf '%s' "$own" > "$work/own.txt"
printf '%s' "$other" > "$work/other.txt"
restart_message='[restart-session] This session was restarted by the restart-session tool. Continue where you left off.'
# A new or switched-to session must be told, in words the caller cannot remove or change, that an
# agent - not the user - wrote its message; otherwise a misled agent could pass its instructions on as "the user's".
notice_new='[restart-session] This session was started by an AI agent through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
notice_switch='[restart-session] An AI agent switched this terminal to this session through the restart-session tool. The user did not type this message. Everything after this sentence was written by that agent, not by the user:'
resume_command() {   # kind id
    case "$1" in
        claude) echo "claude --resume $2" ;;
        codex)  echo "codex resume $2" ;;
        agy)    echo "agy --conversation $2 -i" ;;
    esac
}

# Run a stand-in agent of the given kind whose shell tool asks for a dry run; the output lands in $dry.
n=0
dry_run() {   # kind mode sid_file prompt_file [own_session [transcripts [decoy_session]]]
    n=$((n + 1)); dry="$work/dry$n.txt"
    RS_TEST_SCRIPT="$launcher" RS_TEST_MODE="$2" RS_TEST_SID_FILE="$3" RS_TEST_PROMPT_FILE="$4" \
        RS_TEST_OWN_SESSION="${5-}" RS_TEST_TRANSCRIPTS="${6-}" RS_TEST_DECOY_SESSION="${7-}" \
        RS_TEST_DRYOUT="$dry" RS_TEST_CHILD="$fake" RS_TEST_OUT="" "$bin/$1" > /dev/null 2>&1
}
# The typed line is exactly: <template> "<notice>$(cat "<state dir>/<random id>.prompt.txt")"
typed_line_is() {   # template notice
    local id; id=$(sed -n 's/.*restart-session\/\([0-9a-f]\{32\}\)\.prompt\.txt.*/\1/p' "$dry")
    [ -n "$id" ] && grep -qF -- "\"commandLine\": $(json_str "$1 \"$2\$(cat \"\$HOME/.local/state/restart-session/$id.prompt.txt\")\"")" "$dry"
}
refused_with() { grep -q -- "$1" "$dry" && ! grep -q commandLine "$dry"; }
wait_for() { local i=0; while [ ! -s "$1" ] && [ $i -lt "$2" ]; do sleep 0.25; i=$((i + 1)); done; [ -s "$1" ]; }

# ---- A. what gets typed is the fixed template, whatever the caller passes ----
for kind in claude codex agy; do
    case "$kind" in claude) fresh="claude" ;; codex) fresh="codex" ;; agy) fresh="agy -i" ;; esac

    dry_run "$kind" restart "$work/own.txt" ""
    grep -qF -- "\"commandLine\": $(json_str "$(resume_command "$kind" "$own") '$restart_message'")" "$dry"
    check "$kind restart: typed line is exactly the fixed resume command" $? "got: $(cat "$dry")"

    dry_run "$kind" new "" "$work/hostile.txt"
    typed_line_is "$fresh" "$notice_new"
    check "$kind new: typed line is the fixed template and notice, with nothing from the prompt" $? "got: $(cat "$dry")"

    dry_run "$kind" switch "$work/other.txt" "$work/hostile.txt" "$own" "$own $other"
    typed_line_is "$(resume_command "$kind" "$other")" "$notice_switch"
    check "$kind switch: typed line is the fixed resume command and notice, with nothing from the prompt" $? "got: $(cat "$dry")"
done

bad_id() {   # label, session id bytes (printf format)
    printf -- "$2" > "$work/bad.txt"
    dry_run agy restart "$work/bad.txt" ""
    refused_with 'session id rejected'; check "restart: session id that is $1 is refused" $? "got: $(cat "$dry")"
    dry_run agy switch "$work/bad.txt" "$work/x.txt"
    refused_with 'session id rejected'; check "switch: session id that is $1 is refused" $? "got: $(cat "$dry")"
}
bad_id 'an option'              '--dangerously-skip-permissions'
bad_id 'a command after the id' "$own; touch '$canary'"
bad_id 'a trailing newline'     "$own\n"
bad_id 'a substitution'         "\$(touch '$canary')"

# ---- B. who may say what to which session ----
dry_run claude restart "$work/own.txt" "$work/hostile.txt"
refused_with 'takes no prompt'; check 'restart mode refuses a prompt' $? "got: $(cat "$dry")"
# For claude, "restart" must mean this session: its own record wins over whatever id the caller passes.
dry_run claude restart "$work/other.txt" "" "$own" "$own $other"
grep -qF -- "\"commandLine\": $(json_str "$(resume_command claude "$own") '$restart_message'")" "$dry"
check 'claude restart resumes its own session, not the id the caller passed' $? "got: $(cat "$dry")"
# ...and that record must be the agent's real one: a caller cannot swap in its own by changing its environment.
dry_run claude restart "" "" "$own" "$own $other" "$(new_uuid)"
grep -qF -- "\"commandLine\": $(json_str "$(resume_command claude "$own") '$restart_message'")" "$dry"
check 'claude restart ignores session records the caller points it at' $? "got: $(cat "$dry")"
dry_run claude new "" ""
refused_with 'requires --activation-prompt'; check 'new mode requires an activation prompt' $? "got: $(cat "$dry")"
dry_run claude switch "$work/other.txt" "" "$own" "$own $other"
refused_with 'requires --activation-prompt'; check 'switch mode requires an activation prompt' $? "got: $(cat "$dry")"
dry_run claude switch "" "$work/x.txt" "$own" "$own $other"
refused_with 'requires --session-id'; check 'switch mode requires a session id' $? "got: $(cat "$dry")"
# Switching to yourself would be a restart that carries a prompt - exactly what restart mode forbids.
dry_run claude switch "$work/own.txt" "$work/x.txt" "$own" "$own $other"
refused_with 'needs another session'; check 'switch to the session you are in is refused' $? "got: $(cat "$dry")"
# A wrong id must be refused while the agent is still alive, not after it has been stopped.
new_uuid | tr -d '\n' > "$work/missing.txt"
dry_run claude switch "$work/missing.txt" "$work/x.txt" "$own" "$own"
refused_with 'no claude session'; check 'switch to a session that does not exist is refused' $? "got: $(cat "$dry")"

# ---- C. real replacement of a stand-in claude, one new interactive shell per mode ----
# Open a new interactive bash in the terminal under test; it runs $2 first (from its rc file), then
# sits at its prompt like a shell the user started an agent from.
open_shell() {   # name, first line
    local rc="$work/rc-$1"
    printf '%s\n' "$2" > "$rc"
    if [ "$terminal" = terminal-app ]; then
        printf '#!/bin/bash\nexec bash --rcfile %q -i\n' "$rc" > "$work/$1.command"
        chmod +x "$work/$1.command"
        open -a Terminal "$work/$1.command"
    else
        tmux new-window -d -n "$1" "exec bash --rcfile '$rc' -i"
    fi
}

shells=""
end_to_end() {   # mode sid_file prompt_file [own_session [transcripts]]
    n=$((n + 1)); local out1="$work/before$n" out2="$work/after$n" win="rs-test-$n"
    after_args="$out2.args"
    # Stand-in is first on PATH, so the typed "claude ..." starts it again; once the first one has been
    # stopped, the shell switches the stand-in to "record argv and idle".
    open_shell "$win" "export PATH='$bin':\"\$PATH\" CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR'; RS_TEST_SCRIPT='$launcher' RS_TEST_MODE=$1 RS_TEST_SID_FILE='$2' RS_TEST_PROMPT_FILE='$3' RS_TEST_OWN_SESSION='${4-}' RS_TEST_TRANSCRIPTS='${5-}' RS_TEST_DRYOUT='$work/dry-e2e-$n.txt' RS_TEST_RESTART=1 RS_TEST_CHILD='$fake' RS_TEST_OUT='$out1' claude; export RS_TEST_OUT='$out2'"

    wait_for "$out1" 160 || { check "$1: stand-in agent started" 1 "no $out1"; return 1; }
    local old_pid shell_pid new_pid
    old_pid=$(cat "$out1"); shell_pid=$(ps -o ppid= -p "$old_pid" | tr -d ' ')
    shells="$shells $shell_pid"

    wait_for "$out2" 160
    check "$1: next agent started" $? "no $out2; dry run: $(cat "$work/dry-e2e-$n.txt" 2>/dev/null); logs: $(cat "$HOME"/.local/state/restart-session/*.log 2>/dev/null | tail -n 5)"
    [ -s "$out2" ] || return 1
    new_pid=$(cat "$out2")
    ! kill -0 "$old_pid" 2>/dev/null;                                   check "$1: old agent process is gone" $? "pid $old_pid still alive"
    [ "$new_pid" != "$old_pid" ];                                       check "$1: next agent is a new process" $? "same pid $new_pid"
    [ "$(ps -o ppid= -p "$new_pid" | tr -d ' ')" = "$shell_pid" ];      check "$1: started by the same shell" $? "before shell $shell_pid, after $(ps -o ppid= -p "$new_pid")"
}
show_args() { tr '\0' '|' < "$after_args" | od -c | head -n 16; }

if end_to_end restart "$work/own.txt" ""; then
    printf '%s\0' --resume "$own" "$restart_message" | cmp -s - "$after_args"
    check 'restart: resumes the same session with the fixed notice' $? "argv: $(tr '\0' '|' < "$after_args")"
fi
if end_to_end new "" "$work/hostile.txt"; then
    printf '%s\n\nStarted by: claude session (id unknown)\nTool: %s --mode new\nHandoff note from that agent:\n\n%s\0' "$notice_new" "$launcher" "$hostile" | cmp -s - "$after_args"
    check 'new: one inert argument - the notice, where it came from, then the hostile prompt' $? "argv: $(show_args)"
fi
if end_to_end switch "$work/other.txt" "$work/hostile.txt" "$own" "$own $other"; then
    { printf '%s\0' --resume "$other"
      printf '%s\n\nSwitched from: claude session %s\nTool: %s --mode switch\nNote from that agent:\n\n%s\0' "$notice_switch" "$own" "$launcher" "$hostile"
    } | cmp -s - "$after_args"
    check 'switch: resumes the other session with one inert argument - the notice, which session it came from, then the hostile prompt' $? "argv: $(show_args)"
fi
[ ! -e "$canary" ]; check 'nothing from a prompt or session id was executed' $? "$canary was created"

for s in $shells; do pkill -P "$s" 2>/dev/null; kill -HUP "$s" 2>/dev/null; done
rm -rf "$work"
if [ "$failures" -gt 0 ]; then printf '\n%s check(s) failed\n' "$failures"; exit 1; fi
printf '\nall checks passed\n'
