# Live tests (opt-in)

Real network and your real agent credentials. Never run in CI. Run with:

    AGENT_SANDBOX_LIVE=1 tests/run.sh live

Preconditions (each test skips if unmet): `bwrap` installed, and for each agent what its
profile's test adapter (`profiles/<name>/test.bash`, `test_live_ready`) checks -- for
claude: the proxy on `127.0.0.1` at the port `install.sh` recorded in
`~/.config/agent-sandbox/proxy-port` (8888 unless it chose another;
`AGENT_SANDBOX_PROXY_PORT` overrides it, as for the engine) -- the
`agent-sandbox-mitmproxy` service -- credentials in `~/.claude`, and Claude Code
installed for asb (`asb --install claude`, under `~/.local/state/agent-sandbox/claude/install/`). The strict tests additionally need
`pasta`/`nft` and the ability to create a namespace here.

- `proxy.bats` — the proxy allows/refuses hosts; leaf certs carry an AKI.
- `agent.bats` — the real agent, one cheap turn per net mode, reaches the API, and the
  briefing reaches its context; once for every profile with a test adapter, the turn
  as its `test_live_turn` asks for it (claude: Haiku, `-p`). These exercise the
  agent's own HTTP stack, which the stub-agent suites cannot; they catch proxy/DNS
  regressions (e.g. the token-hang and the strict `--clearenv` proxy-env wipe) that
  unit and integration tests missed. An agent that is not ready here skips, saying
  why; `AGENT_SANDBOX_LIVE_AGENTS="claude"` runs only the agents named, and fails one
  that is not ready.
