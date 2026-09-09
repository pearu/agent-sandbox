#!/usr/bin/env bats
# Real ssh through the engine in strict mode (AGENT_SANDBOX_LIVE=1; never in CI).
# Guards the uid-0 bug: in strict the agent runs as uid 0, so ssh resolves ~ via
# getpwuid(0) to root's home, not $HOME, and must still find the bound
# known_hosts. A stubbed ssh toolchain (the unit test) cannot exercise this.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  [[ "${AGENT_SANDBOX_LIVE:-0}" == 1 ]] || skip "set AGENT_SANDBOX_LIVE=1 to run live tests"
  command -v bwrap >/dev/null || skip "bwrap not installed"
  command -v pasta >/dev/null || skip "pasta (passt) not installed"
  command -v nft >/dev/null || skip "nft (nftables) not installed"
  ip route show default 2>/dev/null | grep -q . || skip "no default-route gateway"
  timeout -k 1 8 pasta --config-net --quiet -- true >/dev/null 2>&1 3>&- \
    || skip "pasta cannot create a namespace here"
  ssh-keygen -F github.com >/dev/null 2>&1 || skip "github.com not in ~/.ssh/known_hosts"
  ls "$HOME"/.ssh/id_* >/dev/null 2>&1 || skip "no ssh key under ~/.ssh"
  PROF="$(mktemp -d)"
  cat >"$PROF/sshprobe.sh" <<'P'
profile_command=sshprobe
profile_bin_discover() {
  profile_bin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/sshprobe-bin.sh"
}
P
  cat >"$PROF/sshprobe-bin.sh" <<'P'
#!/usr/bin/env bash
echo "uid=$(id -u)"
ssh -o BatchMode=yes -o ConnectTimeout=12 -T git@github.com 2>&1 | tail -2
P
  chmod +x "$PROF/sshprobe-bin.sh"
}

teardown() {
  [ -n "${PROF:-}" ] && rm -rf "$PROF"
  return 0
}

@test "strict --ssh: the agent verifies github's host key and authenticates as uid 0" {
  run env AGENT_SANDBOX_PROFILE_DIR="$PROF" AGENT_SANDBOX_NET=strict \
    "$ENGINE" --profile sshprobe --ssh github.com run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uid=0"* ]]                      # strict runs the agent as root in pasta's userns
  [[ "$output" == *"successfully authenticated"* ]] # host key verified (from uid 0's ~) + agent key accepted
}
