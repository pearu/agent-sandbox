#!/usr/bin/env bash
# shellcheck disable=SC2012 # version dirs: plain names
# Smoke-test 3b (wrapper-mode background sandboxing) through the REAL launcher --
# no manual CLAUDE_CODE_PROCESS_WRAPPER shim, no pre-trust. Runs THIS checkout's
# engine as `claude --profile claude --sandbox "fg bg" --bg <task>` and checks the
# whole path wires up: profile_route -> _claude_bg_launch -> auto-trust -> wrapper
# shim -> a sandboxed worker bound to the launching project.
#
#   F1 sandboxed pool: bwrap processes wrap the background --bg-spare workers.
#   F2 functional:     the worker wrote DONE.txt (word "hi") in its project.
#   F3 project-bound:  a sandboxed worker's bwrap argv binds the project.
#   F4 auto-trust:     the project got hasTrustDialogAccepted (we did NOT pre-set
#                      it), so the non-interactive worker did not stall on trust.
#   F5 clean:          cleanup leaves no background workers and removes the
#                      auto-trust entry.
#
# Uses the default background model (which has "auto mode", so an in-project write
# is auto-approved). HOST only; installs nothing. Cleans up EVERYTHING it creates.
#     ./probes/wrapper-mode-smoke.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q 'profile_route' "$(cd -- "$(dirname -- "$0")/.." && pwd)/profiles/claude.sh" || {
  echo "profile has no profile_route (need the 3b branch): $ENGINE"
  exit 1
}
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
  echo "no runnable Claude Code executable found"
  exit 1
}
UID_="$(id -u)"
CJSON="$HOME/.claude.json"

agents_json() { "$nat" agents --json 2>/dev/null; }
agents_has() { agents_json | grep -qi "$1"; }
bwrap_spares() {
  local q
  for q in $(pgrep -f -- '--bg-spare' 2>/dev/null); do
    [ "$(ps -o comm= -p "$q" 2>/dev/null)" = bwrap ] && echo "$q"
  done
}
cmdline_of() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null; }
trust_state() {
  AS_CJ="$CJSON" AS_P="$1" python3 - 2>/dev/null <<'PY'
import json, os
try:
    d = json.load(open(os.environ["AS_CJ"]))
    print(bool((d.get("projects", {}) or {}).get(os.environ["AS_P"], {}).get("hasTrustDialogAccepted")))
except Exception:
    print("False")
PY
}
untrust() {
  AS_CJ="$CJSON" AS_P="$1" python3 - 2>/dev/null <<'PY' || true
import json, os
p = os.environ["AS_CJ"]
d = json.load(open(p))
d.get("projects", {}).pop(os.environ["AS_P"], None)
json.dump(d, open(p, "w"))
PY
}
reap_workers() {
  local sig p
  for sig in TERM KILL; do
    for p in $(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null); do kill "-$sig" "$p" 2>/dev/null || true; done
    sleep 1
  done
}

echo "engine: $ENGINE ; runtime: $nat"
echo "== clean slate (abort if live host bg sessions) =="
if agents_has '"id"'; then
  echo "   host has live bg sessions; aborting to stay safe"
  exit 1
fi
"$nat" daemon stop --any >/dev/null 2>&1 || true
reap_workers
rm -rf "/tmp/cc-daemon-$UID_"/* 2>/dev/null || true

P="$(mktemp -d)/proj"
mkdir -p "$P"
base="${XDG_RUNTIME_DIR:-/run/user/$UID_}/agent-sandbox.$UID_"
[ -d "$base" ] || base="/tmp/agent-sandbox.$UID_"

echo "== trust state BEFORE (must be False -- fresh project) =="
echo "   trusted=$(trust_state "$P")"

echo "== run the REAL launcher: engine as claude --sandbox 'fg bg' --bg =="
OUT="$(cd "$P" && "$ENGINE" --profile claude --sandbox "fg bg" --bg 'create a file named DONE.txt containing the word hi in the current directory, then stop' 2>&1)"
printf '%s\n' "$OUT" | sed 's/^/   /'
ID="$(printf '%s' "$OUT" | grep -i backgrounded | grep -oiE '[0-9a-f]{8}' | head -1)"
echo "   session id: ${ID:-<none>}"

echo "== wait up to 90s for DONE.txt =="
D=""
for _ in $(seq 1 30); do
  sleep 3
  [ -f "$P/DONE.txt" ] && {
    D="$(tr -d '[:space:]' <"$P/DONE.txt")"
    break
  }
done

echo
echo "== checks =="
mapfile -t SP < <(bwrap_spares)
f1=$([ "${#SP[@]}" -gt 0 ] && echo pass || echo FAIL)
echo "   F1 sandboxed pool (bwrap over --bg-spare): $f1 (${#SP[@]} worker(s))"
f2=$([ "$D" = hi ] && echo pass || echo FAIL)
echo "   F2 functional (DONE.txt = hi): $f2 (got '${D:-<none>}')"
f3=FAIL
for q in ${SP[@]+"${SP[@]}"}; do
  case "$(cmdline_of "$q")" in *"$P"*) f3=pass ;; esac
  [ "$f3" = pass ] && break
done
echo "   F3 a sandboxed worker binds the project: $f3"
f4=$([ "$(trust_state "$P")" = True ] && echo pass || echo FAIL)
echo "   F4 project auto-trusted: $f4"

echo
echo "== verdict =="
if [ "$f1" = pass ] && [ "$f2" = pass ] && [ "$f3" = pass ] && [ "$f4" = pass ]; then
  echo "   WRAPPER MODE WORKS end-to-end through the real launcher."
else
  echo "   ISSUE (F1=$f1 F2=$f2 F3=$f3 F4=$f4). Diagnostics:"
  echo "   --- claude logs $ID (tail) ---"
  [ -n "$ID" ] && "$nat" logs "$ID" 2>&1 | tail -20 | sed 's/^/     /'
fi

echo
echo "== cleanup =="
for x in $(agents_json | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
  "$nat" rm "$x" >/dev/null 2>&1 || true
done
"$nat" daemon stop --any >/dev/null 2>&1 || true
reap_workers
untrust "$P"
rm -f "$base/bg-project" "$base/wrap-claude.sh"
rm -rf "$(dirname "$P")"
left="$(pgrep -f -- '--bg-spare|--bg-pty-host' 2>/dev/null | wc -l | tr -d ' ')"
f5=$([ "$left" -eq 0 ] && [ "$(trust_state "$P")" = False ] && echo pass || echo FAIL)
echo "   F5 clean (no workers left, trust entry removed): $f5 (workers left: $left)"
echo "done."
