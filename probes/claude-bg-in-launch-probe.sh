#!/usr/bin/env bash
# claude-bg-in-launch-probe.sh -- does `claude --bg` work INSIDE a running launch, with
# its daemon and worker inside too? Evidence for #121 (one launch per role, every app
# joins it) applied to background sessions: if the daemon starts inside the launch,
# the host-side wrapper machinery (CLAUDE_CODE_PROCESS_WRAPPER, project record,
# pool clearing) is not needed for a role's background sessions.
#
#   1. a real launch of a throwaway project, `claude --exec` of a sleeper (the keeper)
#   2. join it (probes/join-launch.py) and run `claude --bg "..."` there
#   3. where are the daemon and the worker: inside the launch's namespaces, or host?
#   4. `claude agents` / `claude logs` from another joined process see the session?
#   5. does the daemon exit on its own once the session is finished? (waits up to $IDLE s)
#   6. when the keeper exits, is everything inside gone?
#
# Runs the REAL launcher (`claude` on PATH must be the agent-sandbox launcher) with your
# login, on Haiku, in a throwaway project under /tmp. Removes the project, its engine
# state directory and its native transcript directory at the end.
#
#   bash probes/claude-bg-in-launch-probe.sh
#   IDLE=180 bash probes/claude-bg-in-launch-probe.sh      # longer idle wait (default 90)
set -uo pipefail

ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JOIN="$ENGINE_DIR/probes/join-launch.py"
BPF="${AGENT_SANDBOX_SECCOMP_DIR:-$HOME/.local/share/agent-sandbox/seccomp}/x86_64.bpf"
IDLE="${IDLE:-90}"
command -v claude >/dev/null || {
  echo "no claude launcher on PATH" >&2
  exit 2
}
[[ -r "$JOIN" ]] || {
  echo "missing $JOIN" >&2
  exit 2
}
[[ -r "$BPF" ]] || {
  echo "no seccomp filter at $BPF (run install.sh); continuing without it" >&2
  BPF=""
}
P="$(mktemp -d /tmp/ccbg-proj-XXXXXX)" # no dot: Claude Code turns dots into dashes
cd "$P" || exit 2
echo "project: $P"
NATIVE="$(printf '%s\n' "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
echo "launcher: $(command -v claude); native: $NATIVE"
# Inside, the native binary is bound read-only at its own path but that directory is
# not on PATH, so every claude command run inside names it by path.

# where a process lives: "inside" if its mount namespace is not ours
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
join() { # join CMD... -- run CMD inside the launch, as its equal
  JOIN_SECCOMP_BPF="$BPF" python3 "$JOIN" "$INSIDE" "$@"
}

# ---- 1. the launch -------------------------------------------------------------
echo
echo "=== 1. the launch (keeper stand-in)"
claude --exec sh -c 'echo started >keeper.started; exec sleep 900' >"$P/launch.out" 2>&1 &
LAUNCHER=$!
for _ in $(seq 60); do
  [[ -e "$P/keeper.started" ]] && break
  sleep 0.5
done
[[ -e "$P/keeper.started" ]] || {
  echo "the launch did not start:"
  cat "$P/launch.out"
  exit 1
}
INSIDE=""
for _ in $(seq 20); do
  INSIDE="$(
    python3 - "$P" <<'PY'
import os, sys
me = os.readlink('/proc/self/ns/mnt')
for p in sorted((x for x in os.listdir('/proc') if x.isdigit()), key=int):
    try:
        cmd = open(f'/proc/{p}/cmdline', 'rb').read().split(b'\0')
        if cmd[:2] == [b'sleep', b'900'] and os.readlink(f'/proc/{p}/ns/mnt') != me:
            print(p); break
    except Exception: pass
PY
  )"
  [[ -n "$INSIDE" ]] && break
  sleep 0.5
done
[[ -n "$INSIDE" ]] || {
  echo "cannot find the sleeper inside"
  kill "$LAUNCHER"
  exit 1
}
echo "inside process (host pid $INSIDE): user ns $(readlink "/proc/$INSIDE/ns/user"), host $(readlink /proc/self/ns/user)"
echo "daemons before: $(claude_pids daemon | tr '\n' ' ')"

# ---- 2. claude --bg from a joined process ---------------------------------------
echo
echo "=== 2. claude --bg inside"
# Claude Code's own workspace trust, recorded the way the profile records it for a
# wrapped worker: in this project's config copy, which the launch created.
slug="$(printf '%s' "$P" | sed 's:[^A-Za-z0-9-]:-:g')"
COPY="$HOME/.local/state/agent-sandbox/claude/$slug/claude.json"
AS_CJ="$COPY" AS_PROJ="$P" python3 - <<'PY2'
import json, os
cj, proj = os.environ["AS_CJ"], os.environ["AS_PROJ"]
try: d = json.load(open(cj))
except Exception: d = {}
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(cj, "w"))
print("trust recorded in", cj)
PY2
BG_OUT="$(join /bin/sh -c "$NATIVE --model haiku --bg 'Reply with exactly: BG-OK. Then stop.' 2>&1")"
echo "$BG_OUT" | head -5
sleep 5
ID="$(join /bin/sh -c "$NATIVE agents --json 2>/dev/null" | python3 -c 'import json,sys
try: a=json.load(sys.stdin)
except Exception: a=[]
print(a[0].get("id","") if a else "")')"
echo "session id (from agents --json): ${ID:-?}"

# ---- 3. where the daemon and the worker live --------------------------------------
echo
echo "=== 3. where do they live"
for tok in daemon --bg-spare --bg-pty-host; do
  for p in $(claude_pids "$tok"); do echo "  $tok: pid $p -> $(where "$p")"; done
done
[[ -z "$(claude_pids daemon)" ]] && echo "  (no daemon process found by argv token 'daemon')"

# ---- 4. seen from another joined process ------------------------------------------
echo
echo "=== 4. from another joined process"
join /bin/sh -c "$NATIVE agents --json 2>&1 | head -c 600"
echo
echo "--- wait for the session to finish (up to 120 s)"
for _ in $(seq 60); do
  st="$(join /bin/sh -c "$NATIVE agents --json 2>/dev/null" | python3 -c 'import json,sys
try: a=json.load(sys.stdin)
except Exception: a=[]
print(" ".join(str(s.get("status") or s.get("state") or "?") for s in a) or "none")')"
  [[ "$st" != *working* && "$st" != *running* && "$st" != none ]] && break
  sleep 2
done
echo "agents status: $st"
[[ -n "$ID" ]] && {
  echo "--- claude logs $ID (tail):"
  join /bin/sh -c "$NATIVE logs $ID 2>&1 | tail -5"
}
tr_files=("$HOME/.claude/projects/"*"$(basename "$P")"/*.jsonl)
[[ -e "${tr_files[0]}" ]] || tr_files=()
echo "--- the transcript, host side: ${#tr_files[@]} file(s) under ~/.claude/projects/*$(basename "$P")"

# ---- 5. does the daemon exit when idle -------------------------------------------
echo
echo "=== 5. idle: does the daemon exit on its own (waiting up to $IDLE s)"
t0=$SECONDS
while ((SECONDS - t0 < IDLE)); do
  [[ -z "$(claude_pids daemon)" ]] && break
  sleep 5
done
if [[ -z "$(claude_pids daemon)" ]]; then echo "daemon gone after $((SECONDS - t0)) s"; else echo "daemon still running after $IDLE s: $(claude_pids daemon | tr '\n' ' ') (spares: $(claude_pids --bg-spare | wc -l))"; fi

# ---- 6. the keeper exits ------------------------------------------------------------
echo
echo "=== 6. keeper exits: is everything inside gone"
kill "$INSIDE" 2>/dev/null
sleep 3
left=0
for tok in daemon --bg-spare --bg-pty-host; do for p in $(claude_pids "$tok"); do
  echo "  still alive: $tok pid $p ($(where "$p"))"
  left=1
done; done
((left)) || echo "nothing of it left"
wait "$LAUNCHER" 2>/dev/null
echo "launcher exit=$?"

# ---- cleanup ---------------------------------------------------------------------------
echo
echo "=== cleanup"
for d in "$HOME/.local/state/agent-sandbox/claude/$slug" "$HOME/.claude/projects/"*"$(basename "$P")"; do
  [[ -d "$d" && "$d" == *"$(basename "$P")"* ]] && {
    chmod -R u+rwX "$d" 2>/dev/null
    rm -rf -- "$d"
    echo "removed $d"
  }
done
rm -rf -- "$P"
echo "removed $P"
