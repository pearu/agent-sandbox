#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# What does `claude daemon stop --any` do to a running transient daemon that has
# an ACTIVE sandboxed session plus idle pool spares? This decides 3b's restart
# mechanism: force-kill the supervisor (proven active-safe) vs the official
# `daemon stop --any`.
#
#   S1. Does `daemon stop --any` succeed (daemon actually stops)?
#   S2. Does the ACTIVE session survive it (worker subtree alive + still in
#       `claude agents`, adopted by the next daemon)?
#   S3. Are the idle pool spares cleaned by --any, or do they leak (orphan)?
#   S4. Does a subsequent `--bg` bring up a fresh daemon cleanly?
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses the
# installed runtime. HOST only. bg-only kills (foreground sessions untouched).
#     ./probes/bg-daemonstop-measure.sh
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
ROSTER="$HOME/.claude/daemon/roster.json"

ppidof() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
roster_supervisor() {
  python3 - "$ROSTER" 2>/dev/null <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("supervisorPid")
except Exception:
    sys.exit(0)
if isinstance(v, int):
    print(v)
PY
}
roster_pid_for_id() {
  python3 - "$ROSTER" "$1" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
sid = sys.argv[2]
for k, w in (d.get("workers", {}) or {}).items():
    if isinstance(w, dict) and (sid in str(k) or sid in str(w.get("sessionId", ""))):
        if isinstance(w.get("pid"), int):
            print(w["pid"])
            sys.exit(0)
PY
}
all_bg_pids() { pgrep -f -- '--bg-pty-host|--bg-spare|daemon run' 2>/dev/null | sort -un; }
bg_markers() { pgrep -f -- '--bg-pty-host|--bg-spare' 2>/dev/null | sort -un; }
agents_json() { "$nat" agents --json 2>/dev/null; }
agents_has() { agents_json | grep -qi "$1"; }
id_from_out() { grep -i backgrounded | grep -oiE '[0-9a-f]{8}' | head -1; }
descendants() {
  local q=("$1") p c
  while [ ${#q[@]} -gt 0 ]; do
    p="${q[0]}"
    q=("${q[@]:1}")
    for c in $(pgrep -P "$p" 2>/dev/null); do
      echo "$c"
      q+=("$c")
    done
  done
}
subtree_alive() {
  local n=0 p
  for p in "$1" $(descendants "$1"); do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  echo "$n"
}
# is $1 within the process subtree rooted at $2 (or == $2)?
in_subtree() {
  local p="$1" root="$2"
  for _ in $(seq 1 30); do
    { [ -z "$p" ] || [ "$p" = 1 ]; } && break
    [ "$p" = "$root" ] && return 0
    p="$(ppidof "$p")"
  done
  return 1
}
count_alive() {
  local n=0 p
  for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  echo "$n"
}

SHIM="$(mktemp)"
printf '#!/bin/sh\nexec "%s" --profile claude --wrap "$@"\n' "$ENGINE" >"$SHIM"
chmod +x "$SHIM"
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"
mkdir -p "$base"
setproj() { printf '%s' "$1" >"$base/bg-project"; }
trust() {
  python3 - "$CJSON" "$1" <<'PY'
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PY
}
untrust() {
  python3 - "$CJSON" "$1" 2>/dev/null <<'PY' || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PY
}
wait_worker() {
  local id="$1" tries="$2" p
  for _ in $(seq 1 "$tries"); do
    sleep 3
    p="$(roster_pid_for_id "$id")"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  echo ""
  return 1
}
kill_everything() {
  local sig p sup
  sup="$(roster_supervisor)"
  for id in $(agents_json | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
    "$nat" rm "$id" >/dev/null 2>&1 || true
  done
  "$nat" daemon stop --any >/dev/null 2>&1 || "$nat" daemon stop >/dev/null 2>&1 || true
  for sig in TERM KILL; do
    [ -n "$sup" ] && kill "-$sig" "$sup" 2>/dev/null || true
    for p in $(all_bg_pids); do kill "-$sig" "$p" 2>/dev/null || true; done
    sleep 1
  done
}
cleanup() {
  echo "== cleanup (everything, bg-only) =="
  kill_everything
  pkill -f -- 'sleep 301' 2>/dev/null || true
  [ -n "${P1:-}" ] && untrust "$P1"
  [ -n "${P2:-}" ] && untrust "$P2"
  rm -f "$SHIM" "$base/bg-project"
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  echo "   bg workers remaining: $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l | tr -d ' ')"
  echo "done."
}

echo "engine: $ENGINE ; uid: $UID_ ; runtime: $nat"
echo "== clean slate (abort if live host bg sessions) =="
if agents_has '"id"'; then
  echo "   host has live bg sessions; aborting to stay safe"
  rm -f "$SHIM"
  exit 1
fi
kill_everything
rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true

TMP="$(mktemp -d)"
P1="$TMP/proj1"
P2="$TMP/proj2"
mkdir -p "$P1" "$P2"
trust "$P1"
trust "$P2"

echo
echo "== session 1: active sandboxed bg session (sleep 301) in P1 =="
setproj "$P1"
OUT1="$(cd "$P1" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'run this exact shell command and wait for it: sleep 301' 2>&1)"
ID1="$(printf '%s' "$OUT1" | id_from_out)"
echo "   session 1 id: ${ID1:-<none>}"
PTYH1="$(wait_worker "$ID1" 40)" || true
if [ -z "$PTYH1" ]; then
  echo "   SETUP FAILED: no rostered worker for session 1"
  printf '%s\n' "$OUT1" | sed 's/^/     /'
  cleanup
  exit 1
fi
sleep 5
SUP1="$(roster_supervisor)"
echo "   ACTIVE1 launcher pid: $PTYH1 (subtree procs=$(subtree_alive "$PTYH1")) ; supervisor: ${SUP1:-<none>}"
# idle markers = bg markers not within the active session's subtree
mapfile -t IDLE < <(for m in $(bg_markers); do in_subtree "$m" "$PTYH1" || echo "$m"; done)
echo "   idle bg markers (pre-stop): ${IDLE[*]:-<none>}  (count=${#IDLE[@]})"

echo
echo "== S1: run \`claude daemon stop --any\` (output shown) =="
"$nat" daemon stop --any 2>&1 | sed 's/^/   /'
sleep 4
echo "   supervisor $SUP1 alive: $([ -n "$SUP1" ] && (kill -0 "$SUP1" 2>/dev/null && echo yes || echo no) || echo '?')"

echo
echo "== S2/S3: state right after --any =="
echo "   ACTIVE1 subtree procs alive: $(subtree_alive "$PTYH1")  in-agents=$(agents_has "$ID1" && echo yes || echo no)"
echo "   idle bg markers still alive: $(count_alive "${IDLE[@]}") of ${#IDLE[@]}"

echo
echo "== S4: does a subsequent --bg bring up a fresh daemon? (session 2 in P2) =="
setproj "$P2"
OUT2="$(cd "$P2" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'print the word ready and stop' 2>&1)"
ID2="$(printf '%s' "$OUT2" | id_from_out)"
PTYH2="$(wait_worker "$ID2" 40)" || true
SUP2="$(roster_supervisor)"
echo "   session 2 id: ${ID2:-<none>} ; worker: ${PTYH2:-<none>} ; new supervisor: ${SUP2:-<none>}"
echo "   session 1 adopted by new daemon (in-agents): $(agents_has "$ID1" && echo yes || echo no)"

echo
echo "== summary =="
s2="$([ "$(subtree_alive "$PTYH1")" -gt 0 ] && agents_has "$ID1" && echo survived || echo GONE)"
s3="$([ "$(count_alive "${IDLE[@]}")" -eq 0 ] && echo cleaned || echo "leaked($(count_alive "${IDLE[@]}"))")"
echo "   S2 active session on --any: $s2"
echo "   S3 idle spares on --any:    $s3"
echo "   S4 fresh daemon after --any: $([ -n "$PTYH2" ] && echo ok || echo FAILED)"
echo
echo "== reading =="
echo "   active survived + idle cleaned -> restart = 'daemon stop --any', NO reap needed."
echo "   active survived + idle leaked  -> restart = 'daemon stop --any' + ancestor-aware reap."
echo "   active GONE                    -> --any kills live sessions; use supervisor force-kill + reap."

echo
cleanup
