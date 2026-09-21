#!/usr/bin/env bats
# The holder, under the REAL bwrap: one overlay per sandbox, joined by every
# session.
#
# The unit suite cannot reach this. Its stub bwrap exits immediately, so no
# holder ever records itself and every cow launch there takes the fallback --
# which makes those tests a good check of the fallback and no check at all of
# the thing that replaced it. tests/integration/overlay-sharing.bats proves the
# kernel primitives on every platform CI covers; this proves the ENGINE uses
# them, which is a different claim and was for a while asserted only by hand.
#
# The one that matters is the third: two sessions of one sandbox reporting the
# same superblock. That is the whole reason the holder exists, and no study cell
# can see it -- a behavioural cell cannot tell a shared mount from two
# independent ones, because both let each session read the other's writes.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11; this host: $(bwrap --version))"
  command -v nsenter >/dev/null || skip "nsenter not installed (util-linux)"
  command -v flock >/dev/null || skip "flock not installed (util-linux)"
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/${REPORT_NAME:-report}"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say seen "$(cat "$HOME/.probe/docs/a.md" 2>/dev/null)"
say dev "$(awk -v m="$HOME/.probe/docs" '$5 == m {print $3}' /proc/self/mountinfo)"
[[ -n "${PROBE_WRITE:-}" ]] && printf '%s\n' "$PROBE_WRITE" >"$HOME/.probe/docs/a.md"
[[ -n "${PROBE_HOLD:-}" ]] && sleep "$PROBE_HOLD"
say done yes
PROBE
  SB="$IHOME/.local/state/agent-sandbox/probe/$(printf '%s' "$(cd "$IWORK" && pwd -P)" | sed 's:[^A-Za-z0-9-]:-:g')/default"
  printf 'YOURS\n' >"$IHOME/.probe/docs/a.md"
  # The engine does --clearenv and re-exports an allowlist, so the probe's own
  # knobs have to be forwarded explicitly or it never sees them. Every one of
  # these tests failed silently until they were.
  COW=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state"
    AGENT_SANDBOX_FORWARD="REPORT_NAME PROBE_WRITE PROBE_HOLD"
    AGENT_SANDBOX_CONNECT='docs=copy-on-write native')
}

teardown() {
  # Only holders this test recorded, by the pid IT wrote down. Killing by name
  # pattern on a shared machine is how you take out something that is not yours.
  local f pid
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/holder.id; do
    [[ -r "$f" ]] || continue
    read -r pid _ <"$f" 2>/dev/null && [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  return 0
}

@test "a cow launch starts a holder, and the source reads through it" {
  run_sandboxed "${COW[@]}" -- run
  [ "$status" -eq 0 ]
  [ "$(report seen)" = YOURS ]
  [ -r "$SB/holder.id" ]
  local pid
  read -r pid _ <"$SB/holder.id"
  [ -d "/proc/$pid" ] # and it is still there for the next session
}

@test "a write inside lands in the layer, never in the source" {
  run_sandboxed "${COW[@]}" PROBE_WRITE=MINE -- run
  [ "$status" -eq 0 ]
  [ "$(cat "$IHOME/.probe/docs/a.md")" = YOURS ] # the user's own copy
  run_sandboxed "${COW[@]}" -- run
  [ "$(report seen)" = MINE ] # and the sandbox keeps its own
}

@test "TWO SESSIONS AT ONCE SHARE ONE SUPERBLOCK -- the whole point of the holder" {
  # Without a holder each session mounts its own overlay over the same upper
  # directory, which overlayfs documents as undefined. Both arrangements let the
  # sessions read each other's writes, so only the superblock tells them apart.
  local dir="$IWORK"
  (cd "$dir" && env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
    AGENT_SANDBOX_SESSION_BASE="$I/base" REPORT_NAME=report.a PROBE_HOLD=4 \
    "${COW[@]}" "$ENGINE" --profile probe run) >/dev/null 2>&1 &
  local first=$!
  # wait for the first session to be inside, not merely started
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -s "$dir/report.a" ]] && grep -q '^dev=' "$dir/report.a" && break
    sleep 0.05
  done
  (cd "$dir" && env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
    AGENT_SANDBOX_SESSION_BASE="$I/base" REPORT_NAME=report.b \
    "${COW[@]}" "$ENGINE" --profile probe run) >/dev/null 2>&1
  wait "$first" 2>/dev/null || true

  local a b
  a="$(sed -n 's/^dev=//p' "$dir/report.a")"
  b="$(sed -n 's/^dev=//p' "$dir/report.b")"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" = "$b" ]
}

@test "--reset-connection stops the holder and the source comes back" {
  # It reported success and changed nothing before the holder was stopped first:
  # the mount holds references to the layer directories, not their paths, so
  # removing them underneath it left the old content still being served.
  run_sandboxed "${COW[@]}" PROBE_WRITE=MINE -- run
  run_sandboxed "${COW[@]}" -- run
  [ "$(report seen)" = MINE ]
  local pid
  read -r pid _ <"$SB/holder.id"

  run_sandboxed "${COW[@]}" -- --reset-connection docs
  [ "$status" -eq 0 ]
  [ ! -d "/proc/$pid" ] # the holder is gone
  run_sandboxed "${COW[@]}" -- run
  [ "$(report seen)" = YOURS ] # and the source is what the sandbox sees again
}

@test "--reset-connection refuses while a session of the sandbox is live" {
  run_sandboxed "${COW[@]}" -- run
  local dir="$IWORK"
  (cd "$dir" && env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_TEST_BIN="$I/probe.sh" \
    AGENT_SANDBOX_SESSION_BASE="$I/base" REPORT_NAME=report.c PROBE_HOLD=4 \
    "${COW[@]}" "$ENGINE" --profile probe run) >/dev/null 2>&1 &
  local first=$! i
  for ((i = 0; i < 200; i++)); do
    [[ -s "$dir/report.c" ]] && grep -q '^dev=' "$dir/report.c" && break
    sleep 0.05
  done
  run_sandboxed "${COW[@]}" -- --reset-connection docs
  [ "$status" -ne 0 ]
  [[ "$output" == *"session of this sandbox is running"* ]]
  wait "$first" 2>/dev/null || true
}
