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

## Why

The more you let an AI coding agent work on its own, the more useful it is:
reading the whole project, installing what it needs, running the tests,
changing a dozen files. That freedom is also the problem. You cannot check what
an agent means to do, and you cannot review everything it touched afterwards,
so in practice you just trust it. Trust has to cover two different failures
here. An agent can be led into doing something you never asked for, by the
content it reads or by a package it installs. It can also simply be wrong, and
run a command that deletes your work or publishes something private. From the
outside these look the same, and both run with everything you can reach.

agent-sandbox replaces that trust with a boundary you set in advance. You say
which project the agent may work in and which places on the network it may
reach. Everything else, the rest of your files, your keys and tokens, your
other machines and services, is not discouraged but simply absent. What matters
is that the limits are enforced around the agent, not by it. Asking an agent to
respect a rule does not last: it obeys for a while, then drifts, and you have
to remind it again. A limit around the agent cannot drift. It holds whether the
agent is careful, mistaken, or deliberately pushed against you. Two more aims
follow. Sessions running at the same time cannot reach into each other's work.
And where a protection is weaker than it sounds, we say so plainly. Believing
you are safe when you are not is worse than knowing where the limit really is.

A limit the agent cannot see is a limit it will fight. Blocked once, an agent
retries, looks for another route, and spends your time proving what you already
decided. So the sandbox tells it, at the start of every session, what is closed,
what is open, and how to ask you for more. The same message does the opposite
job too: access you opened on purpose is worth nothing if the agent never learns
it is there, and asking you costs far less than twenty attempts to get around
you.

Is it worth installing? That depends on one question: how much does the agent
do while you are not reading every command? If you approve each step yourself,
you are already the sandbox, and this adds little. Once you stop doing that,
the question becomes what a single bad step could reach. That is what you set
here, once, and then stop thinking about.

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
that: its own namespace, only the proxy reachable); the agent's own credentials
in `~/.claude` are readable; syscall filtering is opt-in, not on by default
(`AGENT_SANDBOX_SECCOMP=on`).

## Scope

agent-sandbox wraps a **local process**. If you launch an agent on your machine,
it can run inside the sandbox; if the agent runs on someone else's machine,
there is nothing here to put a boundary around.

**Covered.** Any agent you start locally through a launcher: the engine is
provider-agnostic and everything agent-specific lives in a profile, so a new
agent needs a profile rather than engine changes
([profiles.md](docs/profiles.md)). Only the `claude` profile ships today. MCP
servers are covered automatically, since the agent spawns them inside the
sandbox.

**Not covered, and cannot be.** claude.ai in a browser, Claude Code on the web,
and cloud or background sessions all run on Anthropic's servers. The risk there
is a different shape: such an agent has no access to your filesystem or your LAN
in the first place, so a local sandbox has nothing to protect. What it *can*
reach — a connected GitHub account, say — is granted on the service side and can
only be limited there.

**Depends on how it is launched.** Anything that runs `claude` from your PATH
reaches the launcher and is sandboxed — a terminal inside your editor included.
Anything that calls the agent's own binary by an absolute path is not, and
nothing will tell you.

The **VS Code extension is the second case**: it ships its own copy of Claude
Code and runs that, so its sessions are outside the sandbox while a terminal in
the same window is inside it. To see which you have, with a session running:

```
./probes/whats-running.sh    # lists agent processes, sandboxed or not
```

[recipes.md](docs/recipes.md#editors-and-ides) covers what to do about it.

**Single user.** Everything installs into one account and there is no
system-wide mode; the installer refuses to run through `sudo`. See
[Install](#install).

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

agent-sandbox is a **single-user tool**. Everything it installs belongs to one
account: the proxy is a systemd *user* unit, the allowlist and trust store live
in that account's `~/.config`, and the launcher goes on that account's PATH.
There is no system-wide mode, and the installer refuses to run through `sudo` —
it asks for sudo itself for the one step that needs it, the AppArmor profile.

The installer is idempotent: it sets up the proxy (mitmproxy 12+ in a private
environment under `~/.local/share/agent-sandbox`), generates the CA, writes
the allowlist (keeping your edits on re-runs) and adds each profile's hosts,
installs the systemd user unit, and **copies the engine and profiles under
`~/.local/share/agent-sandbox`**. Because the command runs from the copy, you
can move or delete this clone afterward; re-run `./install.sh` after pulling to
update.

It then makes sure that typing the command reaches the sandbox, which is the
only thing that decides whether any of this applies. If `claude` is already on
your PATH in a directory you can write to — what Claude Code's own installer
leaves — it is moved aside to `claude.pre-agent-sandbox` and the sandbox
launcher takes its place, so PATH order is untouched. If it lives somewhere
read-only such as `/usr/bin`, the launcher goes in the first writable PATH
directory *before* it and shadows it, leaving the original alone. If there is
no `claude` on PATH at all, the launcher goes in the first writable PATH
directory. And if none of those is possible, the installer stops and shows how
to fix your PATH, rather than installing something that would lose.

Undo it with `./install.sh --uninstall`: it gives the original launcher back
and removes the rest ([troubleshooting.md](docs/troubleshooting.md)).
Working *on* agent-sandbox? `./install.sh --dev` points the launcher at the
checkout instead, so your edits take effect at the next launch (see
[docs/design.md](docs/design.md) for why that is dev-only). Standalone:
`curl -fsSL https://raw.githubusercontent.com/pearu/agent-sandbox/main/install.sh | bash`
clones the repository under `~/.local/share/agent-sandbox/src` and installs
the copy from there.

Then open a fresh shell, `cd` into a project, and run `claude`.

## Knobs and flags

Each setting is listed with every way to set it; a dash means that form does
not exist. Values and defaults are in the last column.

| Command line | Environment | `.agent-sandbox` | What it does (default) |
|---|---|---|---|
| `--profile NAME` | — | — | which agent profile to run; inferred from the launcher's name ([profiles.md](docs/profiles.md)) |
| `--allow HOST` | — | `[allow]` | extra hosts the agent may reach, on top of the global allowlist; one host per line in the file, and the flag lasts one session (none) ([network.md](docs/network.md)) |
| — | `AGENT_SANDBOX_NET` | `[net] mode` | network mode: `proxy` (default), `strict`, `open`, `none` ([network.md](docs/network.md)) |
| `--host-port PORT` | `AGENT_SANDBOX_HOST_PORTS` | `[net] host-port` | `strict` only: host loopback ports the sandbox may reach, space-separated in the variable; `none` closes the direction (none) ([network.md](docs/network.md)) |
| `--agent-port PORT` | `AGENT_SANDBOX_AGENT_PORTS` | `[net] agent-port` | `strict` only: agent ports published on the host's loopback; `none` closes the direction (none) ([network.md](docs/network.md)) |
| — | `AGENT_SANDBOX_RO` | `[ro]` | extra read-only paths: colon-separated in the variable, one per line in the file (none) ([design.md](docs/design.md)) |
| — | `AGENT_SANDBOX_RW` | `[rw]` | extra read-write paths, same syntax (none) ([design.md](docs/design.md)) |
| — | `AGENT_SANDBOX_FORWARD` | `[forward]` | extra environment variables to forward, by name, space-separated (only the built-in set: locale, proxy, CA, CUDA) |
| — | `AGENT_SANDBOX_CONDA_WRITE` | `[conda] write` | `1` makes the active conda env writable; its base install and other envs stay read-only (read-only) |
| — | `AGENT_SANDBOX_CONDA_PKGS` | `[conda] pkgs` | package cache used in write mode (`~/.cache/agent-sandbox/conda-pkgs`) |
| — | — | `[conda] name` | run in this conda env instead of the shell's active one (the active one) ([config.md](docs/config.md)) |
| — | — | `[share-memory]` | which projects' agent memory this session may read: paths, `all`, or present-but-empty for this project only (scoped to this project; widen with the global `memory_default = shared`) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_SECCOMP` | `[seccomp] mode` | `on` loads a default-deny syscall filter, compiled per machine by `install.sh` (off) ([seccomp](components/seccomp/README.md)) |
| — | `AGENT_SANDBOX_BRIEFING` | `[briefing] mode` | tell the session what its sandbox allows, what is blocked and how to ask for more (on) ([config.md](docs/config.md)) |
| `--ssh HOST` | — | — | reach HOST over SSH through a per-session agent constrained to it; the key never enters the sandbox (no SSH) ([ssh.md](docs/ssh.md)) |
| `--ssh-unrestricted` | — | — | any host the key is trusted by; refused in `strict`, which must pin named hosts (off) ([ssh.md](docs/ssh.md)) |
| `--ssh-key PATH` | — | — | which private key to load (the first readable one under `~/.ssh`) ([ssh.md](docs/ssh.md)) |
| `--ssh-timeout LIFE` | — | — | how long that key stays loaded, e.g. `30m` (no expiry) ([ssh.md](docs/ssh.md)) |
| `--trust` | — | — | review and approve this project's `.agent-sandbox`; an unapproved file is ignored, an edited one blocks launches until re-reviewed ([config.md](docs/config.md)) |
| `--engine-help`, `--engine-version` | — | — | print the engine's own flags, or its version, and exit |

When a setting can be given more than one way, they combine like this. Hosts,
paths, forwarded names and ports **add up** across all three, so the dot-file's
grants and your shell's grants are a union. The network mode and the conda
settings are **taken over** by the environment variable when it is set, and the
engine says so. Nothing in a `.agent-sandbox` applies until `--trust` approves
it.

Four more variables name locations rather than behaviour and are rarely set by
hand: `AGENT_SANDBOX_PROXY_CA`, `AGENT_SANDBOX_PROFILE_DIR`,
`AGENT_SANDBOX_SESSION_BASE` and `AGENT_SANDBOX_SECCOMP_DIR`. `--engine-help`
prints each with its default.

Engine flags go before the agent's own arguments. `agent-sandbox --help` lists
them; with a profile, `<agent> --engine-help` shows the same, and
`<agent> --help` ends with a footer pointing at it. The per-project file has a
commented template in
[docs/agent-sandbox.example](docs/agent-sandbox.example).

## Documentation

- [docs/design.md](docs/design.md): architecture, threat model, every
  guarantee with its mechanism and check, residual risks, open questions.
- [docs/network.md](docs/network.md): network modes, the allowlist,
  `--allow`, the CA, the proxy.
- [docs/config.md](docs/config.md): the per-project `.agent-sandbox` file, its
  trust gate, and per-project memory scoping.
- [docs/ssh.md](docs/ssh.md): the SSH broker.
- [docs/recipes.md](docs/recipes.md): ordinary tools from inside the sandbox — git, `gh`,
  package installs, ports, editors — and how to tell what is blocking you.
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
