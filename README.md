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
asb --account work claude        # on another login, a second subscription (asb --account-login)
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
([profiles.md](docs/profiles.md)). Two profiles ship: `claude`, and `sshd`, a
sandboxed ssh login for other machines (`asb --profile sshd --role NAME`, #335;
[sshd.md](docs/sshd.md)). MCP
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
standard-library helper). The proxy runtime needs neither conda nor `python3-venv`: the
installer builds it with a micromamba it fetches itself. On Ubuntu 24.04+ the installer needs `sudo` once, to install an
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

The installer is idempotent: it installs agent-sandbox's own
**micromamba** (a pinned release, checked against its SHA-256, at
`~/.local/share/agent-sandbox/micromamba/bin/micromamba`, with an empty conda root for
its environments at `~/.local/share/agent-sandbox/conda`), sets up the proxy with it
(mitmproxy 12+ in a private conda-forge environment,
`~/.local/share/agent-sandbox/proxy-env`; a working one an earlier run made is kept),
generates the CA, writes
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

Inside a sandbox a tool like `gh` would be the host's `/usr/bin` one, which a
distribution can leave far behind (Ubuntu ships gh 2.46, without `gh pr checks --json`).
So the installer also builds a small **tools environment** from conda-forge with that
micromamba, at `~/.local/share/agent-sandbox/tools`, and **rebuilds it at every run**, so
re-running `./install.sh` is how the tools are updated. What it holds is yours to say:
`~/.config/agent-sandbox/tools.txt`, one conda package spec per line (`#` comments), and
`gh` and `tmux` when there is no such file. Beside them it always holds `gpg` (conda-forge's
`gnupg`), which agent-sandbox itself runs on the host for `asb --install` and which no
sandbox has on its PATH unless you list it; so a file listing none leaves an environment
with none of your tools. Every
sandbox gets it read-only, its commands on PATH after the conda env and your own
directories and before `/usr/bin` and the other system directories: a project that has
its own `gh` keeps it, and otherwise conda-forge's beats the distribution's. Only the
listed packages' own commands are on PATH, not their dependencies' (a tool that pulls in
Python does not put a `python3` ahead of the system one). A failed update warns and
keeps the previous environment; until one has been built, sandboxes are unchanged.
It applies under every preset, `--preset native` included.

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
| `--agent-port [ADDR:]PORT` | `AGENT_SANDBOX_AGENT_PORTS` | `[net] agent-port` | `strict` only: agent ports published on the host's loopback, or at ADDR (an IPv4 address of the host, `0.0.0.0` = every one: reachable from the network); `none` closes the direction (none) ([network.md](docs/network.md)) |
| — | `AGENT_SANDBOX_FORWARD` | `[env]` | extra environment variables to forward, by name, space-separated (only the built-in set: locale, proxy, CA, CUDA); under the `sshd` profile a project's `NAME = VALUE` also sets one (#335) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_CONDA_WRITE` | `[conda] write` | `1` makes the active conda env writable; its base install and other envs stay read-only (read-only) |
| — | `AGENT_SANDBOX_CONDA_PKGS` | `[conda] pkgs` | the sandbox-owned package cache conda downloads into, persistent; a relative path is the project's, like `[conda] prefix` (`~/.cache/agent-sandbox/conda-pkgs`) |
| — | `AGENT_SANDBOX_CONDA_BASE` | `[conda] base` | whose conda the sandbox gets: `host` (yours, passed through) or `sandbox` (agent-sandbox's own `micromamba` and its conda root; none of the host's conda is bound) (`~/.config/agent-sandbox/conda`, which `install.sh` asks; else `host` where the host has conda) ([config.md](docs/config.md)) |
| — | — | `[conda] name` | run in this conda env instead of the shell's active one (the active one) ([config.md](docs/config.md)) |
| — | — | `[conda] prefix` | the same for an env given by its path, such as a clone in a role's tree; `name` and `prefix` are one setting, the later wins (none) ([config.md](docs/config.md)) |
| — | — | `[share-memory]` | which other projects' agent memory this session may read, read-only: paths, `~/dir/*` wildcards, or `all` for every project's state. Sugar for `[connect]`: by default a role sees only its own project, and its memory is its own under `isolated` and `inherit` (#196) ([config.md](docs/config.md#memory-scoping)) |
| — | `AGENT_SANDBOX_GPU` | `[gpu] mode` | the host's GPUs in the sandbox: their device nodes (`/dev/nvidia*`, `/dev/kfd`, `/dev/dri`) and `/sys` read-only for the driver's library; `off` keeps them out; per role with `[gpu:<role>]` (on) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_GPU_DEVICES` | `[gpu] devices` | which device nodes are the GPUs', as paths or globs under `/dev/`, space-separated; replaces the default list, so one card for CUDA is `/dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidiaN`; per role with `[gpu:<role>]`; a node the host lacks is said and skipped (`/dev/nvidia* /dev/kfd /dev/dri`) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_SECCOMP` | `[seccomp] mode` | default-deny syscall filter, compiled per machine by `install.sh`; `off` disables it (on) ([seccomp](components/seccomp/README.md)) |
| — | — | `[permissions]` | agent permission rules a session gets without asking, one per line in the agent's own syntax (claude: its settings' `permissions.allow`, e.g. `Bash(git push:*)`, `Read`); per role with `[permissions:ROLE]`, a union; a widening the review names, and `--check` lists; handed over with the briefing, so not with `[briefing] mode = off` (none) ([config.md](docs/config.md)) |
| — | — | `[claude] hide` | extra paths under `~/.claude` to blank inside, space separated; `daemon/` is hidden already ([config.md](docs/config.md)) |
| — | — | `[claude] state-background` | `on` tints the terminal's background with the session's state, as the status line shows it: working or running, needs you or asks you, and your own background while it waits or is idle; written over Claude Code's own stdout from its hooks, reset at exit; with the briefing (off) ([config.md](docs/config.md)) |
| — | — | `[sshd] authorized-keys` | the `sshd` profile's keys file: the public keys that may log in to the role's sshd, an absolute path outside the project, copied at each launch; required, and the profile also needs `[net] mode = strict` and exactly one `agent-port` (#335) ([config.md](docs/config.md)) |
| — | — | `[remote:<alias>]` | a sandboxed login on another host, the `sshd` profile run there by an account, reached by the roles as the SSH host `<alias>`: `host` (an ssh destination, required), `account` (an adduser name; the ssh user), `port` (an `--agent-port` token, required), `scratch` (absolute or under `~`), `gpu` (as `[gpu] devices`), `allow`, `env` (`NAME=VALUE`); reviewed and listed by `--check`; `asb --setup-remote ALIAS` sets it up (#344) (none) ([remote.md](docs/remote.md)) |
| — | — | `[channel:<name>]` | a **profile's own dot-file** only (`profiles/<name>/agent-sandbox`): one section per channel, a path per line under `{base}` (the profile's base, which `[agent] base-env` -- claude: `CLAUDE_CONFIG_DIR` -- can move), a trailing `/` for a directory, and per path `outside:`, `filter:`, `vendor:` or `start:` (a template file the store starts as, under `{profile}`, the profile's directory). In a project's file it is warned of at the review and ignored ([profiles.md](docs/profiles.md#the-profiles-dot-file)) |
| — | — | `[preset:<name>]` | a **profile's own dot-file** only: a preset's rungs (`isolated`, `inherit` or `shared`), in the `[connect]` grammar, for the channels where they are not the ladder's. A project picks a preset with `[sandbox] preset` and moves a channel with `[connect]`; a `[preset:...]` in a project's file is warned of at the review and ignored ([profiles.md](docs/profiles.md#the-profiles-dot-file)) |
| — | — | `[agent] command` | `command = AGENT [ARGS]`: a role's agent and the native arguments always passed to it, words split at blanks; per role with `[agent:<glob>]`, which beats `[agent]`; the review says each line, for which roles, and whether AGENT names an installed profile, and `--check` lists the role's lines; a launch with no command runs it, its fixed arguments first (#355). The profile name `agent` is reserved (none) ([config.md](docs/config.md#roles)) |
| — | — | `[agent] account` | `account = NAME`: the role's account (#355), a directory of the agent's, `~/.local/state/agent-sandbox/<agent>/accounts/NAME/`, holding its login, which is bound where the agent's base is (claude: `~/.claude`) in place of the base, the channels on top; per role with `[agent:<glob>]`, which beats `[agent]`; `-` is the base (your own login), over a weaker line's account. A launch is refused while the directory is missing (`asb --account-login NAME AGENT`), and under `--preset native` or `none`. An account role sees the base's other top-level entries, bound one by one, never its login (the base) ([config.md](docs/config.md#accounts)) |
| — | — | `[serve] watch`, `[serve] prompt` | what `--serve` waits on (a file in the project, an inbox) and what each turn is told (a file in the project, its text); per role with `[serve:ROLE]`, both required; the review says what the loop will wait on and read (none) ([config.md](docs/config.md)) |
| — | `AGENT_SANDBOX_BRIEFING` | `[briefing] mode` | tell the session what its sandbox allows, what is blocked and how to ask for more (on) ([config.md](docs/config.md)) |
| — | — | `[briefing] file` | the purpose file a role is briefed from, `{role}` its name; in `[briefing:<glob>]` for those roles, whose default is `.asb/roles/{role}.md` (none) ([config.md](docs/config.md)) |
| — | — | `[briefing] start` | a file in the project whose text the session runs as its first turn at every interactive start, `{role}` its name, so a resumed role acts without a keypress; in `[briefing:<glob>]` for those roles; not under `--serve`, `--exec` or a verb; a missing file refuses the launch (none) ([config.md](docs/config.md)) |
| `--role NAME` | `AGENT_SANDBOX_ROLE` | `[sandbox] role` | which role of this project to run: a named, persistent instance with its own state, under the policy the dot-file's role-suffixed sections (`[connect:<glob>]` and the like) give the names they match (`default`) ([config.md](docs/config.md#roles)) |
| `--roles ROLE...` | — | — | one tmux session with a pane per role (#317, #320), five to a window: `asb --roles supervisor planner-1 implementer-1 reviewer-1 gate --resume` is one window, the first role in the top pane, full width and half the height, and the other four in a row below; a sixth role starts the next window, laid out the same way. A window is named by its first role and a pane's border shows its role; each pane starts in the project directory and runs `asb --role ROLE` with the line's engine words; the roles end at the first word that starts with `-`. It takes no command (#355): each pane runs its role's agent, `[agent:<glob>]` or `[agent]` command, and gets `--agent AGENT` only when the line named that role's (`--agent b=codex` in b's pane alone, a bare `--agent X` in every pane); every role's agent is resolved before tmux is called, and a role with none, with an agent not installed, or under `--resume` with a profile that cannot resume, is refused by name and nothing opens. A word after the roles that names a profile, and a command or agent arguments after the engine words, are refused. The session is named after the project directory, and one of that name already open is refused, naming `tmux attach -t NAME` and `tmux kill-session -t NAME`. The dot-file review runs once, here, before the panes open; then it attaches with the first window's top pane active, or, not at a terminal, prints the attach command. A pane whose launch ends drops to a shell. Beside the session, one host process takes the Supervisor's reset markers: for `.asb/coord/to/ROLE.reset` it types the role's fresh start (its agent's profile's `[agent] clear`; claude: `/clear`) and Enter in that role's pane and removes the marker, and it ends with the session (#329); a role whose profile has no `clear` is not watched, and named. Its log is `~/.local/state/agent-sandbox/.roles-resets/<project slug>.log`. tmux is the host's, else the tools env's (`install.sh` installs it). Refused with `--role`, `--profile`, a verb, `--exec`, a review, and inside a sandbox ([roles.md](docs/roles.md#9-one-round-terminal-by-terminal)) |
| `--agent AGENT` | — | `[agent] command` | the role's agent for this launch (#355): `--agent AGENT` every launched role's, `--agent ROLE=AGENT` or `--agent 'GLOB=AGENT'` one role's, repeatable; an exact name beats a glob, which beats a bare one. It replaces the dot-file's whole command, and a launch with no command runs it as if typed (`asb --role r --agent claude --resume` runs `claude --continue`). With `--roles`, a pane gets `--agent AGENT` only for its own role. Refused with a command, with two forms that disagree for a role, with a role or glob that matches no launched role (with `--roles`: none of the listed roles), and with `--exec`, `--list`, `--init` or a review but `--check`. With no agent on the line or in the file, a launch with no command is refused, naming both places (none) ([config.md](docs/config.md#roles)) |
| `--account NAME` | — | `[agent] account` | the role's account for this launch (#355): `--account NAME` every launched role's, `--account ROLE=NAME` or `--account 'GLOB=NAME'` one role's, repeatable, with `--agent`'s precedence and refusals; it beats the dot-file's lines, and `--account -` runs the role on the base whatever the file says. Resolved under the role's agent: claude's `work` is `~/.local/state/agent-sandbox/claude/accounts/work/`, bound at `~/.claude`. `--exec` counts. With `--roles`, a pane gets `--account NAME` only for its own role. Refused when the directory is missing (`asb --account-login NAME AGENT`), a symlink or not a directory, for a profile with no `[agent] account-paths`, under `--preset native` or `none`, with `--list`, `--init` or a review but `--check`, and on a join into a role running on another account (the base) ([config.md](docs/config.md#accounts)) |
| `--account-login NAME AGENT` | — | — | log the account NAME of AGENT in (#355), alone on the line, at your own shell: makes `~/.local/state/agent-sandbox/AGENT/accounts/NAME/` (mode 700; an existing directory is a re-login) and runs the agent's own login there, in the foreground -- the profile's `[agent] login`, claude: `claude auth login` -- sandboxed, as the role `account-login` of the scratch project `~/.cache/agent-sandbox/account-login/` (no dot-file, so no project's policy applies; never listed by `--list`) under `--preset isolated` and the default network mode; the shell's `AGENT_SANDBOX_NET` and `AGENT_SANDBOX_CONNECT` do not apply to it. Then it removes that role's stores (Ctrl-C included; a killed run's are removed by the next) and says whether the account has its login file (claude: `.credentials.json`), by its path. Exit: the login's status when it failed, 1 with no login file, else 0. Refused for a bad NAME, an AGENT naming no profile, a profile with no `[agent] account-paths` or `login`, a symlink or a non-directory there, and inside a sandbox ([config.md](docs/config.md#accounts)) |
| `--install AGENT[@VERSION] [--from FILE]` | — | — | install AGENT for asb (#6), alone on the line, at your own shell: VERSION -- default the profile's pin, and only a version in its `versions` table -- is named by the profile's `resolve.sh` (claude: from the vendor's GPG-signed manifest), downloaded with `curl` (or taken from FILE), refused unless its size and SHA-256 are the ones stated, a tarball's members checked, and renamed into `~/.local/state/agent-sandbox/AGENT/install/VERSION/`; `install/current` then names it, the version launches will run. A version already there is not downloaded again. A failure leaves nothing. Exit 2 for a refusal (a version not in the table, no recipe, inside a sandbox), 1 for a failure ([profiles.md](docs/profiles.md#asb---install-agentversion---from-file)) |
| `--resume` | — | — | resume the agent's last session (#355): the engine's flag, which the profile translates (`[agent] resume` in its own dot-file; claude: `resume = --continue`) and puts after the agent's own arguments and before a `[briefing] start` text, so `asb --role R --resume claude --model x` runs `claude --model x --continue`; with `--roles` every pane takes it. After the command it is the agent's: `asb claude --resume ID` is Claude Code's own. Refused under a profile with no resume words, and with `--serve`, `--exec`, a verb or a review (off) ([profiles.md](docs/profiles.md)) |
| `--preset NAME` | `AGENT_SANDBOX_PRESET` | `[sandbox] preset` | where every channel sits before any `[connect]` override: `isolated`, `inherit` (read your files live, keep the sandbox's writes to itself) or `shared` (one directory, both ways -- the engine before 0.3) (inherit). Two more are the flag only: `native` -- parity with `none`, so that a difference is a bug -- and `none`, no sandbox at all ([connections.md](docs/connections.md)) |
| `--overlay MODE` | `AGENT_SANDBOX_OVERLAY` | `[overlay] mode` | `auto` or `off`: what `copy-on-write` is implemented with, an overlay where bubblewrap supports one or the copy fallback everywhere; it can only move `copy-on-write` to `copy` (auto) ([connections.md](docs/connections.md)) |
| `--reset NAME` | — | — | discard what this role holds at channel NAME, or at a declared path (`--reset ./scratch/`), and take the source's version again (yours, or for an `own` store the profile's start), then exit; no command needed when one installed profile has its command on PATH (`asb --role R --reset config`); what a conflict warning points at ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--status` | — | — | show this role's running sandbox -- since when, under which dot-file, its account with its directory and the login's expiry date (valid until, due, expired, with what renews it; #355), whether its proxy CA still holds, what runs in it, the background daemon's sessions -- or, when it is not running, where its stores are ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--list [WORD]` | — | — | the role sessions of this project you can resume (#314): per role, running or stopped, created, last active, its agent and account (`claude, account work` or `claude, base`; with `, login due in N days` within 7 days of the login's expiry, `, login expired: asb --account-login NAME AGENT` past it -- `run /login` for the base; #355), and a one-line summary -- the role's own line when there is one, else the conversation's recorded title, else its first prompt -- then one line with the `asb --role ROLE --resume` that resumes one (`--agent WORD` added where the line named the agent); role names cyan on a terminal; WORD keeps the roles whose name, summary or conversations mention it; `--role` is ignored, and a command word is accepted and ignored, as for the other verbs (`asb --list cuda claude`) ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--list-all [WORD]` | — | — | the same for every project, one block each, newest activity first, ending with `cd PROJECT_DIR && asb --role ROLE --resume`; works from any directory; a role `--summarize` described has a third line, `description: PATH` (`--list` shows the description itself: its first 5 non-blank lines, then `full description: PATH` when there is more); project lines bold on a terminal ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--summarize` | — | — | for a stopped role (#314): one headless turn in its sandbox, under its policy, as a `--serve` turn runs (a print run with a fresh session id and the agent's permission prompts off), reads its conversations, memory and files and writes its summary line and a description, `<store>/summary/description.md`; prints both, and deletes the turn's own transcript afterwards, so continuing the role resumes its own conversation. One model call; refused while the role runs (naming `--shutdown`), when it has no conversation, and under `--preset native` ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--delete` | — | — | remove every store of this role; refused while anything runs in it, naming `--shutdown` ([connections.md](docs/connections.md#the-role-verbs-126)) |
| `--connect SPEC` | `AGENT_SANDBOX_CONNECT` | `[connect]` | per-channel `channel = mode [source] [scope]`: how much of your native install this project's sandbox sees, on the scale `own < seed-only < copy < copy-on-write < read-only < read-write`; a key with a `/` is a path instead (`./scratch/ = own`, or `./cfg = read-only outside:~/cfg`); `;`-separated in the variable (the preset decides where each channel starts) ([connections.md](docs/connections.md)) |
| `--ssh HOST` | — | `[ssh]` | reach HOST over SSH through a per-session agent constrained to it; the key never enters the sandbox; the file's hosts (per role with `[ssh:ROLE]`) and the flag's are one list; `[net] git` and `retrieve-only` do not reach into it, so a push over SSH to a listed host is the remote's to limit (no SSH) ([ssh.md](docs/ssh.md)) |
| `--ssh-unrestricted` | — | — | any host the key is trusted by; refused in `strict`, which must pin named hosts (off) ([ssh.md](docs/ssh.md)) |
| `--ssh-key PATH` | — | — | which private key to load (the first readable one under `~/.ssh`) ([ssh.md](docs/ssh.md)) |
| `--ssh-timeout LIFE` | — | — | how long that key stays loaded, e.g. `30m` (no expiry) ([ssh.md](docs/ssh.md)) |
| `--trust` | — | — | review and approve this project's `.agent-sandbox` without launching; a launch at a terminal runs the same review itself, and without one a new, changed or missing file refuses the launch ([config.md](docs/config.md#trust)) |
| `--apply '[SECTION]' LINE...` | — | — | add the lines to that section of this project's `.agent-sandbox` (creating the file or the section), then the `--trust` review of the result; lines already there are left alone; host only. What a blocked session prints for you to run ([config.md](docs/config.md#trust)) |
| `--setup-remote ALIAS` | — | — | set up the sandboxed login this project's `[remote:ALIAS]` describes, or, as `--setup-remote [ACCOUNT@]HOST[:SSHPORT] [--port [ADDR:]PORT]`, `[remote:ACCOUNT-HOST]` (appended through the `--apply` review when the file has none; port 2222 unless the destination form names another): a read-only preflight of the host over ssh as you; where root is needed there, the admin's script copied to your home there and the one line that runs it (exit 1; asb never runs it, nor sudo); else, as the account, asb installed there from this checkout, the login's policy written, approved and launched, and here the alias `ALIAS` in `~/.ssh/config`, its host key and the key `~/.ssh/asb-ALIAS`, then checks through it. Run again: the update, or the relaunch after a reboot. `--setup-remote ALIAS --status` and `--setup-remote ALIAS --shutdown` ask after that login and end it, as the account (its own `asb --status`/`--shutdown` in the scratch; `--shutdown` removes nothing, and `--setup-remote ALIAS` starts it again). Host only, the file approved first (#344) ([remote.md](docs/remote.md)) |
| `--init MODEL [ROLE=N ...] [--env NAME \| --shared-env NAME]` | — | — | write this project's `.agent-sandbox`, `.asb/`, the roles' purpose files and clones from a development model in `models/` (`roles`: Planners, Implementers, Reviewers, a Supervisor that coordinates, a Gate that publishes, and a setup role that builds the environment; `github`: a setup role that builds the environment, then review, triage and fix per pull request or issue; `market`: research for a purchase or a tender, per topic); with --shared-env, another project's environment: read-only for every role, never cloned or built here, a copy-on-write layer over it for the roles that install, its editable sources declared; appends to an existing file -- models compose in one, their role names apart -- and run again it adds what is missing, and names the lines the model gained that an existing section lacks, or a common section it is missing (written only with a new file), with the `--apply` line for each; approves nothing ([roles.md](docs/roles.md)) |
| `--check` | — | — | the same review, asking nothing and recording nothing, then what the file means for the profile named, else for each available one (installed, its command on PATH); non-zero exit when a launch of any of them would refuse the file, so CI or a pre-commit hook can run it ([config.md](docs/config.md#trust)) |
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

Ten more variables name locations rather than behaviour and are rarely set by
hand: `AGENT_SANDBOX_PROXY_CA`, `AGENT_SANDBOX_PROXY_PORT` (the proxy's port on
127.0.0.1; `install.sh` records its choice, 8888 or another account's next free
one, in `~/.config/agent-sandbox/proxy-port`), `AGENT_SANDBOX_MITMDUMP` (the mitmdump
a self-contained profile, `sshd`, runs as its proxy of its own; `install.sh`'s by
default), `AGENT_SANDBOX_PROFILE_DIR`,
`AGENT_SANDBOX_HOME` (where `install.sh` put micromamba and its conda root),
`AGENT_SANDBOX_MODELS_DIR` (the development models `--init` reads),
`AGENT_SANDBOX_SESSION_BASE`, `AGENT_SANDBOX_SECCOMP_DIR`,
`AGENT_SANDBOX_CONNECT_SYNC` (the `copy` mode's sync helper) and
`AGENT_SANDBOX_JOIN` (the helper that joins an app into its role's running
launch), the last three normally found beside the engine. One more is timing:
`AGENT_SANDBOX_KEEPER_GRACE`, how many seconds a role's launch waits once nothing
is joined into it before it ends (2), so that commands run one after another
share it. `--engine-help` prints each with its default. And two are the test
suite's: `AGENT_SANDBOX_TEST_PYTHON`, the command the engine runs those two
helpers with instead of `python3`, which the coverage stages point at coverage.py, and
`AGENT_SANDBOX_INSTALL_BASE`, the source `asb --install` has the profile's resolver read
in place of the vendor's (the SHA-256 still enforced).
`AGENT_SANDBOX_TEST_PROBE_ROOT` and `AGENT_SANDBOX_TEST_PROBE_NET` are read by
`--setup-remote`'s probe where it runs, on the remote host: a throwaway root for the
paths it reads and the hosts it tries, which the unit tests set and nothing else does.
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
- [docs/sshd.md](docs/sshd.md): the `sshd` profile, a sandboxed ssh login to this
  account for other machines: the policy, the recipe on a shared host and a cloud
  instance, the roles' side.
- [docs/remote.md](docs/remote.md): `asb --setup-remote`, that login set up on another
  host from one `[remote:ALIAS]` section, and how roles reach it.
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
