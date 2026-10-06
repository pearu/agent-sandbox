# Recipes: ordinary tools from inside the sandbox

Most things that "don't work in the sandbox" are one of five boundary
crossings. Once you can name which one you are hitting, the fix is short — and
the same five explain tools that are not listed here.

| Crossing | What it means | Knob |
|---|---|---|
| **Egress** | a host must be reachable through the proxy | `[allow]`, the global allowlist |
| **Credentials** | a secret must cross — or deliberately must not | `[env]`, `--ssh` |
| **Loopback** | something outside must reach in, or inside must reach out | `--host-port`, `--agent-port` (strict only) |
| **Paths** | a directory outside the project must be visible | path declarations under `[connect]` |
| **Host config** | identity and settings from your home are not there | set it per project |

Anything under `[…]` goes in the project's `.agent-sandbox` and takes effect
only after `asb --trust` ([config.md](config.md)).

## First: find out what is actually blocking you

Three places answer it, in order of speed:

1. **The launch messages.** The engine says which mode it is in and what the
   dot-file gave it.
2. **`/run/agent-sandbox/briefing.md`**, inside the sandbox. It lists the egress
   mode, the hosts added for this session, writable paths, readable projects,
   SSH hosts and the syscall filter — the policy actually in force, written at
   launch. The agent gets a summary of it automatically.
3. **`~/.config/agent-sandbox/blocked.log`**, on the host. Every refused request
   with its host, so `tail -f` it while the thing fails. A refusal through the
   proxy also answers with a 403 that names the host and the line to add.

A blocked host is deliberate. Retrying, or reaching for another tool, cannot get
past it — the point is to decide whether to open it.

## git push and pull

**Crossing: credentials.** Your SSH key deliberately never enters the sandbox.
Instead a per-session agent on the host holds it, constrained to the hosts you
name:

```
asb --ssh github.com claude
```

Inside, `~/.ssh` contains only `config` and `known_hosts` — no key material —
and `SSH_AUTH_SOCK` points at a session socket. The agent can *use* the key for
the hosts you allowed and cannot read it or use it anywhere else. See
[ssh.md](ssh.md).

In `strict` mode `--ssh HOST` also opens the firewall to that host's addresses
and makes its name resolve, since there is otherwise no DNS and no route.

## git commit says "Author identity unknown"

**Crossing: host config.** `~/.gitconfig` is not bound into the sandbox, so
your global identity is not there. Set it per repository, from a host shell:

```
git -C ~/path/to/project config user.name  "Your Name"
git -C ~/path/to/project config user.email "you@example.com"
```

It lands in `.git/config`, which *is* inside the project, so the sandboxed agent
can commit. The engine prints these commands when it detects the situation.

## gh, and anything using the GitHub API

**Crossing: credentials.** `gh` authenticates over HTTPS, so the SSH broker does
not help it, and `~/.config/gh` is not bound. Forward a token:

```ini
[env]
GH_TOKEN
```

with `GH_TOKEN` exported in the shell you launch from — the engine forwards
names, not values, and silently skips names that are unset.

**What you accept:** a forwarded token is readable by the agent, like any
environment variable. That is a real cost and the reason this is not the
default. If you would rather not, run `gh` yourself on the host; only the
outward calls need you.

**Or your gh login, asked for per project:** log in on the host as usual
(`gh auth login`), and give it to the project's sessions:

```ini
[connect]
gh = read-only
```

`gh` inside is then logged in as you, read-only: your `~/.config/gh`, live, so a login
made on the host while a session runs is seen at once. Without the line a sandbox gets
an empty `~/.config/gh` of its own and `gh` is logged out. The same cost applies: the
token is readable inside.

**A token that cannot write.** A gh token that reads issues can write them too, and
nothing but the network decides which it does. A **fine-grained personal access
token** with read-only permissions (metadata, contents, issues, pull requests),
limited to the repositories you work on, bounds that wherever the token ends up,
because GitHub enforces it. Keep it in a gh directory of its own:

    GH_CONFIG_DIR=~/.gh-read gh auth login --with-token < the-token

and give it to the roles that only read, keeping your own login for the one that
publishes:

```ini
[connect]
gh = read-only outside:~/.gh-read
[connect:supervisor]
gh = read-only
```

`asb --check --role NAME` shows which login each role's `gh` is. When the token
expires, log in again.

## pip, npm, conda, and other package installs

**Crossing: egress.** The starter allowlist covers the usual indexes —
`pypi.org`, `files.pythonhosted.org`, `registry.npmjs.org`,
`conda.anaconda.org`, `repo.anaconda.com`, `crates.io` and the GitHub hosts. A
package that pulls from somewhere else fails, and `blocked.log` names it.

For one session:

```
asb --allow files.example.com claude
```

For the project, in `.agent-sandbox`:

```ini
[allow]
files.example.com
.internal.example.com      # a leading dot covers subdomains
```

For every project, add the line to `~/.config/agent-sandbox/allowlist.txt`,
which is re-read per request — no restart.

The allowlist opens **public** hosts. A host that resolves to a non-public
address — loopback, a private/LAN range, or link-local (incl. cloud metadata
`169.254.169.254`) — is refused (`502`) even when it is on the list; the proxy
runs on the host and never dials those. For a host-local service, cross via
`--host-port` in `strict` mode (below), not the allowlist.

## A dev server you want to open in a browser

**Crossing: loopback.** In `proxy` mode the sandbox shares the host's network
namespace, so a server on `127.0.0.1:8000` inside is reachable from your browser
with no configuration.

In `strict` mode the sandbox has its own namespace and nothing crosses unless
you say so:

```ini
[net]
mode = strict
agent-port = 8000
```

`agent-port` publishes a port the agent listens on at the host's
`127.0.0.1:8000`. The mirror image is `host-port`, for a database or a local
model server running on the host that the agent must reach. Both are TCP,
1024–65535, loopback only, and may repeat. See
[network.md](network.md#strict-mode-opening-ports).

## Files outside the project

**Crossing: paths.** Only the current project is writable. To see more:

```ini
[connect]
~/datasets/corpus = read-only
~/scratch/build-cache/ = read-write
```

A key with a `/` is a path: the path inside the sandbox, with the same path outside
as its source. Refused regardless: secret stores (`~/.ssh`, `~/.aws`, …), the
sandbox's own configuration, `$HOME` itself and any parent of it. A monorepo sibling
is a `read-only` declaration; a shared build cache a `read-write` one — or `own`, if
the sandbox should build a cache of its own there.

## A specific conda environment

**Crossing: host config.** By default the sandbox uses the environment active in
the launching shell, read-only. To pin one:

```ini
[conda]
name = myproject
```

Its `bin/` replaces the active environment's on `PATH` inside, so `CONDA_PREFIX`
and `PATH` agree. `write = 1` makes that environment writable if the agent needs
to install into it; the base install and every other environment stay read-only.

## Editors and IDEs

**Crossing: none — only what you start with `asb` is sandboxed.**

- **`asb claude` in a terminal inside your editor is sandboxed.** It is an
  ordinary shell. This is the supported way to use an agent from an editor.
- **Anything else the editor starts is native.** The VS Code extension ships its
  own copy of Claude Code (`resources/native-binary/claude`) and runs that
  directly, and nothing shadows `claude` (#151), so an integration that runs
  `claude` from your PATH is native too. Nothing of agent-sandbox applies to those
  sessions.

To see which you have, with a session running, from a host terminal:

```
./probes/whats-running.sh
```

It lists every agent process and whether a `bwrap` ancestor stands between it
and its session leader. `sandboxed=no` means no limits apply to that process,
whatever is configured.

If you set any agent-related editor setting, put it in **User** settings rather
than Workspace settings: a workspace `.vscode/settings.json` lives inside the
project, where a sandboxed agent can edit it.

There is also `CLAUDE_CODE_PROCESS_WRAPPER`, which Claude Code honours when
spawning its own processes. agent-sandbox does not use it: it is a boundary the
agent's own binary chooses to respect, which cannot be verified from outside,
and this project's claim is that limits are enforced around the agent rather
than honoured by it.

## When you need something that is blocked

You cannot widen the sandbox from inside — `.agent-sandbox` is trust-gated
precisely so an agent cannot grant itself access, and the trust store is never
bound in. The agent's part is to stop and tell you what it needs, what for, and
the exact lines; yours is to decide, add them, and re-run `asb --trust`.

One clear request costs less than twenty attempts to work around you.
