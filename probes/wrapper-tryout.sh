#!/usr/bin/env bash
# Try out the engine's wrapper role (--wrap) on the HOST, without reinstalling.
#
# Points CLAUDE_CODE_PROCESS_WRAPPER at THIS checkout's engine and starts a
# background session with the native binary. The engine then wraps the workers
# the daemon spawns: `daemon run` and `--bg-pty-host` pass through to the host,
# and the `--bg-spare` worker is put in a bwrap. A `bwrap … --bg-spare …`
# process is the proof that background agent work got sandboxed.
#
# Uses the existing 0.2.0 runtime (proxy on 8888, CA, seccomp); no reinstall.
# Runs from a throwaway dir (no .agent-sandbox -> default proxy mode). Starts a
# real background session briefly, then removes it.
#
#     ./probes/wrapper-tryout.sh
set -uo pipefail

ENGINE="$(cd -- "$(dirname -- "$0")/.." && pwd)/agent-sandbox"
grep -q -- '--wrap' "$ENGINE" || {
  echo "this engine has no --wrap: $ENGINE (are you on the feat/wrapper-role branch?)"
  exit 1
}
# shellcheck disable=SC2012 # version entries are plain version names
nat="$(ls -d "$HOME"/.local/share/claude/versions/* | sort -V | tail -1)"
[ -d "$nat" ] && nat="$nat/claude"
[ -x "$nat" ] || {
  echo "no native claude binary under ~/.local/share/claude/versions"
  exit 1
}
echo "engine: $ENGINE"
echo "native: $nat"
systemctl --user is-active agent-sandbox-mitmproxy.service >/dev/null 2>&1 \
  || echo "warning: proxy service not active; a proxy-mode worker may not reach the network"

# the wrapper Claude Code will invoke: our engine, claude profile, --wrap.
shim="$(mktemp)"
cat >"$shim" <<SHIM
#!/bin/sh
exec "$ENGINE" --profile claude --wrap "\$@"
SHIM
chmod +x "$shim"

work="$(mktemp -d)"
echo "workdir: $work"

echo
echo "== start a background session (native top-level, wrapper set) =="
(cd "$work" && CLAUDE_CODE_PROCESS_WRAPPER="$shim" "$nat" --bg 'print the word hi and then stop' 2>&1) | sed 's/^/   /'

echo
echo "== is a spare worker running inside bwrap? (the proof) =="
sleep 5
if pgrep -af 'bwrap' | grep -- '--bg-spare'; then
  echo "   ^ SANDBOXED: a --bg-spare worker is running under bwrap."
else
  echo "   no bwrap'd --bg-spare seen. It may have already exited, or the spare"
  echo "   failed to start sandboxed. Check: $nat logs <id>, and the section below."
fi

echo
echo "== sessions the daemon knows about =="
"$nat" agents 2>/dev/null | sed 's/^/   /' || true

echo
echo "== cleanup =="
for id in $("$nat" agents --json 2>/dev/null | grep -oE '"id"[: ]+"[^"]+"' | grep -oE '[0-9a-f]{6,}'); do
  "$nat" rm "$id" 2>/dev/null && echo "   removed $id"
done
"$nat" daemon stop 2>/dev/null && echo "   daemon stopped" || true
rm -f "$shim"
rm -rf "$work"
echo "done."
