#!/usr/bin/env bash
# Runs tests/test-restart-session.sh inside a tmux pane (the suite needs a terminal the script can type into).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out=$(mktemp -d)

tmux new-session -d -s rs-main -x 200 -y 50 "bash '$here/test-restart-session.sh' > '$out/result.txt' 2>&1; echo \$? > '$out/exit'"
i=0
while [ ! -s "$out/exit" ] && [ $i -lt 300 ]; do sleep 1; i=$((i + 1)); done
cat "$out/result.txt" 2>/dev/null
[ -s "$out/exit" ] || { echo "timed out waiting for the test"; exit 2; }
exit "$(cat "$out/exit")"
