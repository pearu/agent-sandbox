#!/usr/bin/env bats
# --exec runs a command INSTEAD of the agent, in the sandbox the profile would
# have built. The unit tests assert on the argv the engine produces; these run the
# real bwrap and check what the command actually sees from inside -- the isolation
# is the whole claim, and an argv can look right while the command runs outside.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
# the agent, which --exec must NOT run
printf 'agent_ran=yes\n' >"$PWD/report"
PROBE
  TMP_MARKER="$(mktemp /tmp/agent-sandbox-exec-marker.XXXXXX)"
}

teardown() { rm -f "${TMP_MARKER:-}"; }

@test "inside a sandbox, asb runs what it names as it is: the agent, or an --exec command, no second sandbox (#197)" {
  # The checkout is bound read-only so that the engine can run inside; its own profile
  # dir (next to it) supplies the claude profile there. The probe agent is bound at its
  # path, as an agent binary always is.
  # shellcheck disable=SC2016 # deliberate: the inner sh expands these, not bats
  run_sandboxed AGENT_SANDBOX_NET=none -- --connect "$REPO_ROOT/ = read-only" --profile probe --exec /bin/sh -c '
    "$0" --profile claude --exec sh -c "echo inner-exec=\$\$" >"$PWD/inner-exec" 2>&1
    "$0" --profile claude "$1" >"$PWD/inner-agent" 2>&1
    echo "pid1=$(cat /proc/1/comm)" >"$PWD/pid1"' "$ENGINE" "$I/probe.sh"
  [ "$status" -eq 0 ]
  grep -q '^inner-exec=[0-9]' "$IWORK/inner-exec" # ran, as itself
  run ! grep -q 'bwrap\|did not start\|refus' "$IWORK/inner-exec" "$IWORK/inner-agent"
  [ "$(cat "$IWORK/report")" = agent_ran=yes ] # the agent ran, in this same sandbox
  [ "$(cat "$IWORK/pid1")" = pid1=bwrap ]      # and nothing nested replaced it
}

@test "--exec: the command runs inside the sandbox, and the agent does not run at all" {
  # the command writes the same report the agent would have, so "who ran" is
  # unambiguous, and reports what it can see of the host
  # shellcheck disable=SC2016 # deliberate: the inner sh expands these, not bats
  run_sandboxed AGENT_SANDBOX_NET=none AGENT_SANDBOX_FORWARD=TMP_MARKER \
    TMP_MARKER="$TMP_MARKER" -- --profile probe --exec /bin/sh -c '
      R="$PWD/report"; : >"$R"
      printf "who=command\n" >>"$R"
      printf "home_writable=%s\n" "$(touch "$HOME/x" 2>/dev/null && echo yes || echo no)" >>"$R"
      printf "host_tmp_marker_visible=%s\n" "$([ -e "${TMP_MARKER:-/nonexistent}" ] && echo yes || echo no)" >>"$R"
      printf "pid1=%s\n" "$(cat /proc/1/comm 2>/dev/null)" >>"$R"
      printf "argv=%s\n" "$*" >>"$R"
    ' sh-name first second
  [ "$status" -eq 0 ]
  # the command ran, the agent did not
  [ "$(report who)" = command ]
  run ! grep -q 'agent_ran' "$IWORK/report"
  # ...and it ran INSIDE: HOME read-only, a fresh /tmp, its own pid namespace
  [ "$(report home_writable)" = no ]
  [ "$(report host_tmp_marker_visible)" = no ]
  [ "$(report pid1)" != init ]
  # its own arguments reached it untouched
  [ "$(report argv)" = "first second" ]
}

@test "--exec: the agent binary is still bound, so an agent started from inside can run" {
  # this is what makes one sandbox able to host agent sessions: --exec replaces
  # the entrypoint, not the contents
  # PROBE_BIN names the profile's binary on the host (what `probe` on PATH resolves
  # to); forward it so the command inside can look for it at that same path
  # shellcheck disable=SC2016 # deliberate: the inner sh expands these, not bats
  run_sandboxed AGENT_SANDBOX_NET=none AGENT_SANDBOX_FORWARD=PROBE_BIN PROBE_BIN="$I/probe.sh" \
    -- --profile probe --exec /bin/sh -c '
      R="$PWD/report"; : >"$R"
      printf "who=command\n" >>"$R"
      printf "agent_bin_present=%s\n" "$([ -x "$PROBE_BIN" ] && echo yes || echo no)" >>"$R"
    '
  [ "$status" -eq 0 ]
  [ "$(report who)" = command ]
  [ "$(report agent_bin_present)" = yes ]
}

@test "--exec: the command starts with SIGPIPE and SIGXFSZ at their defaults, not the join's ignored ones" {
  # Python ignores both at startup, and an ignored signal survives exec; measured
  # before the fix, SigIgn of a joined command had SIGXFSZ (bit 25) set.
  run_sandboxed AGENT_SANDBOX_NET=none -- --profile probe --exec sh -c 'sed -n "s/^SigIgn:[[:space:]]*//p" /proc/self/status'
  [ "$status" -eq 0 ]
  local ign=$((16#${output##*$'\n'}))
  (((ign >> 12) & 1)) && {
    echo "SIGPIPE is ignored in the joined command"
    false
  }
  (((ign >> 24) & 1)) && {
    echo "SIGXFSZ is ignored in the joined command"
    false
  }
  true
}
