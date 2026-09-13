#!/usr/bin/env bats
# _claude_bg_reap_select (background pool reap, issue W1): it must select ONLY
# genuine leaked worker trees -- a claude version binary running
# --bg-spare/--bg-pty-host as an EXACT argv element, with no rostered ancestor --
# and never a shell or test that merely MENTIONS the token in its command line,
# an unrelated binary that happens to carry the token, or an active (rostered)
# session. Regression guard for the substring-match over-reach.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  # shellcheck disable=SC1090
  source "$ENGINE"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/profiles/claude.sh"
  PROC="$BATS_TEST_TMPDIR/proc"
  VROOT="$BATS_TEST_TMPDIR/versions"
  CLAUDE="$VROOT/9.9.9/claude"
  mkdir -p "$PROC" "$VROOT/9.9.9"
  : >"$CLAUDE"
  chmod +x "$CLAUDE"
  _claude_versions_dir="$VROOT"
  export PROC VROOT CLAUDE
}

# mkproc PID PPID EXE ARGV... -- write a synthetic /proc entry.
mkproc() {
  local pid="$1" ppid="$2" exe="$3" a
  shift 3
  mkdir -p "$PROC/$pid"
  printf '%d (comm) S %d 0 0 0 0 0 0 0 0 0 0 0\n' "$pid" "$ppid" >"$PROC/$pid/stat"
  : >"$PROC/$pid/cmdline"
  for a in "$@"; do printf '%s\0' "$a" >>"$PROC/$pid/cmdline"; done
  ln -sf "$exe" "$PROC/$pid/exe"
}

sel() { AS_PROC="$PROC" _claude_bg_reap_select "$1"; }

@test "selects a genuine leaked worker and its subtree; spares shells, decoys, and rostered workers" {
  # genuine leaked worker: exe is a claude version binary, exact --bg-spare, not rostered
  mkproc 1000 1 "$CLAUDE" "$CLAUDE" --bg-spare /tmp/cc-daemon-1/spare/a.claim.sock
  mkproc 1001 1000 /usr/bin/python3 python3 do-work # its own child, no marker -> swept via subtree
  # a shell that merely MENTIONS the token in its script text (must NOT match)
  mkproc 2000 1 /bin/bash bash -c 'setsid python3 x --bg-spare /tmp/y.sock'
  mkproc 2001 2000 /bin/sleep sleep 300 # that shell's child (must NOT be swept)
  # a non-claude binary carrying the token as an exact argv element (must NOT match)
  mkproc 3000 1 /usr/bin/python3 python3 -c sleep --bg-spare /tmp/decoy.claim.sock
  # an active (rostered) worker (must NOT be reaped)
  mkproc 4000 1 "$CLAUDE" "$CLAUDE" --bg-spare /tmp/cc-daemon-1/spare/live.claim.sock
  printf '{"workers":{"w":{"pid":4000}}}' >"$BATS_TEST_TMPDIR/roster.json"

  run sel "$BATS_TEST_TMPDIR/roster.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1000 1001" ]
}

@test "a rostered worker's descendant tree is spared via the rostered ancestor" {
  mkproc 5000 1 "$CLAUDE" "$CLAUDE" --bg-pty-host /tmp/cc-daemon-1/spare/p.pty.sock 80 24
  mkproc 5001 5000 "$CLAUDE" "$CLAUDE" --bg-spare /tmp/cc-daemon-1/spare/p.claim.sock
  printf '{"workers":{"w":{"pid":5000}}}' >"$BATS_TEST_TMPDIR/roster.json"
  run sel "$BATS_TEST_TMPDIR/roster.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an orphaned pty-host + its --die-with-parent spare are both selected" {
  mkproc 6000 1 "$CLAUDE" "$CLAUDE" --bg-pty-host /tmp/cc-daemon-1/spare/o.pty.sock 80 24
  mkproc 6001 6000 "$CLAUDE" "$CLAUDE" --bg-spare /tmp/cc-daemon-1/spare/o.claim.sock
  printf '{"workers":{}}' >"$BATS_TEST_TMPDIR/roster.json"
  run sel "$BATS_TEST_TMPDIR/roster.json"
  [ "$status" -eq 0 ]
  [ "$output" = "6000 6001" ]
}
