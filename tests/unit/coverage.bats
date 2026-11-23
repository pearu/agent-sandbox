#!/usr/bin/env bats
# scripts/coverage.sh's test run (timed_bats) and its report of failed tests (#462): the
# timing file names each file as it was given, the path tests/shard.sh deals; a failed
# test fails the stage and is listed; `failures` lists them as Markdown for CI's step
# summary. The stages themselves need kcov, which CI's coverage jobs run.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  # coverage.sh's own knobs come from each test, not from the run around it: CI's coverage
  # job sets COVERAGE_SHARD, which dealt a test's own files out of its stage (#469's CI)
  unset COVERAGE_FILE COVERAGE_JOBS COVERAGE_OUT COVERAGE_SHARD COVERAGE_TEST_TIMEOUT
  T="$BATS_TEST_TMPDIR/t"
  mkdir -p "$T/a/sub" "$T/b" "$T/out"
  printf '@test "x1" {\n  :\n}\n@test "x2" {\n  :\n}\n' >"$T/a/x.bats"
  printf '@test "y1" {\n  :\n}\n' >"$T/a/sub/y.bats"
  printf '@test "z1" {\n  :\n}\n' >"$T/b/z.bats"
}

# timed STAGE FILE... -- scripts/coverage.sh's timed_bats, from $T, into $T/out, one test
# at a time and with no per-test timeout unless TIMEOUT says one (bats 1.14 waits a
# failed test's countdown out when run one test at a time)
timed() {
  # shellcheck disable=SC2016 # the script's own $1 and $2
  run --separate-stderr env COVERAGE_OUT="$T/out" COVERAGE_JOBS=1 COVERAGE_TEST_TIMEOUT="${TIMEOUT-}" bash -c \
    'source "$1/scripts/coverage.sh" && cd "$2" && shift 2 && timed_bats "$@"' _ "$REPO_ROOT" "$T" "$@"
}

@test "coverage: the timing file names each file as it was given, a subdirectory's and another directory's too" {
  timed st a/x.bats a/sub/y.bats b/z.bats
  echo "$output"
  [ "$status" -eq 0 ]
  cat "$T/out/timing-st.tsv"
  [ "$(cut -f2 "$T/out/timing-st.tsv" | sort | tr '\n' ' ')" = "a/sub/y.bats a/x.bats b/z.bats " ]
  [[ "$output" != *FAILED* ]]
  # the slowest tests, read from bats' `# in N ms`
  [ "$(sed -n '/^   slowest tests:$/,$p' <<<"$output" | grep -cE '^ +[0-9]+\.[0-9] s  [xyz][12]$')" -eq 4 ]
}

@test "coverage: a failed test fails the stage, and its not-ok line is printed" {
  printf '@test "z2 fails" {\n  false\n}\n' >>"$T/b/z.bats"
  timed st a/x.bats b/z.bats
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"   FAILED: 1 test(s); the .tap file has their output:"* ]]
  [ "$(grep -c '^   not ok ' <<<"$output")" -eq 1 ]
  [[ "$output" == *$'\n   not ok 4 z2 fails # in '* ]]
}

@test "coverage: a test that hangs fails after the per-test timeout (COVERAGE_TEST_TIMEOUT), and the stage fails" {
  printf '@test "hangs" {\n  sleep 60\n}\n' >"$T/b/hang.bats"
  local t0=$SECONDS
  TIMEOUT=2 timed st b/hang.bats
  echo "$output"
  [ "$status" -eq 1 ]
  [ $((SECONDS - t0)) -lt 30 ]
  [[ "$output" == *$'\n   not ok 1 hangs # in '*' ms # timeout after 2 s'* ]]
}

@test "coverage: the per-test timeout is 600 s unless COVERAGE_TEST_TIMEOUT says otherwise" {
  # shellcheck disable=SC2016 # the script's text
  grep -qF 'BATS_TEST_TIMEOUT="${COVERAGE_TEST_TIMEOUT-600}" bats' "$REPO_ROOT/scripts/coverage.sh"
}

@test "coverage: failures lists each stage's failed tests as Markdown, and nothing when none failed" {
  printf 'ok 1 a in 5ms\nnot ok 2 b in 6ms\n# (in test file x.bats, line 3)\nnot ok 3 c in 7ms\n' >"$T/out/engine-unit.tap"
  printf 'ok 1 d in 5ms\n' >"$T/out/engine-integration.tap"
  run env COVERAGE_OUT="$T/out" "$REPO_ROOT/scripts/coverage.sh" failures
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "### engine-unit: 2 test(s) failed" ]
  [ "${lines[1]}" = '```' ]
  [ "${lines[2]}" = "not ok 2 b in 6ms" ]
  [ "${lines[3]}" = "not ok 3 c in 7ms" ]
  [ "${lines[4]}" = '```' ]
  [ "${#lines[@]}" -eq 5 ]
  rm "$T/out/engine-unit.tap"
  run env COVERAGE_OUT="$T/out" "$REPO_ROOT/scripts/coverage.sh" failures
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "coverage: under kcov the engine writes to the test's stdout and stderr, kcov's own go elsewhere, and kcov is still the engine's parent" {
  # A stand-in kcov: it writes to its own stdout and stderr, then runs what follows its
  # options as its child, as kcov does, and waits for it.
  cat >"$T/kcov" <<'STUB'
#!/usr/bin/env bash
echo KCOV-OUT
echo KCOV-ERR >&2
while [[ "$1" == --* || "$1" == */r.* ]]; do shift; done
"$@"
STUB
  cat >"$T/engine" <<'STUB'
#!/usr/bin/env bash
tr '\0' ' ' </proc/$PPID/cmdline >"${0%/*}/engine.parent"
ls /proc/$$/fd >"${0%/*}/engine.fds"
echo ENGINE-OUT
echo ENGINE-ERR >&2
STUB
  chmod +x "$T/kcov" "$T/engine"
  mkdir -p "$T/kd"
  AGENT_SANDBOX_KCOV="$T/kcov" AGENT_SANDBOX_KCOV_DIR="$T/kd" engine_cmd "$T/engine"
  echo "${ENGINE_CMD[*]}"
  run --separate-stderr env -i PATH=/usr/bin:/bin "${ENGINE_CMD[@]}" 3>&-
  [ "$status" -eq 0 ]
  [ "$output" = ENGINE-OUT ]
  [ "$stderr" = ENGINE-ERR ]
  [ "$(cat "$T/kd/kcov.log")" = KCOV-ERR ]
  # every launch's kcov appends to the one log
  run --separate-stderr env -i PATH=/usr/bin:/bin "${ENGINE_CMD[@]}" 3>&-
  [ "$(cat "$T/kd/kcov.log")" = $'KCOV-ERR\nKCOV-ERR' ]
  # kcov is the engine's direct parent, and fds 8 and 9 are not left to it
  [[ "$(cat "$T/engine.parent")" == "bash $T/kcov "* ]]
  run cat "$T/engine.fds"
  [[ $'\n'"$output"$'\n' != *$'\n8\n'* ]]
  [[ $'\n'"$output"$'\n' != *$'\n9\n'* ]]
}

@test "coverage: AGENT_SANDBOX_KCOV_LIBS is kcov's LD_LIBRARY_PATH alone; the engine gets the caller's back, or none" {
  # stand-ins that write the LD_LIBRARY_PATH each was given: kcov, then the engine it runs
  cat >"$T/kcov" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${LD_LIBRARY_PATH-unset}" >"${0%/*}/kcov.ldp"
while [[ "$1" == --* || "$1" == */r.* ]]; do shift; done
"$@"
STUB
  cat >"$T/engine" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${LD_LIBRARY_PATH-unset}" "${KCOV_EXEC_LD_LIBRARY_PATH-unset}" >"${0%/*}/engine.ldp"
STUB
  chmod +x "$T/kcov" "$T/engine"
  mkdir -p "$T/kd"
  # the libraries named, the caller with none (env -i, as the harness launches)
  AGENT_SANDBOX_KCOV="$T/kcov" AGENT_SANDBOX_KCOV_DIR="$T/kd" AGENT_SANDBOX_KCOV_LIBS=/conda/lib engine_cmd "$T/engine"
  run env -i PATH=/usr/bin:/bin "${ENGINE_CMD[@]}" 3>&-
  [ "$status" -eq 0 ]
  [ "$(cat "$T/kcov.ldp")" = /conda/lib ]
  [ "$(cat "$T/engine.ldp")" = $'unset\nunset' ]
  # the caller's own, even an empty one, is the engine's again
  run env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH=/mine "${ENGINE_CMD[@]}" 3>&-
  [ "$(cat "$T/kcov.ldp")" = /conda/lib ]
  [ "$(cat "$T/engine.ldp")" = $'/mine\nunset' ]
  run env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH= "${ENGINE_CMD[@]}" 3>&-
  [ "$(cat "$T/kcov.ldp")" = /conda/lib ]
  [ "$(cat "$T/engine.ldp")" = $'\nunset' ]
  # no libraries named: kcov and the engine both get the caller's
  AGENT_SANDBOX_KCOV="$T/kcov" AGENT_SANDBOX_KCOV_DIR="$T/kd" AGENT_SANDBOX_KCOV_LIBS='' engine_cmd "$T/engine"
  run env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH=/mine "${ENGINE_CMD[@]}" 3>&-
  [ "$(cat "$T/kcov.ldp")" = /mine ]
  [ "$(cat "$T/engine.ldp")" = $'/mine\nunset' ]
  # coverage.sh names the libraries in AGENT_SANDBOX_KCOV_LIBS, not in LD_LIBRARY_PATH,
  # which every test and every tool they run would get
  # shellcheck disable=SC2016 # the script's own text
  grep -qF 'AGENT_SANDBOX_KCOV_LIBS="${LD_LIBRARY_PATH:-${CONDA_PREFIX:+$CONDA_PREFIX/lib}}"' "$REPO_ROOT/scripts/coverage.sh"
  run grep -n 'LD_LIBRARY_PATH=' "$REPO_ROOT/scripts/coverage.sh"
  [ "$status" -eq 1 ]
}

@test "coverage: a failed test fails its engine stage, once the stage has run, with what its last run said; a stage with none failed passes" {
  # a stand-in kcov on PATH (need_kcov): these files launch no engine, so it never runs
  mkdir -p "$T/bin" "$T/u"
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/kcov"
  chmod +x "$T/bin/kcov"
  printf '@test "u1" {\n  :\n}\n@test "u2 fails" {\n  run echo U2-SAID\n  false\n}\n' >"$T/u/u.bats"
  # shellcheck disable=SC2016 # the script's own $1 and $2
  run --separate-stderr env PATH="$T/bin:$PATH" COVERAGE_OUT="$T/out" COVERAGE_JOBS=1 COVERAGE_TEST_TIMEOUT= bash -c \
    'source "$1/scripts/coverage.sh" && run_engine_suite engine-unit "$2/u"' _ "$REPO_ROOT" "$T"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"   kcov runs collected: 0"* ]]
  [ "$(grep -c '^not ok' "$T/out/engine-unit.tap")" -eq 1 ]
  # the output of the failed test's last run is in the .tap CI uploads: a failure under
  # kcov on the runner says what the engine said (#469's CI run did not)
  grep -qx '# U2-SAID' "$T/out/engine-unit.tap"
  printf '@test "u1" {\n  :\n}\n' >"$T/u/u.bats"
  # shellcheck disable=SC2016 # the script's own $1 and $2
  run --separate-stderr env PATH="$T/bin:$PATH" COVERAGE_OUT="$T/out" COVERAGE_JOBS=1 COVERAGE_TEST_TIMEOUT= bash -c \
    'source "$1/scripts/coverage.sh" && run_engine_suite engine-unit "$2/u"' _ "$REPO_ROOT" "$T"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "coverage: engine runs both stages and the merge, then fails if a stage's test failed; a missing tool ends it at once" {
  # shellcheck disable=SC2016 # the script's own text
  local stubs='run_engine_suite() { echo "ran $1"; [[ "$1" != "$FAIL" ]] || return "$RC"; }; run_engine_merge() { echo merged; }'
  # shellcheck disable=SC2016 # the script's own $1
  run env COVERAGE_OUT="$T/out" FAIL=engine-unit RC=1 bash -c 'source "$1/scripts/coverage.sh" && eval "$2" && run_engine' _ "$REPO_ROOT" "$stubs"
  echo "$output"
  [ "$status" -eq 1 ]
  [ "$output" = $'ran engine-unit\nran engine-integration\nmerged' ]
  # shellcheck disable=SC2016 # the script's own $1
  run env COVERAGE_OUT="$T/out" FAIL=engine-unit RC=2 bash -c 'source "$1/scripts/coverage.sh" && eval "$2" && run_engine' _ "$REPO_ROOT" "$stubs"
  echo "$output"
  [ "$status" -eq 2 ]
  [ "$output" = "ran engine-unit" ]
  # shellcheck disable=SC2016 # the script's own $1
  run env COVERAGE_OUT="$T/out" FAIL=none RC=1 bash -c 'source "$1/scripts/coverage.sh" && eval "$2" && run_engine' _ "$REPO_ROOT" "$stubs"
  [ "$status" -eq 0 ]
}

@test "coverage: all measures the addon whatever the engine did, and fails on a failed test or a failed addon, not on a missing kcov" {
  # shellcheck disable=SC2016 # the script's own text
  local stubs='run_engine() { echo engine; return "$ENG"; }; run_addon() { echo addon; return "$ADD"; }'
  local eng add want
  for eng in 0 1 2; do
    for add in 0 1; do
      want=$add
      [[ "$eng" != 1 ]] || want=1
      # shellcheck disable=SC2016 # the script's own $1
      run env COVERAGE_OUT="$T/out" ENG="$eng" ADD="$add" bash -c 'source "$1/scripts/coverage.sh" && eval "$2" && run_all' _ "$REPO_ROOT" "$stubs"
      echo "engine $eng, addon $add: status $status"
      [ "$output" = $'engine\naddon' ]
      [ "$status" -eq "$want" ]
    done
  done
}
