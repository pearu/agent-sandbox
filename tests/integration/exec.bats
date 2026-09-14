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

@test "--exec: the command runs inside the sandbox, and the agent does not run at all" {
  # the command writes the same report the agent would have, so "who ran" is
  # unambiguous, and reports what it can see of the host
  # shellcheck disable=SC2016 # deliberate: the inner sh expands these, not bats
  run_sandboxed AGENT_SANDBOX_NET=none AGENT_SANDBOX_FORWARD=TMP_MARKER \
    TMP_MARKER="$TMP_MARKER" -- --exec /bin/sh -c '
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
  # AGENT_SANDBOX_TEST_BIN names the profile's binary on the host; forward it so
  # the command inside can look for it at that same path
  # shellcheck disable=SC2016 # deliberate: the inner sh expands these, not bats
  run_sandboxed AGENT_SANDBOX_NET=none AGENT_SANDBOX_FORWARD=AGENT_SANDBOX_TEST_BIN \
    -- --exec /bin/sh -c '
      R="$PWD/report"; : >"$R"
      printf "who=command\n" >>"$R"
      printf "agent_bin_present=%s\n" "$([ -x "$AGENT_SANDBOX_TEST_BIN" ] && echo yes || echo no)" >>"$R"
    '
  [ "$status" -eq 0 ]
  [ "$(report who)" = command ]
  [ "$(report agent_bin_present)" = yes ]
}
