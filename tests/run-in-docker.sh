#!/usr/bin/env bash
# Runs the Linux test suite in a throwaway container.
# Usage:  docker run --rm -v "<repo root>:/plugin:ro" debian:stable-slim bash /plugin/tests/run-in-docker.sh
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq tmux procps >/dev/null || { echo "could not install tmux/procps"; exit 2; }
exec bash /plugin/tests/run-in-tmux.sh
