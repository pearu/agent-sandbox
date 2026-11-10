#!/usr/bin/env bats
# The host-only verbs (--install, --login, --setup-remote) are refused inside a
# sandbox on either sign of one: the AGENT_SANDBOX marker, or pid 1 being bubblewrap. The
# second is checked here with the real bwrap: the engine runs as a child of a bwrap that
# is pid 1 of its own pid namespace, with AGENT_SANDBOX unset.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  T="$BATS_TEST_TMPDIR"
}

# in_pidns WORDS... -- the engine with WORDS, under a bwrap that is pid 1, the marker unset.
in_pidns() {
  engine_cmd
  run env -i HOME="$T/home" PATH=/usr/bin:/bin bwrap --dev-bind / / --unshare-user --unshare-pid \
    --proc /proc --unsetenv AGENT_SANDBOX -- "${ENGINE_CMD[@]}" "$@"
}

@test "pid 1 bubblewrap, AGENT_SANDBOX unset: --install, --login and --setup-remote are refused (2)" {
  mkdir -p "$T/home"
  in_pidns --install claude
  [ "$status" -eq 2 ]
  [ "$output" = "agent-sandbox: --install runs on the host: it downloads the agent there, for every sandbox to run; a role proposes the line, you run it." ]
  in_pidns --agent claude --account work --login
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: --login runs on the host:"* ]]
  in_pidns --setup-remote somehost
  [ "$status" -eq 2 ]
  [[ "$output" == "agent-sandbox: --setup-remote runs on the host:"* ]]
  [ ! -e "$T/home/.local/state" ]
}
