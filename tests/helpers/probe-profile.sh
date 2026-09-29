#!/usr/bin/env bash
# A test profile: the "agent" is the command `probe`, which the integration
# harness puts on PATH (#151). The engine binds it read-only into the sandbox and
# runs it: a probe that writes a report into $CWD (bound read-write).
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

# A background daemon, for the keeper's hold (tests/integration/keeper.bats): a
# process with these argv tokens, inside the launch, keeps the role running.
# shellcheck disable=SC2034 # engine contract
profile_daemon_argv=(daemon run)
# shellcheck disable=SC2034
profile_verbs=(agents stop)
# shellcheck disable=SC2034
profile_verbs_observe=(agents)
