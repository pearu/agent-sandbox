#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2001 # version dirs; sed for display
# Does a SANDBOXED background worker actually function? Starts a bg session
# (workers bwrap'd via --wrap) whose task writes a marker file in its project,
# and checks whether the file appears on the host -- proving the worker reached
# the API, ran a tool, saw its project (bound via 3c), and chdir'd into it.
#
# Uses this checkout's engine as CLAUDE_CODE_PROCESS_WRAPPER; reuses the
# installed runtime. HOST only. Cleans up.
#     ./probes/wrapper-func-measure.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "engine has no --wrap: $ENGINE"
  exit 1
}
nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
UID_="$(id -u)"

SHIM="$(mktemp)"
printf '#!/bin/sh\nexec "%s" --profile claude --wrap "$@"\n' "$ENGINE" >"$SHIM"
chmod +x "$SHIM"

echo "engine: $ENGINE"
echo "== clean slate (only if no host bg sessions) =="
if ! "$nat" agents --json 2>/dev/null | grep -q '"id"'; then
  "$nat" daemon stop >/dev/null 2>&1 || true
  sleep 2
  rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true
  echo "   cleared"
else
  echo "   host has live bg sessions; aborting"
  exit 1
fi

P0="$(mktemp -d)/proj-$$"
mkdir -p "$P0"
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"
mkdir -p "$base"
printf '%s' "$P0" >"$base/bg-project"

# Pre-trust the temp project: a bg session can't answer Claude Code's interactive
# workspace-trust prompt, and a fresh mktemp dir is untrusted (a real user's
# project is already trusted). Recorded in ~/.claude.json projects[<path>].
CJSON="$HOME/.claude.json"
python3 - "$CJSON" "$P0" <<'PYT'
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault("projects", {}).setdefault(proj, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PYT

echo "== start a sandboxed bg session; task writes DONE.txt in its project =="
out="$(cd "$P0" && CLAUDE_CODE_PROCESS_WRAPPER="$SHIM" "$nat" --bg 'create a file named DONE.txt containing the word hi in the current directory, then stop' 2>&1)"
echo "$out" | sed 's/^/   /'
id="$(printf '%s' "$out" | grep -oE 'backgrounded[^0-9a-f]*[0-9a-f]{6,}' | grep -oE '[0-9a-f]{6,}$')"
echo "   session id: ${id:-<none>}"

echo "== wait up to 75s for the project marker to appear on the host =="
found=no
for _ in $(seq 1 25); do
  sleep 3
  [ -f "$P0/DONE.txt" ] && {
    found=yes
    break
  }
done
echo "   $P0/DONE.txt present: $found"
[ "$found" = yes ] && echo "   contents: $(cat "$P0/DONE.txt")"

echo "== diagnostics =="
echo "   sandboxed spares (bwrap over --bg-spare): $(pgrep -f -- '--bg-spare' 2>/dev/null | while read -r p; do [ "$(ps -o comm= -p "$p" 2>/dev/null)" = bwrap ] && echo x; done | grep -c x || true)"
echo "   --- claude logs $id (tail) ---"
[ -n "$id" ] && "$nat" logs "$id" 2>&1 | tail -20 | sed 's/^/     /' || echo "     (no id)"

echo
echo "== verdict =="
if [ "$found" = yes ]; then
  echo "   FUNCTIONAL: the sandboxed worker reached the API, ran a tool, and wrote to its bound project."
else
  echo "   NOT functional: the sandboxed worker did not produce the marker -> the sandbox breaks the worker"
  echo "   (rendezvous, API, project bind, or chdir). See the logs above."
fi

echo "== cleanup =="
for x in $("$nat" agents --json 2>/dev/null | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
  "$nat" rm "$x" >/dev/null 2>&1 || true
done
"$nat" daemon stop >/dev/null 2>&1 || true
python3 - "$CJSON" "$P0" <<'PYT' 2>/dev/null || true
import json, sys
p, proj = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d.get("projects", {}).pop(proj, None); json.dump(d, open(p, "w"))
PYT
rm -f "$SHIM" "$base/bg-project"
rm -rf "$(dirname "$P0")"
echo "done."
