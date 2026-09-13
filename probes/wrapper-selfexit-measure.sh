#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Definitive check for restart-per-launch, with REAL sandboxed workers (not a
# native resolver): the workers run under bwrap via the engine's --wrap role,
# which adds --die-with-parent -- so survival on daemon-kill can differ from
# native workers. With an active session AND idle spares present (all bwrap'd),
# kill ONLY the daemon and confirm the active session's sandboxed worker
# survives while the idle sandboxed spares self-exit.
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER (daemon passes
# through host-side; --bg-spare workers are bwrap'd). Reuses the installed 0.2.0
# runtime (proxy/CA/seccomp). HOST only. Starts a real sandboxed bg session
# (sleep 300); cleans up only what it created.
#     ./probes/wrapper-selfexit-measure.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "engine has no --wrap (need the feat/wrapper-role branch): $ENGINE"
  exit 1
}
nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
UID_="$(id -u)"
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }
commof() { ps -o comm= -p "$1" 2>/dev/null; }
ppidof() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

systemctl --user is-active agent-sandbox-mitmproxy.service >/dev/null 2>&1 \
  || echo "warning: proxy service not active; a proxy-mode worker may fail to sandbox"

# The wrapper Claude Code invokes: our engine, claude profile, --wrap.
SHIM="$(mktemp)"
printf '#!/bin/sh\nexec "%s" --profile claude --wrap "$@"\n' "$ENGINE" >"$SHIM"
chmod +x "$SHIM"

echo "engine: $ENGINE ; uid: $UID_"
echo "== record PRE-EXISTING bwrap workers (never touched) =="
PRE="$(pgrep -f -- '--bg-spare' 2>/dev/null | sort -n)"
echo "   pre-existing: $(echo "$PRE" | grep -c . || true)"

echo "== clean slate for the host daemon (only if no host bg sessions) =="
if ! "$nat" agents --json 2>/dev/null | grep -q '"id"'; then
  "$nat" daemon stop >/dev/null 2>&1 || true
  sleep 2
  rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true
  # kill LEAKED background-worker bwraps from prior runs (only --bg-spare/
  # --bg-pty-host; foreground sessions never carry those, so they are untouched)
  for q in $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null); do
    [ "$(commof "$q")" = bwrap ] && kill "$q" 2>/dev/null || true
  done
  sleep 2
  for q in $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null); do
    [ "$(commof "$q")" = bwrap ] && kill -9 "$q" 2>/dev/null || true
  done
  echo "   cleared (incl. leaked bg-worker bwraps)"
  PRE="$(pgrep -f -- '--bg-spare' 2>/dev/null | sort -n)"
else
  echo "   host has live bg sessions; aborting to stay safe"
  exit 1
fi

P0="$(mktemp -d)/proj-$$"
mkdir -p "$P0"
# 3c delivery: record the project so the sandboxed worker binds it.
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"
mkdir -p "$base"
printf '%s' "$P0" >"$base/bg-project"

# Pre-trust the temp project so the bg session doesn't hit the interactive
# workspace-trust prompt (a bg session can't answer it).
CJSON="$HOME/.claude.json"
python3 - "$CJSON" "$P0" <<'PYT'
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PYT

echo "== start a SANDBOXED bg session (sleep 300) in $P0 =="
(cd "$P0" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'run this exact shell command and wait for it: sleep 300' >"$P0/bg.out" 2>&1) || true

echo "== wait for the sandboxed active worker (bwrap ancestor of sleep 300) =="
ACTIVE=""
for _ in $(seq 1 40); do
  sleep 3
  sp="$(pgrep -f -- 'sleep 300' 2>/dev/null | head -1)"
  [ -n "$sp" ] || continue
  p="$sp"
  for _ in $(seq 1 12); do
    [ -z "$p" ] || [ "$p" = 1 ] && break
    [ "$(commof "$p")" = bwrap ] && {
      ACTIVE="$p"
      break
    }
    p="$(ppidof "$p")"
  done
  [ -n "$ACTIVE" ] && break
done
if [ -z "$ACTIVE" ]; then
  echo "   SETUP FAILED: no sandboxed active worker (bwrap over sleep 300). --bg output:"
  sed 's/^/     /' "$P0/bg.out" 2>/dev/null
  "$nat" daemon stop >/dev/null 2>&1 || true
  pkill -f -- 'sleep 300' 2>/dev/null || true
  rm -f "$SHIM" "$base/bg-project"
  rm -rf "$(dirname "$P0")"
  exit 1
fi
echo "   active sandboxed worker (bwrap): $ACTIVE  comm=$(commof "$ACTIVE")"

# idle sandboxed spares = bwrap procs with --bg-spare, not PRE, not ACTIVE
mapfile -t IDLE < <(for q in $(pgrep -f -- '--bg-spare' 2>/dev/null); do
  [ "$(commof "$q")" = bwrap ] || continue
  [ "$q" = "$ACTIVE" ] && continue
  echo "$PRE" | grep -qx "$q" && continue
  echo "$q"
done)
DAEMON="$(pgrep -f 'daemon run' 2>/dev/null | head -1)"
echo "== idle sandboxed spares: ${IDLE[*]:-<none>} ; daemon: ${DAEMON:-<none>} =="

echo
echo "== kill ONLY the daemon; wait 12s =="
[ -n "$DAEMON" ] && kill "$DAEMON" 2>/dev/null || true
sleep 12

echo "== results (sandboxed workers) =="
echo "   active worker $ACTIVE alive: $(alive "$ACTIVE")"
idle_alive=0
for q in "${IDLE[@]}"; do
  a="$(alive "$q")"
  echo "   idle spare $q alive: $a"
  [ "$a" = yes ] && idle_alive=$((idle_alive + 1))
done

echo
echo "== verdict =="
if [ "$(alive "$ACTIVE")" = yes ] && [ "$idle_alive" -eq 0 ]; then
  echo "   CLEAN (sandboxed): active session survived; idle sandboxed spares self-exited."
  echo "   -> restart-per-launch holds for the REAL sandboxed workers; no manual reap."
elif [ "$(alive "$ACTIVE")" != yes ]; then
  echo "   active sandboxed worker DIED on daemon kill (likely --die-with-parent via the pty-host)."
  echo "   -> restart-per-launch would KILL running bg sessions; design needs rework."
else
  echo "   active survived but $idle_alive idle sandboxed spare(s) lingered -> not self-exiting; reap/leak concern."
fi

echo "== cleanup (only ours) =="
kill "$ACTIVE" 2>/dev/null || true
for q in "${IDLE[@]}"; do kill "$q" 2>/dev/null || true; done
sleep 1
kill -9 "$ACTIVE" 2>/dev/null || true
for q in "${IDLE[@]}"; do kill -9 "$q" 2>/dev/null || true; done
for id in $("$nat" agents --json 2>/dev/null | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
  "$nat" rm "$id" >/dev/null 2>&1 || true
done
"$nat" daemon stop >/dev/null 2>&1 || true
pkill -f -- 'sleep 300' 2>/dev/null || true
python3 - "$CJSON" "$P0" <<'PYT' 2>/dev/null || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PYT
rm -f "$SHIM" "$base/bg-project"
rm -rf "$(dirname "$P0")"
echo "done."
