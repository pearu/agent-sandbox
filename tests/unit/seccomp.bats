#!/usr/bin/env bats
# AGENT_SANDBOX_SECCOMP=on: bwrap gets --seccomp 10 with fd 10 open on the
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

@test "ON by default: no knob needed, --seccomp 10 with the arch's filter" {
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  [ "$(cat "$H/argv.fd10")" = "$SC/$(uname -m).bpf" ]
}

@test "on by default with no filter compiled: warns, runs anyway, no --seccomp" {
  # install.sh only warns when it cannot build the filter, so a machine can end
  # up without one. Refusing here would break a tool the user never asked to
  # change, for no gain over the previous default -- so it runs and says so.
  rm -f "$SC/$(uname -m).bpf"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 0 ]
  ! argv_has --seccomp
  [ "$(cat "$H/argv.fd10")" = /dev/null ] # and the launcher still opens fd 10
  [[ "$output" == *"runs WITHOUT one"* ]]
  [[ "$output" == *"re-run install.sh"* || "$output" == *"Re-run install.sh"* ]]
  # ...and why it is not merely defence in depth on an installed host
  [[ "$output" == *"user namespaces"* ]]
}

@test "explicitly on with no filter still refuses: asked for, so not silently weaker" {
  rm -f "$SC/$(uname -m).bpf"
  run_engine AGENT_SANDBOX_SECCOMP=on AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 1 ]
  [ ! -s "$H/argv" ]
}

@test "on: --seccomp 10 is passed and fd 10 is the arch's compiled filter" {
  run_engine AGENT_SANDBOX_SECCOMP=on AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  [ "$(cat "$H/argv.fd10")" = "$SC/$(uname -m).bpf" ]
  [[ "$output" == *"seccomp: default-deny syscall filter on"* ]]
}

@test "on with no compiled filter for this arch refuses to launch and says how to fix it" {
  rm -f "$SC/$(uname -m).bpf"
  run_engine AGENT_SANDBOX_SECCOMP=on AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 1 ]
  [[ "$output" == *"no seccomp filter for $(uname -m)"* && "$output" == *"re-run install.sh"* ]]
  [ ! -s "$H/argv" ] # bwrap never ran
}

@test "1 is on too; off and 0 turn it off; empty means the default, which is on" {
  local v
  for v in 1 ""; do
    run_engine AGENT_SANDBOX_SECCOMP="$v" AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
    [ "$status" -eq 0 ]
    argv_has --seccomp 10
  done
  for v in off 0; do
    run_engine AGENT_SANDBOX_SECCOMP="$v" AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
    [ "$status" -eq 0 ]
    ! argv_has --seccomp
    [ "$(cat "$H/argv.fd10")" = /dev/null ]
  done
}

@test "an unknown value is refused -- including 'default', which no longer means on" {
  run_engine AGENT_SANDBOX_SECCOMP=strictest AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* ]]
  # the value the knob used to take. Refused loudly rather than accepted as an
  # alias or ignored as unset: a stale AGENT_SANDBOX_SECCOMP=default in someone's
  # shell profile must not silently launch WITHOUT the filter they asked for.
  run_engine AGENT_SANDBOX_SECCOMP=default AGENT_SANDBOX_SECCOMP_DIR="$SC" -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* && "$output" == *"'on' or 'off'"* ]]
  [ ! -s "$H/argv" ]
}

# ---- the generator's kernel gate (issue found by review, F4) ---------------

@test "generator: a minKernel gate is judged against the host kernel, not a fixed floor" {
  python3 -c 'import pyseccomp' 2>/dev/null || skip "pyseccomp not importable"
  local gen="$REPO_ROOT/components/seccomp/gen-seccomp.py"

  # A profile with one allow rule gated above the old hard-coded floor (5.15).
  # Judged against the floor it is dropped; judged against a 6.8 host it applies.
  local prof="$BATS_TEST_TMPDIR/p.json"
  cat >"$prof" <<'JSON'
{ "defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 1,
  "syscalls": [ { "names": ["listen"], "action": "SCMP_ACT_ALLOW",
                  "includes": { "minKernel": "6.0" } } ] }
JSON
  run python3 - "$gen" "$prof" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gen", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.HOST_KERNEL = (5, 15); floor = m.kernel_ok("6.0")
m.HOST_KERNEL = (6, 8);  host  = m.kernel_ok("6.0")
bad = m.kernel_ok("not-a-version")
print(f"floor={floor} host={host} unparseable={bad}")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"floor=False"* ]]       # the old behaviour, now only for old hosts
  [[ "$output" == *"host=True"* ]]         # the bug: this used to be False on a 6.8 host
  [[ "$output" == *"unparseable=False"* ]] # a gate we cannot read stays denied
}

@test "generator: the kernel argument is optional and a bad one falls back, not crashes" {
  python3 -c 'import pyseccomp' 2>/dev/null || skip "pyseccomp not importable"
  local gen="$REPO_ROOT/components/seccomp/gen-seccomp.py"
  local prof="$REPO_ROOT/components/seccomp/moby-default.json"
  local arch
  arch="$(uname -m)"
  [[ "$arch" == x86_64 || "$arch" == aarch64 ]] || skip "unsupported arch $arch"

  run python3 "$gen" "$prof" "$arch" "$BATS_TEST_TMPDIR/a.bpf" # no kernel arg
  [ "$status" -eq 0 ] && [ -s "$BATS_TEST_TMPDIR/a.bpf" ]
  run python3 "$gen" "$prof" "$arch" "$BATS_TEST_TMPDIR/b.bpf" "$(uname -r)"
  [ "$status" -eq 0 ] && [ -s "$BATS_TEST_TMPDIR/b.bpf" ]
  run python3 "$gen" "$prof" "$arch" "$BATS_TEST_TMPDIR/c.bpf" "garbage"
  [ "$status" -eq 0 ] && [ -s "$BATS_TEST_TMPDIR/c.bpf" ] # falls back, still builds
  [[ "$output" == *"cannot parse kernel"* ]]
}
