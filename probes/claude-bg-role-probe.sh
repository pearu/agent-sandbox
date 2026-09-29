#!/usr/bin/env bash
# claude-bg-role-probe.sh -- a REAL `claude --bg` through the launcher, as #123 built it:
# the session, its daemon and workers inside the role's launch, the management verbs
# joining it, the daemon holding the launch, and --shutdown ending all of it.
#
#   1. `claude --model haiku --bg ...` from a throwaway project
#   2. where the daemon, spares and pty hosts live: inside the launch, or on the host?
#      is the keeper still running past its grace (held by the daemon)?
#   3. `claude agents --json` and `claude logs` see the session; wait for it to finish
#   4. `claude --shutdown`: is everything gone, and does `agents` then say "not running"?
#
# Runs the REAL launcher (`claude` on PATH must be the agent-sandbox launcher you want to
# test -- a checkout's engine through a symlink will do) with your login, on Haiku, in a
# throwaway project under /tmp. Removes the project and its engine state at the end.
#
#   bash probes/claude-bg-role-probe.sh
set -uo pipefail
command -v claude >/dev/null || {
  echo "no claude launcher on PATH" >&2
  exit 2
}
P="$(mktemp -d /tmp/ccbgrole-XXXXXX)" # no dot: Claude Code turns dots into dashes
cd "$P" || exit 2
slug="$(printf '%s' "$P" | sed 's:[^A-Za-z0-9-]:-:g')"
SB="${XDG_STATE_HOME:-$HOME/.local/state}/agent-sandbox/claude/$slug/default"
echo "project: $P"
echo "launcher: $(readlink -f "$(command -v claude)")"
echo "engine: $(claude --engine-version 2>/dev/null)"

# where PID lives: "inside" if its mount namespace is not ours
where() { [[ "$(readlink "/proc/$1/ns/mnt" 2>/dev/null)" == "$(readlink /proc/self/ns/mnt)" ]] && echo host || echo inside; }
# host pids of claude version binaries whose argv holds the exact token $1
claude_pids() {
  python3 - "$1" <<'PY'
import os, sys
tok = sys.argv[1].encode()
for p in sorted((x for x in os.listdir('/proc') if x.isdigit()), key=int):
    try:
        cmd = open(f'/proc/{p}/cmdline', 'rb').read().split(b'\0')
        exe = os.readlink(f'/proc/{p}/exe')
    except Exception:
        continue
    if '/.local/share/claude/versions/' in exe and tok in cmd:
        print(p)
PY
}
keeper_alive() {
  local s st
  read -r s st _ 2>/dev/null <"$SB/keeper/id" || return 1
  [[ -d "/proc/$s" ]]
}
before_daemons="$(claude_pids daemon | tr '\n' ' ')"
echo "daemons on this machine before: ${before_daemons:-none}"

echo
echo "=== 1. claude --bg"
claude --model haiku --bg 'Reply with exactly: BG-OK. Then stop.' 2>&1 | tail -5
echo "exit=${PIPESTATUS[0]}"

echo
echo "=== 2. where they live, and the keeper"
sleep 5 # past the keeper's idle grace
for tok in daemon --bg-spare --bg-pty-host; do
  for p in $(claude_pids "$tok"); do
    [[ " $before_daemons " == *" $p "* ]] && continue
    echo "  $tok: pid $p -> $(where "$p")"
  done
done
keeper_alive && echo "keeper: running, $(($(date +%s) - $(stat -c %Y "$SB/keeper/id"))) s after it started" || echo "keeper: NOT running"
cfg="$(find "$SB/config" -name '*claude.json' 2>/dev/null | head -1)"
[[ -n "$cfg" ]] && echo "trust recorded in the role's config: $(python3 -c 'import json,sys; print(bool((json.load(open(sys.argv[1])).get("projects") or {}).get(sys.argv[2],{}).get("hasTrustDialogAccepted")))' "$cfg" "$P")"

echo
echo "=== 3. agents and logs, joined"
ID=""
for _ in $(seq 60); do
  js="$(claude agents --json 2>/dev/null)"
  ID="$(python3 -c 'import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
print(a[0].get("id","") if a else "")' "$js")"
  st="$(python3 -c 'import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
print(" ".join(str(s.get("status") or s.get("state") or "?") for s in a) or "none")' "$js")"
  [[ -n "$ID" && "$st" != *working* && "$st" != *running* ]] && break
  sleep 2
done
echo "session: ${ID:-?}, status: ${st:-?}"
[[ -n "$ID" ]] && {
  echo "--- claude logs $ID (tail):"
  claude logs "$ID" 2>&1 | tail -5
}

echo
echo "=== 4. --shutdown"
claude --shutdown 2>&1 | tail -2
sleep 2
left=0
for tok in daemon --bg-spare --bg-pty-host; do
  for p in $(claude_pids "$tok"); do
    [[ " $before_daemons " == *" $p "* ]] && continue
    echo "  still alive: $tok pid $p ($(where "$p"))"
    left=1
  done
done
((left)) || echo "nothing of it left"
keeper_alive && echo "keeper: STILL running" || echo "keeper: gone"
echo "--- claude agents afterwards:"
claude agents 2>&1 | tail -2

echo
echo "=== cleanup"
[[ -d "$SB" ]] && {
  chmod -R u+rwX "${SB%/default}" 2>/dev/null
  rm -rf -- "${SB%/default}"
  echo "removed ${SB%/default}"
}
rm -rf -- "$P"
echo "removed $P"
