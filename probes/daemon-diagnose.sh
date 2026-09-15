#!/usr/bin/env bash
# shellcheck disable=SC2012 # diagnostics: human-readable listings
# Diagnose why the background daemon won't start ("not reachable within 45s").
# Captures the daemon's own log around a fresh start attempt, plus its state
# dirs. Read-only except for the --bg start attempt it makes. HOST, native.
#     ./probes/daemon-diagnose.sh
set -uo pipefail

nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
LOG="$HOME/.claude/daemon.log"
UID_="$(id -u)"

echo "== ~/.claude/daemon/ contents (look for locks/stale files) =="
ls -la "$HOME/.claude/daemon/" 2>/dev/null | sed 's/^/   /'
echo "== /tmp/cc-daemon-$UID_/ =="
ls -la "/tmp/cc-daemon-$UID_"/ 2>/dev/null | sed 's/^/   /' || echo "   (absent)"
find "/tmp/cc-daemon-$UID_" -maxdepth 2 2>/dev/null | sed 's/^/   /' | head -30

echo
echo "== daemon.log: last 30 lines BEFORE the attempt =="
tail -30 "$LOG" 2>/dev/null | sed 's/^/   /' || echo "   (no daemon.log)"
before_lines="$(wc -l <"$LOG" 2>/dev/null || echo 0)"

echo
echo "== attempt: native claude --bg (output shown), watch for a daemon-run process =="
tmp="$(mktemp -d)"
(cd "$tmp" && timeout 60 "$nat" --bg 'print hi and stop' 2>&1) | sed 's/^/   /' &
bgpid=$!
for _ in $(seq 1 12); do
  d="$(pgrep -af 'daemon run' 2>/dev/null | head -3)"
  [ -n "$d" ] && {
    echo "   [saw daemon-run]: $d"
    break
  }
  sleep 1
done
wait "$bgpid" 2>/dev/null || true

echo
echo "== daemon.log: NEW lines from the attempt (the startup error) =="
tail -n +"$((before_lines + 1))" "$LOG" 2>/dev/null | sed 's/^/   /' || echo "   (none)"

echo
echo "== hints =="
echo "   - a 'lock'/'EADDRINUSE'/'permission'/'ENOENT'/'stale' line above points at the cause."
echo "   - if it is a stale lock/key in ~/.claude/daemon/, the fix is to remove that file."
"$nat" daemon stop >/dev/null 2>&1 || true
rm -rf "$tmp"
echo "done."
