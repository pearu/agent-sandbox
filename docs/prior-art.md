# Prior art

A landscape scan done while planning this repository (September 2026),
based on the projects' READMEs. Details may have changed since; treat this as
orientation, not review.

| Project | Isolation | Egress control | SSH / credentials | Notes |
|---|---|---|---|---|
| `claude-contrib/claude-sandbox`, `aniktatripathy/claude-sandbox`, `textcortex/claude-code-sandbox`, `tobby-lie/claude-sbx`, `bxxf/codebox` | Docker devcontainers (codebox: E2B) | mostly none or optional | varies | the majority of the field |
| `FoamoftheSea/claude-code-sandbox` | Docker | Squid with **SNI** allowlisting, no CA injection | | ships a security test suite in CI; the most mature on trust |
| `CaptainMcCrank/SandboxedClaudeCode` | bwrap + firejail; Apple Container on macOS | optional | forwards the **unconstrained** ssh agent socket | firejail gives seccomp; macOS support |
| `janvojt/ai-agent-sandbox` | bwrap | **full network** | **removes ssh** entirely | |
| Anthropic's official sandboxing | local + web sandboxing | | the web sandbox uses an out-of-sandbox credential broker with scoped credentials | not verified from inside this project's own allowlist; same philosophy as this project's SSH broker |

## Where agent-sandbox stands

- An **egress allowlist enforced by default** among the bubblewrap-based
  tools, refusing blocked hosts before any connection is made, with the proxy
  CA trusted inside the sandbox only.
- A **destination-constrained SSH broker**: the key stays on the host and the
  per-session agent signs only for the hosts you named. No other tool in the
  scan has this.
- Host-routed self-update, conda/CUDA passthrough, a single script with no
  image to build, and a provider-profile engine aimed at running many agents.

## Design questions this scan raised

Both are tracked in [design.md](design.md) under open questions:

1. **SNI/TLS-passthrough allowlisting** (FoamoftheSea's approach) enforces the
   same host allowlist without a custom CA. Measured here at 71 MB/s against
   50 to 74 MB/s for interception; rejected for now to keep per-path logging
   and refuse non-HTTP tunnels, but it would remove the CA entirely.
2. **A seccomp/firejail backend.** The firejail-based tools filter syscalls;
   this project does not.
