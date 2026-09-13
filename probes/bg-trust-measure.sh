#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Decides 3b's trust handling. When `claude --bg` runs in an UNTRUSTED project
# (fresh dir, not in ~/.claude.json), what happens? A bg session cannot answer
# the interactive workspace-trust prompt.
#
#   Arm A (NATIVE, untrusted): --bg via a PASSTHROUGH wrapper that execs the
#     native binary (daemon + workers run native, untrapped -- NOT via our PATH
#     launcher, which would fail daemon startup). Does the task run (DONE.txt
#     appears) or does trust block it? This is true native trust behavior.
#   Arm B (WRAPPED, untrusted): our --wrap path, no pre-trust. Same question --
#     does OUR sandboxing change the trust behavior vs native?
#
# Reading:
#   - Native BLOCKS  -> it's a native limitation; 3b should MATCH native (no
#     special trust handling; behave as native does).
#   - Native WORKS but wrapped BLOCKS -> our path introduces the trust wall;
#     3b should AUTO-TRUST the project (+ document it, + a disable hint).
#   - Both WORK -> no trust handling needed at all.
#
# Trust is a per-path flag independent of sandboxing, so workers here need not be
# truly sandboxed for the trust question. HOST only. bg-only kills. Cleans up,
# and removes any ~/.claude.json project entries it created.
#     ./probes/bg-trust-measure.sh
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

all_bg_pids() { pgrep -f -- '--bg-pty-host|--bg-spare|daemon run' 2>/dev/null | sort -un; }
agents_json() { "$nat" agents --json 2>/dev/null; }
agents_has() { agents_json | grep -qi "$1"; }
id_from_out() { grep -i backgrounded | grep -oiE '[0-9a-f]{8}' | head -1; }

SHIM="$(mktemp)"
printf '#!/bin/sh\nexec "%s" --profile claude --wrap "$@"\n' "$ENGINE" >"$SHIM"
chmod +x "$SHIM"
# native-equivalent wrapper: drop the resolved-binary token ($1, which is `claude`
# -> our PATH launcher, the trap) and exec the NATIVE binary directly. This makes
# the daemon + workers run native (untrapped, unsandboxed), so Arm A measures true
# native trust behavior instead of the launcher's daemon trap.
PASS="$(mktemp)"
printf '#!/bin/sh\nshift\nexec "%s" "$@"\n' "$nat" >"$PASS"
chmod +x "$PASS"
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"
mkdir -p "$base"
setproj() { printf '%s' "$1" >"$base/bg-project"; }

# print the project's ~/.claude.json entry (or "<absent>")
show_trust() {
  python3 - "$CJSON" "$1" 2>/dev/null <<'PY' || echo "     <unreadable>"
import json, sys
d = json.load(open(sys.argv[1]))
e = (d.get("projects", {}) or {}).get(sys.argv[2])
if e is None:
    print("     <absent from projects>")
else:
    print(f"     hasTrustDialogAccepted={e.get('hasTrustDialogAccepted')}  keys={sorted(e.keys())[:8]}")
PY
}
untrust() {
  python3 - "$CJSON" "$1" 2>/dev/null <<'PY' || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PY
}
stop_daemon() {
  local sig p
  for id in $(agents_json | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
    "$nat" rm "$id" >/dev/null 2>&1 || true
  done
  "$nat" daemon stop --any >/dev/null 2>&1 || "$nat" daemon stop >/dev/null 2>&1 || true
  for sig in TERM KILL; do
    for p in $(all_bg_pids); do kill "-$sig" "$p" 2>/dev/null || true; done
    sleep 1
  done
}

run_arm() {
  # $1 = label, $2 = project dir, $3 = "native"|"wrapped"
  local label="$1" proj="$2" mode="$3" out id found=no
  echo
  echo "== Arm $label ($mode, UNTRUSTED): $proj =="
  echo "   trust entry BEFORE:"
  show_trust "$proj"
  local wrapper="$PASS"
  [ "$mode" = wrapped ] && wrapper="$SHIM"
  setproj "$proj"
  out="$(cd "$proj" && CLAUDE_CODE_PROCESS_WRAPPER="$wrapper" "$nat" --bg 'create a file named DONE.txt containing the word hi in the current directory, then stop' 2>&1)"
  echo "   --- --bg output ---"
  printf '%s\n' "$out" | sed 's/^/     /'
  id="$(printf '%s' "$out" | id_from_out)"
  echo "   session id: ${id:-<none>}"
  for _ in $(seq 1 25); do
    sleep 3
    [ -f "$proj/DONE.txt" ] && {
      found=yes
      break
    }
  done
  echo "   DONE.txt present: $found"
  if [ -n "$id" ]; then
    echo "   --- claude logs $id (tail) ---"
    "$nat" logs "$id" 2>&1 | tail -20 | sed 's/^/     /'
  fi
  echo "   trust entry AFTER:"
  show_trust "$proj"
  echo "   RESULT Arm $label: $([ "$found" = yes ] && echo WORKED || echo BLOCKED)"
  stop_daemon
}

echo "engine: $ENGINE ; uid: $UID_ ; runtime: $nat"
echo "== clean slate (abort if live host bg sessions) =="
if agents_has '"id"'; then
  echo "   host has live bg sessions; aborting to stay safe"
  rm -f "$SHIM" "$PASS"
  exit 1
fi
stop_daemon
rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true

TMP="$(mktemp -d)"
PA="$TMP/native-proj"
PB="$TMP/wrapped-proj"
mkdir -p "$PA" "$PB"
# make sure neither is trusted
untrust "$PA"
untrust "$PB"

run_arm A "$PA" native
run_arm B "$PB" wrapped

echo
echo "== verdict =="
echo "   Compare 'RESULT Arm A' (native) and 'RESULT Arm B' (wrapped) above, and the trust entries:"
echo "   - A BLOCKED            -> native limitation; 3b MATCHES native (no special handling)."
echo "   - A WORKED, B BLOCKED  -> our path adds the wall; 3b AUTO-TRUSTS (+docs +disable hint)."
echo "   - A WORKED, B WORKED   -> no trust handling needed."

echo
echo "== cleanup =="
stop_daemon
untrust "$PA"
untrust "$PB"
rm -f "$SHIM" "$PASS" "$base/bg-project"
rm -rf "$TMP"
echo "   bg workers remaining: $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l | tr -d ' ')"
echo "done."
