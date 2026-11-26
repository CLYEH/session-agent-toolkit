#!/usr/bin/env bash
# macOS only: runs tests/test-restart-session.sh inside a Terminal.app tab, so the suite exercises
# the Terminal.app (AppleScript) typing path instead of tmux.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out=$(mktemp -d)

if ! err=$(osascript - "RS_TEST_TERMINAL=terminal-app bash '$here/test-restart-session.sh' > '$out/result.txt' 2>&1; echo \$? > '$out/exit'" 2>&1 <<'APPLESCRIPT'
on run argv
    tell application "Terminal"
        activate
        do script (item 1 of argv)
    end tell
end run
APPLESCRIPT
); then
    echo "could not drive Terminal.app: $err"
    exit 2
fi
i=0
while [ ! -s "$out/exit" ] && [ $i -lt 300 ]; do sleep 1; i=$((i + 1)); done
cat "$out/result.txt" 2>/dev/null
[ -s "$out/exit" ] || { echo "timed out waiting for the test"; exit 2; }
exit "$(cat "$out/exit")"
