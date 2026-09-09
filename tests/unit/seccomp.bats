#!/usr/bin/env bats
# AGENT_SANDBOX_SECCOMP=default: bwrap gets --seccomp 10 with fd 10 open on the
# compiled filter for this arch; off by default; refuses when the filter is
# missing or the value is unknown. The stub bwrap here also records what fd 10
# points at, so the fd plumbing (not just the flag) is under test.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  cat >"$H/bin/bwrap" <<'S'
#!/usr/bin/env bash
: >"${BWRAP_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >>"$BWRAP_DUMP"; done
readlink /proc/self/fd/10 >"$BWRAP_DUMP.fd10" 2>/dev/null || echo "(no fd 10)" >"$BWRAP_DUMP.fd10"
exit 0
S
  chmod +x "$H/bin/bwrap"
  SC="$H/seccomp"
  mkdir -p "$SC"
  printf 'not-a-real-bpf' >"$SC/$(uname -m).bpf"
}

@test "off by default: no --seccomp, fd 10 is /dev/null" {
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --seccomp
  [ "$(cat "$H/argv.fd10")" = /dev/null ]
}

@test "default: --seccomp 10 is passed and fd 10 is the arch's compiled filter" {
  run_engine AGENT_SANDBOX_SECCOMP=default AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  [ "$(cat "$H/argv.fd10")" = "$SC/$(uname -m).bpf" ]
  [[ "$output" == *"seccomp: default-deny syscall filter on"* ]]
}

@test "default with no compiled filter for this arch refuses to launch and says how to fix it" {
  rm -f "$SC/$(uname -m).bpf"
  run_engine AGENT_SANDBOX_SECCOMP=default AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"no seccomp filter for $(uname -m)"* && "$output" == *"re-run install.sh"* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
}

@test "an unknown value is refused" {
  run_engine AGENT_SANDBOX_SECCOMP=strictest AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* ]]
}
