# agent-sandbox

[![CI](https://github.com/pearu/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/pearu/agent-sandbox/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/pearu/agent-sandbox/graph/badge.svg)](https://codecov.io/gh/pearu/agent-sandbox)

Run an AI coding agent inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox: a default-deny filesystem, an egress allowlist the agent cannot
bypass with its normal HTTP clients, host-routed self-update, and an opt-in
SSH broker whose keys never enter the sandbox. One bash script and a
per-agent profile; no image to build. The flagship profile runs
[Claude Code](https://docs.anthropic.com/claude-code) as `claude`, exactly as
before, now inside the sandbox.

```
cd ~/projects/thing
claude                       # sandboxed: this directory read-write, little else
claude --ssh github.com      # + git push through a per-session, host-constrained ssh-agent
claude --allow pypi.org      # + one more host through the egress proxy, this session only
```

## What the agent gets

- **Filesystem**: the system directories read-only; a fresh `/tmp`; an empty,
  read-only `$HOME` in which only the agent's own state (`~/.claude`), the
  current project directory (read-write), the active conda env (read-only
  unless asked), a session-private `~/.cache`, and paths you list are visible.
  Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.netrc`, ...) and the
  sandbox's own configuration are refused, as CWD too, along with any directory
  that contains them.
- **Network**: through a host-side mitmproxy with an allowlist you edit
  (`~/.config/agent-sandbox/allowlist.txt`). Blocked hosts are refused before
  any connection is made and logged. The proxy's CA is trusted inside the
  sandbox only; your host never trusts it. Near-native throughput.
- **Credentials**: an explicit, small environment allowlist; no `AWS_*`,
  `GH_TOKEN`, `KUBECONFIG`, `SSH_AUTH_SOCK`. With `--ssh HOST` a per-session
  ssh-agent on the host signs only for the hosts you name.
- **Updates**: `claude update` runs the native updater on the host, never
  inside.

What it does **not** do is spelled out in [docs/design.md](docs/design.md):
in the default `proxy` mode the sandbox shares the host network namespace, so a
tool that ignores `HTTPS_PROXY` is unfiltered (`AGENT_SANDBOX_NET=strict` closes
that — its own namespace, only the proxy reachable); the agent's own credentials
in `~/.claude` are readable; there is no seccomp filter.

## Install

Requirements: Linux with unprivileged user namespaces, `bubblewrap`, `curl`,
`git`, and either `python3 >= 3.12` with `venv` or conda/mamba (for the proxy
runtime). On Ubuntu 24.04+ the installer needs `sudo` once, to install an
AppArmor profile allowing bwrap to use user namespaces (and, if you use the
strict network mode, one for pasta); nothing else needs root.

```
git clone https://github.com/pearu/agent-sandbox.git
cd agent-sandbox
./install.sh            # or ./install.sh --dry-run to see what it would do
```

The installer is idempotent: it sets up the proxy (mitmproxy 12+ in a private
environment under `~/.local/share/agent-sandbox`), generates the CA, writes
the allowlist (keeping your edits on re-runs) and adds each profile's hosts,
installs the systemd user unit, **copies the engine and profiles under
`~/.local/share/agent-sandbox`** and points `~/.local/bin/<agent>` at that copy
for every profile. Because the command runs from the copy, you can move or
delete this clone afterward; re-run `./install.sh` after pulling to update.
Working *on* agent-sandbox? `./install.sh --dev` points the launcher at the
checkout instead, so your edits take effect at the next launch (see
[docs/design.md](docs/design.md) for why that is dev-only). Standalone:
`curl -fsSL https://raw.githubusercontent.com/pearu/agent-sandbox/main/install.sh | bash`
clones the repository under `~/.local/share/agent-sandbox/src` and installs
the copy from there.

Then open a fresh shell, `cd` into a project, and run `claude`.

## Knobs and flags

Environment knobs, set in the calling shell:

| Knob | Effect |
|---|---|
| `AGENT_SANDBOX_RO=/a:/b`, `AGENT_SANDBOX_RW=/c` | extra read-only / read-write paths |
| `AGENT_SANDBOX_PASSENV="A B"` | extra environment variables to forward |
| `AGENT_SANDBOX_CONDA_WRITE=1` | make the active conda env writable (`mamba install`, `pip install`); the base install stays read-only |
| `AGENT_SANDBOX_NET=proxy\|strict\|open\|none` | network mode, default `proxy` |
| `AGENT_SANDBOX_HOST_PORTS="5432"`, `AGENT_SANDBOX_AGENT_PORTS="8000"` | in `strict` mode: host loopback ports the sandbox may reach / agent ports published on the host's loopback (TCP; or `none`) |
| `AGENT_SANDBOX_CONDA_PKGS`, `AGENT_SANDBOX_PROXY_CA`, `AGENT_SANDBOX_PROFILE_DIR`, `AGENT_SANDBOX_SESSION_BASE` | locations; see `agent-sandbox --help` |

Engine flags, before the agent's own arguments: `--profile NAME`,
`--allow HOST`, `--host-port PORT`, `--agent-port PORT`, `--ssh HOST`,
`--ssh-unrestricted`, `--ssh-key PATH`, `--ssh-timeout LIFE`, `--trust`,
`--engine-help`, `--engine-version`. `agent-sandbox --help` lists
them; with a profile, `<agent> --engine-help` shows the same, and `<agent> --help`
ends with a footer pointing at it.

A project can carry a git-ignored `.agent-sandbox` file with per-project
policy (egress hosts, memory scoping, extra paths, forwarded variables, conda
settings, the network mode and strict-mode ports), honored only after
`claude --trust` approves it. See [docs/config.md](docs/config.md).

## Documentation

- [docs/design.md](docs/design.md): architecture, threat model, every
  guarantee with its mechanism and check, residual risks, open questions.
- [docs/network.md](docs/network.md): network modes, the allowlist,
  `--allow`, the CA, the proxy.
- [docs/config.md](docs/config.md): the per-project `.agent-sandbox` file, its
  trust gate, and per-project memory scoping.
- [docs/ssh.md](docs/ssh.md): the SSH broker.
- [docs/profiles.md](docs/profiles.md): the profile contract; adding an agent.
- [docs/updating.md](docs/updating.md), [docs/troubleshooting.md](docs/troubleshooting.md),
  [docs/prior-art.md](docs/prior-art.md).
- [AGENTS.md](AGENTS.md): rules for AI maintainers; [CONTRIBUTING.md](CONTRIBUTING.md);
  tests: `tests/run.sh` (bats, from `environment.yml`; `e2e` installs for real
  into a throwaway HOME, opt-in).

## How it compares

Most sandboxes for coding agents are Docker devcontainers, usually with
unrestricted egress. Among the bubblewrap-based ones, agent-sandbox is the one
that enforces an egress allowlist by default, and its destination-constrained
SSH broker has no counterpart in the projects surveyed. Details and credits in
[docs/prior-art.md](docs/prior-art.md).

## License

BSD-3-Clause; see [LICENSE](LICENSE).
