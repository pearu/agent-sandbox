#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Does an ADOPTED bg session stay FUNCTIONAL after restart-per-launch, not just
# alive? (R2 in wrapper-rosterreap-measure.sh proved the worker survives a
# supervisor kill and is re-listed; this checks it still WORKS.)
#
# Session 1's task runs a shell command that sleeps PAST the restart, then writes
# a unix timestamp to DONE.txt in its project and prints ADOPTION_OK. We restart
# (force-kill the supervisor) while that command is mid-flight, start session 2
# to bring up a fresh supervisor that adopts session 1, then check three paths:
#   F1 (work continuity): DONE.txt appears with a timestamp AFTER the restart
#      -> the sandboxed worker kept executing its tool across the restart.
#   F2 (read path via tooling): `claude logs <id>` shows ADOPTION_OK.
#   F3 (control path via tooling): `claude stop <id>` actually terminates the
#      adopted worker's process tree.
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses the
# installed runtime. HOST only. Cleans up EVERYTHING (bg-only kills; foreground
# sandboxed sessions are never touched).
#     ./probes/wrapper-adopt-func-measure.sh
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
  "$nat" daemon stop >/dev/null 2>&1 || true
  for sig in TERM KILL; do
    [ -n "$sup" ] && kill "-$sig" "$sup" 2>/dev/null || true
    for p in $(all_bg_pids); do kill "-$sig" "$p" 2>/dev/null || true; done
    sleep 1
  done
}
cleanup() {
  echo "== cleanup (everything, bg-only) =="
  kill_everything
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
echo "== session 1: task sleeps past the restart, then writes DONE.txt + ADOPTION_OK =="
setproj "$P1"
TASK='run this exact shell command and wait for it: sleep 45 && date +%s > DONE.txt && echo ADOPTION_OK'
OUT1="$(cd "$P1" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg "$TASK" 2>&1)"
ID1="$(printf '%s' "$OUT1" | id_from_out)"
echo "   session 1 id: ${ID1:-<none>}"
PTYH1="$(wait_worker "$ID1" 40)" || true
if [ -z "$PTYH1" ]; then
  echo "   SETUP FAILED: no rostered worker for session 1"
  printf '%s\n' "$OUT1" | sed 's/^/     /'
  cleanup
  exit 1
fi
SUP1="$(roster_supervisor)"
echo "   worker pid: $PTYH1 ; supervisor: ${SUP1:-<none>}"

echo
echo "== restart: force-kill supervisor $SUP1 mid-task, then session 2 (triggers adoption) =="
RESTART_TS="$(date +%s)"
echo "   restart at unix ts: $RESTART_TS (DONE.txt must carry a LATER ts to prove post-restart work)"
[ -n "$SUP1" ] && kill "$SUP1" 2>/dev/null || true
sleep 3
echo "   session 1 in-agents right after supervisor kill: $(agents_has "$ID1" && echo yes || echo no)"
setproj "$P2"
(cd "$P2" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'print the word ready and stop' >/dev/null 2>&1) || true
SUP2="$(roster_supervisor)"
echo "   new supervisor: ${SUP2:-<none>} ; session 1 adopted (in-agents): $(agents_has "$ID1" && echo yes || echo no)"

echo
echo "== F1: wait up to 90s for DONE.txt (post-restart work continuity) =="
DONE_TS=""
for _ in $(seq 1 30); do
  sleep 3
  [ -f "$P1/DONE.txt" ] && {
    DONE_TS="$(cat "$P1/DONE.txt" 2>/dev/null)"
    break
  }
done
echo "   DONE.txt present: $([ -n "$DONE_TS" ] && echo yes || echo no) ; contents(ts)=${DONE_TS:-<none>} ; restart_ts=$RESTART_TS"
f1=no
if [ -n "$DONE_TS" ] && [ "$DONE_TS" -ge "$RESTART_TS" ] 2>/dev/null; then f1=yes; fi
echo "   F1 (DONE.txt written AFTER the restart): $f1"

echo
echo "== F2: read path -- claude logs <id> shows ADOPTION_OK =="
LOGS="$("$nat" logs "$ID1" 2>&1)"
echo "$LOGS" | tail -15 | sed 's/^/     /'
f2=no
printf '%s' "$LOGS" | grep -q 'ADOPTION_OK' && f2=yes
echo "   F2 (ADOPTION_OK in logs): $f2"

echo
echo "== F3: control path -- claude stop <id> terminates the adopted worker =="
before="$(subtree_alive "$PTYH1")"
"$nat" stop "$ID1" >/dev/null 2>&1 || true
sleep 4
after="$(subtree_alive "$PTYH1")"
echo "   worker subtree procs alive: before=$before after-stop=$after"
f3=no
[ "$after" -eq 0 ] && f3=yes
echo "   F3 (stop terminated the adopted worker): $f3"

echo
echo "== verdict =="
if [ "$f1" = yes ] && [ "$f2" = yes ] && [ "$f3" = yes ]; then
  echo "   FUNCTIONAL AFTER ADOPTION: work continued across the restart, output is readable,"
  echo "   and the session responds to control. Restart-per-launch preserves usable sessions."
else
  echo "   NOT fully functional (F1=$f1 F2=$f2 F3=$f3): see the sections above. An adopted session"
  echo "   is alive but some path (work continuity / read / control) did not hold post-restart."
fi

echo
cleanup
