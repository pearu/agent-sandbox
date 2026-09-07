#!/usr/bin/env bats
# The SSH broker with a real ssh-agent, a generated host key and the real bwrap.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v ssh-agent >/dev/null && command -v ssh-keygen >/dev/null || skip "openssh-client not installed"
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say sock "${SSH_AUTH_SOCK-unset}"
say sock_exists "$([[ -S ${SSH_AUTH_SOCK-/nonexistent} ]] && echo yes || echo no)"
say agent_keys "$(ssh-add -l 2>&1 | grep -c ED25519)"
say known_hosts_readable "$([[ -r $HOME/.ssh/known_hosts ]] && echo yes || echo no)"
say known_hosts_writable "$(touch "$HOME/.ssh/known_hosts" 2>/dev/null && echo yes || echo no)"
say private_key_visible "$([[ -e $HOME/.ssh/id_ed25519 ]] && echo yes || echo no)"
say config_visible "$([[ -e $HOME/.ssh/config ]] && echo yes || echo no)"
PROBE
  mkdir -p "$IHOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -f "$I/hostkey" -C hostkey
  echo "example.test $(cut -d' ' -f1,2 "$I/hostkey.pub")" >"$IHOME/.ssh/known_hosts"
  ssh-keygen -q -t ed25519 -N '' -f "$IHOME/.ssh/id_ed25519" -C userkey
  chmod 700 "$IHOME/.ssh"
  make_short_base
  SESSION_BASE="$SHORT_BASE"
}

teardown() { rm -rf "${SHORT_BASE:-}"; }

@test "--ssh HOST: the constrained key is in the agent inside, known_hosts read-only, the private key invisible; clean teardown" {
  run_sandboxed AGENT_SANDBOX_NET=none -- --ssh example.test --ssh-key "$IHOME/.ssh/id_ed25519" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"constrained to: example.test"* ]]
  [[ "$(report sock)" == "$SHORT_BASE"/session.*/agent.sock ]]
  [ "$(report sock_exists)" = yes ]
  [ "$(report agent_keys)" = 1 ]
  [ "$(report known_hosts_readable)" = yes ]
  [ "$(report known_hosts_writable)" = no ]
  [ "$(report private_key_visible)" = no ]
  [ "$(report config_visible)" = no ]
  [ -z "$(ls -A "$SHORT_BASE")" ]
  ! pgrep -f "ssh-agent -s -a $SHORT_BASE" >/dev/null
}

@test "--ssh to a host without a trusted key is refused before any session exists" {
  run_sandboxed AGENT_SANDBOX_NET=none -- --ssh nowhere.test --ssh-key "$IHOME/.ssh/id_ed25519" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no trusted host key for 'nowhere.test'"* ]]
  [ -z "$(ls -A "$SHORT_BASE")" ]
  [ ! -e "$IWORK/report" ]
}

@test "the janitor reaps dead and recycled-pid sessions and keeps live ones at launch" {
  sleep 300 &
  local live=$!
  mkdir -p "$SHORT_BASE/session.dead" "$SHORT_BASE/session.live"
  echo "999999 1" >"$SHORT_BASE/session.dead/owner.id"
  printf '%s %s\n' "$live" "$(awk '{print $22}' "/proc/$live/stat")" >"$SHORT_BASE/session.live/owner.id"
  run_sandboxed AGENT_SANDBOX_NET=none -- --ssh example.test --ssh-key "$IHOME/.ssh/id_ed25519" run
  kill "$live"
  [ "$status" -eq 0 ]
  [ ! -d "$SHORT_BASE/session.dead" ]
  [ -d "$SHORT_BASE/session.live" ]
}

@test "--allow and --ssh share one session directory and are cleaned up together" {
  run_sandboxed -- --ssh example.test --ssh-key "$IHOME/.ssh/id_ed25519" --allow pypi.org run
  [ "$status" -eq 0 ]
  [[ "$output" == *"session allowlist: pypi.org"* ]]
  [ "$(report agent_keys)" = 1 ]
  [ -z "$(ls -A "$SHORT_BASE")" ]
}
