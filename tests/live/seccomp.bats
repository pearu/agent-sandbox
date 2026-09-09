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
profile_bin_discover() {
  profile_bin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scprobe-bin.sh"
}
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
  run env AGENT_SANDBOX_PROFILE_DIR="$PROF" AGENT_SANDBOX_NET=proxy "$ENGINE" --profile scprobe run
  [ "$status" -eq 0 ]
  [[ "$output" == *"seccomp_mode=0"* ]]
  [[ "$output" == *"userns=created"* ]]
}

@test "with AGENT_SANDBOX_SECCOMP=default: a filter is active and creating a user namespace is refused" {
  run env AGENT_SANDBOX_PROFILE_DIR="$PROF" AGENT_SANDBOX_NET=proxy AGENT_SANDBOX_SECCOMP=default \
    "$ENGINE" --profile scprobe run
  [ "$status" -eq 0 ]
  [[ "$output" == *"seccomp_mode=2"* ]]
  [[ "$output" == *"userns=refused"* ]]
  [[ "$output" == *"plain_exec=ok"* ]]
}
