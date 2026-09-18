#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Does a freshly-started daemon reap the PREVIOUS daemon's orphaned SANDBOXED
# workers? (daemon.log shows "bg orphan-reap: N roster-less pty host(s)"; killing
# a pty-host takes its --die-with-parent sandboxed spare with it.) If yes, the
# transient leak from restart-per-launch self-heals and no manual reap is needed.
#
# Creates a sandboxed idle pool, kills its daemon (orphaning the workers), starts
# a fresh daemon, and polls whether those specific orphans get reaped.
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses the installed
# runtime. HOST only. Cleans up EVERYTHING it creates.
#     ./probes/wrapper-reaper-measure.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "engine has no --wrap: $ENGINE"
  exit 1
}
nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
UID_="$(id -u)"
CJSON="$HOME/.claude.json"
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }
count_alive() {
  local n=0 p
  for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  echo "$n"
}
reap_bg_workers() {
  local sig p
  for sig in TERM KILL; do
    for p in $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null); do kill "-$sig" "$p" 2>/dev/null || true; done
    sleep 1
  done
}

SHIM="$(mktemp)"
printf '#!/bin/sh\nexec "%s" --profile claude --wrap "$@"\n' "$ENGINE" >"$SHIM"
chmod +x "$SHIM"

echo "engine: $ENGINE"
echo "== clean slate (stop daemon, reap any leaked bg workers) =="
if "$nat" agents --json 2>/dev/null | grep -q '"id"'; then
  echo "   host has live bg sessions; aborting to stay safe"
  exit 1
fi
"$nat" daemon stop >/dev/null 2>&1 || true
reap_bg_workers
rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true

P0="$(mktemp -d)/proj-$$"
mkdir -p "$P0"
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"
mkdir -p "$base"
printf '%s' "$P0" >"$base/bg-project"
python3 - "$CJSON" "$P0" <<'PYT'
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PYT

echo "== session 1: create a sandboxed pool (quick task, then idle) =="
(cd "$P0" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'print the word hi and stop' >/dev/null 2>&1) || true
sleep 30
mapfile -t ORPHANS < <(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null)
DAEMON1="$(pgrep -f 'daemon run' 2>/dev/null | head -1)"
echo "   pool workers (to be orphaned): ${#ORPHANS[@]} ; daemon1: ${DAEMON1:-<none>}"
[ "${#ORPHANS[@]}" -gt 0 ] || {
  echo "   no pool formed; cannot test"
  reap_bg_workers
  "$nat" daemon stop 2>/dev/null || true
  rm -f "$SHIM" "$base/bg-project"
  python3 - "$CJSON" "$P0" <<'PYT' 2>/dev/null || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PYT
  rm -rf "$(dirname "$P0")"
  exit 1
}

echo "== kill daemon1 (orphan the pool) =="
[ -n "$DAEMON1" ] && kill "$DAEMON1" 2>/dev/null || true
sleep 3
echo "   orphaned workers still alive: $(count_alive "${ORPHANS[@]}") of ${#ORPHANS[@]}"

echo "== start a FRESH daemon (session 2) and poll whether it reaps the orphans =="
(cd "$P0" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'print the word hi and stop' >/dev/null 2>&1) || true
elapsed=0
for step in 15 15 15 15 15 15; do
  sleep "$step"
  elapsed=$((elapsed + step))
  echo "   ~${elapsed}s: orphans alive = $(count_alive "${ORPHANS[@]}") of ${#ORPHANS[@]}"
done

echo
echo "== verdict =="
left="$(count_alive "${ORPHANS[@]}")"
if [ "$left" -eq 0 ]; then
  echo "   REAPED: the fresh daemon cleared all orphaned sandboxed workers -> leak self-heals; no manual reap."
else
  echo "   $left/${#ORPHANS[@]} orphans still alive after ~90s -> reaper does not (fully) clear them; leak persists."
fi

echo "== cleanup (everything) =="
reap_bg_workers
for id in $("$nat" agents --json 2>/dev/null | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
  "$nat" rm "$id" >/dev/null 2>&1 || true
done
"$nat" daemon stop >/dev/null 2>&1 || true
python3 - "$CJSON" "$P0" <<'PYT' 2>/dev/null || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PYT
rm -f "$SHIM" "$base/bg-project"
rm -rf "$(dirname "$P0")"
echo "   background workers remaining: $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l | tr -d ' ')"
echo "done."
