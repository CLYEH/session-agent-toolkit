#!/usr/bin/env bash
# macOS only: runs tests/test-restart-session.sh inside a Terminal.app window, so the suite exercises
# the Terminal.app (AppleScript) typing path instead of tmux - and does so as a descendant of
# Terminal.app, the way a real agent session is.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out=$(mktemp -d)

printf '#!/bin/bash\nRS_TEST_TERMINAL=terminal-app bash %q > %q 2>&1; echo $? > %q\n' \
    "$here/test-restart-session.sh" "$out/result.txt" "$out/exit" > "$out/run.command"
chmod +x "$out/run.command"
open -a Terminal "$out/run.command" || { echo "could not open Terminal.app"; exit 2; }

i=0
while [ ! -s "$out/exit" ] && [ $i -lt 420 ]; do sleep 1; i=$((i + 1)); done
cat "$out/result.txt" 2>/dev/null
[ -s "$out/exit" ] || { echo "timed out waiting for the test"; exit 2; }
exit "$(cat "$out/exit")"
