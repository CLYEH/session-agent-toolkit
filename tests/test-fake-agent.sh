#!/usr/bin/env bash
# Plays the agent's shell tool in test-restart-session.sh: it runs as a child of a stand-in
# claude / codex / agy and calls restart-session.sh the way a real agent would.
# Inputs (env): RS_TEST_SCRIPT, RS_TEST_MODE, RS_TEST_PROMPT_FILE, RS_TEST_SID_FILE, RS_TEST_DRYOUT, RS_TEST_RESTART,
#               RS_TEST_OWN_SESSION, RS_TEST_TRANSCRIPTS (with CLAUDE_CONFIG_DIR pointing at a scratch directory)
set -u

# Optionally play Claude Code's own bookkeeping: the per-process record of which session the
# stand-in is, and transcripts of sessions that exist in its project.
if [ -n "${RS_TEST_OWN_SESSION-}" ]; then
    mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
    printf '{"sessionId":"%s"}\n' "$RS_TEST_OWN_SESSION" > "$CLAUDE_CONFIG_DIR/sessions/$PPID.json"
fi
for t in ${RS_TEST_TRANSCRIPTS-}; do
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/proj"
    echo '{}' > "$CLAUDE_CONFIG_DIR/projects/proj/$t.jsonl"
done

# Optionally play a misled agent: point OUR environment (the script's caller) at a decoy record
# that claims the stand-in is a different session.
if [ -n "${RS_TEST_DECOY_SESSION-}" ]; then
    decoy="$CLAUDE_CONFIG_DIR-decoy"
    mkdir -p "$decoy/sessions" "$decoy/projects/proj"
    printf '{"sessionId":"%s"}\n' "$RS_TEST_DECOY_SESSION" > "$decoy/sessions/$PPID.json"
    echo '{}' > "$decoy/projects/proj/$RS_TEST_DECOY_SESSION.jsonl"
    export CLAUDE_CONFIG_DIR="$decoy"
fi

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
