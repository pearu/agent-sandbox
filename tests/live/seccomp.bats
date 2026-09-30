#!/usr/bin/env bats
# The compiled seccomp filter really is enforced inside the sandbox
# (AGENT_SANDBOX_LIVE=1; needs install.sh to have compiled it for this arch).
# Probes from inside: is a filter active, and is creating a user namespace (the
# capability-regain path) refused? The unfiltered launch is the control.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests"
  command -v bwrap >/dev/null || skip "bwrap not installed"
  [ -r "$HOME/.local/share/agent-sandbox/seccomp/$(uname -m).bpf" ] \
    || skip "no compiled seccomp filter for $(uname -m); re-run install.sh"
  PROF="$(mktemp -d)"
  cat >"$PROF/scprobe.sh" <<'P'
profile_command=scprobe
P
  cat >"$PROF/scprobe-bin.sh" <<'P'
#!/usr/bin/env bash
echo "seccomp_mode=$(awk '/^Seccomp:/{print $2}' /proc/self/status)"   # 0 none, 2 filter
if unshare -Ur true 2>/dev/null; then echo "userns=created"; else echo "userns=refused"; fi
echo "plain_exec=ok"
P
  chmod +x "$PROF/scprobe-bin.sh"
}

teardown() {
  [ -n "${PROF:-}" ] && rm -rf "$PROF"
  return 0
}

@test "without seccomp (control): no filter, and a user namespace can be created" {
  # the filter is on by default, so the control turns it off (the shell knob wins over
  # a dot-file, this repository's own included)
  run env AGENT_SANDBOX_PROFILE_DIR="$PROF" AGENT_SANDBOX_NET=proxy AGENT_SANDBOX_SECCOMP=off \
    "$ENGINE" --profile scprobe "$PROF/scprobe-bin.sh" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"seccomp_mode=0"* ]]
  # The other half of the control needs a host that lets an unprivileged process make
  # a user namespace at all. Ubuntu 24.04's AppArmor does not, for anything but a
  # program with a profile (bwrap has one; unshare does not), and then no sandbox can
  # show the difference the filter makes -- so say so rather than fail.
  if ! unshare -Ur true 2>/dev/null; then
    skip "this host refuses unprivileged user namespaces outside the sandbox too (kernel.apparmor_restrict_unprivileged_userns=1?), so the control cannot show one being created"
  fi
  [[ "$output" == *"userns=created"* ]]
}

@test "with AGENT_SANDBOX_SECCOMP=on: a filter is active and creating a user namespace is refused" {
  run env AGENT_SANDBOX_PROFILE_DIR="$PROF" AGENT_SANDBOX_NET=proxy AGENT_SANDBOX_SECCOMP=on \
    "$ENGINE" --profile scprobe "$PROF/scprobe-bin.sh" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"seccomp_mode=2"* ]]
  [[ "$output" == *"userns=refused"* ]]
  [[ "$output" == *"plain_exec=ok"* ]]
}
