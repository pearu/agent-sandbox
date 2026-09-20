#!/usr/bin/env bash
# A test profile: the "agent" is whatever script AGENT_SANDBOX_TEST_BIN names.
# The engine binds it read-only into the sandbox and runs it; integration
# tests point it at a probe that writes a report into $CWD (bound read-write).
# shellcheck disable=SC2034  # the profile contract: read by the engine
profile_command=probe
# A state directory and a channel map, so the connections machinery has
# something to act on under the real bwrap. The engine owns the modes; a profile
# only says where its agent keeps things, and this one keeps them here.
profile_config_binds=("$HOME/.probe")
profile_channels=(
  "docs	dir:$HOME/.probe/docs	file:$HOME/.probe/NOTES.md"
  "extra	dir:$HOME/.probe/extra"
)

profile_bin_discover() {
  profile_bin="${AGENT_SANDBOX_TEST_BIN:?set AGENT_SANDBOX_TEST_BIN}"
  profile_version="test"
}
