# Live tests (opt-in)

Real network and your real Claude credentials. Never run in CI. Run with:

    AGENT_SANDBOX_LIVE=1 tests/run.sh live

Preconditions (each test skips if unmet): `bwrap` installed, the proxy on
`127.0.0.1:8888` (the `agent-sandbox-mitmproxy` service), credentials in
`~/.claude`, and a Claude binary under `~/.local/share/claude/versions`. The
strict tests additionally need `pasta`/`nft` and the ability to create a
namespace here.

- `proxy.bats` — the proxy allows/refuses hosts; leaf certs carry an AKI.
- `agent.bats` — the real agent, one cheap Haiku turn per net mode, reaches the
  API. These exercise the agent's own HTTP stack, which the stub-agent suites
  cannot; they catch proxy/DNS regressions (e.g. the token-hang and the strict
  `--clearenv` proxy-env wipe) that unit and integration tests missed.
