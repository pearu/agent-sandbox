# Live tests

Opt-in only: `AGENT_SANDBOX_LIVE=1 tests/run.sh live`. They use the real
network, the host's running proxy, and (for SSH) your own key and
`~/.ssh/known_hosts`. Never run in CI.
