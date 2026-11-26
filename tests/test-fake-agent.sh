#!/usr/bin/env bash
# Plays the agent's shell tool in test-restart-session.sh: it runs as a child of a stand-in
# claude / codex / agy and calls restart-session.sh the way a real agent would.
# Inputs (env): RS_TEST_SCRIPT, RS_TEST_MODE, RS_TEST_PROMPT_FILE, RS_TEST_SID_FILE, RS_TEST_DRYOUT, RS_TEST_RESTART
set -u

args=(--mode "$RS_TEST_MODE" --delay-seconds 1)
if [ -n "${RS_TEST_PROMPT_FILE-}" ]; then
    IFS= read -r -d '' prompt < "$RS_TEST_PROMPT_FILE" || true     # whole file, newlines included
    args+=(--activation-prompt "$prompt")
fi
if [ -n "${RS_TEST_SID_FILE-}" ]; then
    IFS= read -r -d '' sid < "$RS_TEST_SID_FILE" || true
    args+=(--session-id "$sid")
fi

bash "$RS_TEST_SCRIPT" "${args[@]}" --dry-run > "$RS_TEST_DRYOUT.tmp" 2>&1
mv "$RS_TEST_DRYOUT.tmp" "$RS_TEST_DRYOUT"

# Safety: go on only if the script targets the stand-in that launched us, never an agent further up.
if [ "${RS_TEST_RESTART-}" = 1 ] && grep -q "\"agentPid\": $PPID," "$RS_TEST_DRYOUT"; then
    bash "$RS_TEST_SCRIPT" "${args[@]}"
    sleep 600
fi
