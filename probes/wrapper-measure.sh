#!/usr/bin/env bash
# shellcheck disable=SC2012 # version entries are plain version names; ls + sort -V is fine
# Measure how Claude Code uses CLAUDE_CODE_PROCESS_WRAPPER, on the HOST.
#
# Question: when a background session starts, does the daemon spawn its WORKER
# through the wrapper (so wrapper-mode would sandbox the actual agent work), or
# is only `daemon run` (the supervisor) wrapped?
#
# This runs the NATIVE claude binary directly (not the agent-sandbox launcher),
# with a logging wrapper that resolves the launcher path back to the native
# binary so the daemon runs host-side. It starts a REAL, UNSANDBOXED background
# session on the host briefly, then stops it.
#
#     ./probes/wrapper-measure.sh
#
# Nothing here is committed; the log names local paths.
set -uo pipefail

WRAP=/tmp/agent-sandbox-wrap-log.sh
LOG=/tmp/agent-sandbox-wrap.log

cat >"$WRAP" <<'WRAPEOF'
#!/usr/bin/env bash
echo "WRAPPED: $*" >>/tmp/agent-sandbox-wrap.log
bin="$1"
shift
# The agent-sandbox launcher on PATH would re-sandbox this; resolve it back to
# the native binary so the daemon (trusted infra) runs host-side and we can see
# whether IT wraps its workers.
case "$bin" in
*/.local/bin/claude)
  bin="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
  [ -d "$bin" ] && bin="$bin/claude"
  ;;
esac
exec "$bin" "$@"
WRAPEOF
chmod +x "$WRAP"
: >"$LOG"

nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
echo "native binary: $nat"

echo "== foreground (control: expect no wrapper line) =="
CLAUDE_CODE_PROCESS_WRAPPER="$WRAP" "$nat" -p 'hi' || true

echo "== background + a task (positional prompt forces a worker; -p conflicts with --bg) =="
CLAUDE_CODE_PROCESS_WRAPPER="$WRAP" "$nat" --bg 'print the word hi and stop' || true
sleep 6

echo "== wrap.log =="
cat "$LOG" || echo "(empty)"

echo "== host daemon roster (native binary, not the launcher) =="
"$nat" agents 2>/dev/null || true

echo "== cleanup: remove any bg sessions this run created, then stop the daemon =="
for id in $("$nat" agents --json 2>/dev/null | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[^"]+"$' | tr -d '"'); do
  "$nat" rm "$id" 2>/dev/null || true
done
"$nat" daemon stop 2>/dev/null || true

echo
echo "READ IT LIKE THIS:"
echo " - only a 'daemon run' line       => the wrapper covers the supervisor, not the worker."
echo " - a 'daemon run' line AND a       "
echo "   second line for a session/worker => the daemon spawns workers through the wrapper too"
echo "                                      (wrapper mode would confine the agent work)."
echo " - no foreground line              => foreground sessions do not use the wrapper (expected)."
