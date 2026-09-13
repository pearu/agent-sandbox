#!/usr/bin/env bash
# Clean up leaked background-worker sandboxes (bwrap processes running
# --bg-spare / --bg-pty-host) and stop the daemon. Foreground sessions never
# carry those flags, so they are NOT touched. Safe to run when you have no
# background sessions you want to keep.
#     ./probes/bg-cleanup.sh
set -uo pipefail
# shellcheck disable=SC2012 # version dirs: plain names
nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"

echo "background workers before: $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l)"
"$nat" daemon stop >/dev/null 2>&1 || true
for sig in TERM TERM KILL; do
  for p in $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null); do
    [ "$(ps -o comm= -p "$p" 2>/dev/null)" = bwrap ] && kill "-$sig" "$p" 2>/dev/null || true
  done
  sleep 1
done
# also any host-side pty-host / spare that is not a bwrap (passthrough leftovers)
for p in $(pgrep -f -- '--bg-pty-host|--bg-spare' 2>/dev/null); do kill "$p" 2>/dev/null || true; done
sleep 1
echo "background workers after:  $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l)"
rm -rf "/tmp/cc-daemon-$(id -u)"/* 2>/dev/null || true
echo "done."
