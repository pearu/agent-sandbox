#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Ground-truth probe for restart-per-launch + a roster-keyed reap, using REAL
# sandboxed workers (bwrap via --wrap). It DUMPS the process tree at every stage
# rather than guessing it, and targets the SUPERVISOR (roster.supervisorPid) --
# the process that actually parents the pty-hosts -- not the `daemon run` entry.
#
# The daemon is two processes: `daemon run` and a supervisor (roster.
# supervisorPid). Each pool slot is: supervisor -> pty-host (native, argv has
# --bg-pty-host, direct child of supervisor) -> spare (via the wrapper -> bwrap,
# argv has --bg-spare). roster.json workers are keyed by short session id and
# carry {pid (=pty-host), sessionId, cwd (=bound project)}.
#
# Questions:
#   R1. Does `claude daemon stop` refuse while a session is active? (If so,
#       restart-per-launch must force-kill the supervisor.)
#   R2. Does an ACTIVE session survive a supervisor force-kill (the restart)?
#   R3. What becomes of the old idle pool after the restart: die, orphan (leak),
#       or get re-homed by the new supervisor (reuse)?
#   R4. Is an ancestor-aware roster-keyed reap safe -- keep any proc whose
#       parent-chain contains a rostered launcher OR the live supervisor, reap
#       everything else -- sparing active sessions while clearing the leak?
#       (roster.pid is the LAUNCHER, and killing a pty-host does not cascade to
#       its spare, so the reap must sweep every leaked proc, not just pty-hosts.)
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses the
# installed runtime (proxy/CA/seccomp). HOST only. Cleans up EVERYTHING.
#     ./probes/wrapper-rosterreap-measure.sh
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
commof() { ps -o comm= -p "$1" 2>/dev/null; }
ppidof() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
count_alive() {
  local n=0 p
  for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  echo "$n"
}
show_roster() {
  echo "   --- roster.json ---"
  python3 - "$ROSTER" 2>/dev/null <<'PY' || echo "     (absent/unreadable)"
import json, sys
d = json.load(open(sys.argv[1]))
sup = d.get("supervisorPid")
print(f"     supervisorPid: {sup}")
for k, w in (d.get("workers", {}) or {}).items():
    if isinstance(w, dict):
        print(f"     worker {k}: pid={w.get('pid')} cwd={w.get('cwd')} isolation={(w.get('dispatch') or {}).get('isolation')}")
PY
}
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
out = set()
for w in (d.get("workers", {}) or {}).values():
    if isinstance(w, dict) and isinstance(w.get("pid"), int):
        out.add(w["pid"])
print(" ".join(str(x) for x in sorted(out)))
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
    if not isinstance(w, dict):
        continue
    hay = [str(k), str(w.get("sessionId", ""))]
    if any(sid in h or h.startswith(sid) for h in hay):
        if isinstance(w.get("pid"), int):
            print(w["pid"])
            sys.exit(0)
PY
}
all_bg_pids() { pgrep -f -- '--bg-pty-host|--bg-spare|daemon run' 2>/dev/null | sort -un; }
# real pty-hosts = --bg-pty-host procs that are direct children of the supervisor
pty_hosts_of() {
  local sup="$1" p
  for p in $(pgrep -f -- '--bg-pty-host' 2>/dev/null); do
    [ "$(ppidof "$p")" = "$sup" ] && echo "$p"
  done
}
agents_json() { "$nat" agents --json 2>/dev/null; }
agents_has() { agents_json | grep -qi "$1"; }
id_from_out() { grep -i backgrounded | grep -oiE '[0-9a-f]{8}' | head -1; }
dump_tree() {
  echo "   --- process tree (pid ppid comm args) ---"
  local p
  for p in $(all_bg_pids); do
    [ -e "/proc/$p" ] || continue
    printf '     %6s ppid=%-7s %-8s %s\n' \
      "$p" "$(ppidof "$p")" "$(commof "$p")" "$(ps -o args= -p "$p" 2>/dev/null | cut -c1-84)"
  done
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
  echo "== cleanup (everything) =="
  kill_everything
  pkill -f -- 'sleep 301' 2>/dev/null || true
  pkill -f -- 'sleep 302' 2>/dev/null || true
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
echo "== session 1: sandboxed ACTIVE bg session in P1 =="
setproj "$P1"
OUT1="$(cd "$P1" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'run this exact shell command and wait for it: sleep 301' 2>&1)"
ID1="$(printf '%s' "$OUT1" | id_from_out)"
echo "   session 1 id: ${ID1:-<none>}"
PTYH1="$(wait_worker "$ID1" 40)" || true
if [ -z "$PTYH1" ]; then
  echo "   SETUP FAILED: session 1 never showed a live rostered worker."
  printf '%s\n' "$OUT1" | sed 's/^/     /'
  show_roster
  dump_tree
  cleanup
  exit 1
fi
sleep 5
SUP1="$(roster_supervisor)"
echo "   ACTIVE1 pty-host (rostered pid): $PTYH1 ; supervisor: ${SUP1:-<none>} ; daemon-run: $(pgrep -f 'daemon run' | tr '\n' ' ')"
show_roster
dump_tree
mapfile -t PH1 < <(pty_hosts_of "${SUP1:-0}")
echo "   pty-hosts under supervisor $SUP1: ${PH1[*]:-<none>}"
mapfile -t IDLEH1 < <(for a in "${PH1[@]}"; do [ "$a" = "$PTYH1" ] || echo "$a"; done)
echo "   idle pty-hosts (to be orphaned by restart): ${IDLEH1[*]:-<none>}"

echo
echo "== R1: attempt \`claude daemon stop\` while session 1 is active =="
"$nat" daemon stop 2>&1 | sed 's/^/   /'
sleep 3
echo "   after daemon stop: session 1 in agents=$(agents_has "$ID1" && echo yes || echo no) ; supervisor $SUP1 alive=$([ -n "$SUP1" ] && alive "$SUP1" || echo '?')"
echo "   ACTIVE1 pty-host $PTYH1 alive=$(alive "$PTYH1")"

echo
echo "== R2/R3: force-kill supervisor $SUP1 (what restart-per-launch must do), then session 2 =="
[ -n "$SUP1" ] && kill "$SUP1" 2>/dev/null || true
sleep 4
echo "   after supervisor kill:"
echo "     ACTIVE1 pty-host $PTYH1 alive=$(alive "$PTYH1") ppid=$(ppidof "$PTYH1") in-agents=$(agents_has "$ID1" && echo yes || echo no)"
for a in "${IDLEH1[@]}"; do echo "     idle pty-host $a alive=$(alive "$a") ppid=$(ppidof "$a")"; done
dump_tree

setproj "$P2"
OUT2="$(cd "$P2" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'run this exact shell command and wait for it: sleep 302' 2>&1)"
ID2="$(printf '%s' "$OUT2" | id_from_out)"
echo "   session 2 id: ${ID2:-<none>}"
PTYH2="$(wait_worker "$ID2" 40)" || true
SUP2="$(roster_supervisor)"
echo "   ACTIVE2 pty-host: ${PTYH2:-<none>} ; new supervisor: ${SUP2:-<none>}"
echo "   session 1 ($ID1) still alive: in-agents=$(agents_has "$ID1" && echo yes || echo no) pty-host $PTYH1 alive=$(alive "$PTYH1")   <-- R2"
echo "   old idle pty-hosts alive: $(count_alive "${IDLEH1[@]}") of ${#IDLEH1[@]}   <-- R3 (die/leak/reuse)"
for a in "${IDLEH1[@]}"; do
  echo "     old idle pty-host $a: alive=$(alive "$a") ppid=$(ppidof "$a") rostered=$(roster_hostpids | grep -qw "$a" && echo yes || echo no)"
done
show_roster
dump_tree

echo
echo "== R4: ANCESTOR-AWARE reap, SEEDED ONLY FROM LEAKED BG MARKERS =="
echo "   CRITICAL: never enumerate all-bwrap / all-engine procs -- that matches FOREGROUND"
echo "   sandboxed sessions too and would kill them. Seed strictly from --bg-pty-host/--bg-spare"
echo "   markers that have no live-bg ancestor, then expand within their own process trees only."
declare -A KEEPANC=()
for h in $(roster_hostpids); do KEEPANC["$h"]=1; done
[ -n "$SUP2" ] && KEEPANC["$SUP2"]=1
has_kept_ancestor() {
  local p="$1"
  for _ in $(seq 1 30); do
    { [ -z "$p" ] || [ "$p" = 1 ]; } && break
    [ -n "${KEEPANC[$p]:-}" ] && return 0
    p="$(ppidof "$p")"
  done
  return 1
}
# all descendants of a pid (BFS)
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
# orphaned bg-related ancestors of a leaked marker (walk up while bg-related, not protected)
bg_ancestors() {
  local p args
  p="$(ppidof "$1")"
  for _ in $(seq 1 30); do
    { [ -z "$p" ] || [ "$p" = 1 ]; } && break
    [ -n "${KEEPANC[$p]:-}" ] && break
    args="$(ps -o args= -p "$p" 2>/dev/null)"
    case "$args" in
      *"$ENGINE"* | *bwrap* | *--bg-pty-host* | *--bg-spare*) echo "$p" ;;
      *) break ;;
    esac
    p="$(ppidof "$p")"
  done
}
declare -A KILLSET=()
SEEDS=()
for m in $(pgrep -f -- '--bg-pty-host|--bg-spare' 2>/dev/null); do
  has_kept_ancestor "$m" && continue # belongs to a live session / live daemon
  SEEDS+=("$m")
  KILLSET["$m"]=1
  for d in $(descendants "$m"); do KILLSET["$d"]=1; done
  for a in $(bg_ancestors "$m"); do KILLSET["$a"]=1; done
done
REAPED=("${!KILLSET[@]}")
echo "   leaked bg-marker seeds: ${SEEDS[*]:-<none>}"
for a in "${REAPED[@]}"; do kill "$a" 2>/dev/null || true; done
sleep 2
for a in "${REAPED[@]}"; do kill -9 "$a" 2>/dev/null || true; done
sleep 1
echo "   reaped (leaked bg trees): ${REAPED[*]:-<none>}"
echo "   leaked procs still alive after reap: $(count_alive "${REAPED[@]}") of ${#REAPED[@]}"

echo
echo "== results =="
a1="$(agents_has "$ID1" && echo yes || echo no)"
a2="$(agents_has "$ID2" && echo yes || echo no)"
echo "   session 1 ($ID1): in-agents=$a1  pty-host $PTYH1 alive=$(alive "$PTYH1")"
echo "   session 2 ($ID2): in-agents=$a2  pty-host ${PTYH2:-?} alive=$([ -n "$PTYH2" ] && alive "$PTYH2" || echo '?')"
leaked_left="$(count_alive "${REAPED[@]}")"
echo "   leaked procs alive after reap: $leaked_left of ${#REAPED[@]}"
dump_tree

echo
echo "== verdict (R4) =="
if [ "$a1" = yes ] && [ "$a2" = yes ] && [ "$leaked_left" -eq 0 ]; then
  echo "   SAFE REAP CONFIRMED: both active sessions survived; every leaked proc cleared."
  echo "   -> restart-per-launch + ancestor-aware reap: exact isolation, active-safe, no leak."
elif [ "$a1" != yes ] || [ "$a2" != yes ]; then
  echo "   UNSAFE: an active session died -> the ancestor rule still mis-scoped something (see trees)."
else
  echo "   INCOMPLETE: leaked procs survived the sweep ($leaked_left) -> widen the bg universe / retry KILL."
fi
echo "   (R1/R2/R3 were established above; this verdict is only about the reap.)"
echo
cleanup
