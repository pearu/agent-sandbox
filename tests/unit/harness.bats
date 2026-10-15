#!/usr/bin/env bats
# The test harness itself. A broken assertion is worse than a missing one: it
# reports a guarantee nobody is checking, and the suite stays green while the
# thing it claims to protect rots.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
}

@test "run ! fails the test when the command succeeds, and passes when it fails" {
  # The suite's every negative assertion is `run ! cmd`. On bats < 1.5.0 the
  # `!` is not a flag but a command, which does not exist, so `run` records
  # status 127 and returns 0 -- and the test passes without checking anything.
  # bats_require_minimum_version in the helper refuses such a bats; this proves
  # the idiom is live on the bats actually running, by running it and reading
  # the report rather than trusting the version string.
  local t="$BATS_TEST_TMPDIR/probe.bats"
  cat >"$t" <<BATS
setup() { load "$BATS_TEST_DIRNAME/../helpers/common"; }
@test "negative assertion that should fail" { run ! true; }
@test "negative assertion that should pass" { run ! false; }
BATS
  run bats "$t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ok 1 negative assertion that should fail"* ]]
  [[ "$output" == *"ok 2 negative assertion that should pass"* ]]
  [[ "$output" != *"BW02"* ]] # the version floor is declared, so no warning either
}

# ----- the engine's Python components under AGENT_SANDBOX_TEST_PYTHON -------------
# scripts/coverage.sh measures join.py and connect-sync.py by setting the override;
# a site that ran python3 itself would leave its component unmeasured, and silently.

@test "the engine runs no Python component with python3 itself: every one goes through _as_python" {
  # Only inline heredocs (`python3 - ... <<`) are the engine's own python3; a component
  # is a file, run as `python3 "$file"` -- which must not appear.
  run grep -nE '(^|[^-_a-z])python3 +["$]' "$ENGINE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # shellcheck disable=SC2016 # the engine's text, $ and all
  grep -qE '^ *_as_python "\$join" ' "$ENGINE"
  # shellcheck disable=SC2016 # the same
  [ "$(grep -cE '_as_python "\$connect_sync" ' "$ENGINE")" -eq 2 ]
}

@test "AGENT_SANDBOX_TEST_PYTHON runs the join, the copy sync and the shadow check" {
  make_harness
  # A recording interpreter: its arguments, one launch per line, then the real python3.
  cat >"$H/bin/rec-py" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${*##*/}" >>"${0%/*}/../rec-py.log"
exec python3 "$@"
STUB
  chmod +x "$H/bin/rec-py"
  AGENT_SANDBOX_TEST_PYTHON="$H/bin/rec-py"
  mkdir -p "$H/home/.claude/skills"
  printf 'V1\n' >"$H/home/.claude/skills/s.md"
  run_engine -- asb --connect 'skills=copy native' claude --version
  [ "$status" -eq 0 ]
  run_engine -- asb --connect 'skills=copy-on-write native' claude --version
  [ "$status" -eq 0 ]
  local log
  log="$(cat "$H/rec-py.log")"
  [[ "$log" == *"join-stub.py "* ]]                    # the join (_as_keeper_join)
  [[ "$log" == *"connect-sync.py sync --kind dir "* ]] # the copy sync (_as_connect_sync)
  [[ "$log" == *"connect-sync.py shadows "* ]]         # the shadow check (_as_connect_shadows)
}

@test "python_cmd: python3, or the override's words, as the engine splits them" {
  unset AGENT_SANDBOX_TEST_PYTHON
  python_cmd
  [ "${PYTHON_CMD[*]}" = python3 ]
  AGENT_SANDBOX_TEST_PYTHON="/x/python3 /y/coverage_run.py /data /rc"
  python_cmd
  [ "${#PYTHON_CMD[@]}" -eq 4 ] && [ "${PYTHON_CMD[1]}" = /y/coverage_run.py ]
  engine_cmd /e
  [ "${ENGINE_CMD[0]}" = "AGENT_SANDBOX_TEST_PYTHON=$AGENT_SANDBOX_TEST_PYTHON" ]
}
