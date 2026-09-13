#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# REAP-ONLY (no daemon restart) alternative to restart-per-launch. Instead of
# killing the supervisor to flush the pool, keep the daemon alive and just reap
# the IDLE pool spares, set bg-project to the new project, and let the live
# daemon re-warm spares bound to it. Active sessions are never touched.
#
#   Q1. Reaping idle spares leaves the ACTIVE session fully alive + in `agents`.
#   Q2. After reap + bg-project=P2, session 2 gets a P2-BOUND worker that works
#       (roster cwd=P2, DONE.txt created in P2).
#   Q3. Isolation: session 2's sandbox binds P2 and NOT P1 -- checked HOST-SIDE
#       from the worker's bwrap argv (its bind list), so the agent never has to
#       touch another project (which would trip an out-of-project permission
#       prompt) and no disclaimer/bypass is needed.
#   Q4. Race: does session 2 ever get a stale P1-bound spare (cwd=P1)?
#
# Reap discriminator (daemon ALIVE): keep slots whose top launcher is rostered
# (active sessions); kill children-of-supervisor whose subtree has a bg marker
# but are not rostered (idle pool). This is the reap 3b would use if we pick
# reap-only. Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses
# the installed runtime. HOST only. bg-only kills. Cleans up EVERYTHING.
#     ./probes/wrapper-reaponly-measure.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "engine has no --wrap: $ENGINE"
  exit 1
}
# Highest version with a RUNNABLE binary (mirrors the engine's fixed resolver):
# a mid-update leaves the newest versions/<v> present but not yet executable, so
# `ls | tail -1` would pick a phantom. Skip non-runnable entries.
_pick_nat() {
  local d="$HOME/.local/share/claude/versions" v c
  while IFS= read -r v; do
    if [ -x "$d/$v" ] && [ ! -d "$d/$v" ]; then
      echo "$d/$v"
      return 0
    fi
    for c in "$d/$v/claude" "$d/$v/bin/claude"; do
      [ -x "$c" ] && {
        echo "$c"
        return 0
      }
    done
  done < <(find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -rV)
  return 1
}
nat="$(_pick_nat)" || {
  echo "no runnable Claude Code executable under $HOME/.local/share/claude/versions"
  exit 1
}
UID_="$(id -u)"
CJSON="$HOME/.claude.json"
ROSTER="$HOME/.claude/daemon/roster.json"

alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }
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
roster_hostpids() {
  python3 - "$ROSTER" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(" ".join(str(w["pid"]) for w in (d.get("workers", {}) or {}).values()
                if isinstance(w, dict) and isinstance(w.get("pid"), int)))
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
roster_cwd_for_id() {
  python3 - "$ROSTER" "$1" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
sid = sys.argv[2]
for k, w in (d.get("workers", {}) or {}).items():
    if isinstance(w, dict) and (sid in str(k) or sid in str(w.get("sessionId", ""))):
        print(w.get("cwd", ""))
        sys.exit(0)
PY
}
all_bg_pids() { pgrep -f -- '--bg-pty-host|--bg-spare|daemon run' 2>/dev/null | sort -un; }
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
subtree_has_bg_marker() {
  local p
  for p in "$1" $(descendants "$1"); do
    case "$(ps -o args= -p "$p" 2>/dev/null)" in
      *--bg-pty-host* | *--bg-spare*) return 0 ;;
    esac
  done
  return 1
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
  "$nat" daemon stop --any >/dev/null 2>&1 || true
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
# Minimal model for the bg tasks (fast; user's testing convention). Session tasks
# stay in-project so they are auto-approved (an out-of-project access would prompt,
# and a bg session cannot answer). Isolation is verified host-side (bwrap argv).
MODEL="haiku"

echo
echo "== session 1: active bg session (sleep 301) in P1; pool warms P1-bound =="
setproj "$P1"
OUT1="$(cd "$P1" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --model "$MODEL" --permission-mode acceptEdits --bg 'run this exact shell command and wait for it: sleep 301' 2>&1)"
ID1="$(printf '%s' "$OUT1" | id_from_out)"
PTYH1="$(wait_worker "$ID1" 40)" || true
if [ -z "$PTYH1" ]; then
  echo "   SETUP FAILED: no rostered worker for session 1"
  printf '%s\n' "$OUT1" | sed 's/^/     /'
  cleanup
  exit 1
fi
sleep 5
SUP="$(roster_supervisor)"
echo "   session 1 id: $ID1 ; launcher: $PTYH1 ; supervisor: $SUP"
echo "   session 1 subtree procs: $(subtree_alive "$PTYH1")"

echo
echo "== switch to P2 + REAP-ONLY (keep active, flush idle under the live supervisor) =="
setproj "$P2" # so any re-warm after the reap binds P2
declare -A KEEP=()
for h in $(roster_hostpids); do KEEP["$h"]=1; done
REAPED=()
for L in $(pgrep -P "$SUP" 2>/dev/null); do
  [ -n "${KEEP[$L]:-}" ] && continue     # rostered active slot: keep
  subtree_has_bg_marker "$L" || continue # not a pool slot: leave alone
  for p in $(descendants "$L") "$L"; do
    REAPED+=("$p")
    kill "$p" 2>/dev/null || true
  done
done
sleep 2
for p in ${REAPED[@]+"${REAPED[@]}"}; do kill -9 "$p" 2>/dev/null || true; done
echo "   reaped idle-slot procs: ${REAPED[*]:-<none>}"
echo "   Q1 session 1 after reap: in-agents=$(agents_has "$ID1" && echo yes || echo no) subtree=$(subtree_alive "$PTYH1") worker-alive=$(alive "$PTYH1")"

echo
echo "== session 2 in P2: create DONE.txt (in-project only -> auto-approved, no prompt) =="
OUT2="$(cd "$P2" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --model "$MODEL" --permission-mode acceptEdits --bg 'create a file named DONE.txt containing the word hi in the current directory, then stop' 2>&1)"
ID2="$(printf '%s' "$OUT2" | id_from_out)"
PTYH2="$(wait_worker "$ID2" 40)" || true
echo "   session 2 id: ${ID2:-<none>} ; worker: ${PTYH2:-<none>}"
echo "   session 2 roster cwd: $(roster_cwd_for_id "$ID2")  (want $P2)"
D2=""
for _ in $( # up to 150s: first --bg after a full reap is a COLD warm
  seq 1 50
); do
  sleep 3
  [ -f "$P2/DONE.txt" ] && {
    D2="$(cat "$P2/DONE.txt" 2>/dev/null | tr -d '[:space:]')"
    break
  }
done
echo "   P2/DONE.txt present: $([ -n "$D2" ] && echo yes || echo no) ; contents='${D2:-<none>}'"
echo "   P1/DONE.txt present (stale-bind indicator): $([ -f "$P1/DONE.txt" ] && echo yes || echo no)"

# Isolation, checked HOST-SIDE (no cross-project access by the agent, which would
# prompt): session 2's bwrap argv lists its bind mounts. It must bind P2 and NOT
# P1. Read the full cmdline from /proc (ps truncates bwrap's long argv).
BW2=""
for _p in $(descendants "$PTYH2"); do
  [ "$(ps -o comm= -p "$_p" 2>/dev/null)" = bwrap ] && {
    BW2="$_p"
    break
  }
done
BW2ARGV=""
[ -n "$BW2" ] && BW2ARGV="$(tr '\0' ' ' <"/proc/$BW2/cmdline" 2>/dev/null)"
case "$BW2ARGV" in
  *"$P2"*) sib_p2=yes ;;
  *) sib_p2=no ;;
esac
case "$BW2ARGV" in
  *"$P1"*) sib_p1=yes ;;
  *) sib_p1=no ;;
esac
echo "   session 2 bwrap pid: ${BW2:-<none>} ; binds P2=$sib_p2 binds P1=$sib_p1"

if [ -z "$D2" ]; then
  echo "   --- diagnostics (no DONE.txt) ---"
  echo "   session 2 worker subtree alive: ${PTYH2:+$(subtree_alive "$PTYH2")}"
  echo "   session 2 in agents: $(agents_has "$ID2" && echo yes || echo no)"
  echo "   P2 dir listing: $(ls -a "$P2" 2>/dev/null | tr '\n' ' ')"
  [ -n "$ID2" ] && {
    echo "   claude logs $ID2 (tail):"
    "$nat" logs "$ID2" 2>&1 | tail -25 | sed 's/^/     /'
  }
fi

echo
echo "== results =="
q1=$([ "$(subtree_alive "$PTYH1")" -gt 0 ] && agents_has "$ID1" && echo pass || echo FAIL)
q2=$([ "$(roster_cwd_for_id "$ID2")" = "$P2" ] && [ "$D2" = hi ] && echo pass || echo FAIL)
q3=$([ "$sib_p2" = yes ] && [ "$sib_p1" = no ] && echo pass || echo FAIL)
q4=$([ -f "$P1/DONE.txt" ] && echo FAIL-STALE || echo pass)
echo "   Q1 active session undisturbed:          $q1"
echo "   Q2 session 2 P2-bound + functional:     $q2"
echo "   Q3 sess2 binds P2 but NOT P1 (isolated): $q3"
echo "   Q4 no stale P1-bound spare claimed:     $q4"

echo
echo "== verdict =="
if [ "$q1" = pass ] && [ "$q2" = pass ] && [ "$q3" = pass ] && [ "$q4" = pass ]; then
  echo "   REAP-ONLY WORKS: no daemon restart; active untouched; session 2 exact-P2-bound; no leak/race."
else
  echo "   REAP-ONLY has an issue (see Q1-Q4). Compare with restart-per-launch."
fi

echo
cleanup
