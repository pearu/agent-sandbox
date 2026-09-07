#!/usr/bin/env bash
# A test profile: the "agent" is whatever script AGENT_SANDBOX_TEST_BIN names.
# The engine binds it read-only into the sandbox and runs it; integration
# tests point it at a probe that writes a report into $CWD (bound read-write).
# shellcheck disable=SC2034  # the profile contract: read by the engine
profile_command=probe
profile_bin_discover() {
  profile_bin="${AGENT_SANDBOX_TEST_BIN:?set AGENT_SANDBOX_TEST_BIN}"
  profile_version="test"
}
