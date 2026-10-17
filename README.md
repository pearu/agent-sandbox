# agent-sandbox

[![CI](https://github.com/pearu/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/pearu/agent-sandbox/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/pearu/agent-sandbox/graph/badge.svg)](https://codecov.io/gh/pearu/agent-sandbox)

Run an AI coding agent inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox: a default-deny filesystem, an egress allowlist the agent cannot
bypass with its normal HTTP clients, and an opt-in
SSH broker whose keys never enter the sandbox. One bash script and a
per-agent profile; no image to build. The flagship profile runs
[Claude Code](https://docs.anthropic.com/claude-code). You ask for the sandbox
by name — `asb`, short for `agent-sandbox` — and `claude` alone stays Claude
Code itself, however you installed it.

```
cd ~/projects/thing
asb claude                       # sandboxed: this directory read-write, little else
asb --ssh github.com claude      # + git push through a per-session, host-constrained ssh-agent
asb --allow pypi.org claude      # + one more host through the egress proxy, this session only
asb --role reviewer claude -r    # another role of this project, resuming one of its sessions
claude                           # Claude Code itself, not sandboxed
```

The sandbox's options come before the command, the agent's after it:
`asb [OPTIONS] CMD [AGENT OPTIONS]`. `CMD` is a name on your PATH or a path to
the binary (`asb --profile claude /path/to/2.1.284`).

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
  current project directory (read-write unless `project = read-only`), the active conda env (read-only
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
- **Updates**: `claude update` is Claude Code's own updater, untouched; the
  sandbox runs whatever `claude` is next time.

What it does **not** do is spelled out in [docs/design.md](docs/design.md):
in the default `proxy` mode the sandbox shares the host network namespace, so a
tool that ignores `HTTPS_PROXY` is unfiltered (`AGENT_SANDBOX_NET=strict` closes
that: its own namespace, only the proxy reachable); `~/.claude` is bound
read-write, so the agent's own credentials are readable and so is anything else
you keep there -- `[claude] hide` blanks what you would rather it did not see;
a default-deny syscall filter is on by default
(`AGENT_SANDBOX_SECCOMP=off` disables it), but there are no resource limits.

## Scope

agent-sandbox wraps a **local process**. If you launch an agent on your machine,
it can run inside the sandbox; if the agent runs on someone else's machine,
there is nothing here to put a boundary around.

**Covered.** Any agent you start locally with `asb`: the engine is
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

**Only what you start with `asb`.** Nothing shadows `claude`, so anything that
runs it without `asb` — you at a shell, an editor's integration, a hook script —
runs Claude Code natively, exactly as it would with agent-sandbox not installed
(#151). That is deliberate: `claude` means one thing everywhere, and a sandboxed
launch says so on its command line.

Background sessions are sandboxed too, since 0.4: `asb claude --bg` runs inside its
role's sandbox, and so do the daemon it starts, its workers and the management
verbs (`asb claude agents`, `attach`, `logs`, `stop`). The daemon keeps the role
running until `asb --shutdown claude`. See
[design.md](docs/design.md#background-sessions-123).

The **VS Code extension** ships its own copy of Claude Code and runs that, so its
sessions are native; `asb claude` in the editor's terminal is sandboxed. To see
which you have, with a session running:

```
./probes/whats-running.sh    # lists agent processes, sandboxed or not
```

[recipes.md](docs/recipes.md#editors-and-ides) covers what to do about it.

**Single user.** Everything installs into one account and there is no
system-wide mode; the installer refuses to run through `sudo`. See
[Install](#install).

## Install

Requirements: Linux with unprivileged user namespaces, `bubblewrap` (0.12.0 or
newer recommended: the installer warns below it, and
[troubleshooting.md](docs/troubleshooting.md#bubblewrap-older-than-0120-ubuntu-2404-and-2604)
has the recipe for Ubuntu 24.04 and 26.04), `curl`, `git`, `python3` on `PATH` when you
launch (every session is joined into its role's running sandbox by a small
standard-library helper), and either `python3 >= 3.12` with `venv` or conda/mamba
(for the proxy runtime). On Ubuntu 24.04+ the installer needs `sudo` once, to install an
AppArmor profile allowing bwrap to use user namespaces (and, if you use the
strict network mode, one for pasta); nothing else needs root.

```
git clone https://github.com/pearu/agent-sandbox.git
cd agent-sandbox
./install.sh            # or ./install.sh --dry-run to see what it would do
```

On Ubuntu with a bubblewrap older than 0.12.0, `./install.sh --rebuild-bwrap`
builds Ubuntu's own 0.12.0-1 source locally and installs it (`--dry-run` first
prints the plan).

agent-sandbox is a **single-user tool**. Everything it installs belongs to one
account: the proxy is a systemd *user* unit, the allowlist and trust store live
in that account's `~/.config`, and `asb` goes on that account's PATH.
There is no system-wide mode, and the installer refuses to run through `sudo` —
it asks for sudo itself for the one step that needs it, the AppArmor profile.

The installer is idempotent: it sets up the proxy (mitmproxy 12+ in a private
environment under `~/.local/share/agent-sandbox`), installs agent-sandbox's own
**micromamba** (a pinned release, checked against its SHA-256, at
`~/.local/share/agent-sandbox/micromamba/bin/micromamba`, with an empty conda root for
its environments at `~/.local/share/agent-sandbox/conda`), generates the CA, writes
the allowlist (keeping your edits on re-runs), installs the systemd user unit, and **copies the engine and profiles under
`~/.local/share/agent-sandbox`**. Because the command runs from the copy, you
can move or delete this clone afterward; re-run `./install.sh` after pulling to
update.

Conda inside a sandbox is the sandbox's own concern: a host needs no conda, and a broken
host install does not break a role. Where the host has conda, the installer asks once:
*Sandboxes use the host's conda at BASE, or agent-sandbox's own micromamba?
[host/sandbox]*, and keeps the answer in `~/.config/agent-sandbox/conda` (a host
without conda gets `sandbox` without a question; `--yes` answers `host`; a re-run keeps
the file). A project picks per role with `[conda] base`. Under `sandbox` the command
inside is `micromamba` (`micromamba create -p PREFIX ...`), not `conda`.
`--uninstall` removes the micromamba and asks before removing the conda root, where the
environments live (`--yes` keeps it).

It then puts two commands in `~/.local/bin`, both the engine: `agent-sandbox`
and its short name `asb`. It puts nothing at `claude`, and does not need to know
how Claude Code was installed: `asb claude` runs whatever `claude` your PATH
finds, a package's `/usr/bin/claude` as much as the native installer's
`~/.local/bin/claude`.

**Upgrading from an install before 0.4:** those put the engine at
`~/.local/bin/claude` and moved Claude Code's own launcher aside. Running
`./install.sh` again takes that back — your `claude` returns to where it was,
and says so — and from then on `claude` is native and `asb claude` is sandboxed.
Until you do, the old launcher refuses to run and says why.

Undo it with `./install.sh --uninstall`: it removes `asb` and `agent-sandbox`
and the rest ([troubleshooting.md](docs/troubleshooting.md)).
Working *on* agent-sandbox? `./install.sh --dev` points `asb` at the
checkout instead, so your edits take effect at the next launch (see
[docs/design.md](docs/design.md) for why that is dev-only). Standalone:
`curl -fsSL https://raw.githubusercontent.com/pearu/agent-sandbox/main/install.sh | bash`
clones the repository under `~/.local/share/agent-sandbox/src` and installs
the copy from there.

Then open a fresh shell, `cd` into a project, and run `asb claude`.

## Knobs and flags

Each setting is listed with every way to set it; a dash means that form does
not exist. Values and defaults are in the last column.

| Command line | Environment | `.agent-sandbox` | What it does (default) |
|---|---|---|---|
| `--profile NAME` | — | — | which agent profile to run; the command's basename otherwise (`asb claude` is the `claude` profile) ([profiles.md](docs/profiles.md)) |
| `--allow HOST` | — | `[allow]` | extra hosts the agent may reach, on top of the global allowlist; one host per line in the file, and the flag lasts one session (none) ([network.md](docs/network.md)) |
| — | — | `[deny]` | hosts taken out of what the sessions may reach, the global allowlist included; never a host the profile needs (none) ([network.md](docs/network.md)) |
| — | `AGENT_SANDBOX_NET` | `[net] mode` | network mode: `proxy` (default), `strict`, `open`, `none` ([network.md](docs/network.md)) |
| — | — | `[net] git` | `fetch`: a push over HTTPS refused, fetches pass; `refuse`: git's HTTPS transport refused to every host, for the role; SSH is `[ssh]`'s, whatever this says (allow) ([network.md](docs/network.md)) |
| — | — | `[net] hosts` | `public`: every public host, the allowlist not applying to the role -- localhost, the LAN and `[deny]` stay refused (allowlist) ([network.md](docs/network.md)) |
| — | — | `[net] retrieve-only` | `on`: GET and HEAD only (a GraphQL query, not a mutation; git's fetch where `[net] git` allows it, not a push), but to the profile's own hosts -- read, publish nothing (off) ([network.md](docs/network.md)) |
| `--host-port PORT` | `AGENT_SANDBOX_HOST_PORTS` | `[net] host-port` | `strict` only: host loopback ports the sandbox may reach, space-separated in the variable; `none` closes the direction (none) ([network.md](docs/network.md)) |
| `--agent-port PORT` | `AGENT_SANDBOX_AGENT_PORTS` | `[net] agent-port` | `strict` only: agent ports published on the host's loopback; `none` closes the direction (none) ([network.md](docs/network.md)) |
| — | `AGENT_SANDBOX_FORWARD` | `[env]` | extra environment variables to forward, by name, space-separated (only the built-in set: locale, proxy, CA, CUDA) |
| — | `AGENT_SANDBOX_CONDA_WRITE` | `[conda] write` | `1` makes the active conda env writable; its base install and other envs stay read-only (read-only) |
| — | `AGENT_SANDBOX_CONDA_PKGS` | `[conda] pkgs` | the sandbox-owned package cache conda downloads into, persistent; a relative path is the project's, like `[conda] prefix` (`~/.cache/agent-sandbox/conda-pkgs`) |
| — | `AGENT_SANDBOX_CONDA_BASE` | `[conda] base` | whose conda the sandbox gets: `host` (yours, passed through) or `sandbox` (agent-sandbox's own `micromamba` and its conda root; none of the host's conda is bound) (`~/.config/agent-sandbox/conda`, which `install.sh` asks; else `host` where the host has conda) ([config.md](docs/config.md)) |
| — | — | `[conda] name` | run in this conda env instead of the shell's active one (the active one) ([config.md](docs/config.md)) |
| — | — | `[conda] prefix` | the same for an env given by its path, such as a clone in a role's tree; `name` and `prefix` are one setting, the later wins (none) ([config.md](docs/config.md)) |
| — | — | `[share-memory]` | which other projects' agent memory this session may read, read-only: paths, `~/dir/*` wildcards, or `all` for every project's state. Sugar for `[connect]`: by default a role sees only its own project, and its memory is its own under `isolated` and `inherit` (#196) ([config.md](docs/config.md#memory-scoping)) |
| — | `AGENT_SANDBOX_GPU` | `[gpu] mode` | the host's GPUs in the sandbox: their device nodes (`/dev/nvidia*`, `/dev/kfd`, `/dev/dri`) and `/sys` read-only for the driver's library; `off` keeps them out; per role with `[gpu:<role>]` (on) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_SECCOMP` | `[seccomp] mode` | default-deny syscall filter, compiled per machine by `install.sh`; `off` disables it (on) ([seccomp](components/seccomp/README.md)) |
| — | — | `[permissions]` | agent permission rules a session gets without asking, one per line in the agent's own syntax (claude: its settings' `permissions.allow`, e.g. `Bash(git push:*)`, `Read`); per role with `[permissions:ROLE]`, a union; a widening the review names, and `--check` lists; handed over with the briefing, so not with `[briefing] mode = off` (none) ([config.md](docs/config.md)) |
| — | — | `[claude] hide` | extra paths under `~/.claude` to blank inside, space separated; `daemon/` is hidden already ([config.md](docs/config.md)) |
| — | — | `[claude] state-background` | `on` tints the terminal's background with the session's state, as the status line shows it: working, needs you or asks you, and your own background while it waits or is idle; written over Claude Code's own stdout from its hooks, reset at exit; with the briefing (off) ([config.md](docs/config.md)) |
| — | — | `[channel:<name>]` | a **profile's own dot-file** only (`profiles/<name>/agent-sandbox`): one section per channel, a path per line under `{base}` (the profile's base, which `[agent] base-env` -- claude: `CLAUDE_CONFIG_DIR` -- can move), a trailing `/` for a directory, and per path `outside:`, `filter:`, `vendor:` or `start:` (a template file the store starts as, under `{profile}`, the profile's directory). In a project's file it is warned of at the review and ignored ([profiles.md](docs/profiles.md#the-profiles-dot-file)) |
| — | — | `[preset:<name>]` | a **profile's own dot-file** only: a preset's rungs (`isolated`, `inherit` or `shared`), in the `[connect]` grammar, for the channels where they are not the ladder's. A project picks a preset with `[sandbox] preset` and moves a channel with `[connect]`; a `[preset:...]` in a project's file is warned of at the review and ignored ([profiles.md](docs/profiles.md#the-profiles-dot-file)) |
| — | — | `[serve] watch`, `[serve] prompt` | what `--serve` waits on (a file in the project, an inbox) and what each turn is told (a file in the project, its text); per role with `[serve:ROLE]`, both required; the review says what the loop will wait on and read (none) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_BRIEFING` | `[briefing] mode` | tell the session what its sandbox allows, what is blocked and how to ask for more (on) ([config.md](docs/config.md)) |
| — | — | `[briefing] file` | the purpose file a role is briefed from, `{role}` its name; in `[briefing:<glob>]` for those roles, whose default is `.asb/roles/{role}.md` (none) ([config.md](docs/config.md)) |
| — | — | `[briefing] start` | a file in the project whose text the session runs as its first turn at every interactive start, `{role}` its name, so a resumed role acts without a keypress; in `[briefing:<glob>]` for those roles; not under `--serve`, `--exec` or a verb; a missing file refuses the launch (none) ([config.md](docs/config.md)) |
| `--role NAME` | `AGENT_SANDBOX_ROLE` | `[sandbox] role` | which role of this project to run: a named, persistent instance with its own state, under the policy the dot-file's role-suffixed sections (`[connect:<glob>]` and the like) give the names they match (`default`) ([config.md](docs/config.md#roles)) |
| `--preset NAME` | `AGENT_SANDBOX_PRESET` | `[sandbox] preset` | where every channel sits before any `[connect]` override: `isolated`, `inherit` (read your files live, keep the sandbox's writes to itself) or `shared` (one directory, both ways -- the engine before 0.3) (inherit). Two more are the flag only: `native` -- parity with `none`, so that a difference is a bug -- and `none`, no sandbox at all ([connections.md](docs/connections.md)) |
| `--overlay MODE` | `AGENT_SANDBOX_OVERLAY` | `[overlay] mode` | `auto` or `off`: what `copy-on-write` is implemented with, an overlay where bubblewrap supports one or the copy fallback everywhere; it can only move `copy-on-write` to `copy` (auto) ([connections.md](docs/connections.md)) |
| `--reset NAME` | — | — | discard what this role holds at channel NAME, or at a declared path (`--reset ./scratch/`), and take the source's version again (yours, or for an `own` store the profile's start), then exit; no command needed when one profile is installed (`asb --role R --reset config`); what a conflict warning points at ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--status` | — | — | show this role's running sandbox -- since when, under which dot-file, what runs in it, the background daemon's sessions -- or, when it is not running, where its stores are ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--delete` | — | — | remove every store of this role; refused while anything runs in it, naming `--shutdown` ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--connect SPEC` | `AGENT_SANDBOX_CONNECT` | `[connect]` | per-channel `channel = mode [source] [scope]`: how much of your native install this project's sandbox sees, on the scale `own < seed-only < copy < copy-on-write < read-only < read-write`; a key with a `/` is a path instead (`./scratch/ = own`, or `./cfg = read-only outside:~/cfg`); `;`-separated in the variable (the preset decides where each channel starts) ([connections.md](docs/connections.md)) |
| `--ssh HOST` | — | `[ssh]` | reach HOST over SSH through a per-session agent constrained to it; the key never enters the sandbox; the file's hosts (per role with `[ssh:ROLE]`) and the flag's are one list; `[net] git` and `retrieve-only` do not reach into it, so a push over SSH to a listed host is the remote's to limit (no SSH) ([ssh.md](docs/ssh.md)) |
| `--ssh-unrestricted` | — | — | any host the key is trusted by; refused in `strict`, which must pin named hosts (off) ([ssh.md](docs/ssh.md)) |
| `--ssh-key PATH` | — | — | which private key to load (the first readable one under `~/.ssh`) ([ssh.md](docs/ssh.md)) |
| `--ssh-timeout LIFE` | — | — | how long that key stays loaded, e.g. `30m` (no expiry) ([ssh.md](docs/ssh.md)) |
| `--trust` | — | — | review and approve this project's `.agent-sandbox` without launching; a launch at a terminal runs the same review itself, and without one a new, changed or missing file refuses the launch ([config.md](docs/config.md#trust)) |
| `--apply '[SECTION]' LINE...` | — | — | add the lines to that section of this project's `.agent-sandbox` (creating the file or the section), then the `--trust` review of the result; lines already there are left alone; host only. What a blocked session prints for you to run ([config.md](docs/config.md#trust)) |
| `--init MODEL [ROLE=N ...] [--env NAME \| --shared-env NAME]` | — | — | write this project's `.agent-sandbox`, `.asb/`, the roles' purpose files and clones from a development model in `models/` (`roles`: Planners, Implementers, Reviewers, a Supervisor that coordinates, a Gate that publishes, and a setup role that builds the environment; `github`: a setup role that builds the environment, then review, triage and fix per pull request or issue; `market`: research for a purchase or a tender, per topic); with --shared-env, another project's environment: read-only for every role, never cloned or built here, a copy-on-write layer over it for the roles that install, its editable sources declared; appends to an existing file -- models compose in one, their role names apart -- and run again it adds what is missing; approves nothing ([roles.md](docs/roles.md)) |
| `--check` | — | — | the same review, asking nothing and recording nothing; non-zero exit when a launch would refuse the file, so CI or a pre-commit hook can run it ([config.md](docs/config.md#trust)) |
| `--serve` | — | — | a role with no terminal (#277): `asb --role R --serve claude` holds the role's launch on the host and runs one turn of its session (`-p`, named by id, permission mode `bypassPermissions`: its policy is the only boundary) per change to its `[serve:R] watch` file, told the text of `prompt`; the id is kept in `.asb/coord/R/session`. Refused without `--role`, under `--preset native` and without the section; `--status` shows it, `--shutdown` ends it ([config.md](docs/config.md)) |
| `--shutdown` | — | — | end this role's running sandbox: everything joined into it, and a background daemon with its workers; then exit. A later launch starts afresh under the policy then in force ([connections.md](docs/connections.md)) |
| `--verbose` | `AGENT_SANDBOX_VERBOSE` | — | also print the routine status lines a launch prints — which dot-file values were applied, the session allowlist, the seccomp filter in use. Refusals, warnings and notices that something is **not** sandboxed are always printed, verbose or not. What follows from the dot-file's text alone -- a widening (the network `open`, seccomp `off`), a line it ignores, what a path declaration gives -- is said once, at its review ([config.md](docs/config.md#trust)) (off) |
| `--exec CMD [ARGS...]` | — | — | run CMD instead of the agent, in the sandbox this profile would have built: same binds, environment, network, seccomp and state isolation. Everything after `--exec` is the command, so engine flags come first and `--profile` names the sandbox (`asb --allow pypi.org --profile claude --exec bash -l`). The agent binary stays bound read-only, so an agent started from inside runs natively there |
| `--engine-help`, `--version` | — | — | print the engine's own flags, or its version, and exit; after the command, `--version` is the agent's (`asb claude --version`) |

When a setting can be given more than one way, they combine like this. Hosts,
paths, forwarded names and ports **add up** across all three, so the dot-file's
grants and your shell's grants are a union. The network mode and the conda
settings are **taken over** by the environment variable when it is set, and the
engine says so. Nothing in a `.agent-sandbox` applies until you approve it — at
the launch, which shows it and asks, or with `--trust`.

Nine more variables name locations rather than behaviour and are rarely set by
hand: `AGENT_SANDBOX_PROXY_CA`, `AGENT_SANDBOX_PROFILE_DIR`,
`AGENT_SANDBOX_HOME` (where `install.sh` put micromamba and its conda root),
`AGENT_SANDBOX_GPU_DEVICES` (which device nodes are the GPUs', as globs),
`AGENT_SANDBOX_MODELS_DIR` (the development models `--init` reads),
`AGENT_SANDBOX_SESSION_BASE`, `AGENT_SANDBOX_SECCOMP_DIR`,
`AGENT_SANDBOX_CONNECT_SYNC` (the `copy` mode's sync helper) and
`AGENT_SANDBOX_JOIN` (the helper that joins an app into its role's running
launch), the last three normally found beside the engine. One more is timing:
`AGENT_SANDBOX_KEEPER_GRACE`, how many seconds a role's launch waits once nothing
is joined into it before it ends (2), so that commands run one after another
share it. `--engine-help` prints each with its default. And one is the test
suite's: `AGENT_SANDBOX_TEST_PYTHON`, the command the engine runs those two
helpers with instead of `python3`, which the coverage stages point at coverage.py.
`AGENT_SANDBOX_SERVE_TURN` is the `--serve` loop's own, set on each turn it runs, so
the turn, which has its prompt, is not also given the role's `[briefing] start`.

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
  trust gate, and `[share-memory]`.
- [docs/roles.md](docs/roles.md): working on one project with several agents --
  Planners, Implementers, Reviewers, a Supervisor and a Gate, with you deciding: what
  each may do, how the work moves, and `asb --init roles` to set it up.
- [docs/ssh.md](docs/ssh.md): the SSH broker.
- [docs/recipes.md](docs/recipes.md): ordinary tools from inside the sandbox — git, `gh`,
  package installs, ports, editors — and how to tell what is blocking you.
- [docs/profiles.md](docs/profiles.md): the profile contract; adding an agent.
- [docs/connections.md](docs/connections.md): proposed — sandboxes as
  installations, connections between them under an
  `own < seed-only < copy < copy-on-write < read-only < read-write`
  scale; the model for controlling what passes between projects, roles and agents,
  with its experiments planned in
  [docs/connections-study.md](docs/connections-study.md).
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
