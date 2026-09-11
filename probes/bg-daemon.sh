#!/usr/bin/env bash
# Background sessions (`claude --bg`) and the hidden ~/.claude/daemon.
#
# The claude profile blanks ~/.claude/daemon inside the sandbox: it holds the
# background supervisor's control key and its roster of sessions, a channel
# between sessions rather than one session's state. The reasoning that made
# this safe to do -- the supervisor's sockets live under /tmp, which is a fresh
# tmpfs inside, so the key had nothing to talk to anyway -- is a reading of the
# code. This script measures it, and answers three questions on the HOST:
#
#   1. Inside a sandboxed session, is ~/.claude/daemon empty and is there no
#      /tmp/cc-daemon-*?                                (expect: yes, yes)
#   2. Does `claude --bg` through the launcher leave anything behind: a live
#      supervisor, an entry in the host's roster, a socket dir? The sandbox
#      runs bwrap with --unshare-all --die-with-parent, so the prediction is
#      that the background session ends with the launcher's own exit.
#                                                        (expect: nothing)
#   3. Is the host's own roster byte-identical before and after?
#                                                        (expect: yes)
#
# With --native it also runs the control: `--bg` with the agent's own binary,
# UNSANDBOXED, to show the feature itself works on this machine. Opt-in,
# because that is a real unsandboxed agent session.
#
# Steps 1 and 2 each start a real agent session (one model call for step 1).
# Run on the HOST from a directory the sandbox may use as CWD, after
# re-running install.sh, since the launcher runs the INSTALLED copy of the
# profile, not the checkout:
#     ./probes/bg-daemon.sh [--native]
# shellcheck disable=SC2012 # `ls | wc -l` here counts entries for display; no filename is acted on
set -uo pipefail

say() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
native=0
[[ "${1:-}" == --native ]] && native=1

D="$HOME/.claude/daemon"
model="${PROBE_MODEL:-claude-haiku-4-5-20251001}"

say "Preconditions"
if ! command -v claude >/dev/null; then
  note "no \`claude\` on PATH"
  exit 1
fi
launcher="$(command -v claude)"
# install.sh makes the launcher a symlink to the installed engine, and puts the
# installed profiles beside it. Derive the location from that rather than
# assuming the install layout.
engine="$(readlink -f "$launcher")"
note "launcher: $launcher -> $engine"
if [[ "$(basename "$engine")" != agent-sandbox ]]; then
  note "that is not the agent-sandbox launcher; this probe needs the sandboxed one first on PATH"
  exit 1
fi
profile="$(dirname "$engine")/profiles/claude.sh"
# shellcheck disable=SC2016 # literal \$c: the profile spells the path as "$c/daemon"
if grep -qE 'tmpfs[[:space:]]+\$c/daemon' "$profile" 2>/dev/null; then
  note "installed profile ($profile) hides daemon/: yes"
else
  note "installed profile ($profile) does NOT hide daemon/ -- re-run install.sh from the checkout, then this"
  exit 1
fi

roster_sha() { [[ -f "$D/roster.json" ]] && sha256sum "$D/roster.json" | cut -c1-16 || echo "(no roster.json)"; }
say "Host daemon state before"
note "$D: $(ls -A "$D" 2>/dev/null | tr '\n' ' ')"
note "roster.json sha: $(roster_sha)"
before="$(roster_sha)"
note "/tmp/cc-daemon-$(id -u): $(ls -A "/tmp/cc-daemon-$(id -u)" 2>/dev/null | wc -l) entr(y/ies)"
note "supervisor processes: $(pgrep -fc 'cc-daemon' || true)"

say "1. Inside a sandboxed session (one model call, $model)"
# shellcheck disable=SC2016 # the $(...) are for the AGENT's shell, inside the sandbox
prompt='Run exactly this shell command and paste its output verbatim, nothing else:
  echo "DAEMON_ENTRIES=$(ls -A ~/.claude/daemon 2>/dev/null | wc -l)"; echo "TMP_CC_DAEMON=$(ls -d /tmp/cc-daemon-* 2>/dev/null | wc -l)"; ls -la ~/.claude/daemon 2>&1'
timeout 180 claude -p "$prompt" --model "$model" --allowedTools 'Bash' 2>&1 | sed 's/^/   /'
note "expect DAEMON_ENTRIES=0 (an empty tmpfs) and TMP_CC_DAEMON=0"

say "2. claude --bg through the launcher"
out="$(cd "$PWD" && timeout 90 claude --bg 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/   /'
note "exit=$rc"
sleep 3
note "supervisor processes on the host now: $(pgrep -fc 'cc-daemon' || true)"
note "launcher/bwrap processes still alive: $(pgrep -fc 'bwrap.*claude|agent-sandbox' || true)"
note "/tmp/cc-daemon-$(id -u) now: $(ls -A "/tmp/cc-daemon-$(id -u)" 2>/dev/null | wc -l) entr(y/ies)"
say "   what the launcher's own \`claude agents\` sees (a fresh sandbox)"
timeout 60 claude agents --json --all 2>&1 | head -c 600 | sed 's/^/   /'
echo
note "expect: nothing from step 2 -- a different sandbox, a different /tmp, a different pid namespace"

say "3. Host daemon state after"
after="$(roster_sha)"
note "roster.json sha: $after"
if [[ "$before" == "$after" ]]; then note "UNCHANGED -- the sandboxed session did not touch the host's roster"; else note "CHANGED -- report this; it means something inside reached the host's daemon dir"; fi

if ((native)); then
  bin="$(ls -d "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1)"
  [[ -d "$bin" ]] && bin="$bin/claude"
  say "Control (--native): the agent's own binary, UNSANDBOXED: $bin"
  tmp="$(mktemp -d)"
  id="$(cd "$tmp" && timeout 90 "$bin" --bg 2>&1 | tail -1)"
  note "--bg printed: $id"
  sleep 3
  note "supervisor processes: $(pgrep -fc 'cc-daemon' || true); roster sha: $(roster_sha)"
  timeout 60 "$bin" agents --json 2>&1 | head -c 400 | sed 's/^/   /'
  echo
  sid="$(printf '%s' "$id" | grep -oE '[a-z0-9-]{6,}' | tail -1)"
  [[ -n "$sid" ]] && {
    timeout 60 "$bin" stop "$sid" 2>&1 | sed 's/^/   /'
    timeout 60 "$bin" rm "$sid" 2>&1 | sed 's/^/   /'
  }
  rm -rf "$tmp"
  note "expect: the session listed, then stopped and removed; roster sha changed and changed back or moved on"
fi

say "Done"
note "Paste the whole output back. Nothing here is committed; results describe this machine."
