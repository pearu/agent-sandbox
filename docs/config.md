# Per-project config and memory scoping

A project can carry a `.agent-sandbox` file that sets policy for sessions run
from that directory: egress hosts, memory scoping, extra paths, forwarded
variables, conda settings and, for the strict network mode, ports.
Because the file lives in a directory the sandboxed agent can write, and a
project may come from a repository you do not control, it is **honored only
after you approve it**. Approval is bound to the file's exact contents, so any
later edit, by you or by the agent, drops it back to unapproved until you
review it again.

## The file

`.agent-sandbox`, in the project root. An INI-like format: a `[section]`
header per list, one item per line beneath it, `#` starts a comment (a whole
line or the end of one), blank lines are ignored. It is parsed as data, never
executed, and one item per line means paths and hosts keep any spaces.

```ini
# hosts this project may reach through the egress proxy, this project only
[allow]
pypi.org
files.pythonhosted.org   # for pip
.github.com

# other projects whose memory this session may read (paths; ~ is expanded;
# a trailing /* shares the projects directly under a directory)
[share-memory]
~/git/acme/app
~/work/*
```

Sections:

- **`[allow]`** — hosts to add to the egress allowlist for sessions in this
  project, the same grant as `--allow` on the command line and subject to the
  same rules (a leading dot matches a domain and its subdomains; ignored in
  `open` and `none` network modes). Command-line `--allow` still applies on top.
- **`[share-memory]`** — see [Memory scoping](#memory-scoping). Project paths
  whose memory this project may read, one per line. A single line `all` keeps
  every project visible; the section present but empty scopes to this project
  alone. An entry may be a shell wildcard (`~/git/acme/*`), which shares the
  projects directly under that directory that have memory. Matching is at the
  path level, so `~/git/acme/*` does not match a sibling `~/git/acme-notes`
  or descend past one level.

- **`[ro]` / `[rw]`** — extra host paths to expose in the sandbox, one per
  line, added to any `AGENT_SANDBOX_RO` / `AGENT_SANDBOX_RW` from your shell.
  The same refusals apply as on the command line: secret stores (`~/.ssh`,
  `~/.aws`, ...), the sandbox's own configuration, any directory containing
  one of them, `/`, `$HOME` and any parent of `$HOME` are rejected.
- **`[forward]`** — names of environment variables to carry from your shell
  into the sandbox (the values come from your shell, not this file), one per
  line, on top of the built-in set. Do not list secrets for unrelated services.
- **`[conda]`** — key/value lines: `name = <env>` runs in that conda env
  (resolved under the active or a discoverable conda base) instead of the one
  active in your shell; `write = 1` makes the active env writable; `pkgs = <dir>`
  is the sandbox-owned package cache used in write mode.
- **`[net]`** — key/value lines. `mode = proxy|strict|open|none` selects the
  network mode for sessions in this project (an `AGENT_SANDBOX_NET` set in your
  shell wins); approving `mode = open` switches the egress allowlist off for
  the project, which is what the `--trust` review is for. For the `strict`
  mode, where pasta's port forwarding is off in both directions,
  `host-port = PORT` lets the sandbox reach the host's `127.0.0.1:PORT` and
  `agent-port = PORT` publishes a port the agent listens on at the host's
  `127.0.0.1:PORT`. Each may repeat; TCP; 1024–65535; `none` closes that
  direction for the session. They join the `--host-port`/`--agent-port` flags
  and the `AGENT_SANDBOX_HOST_PORTS` / `AGENT_SANDBOX_AGENT_PORTS` knobs as a
  union, and are noted and ignored in the other modes. See
  [network.md](network.md#strict-mode-opening-ports).

`proxy-ca`, `profile-dir` and `session-base` are **not** accepted in the file,
on purpose: `proxy-ca` is a trust anchor, and `profile-dir` would point the
engine at code to source. They stay command-line/environment knobs; see
`claude --engine-help`. An `[ssh]`
section is not accepted yet either; use `--ssh` on the command line. An unknown
section, or a line before any section, is ignored with a warning.

A ready-to-copy [agent-sandbox.example](agent-sandbox.example) lists every
section with commented examples.

## Trust

The file is inert until approved. From the project directory:

```sh
claude --trust
```

This prints the file so you can see exactly what it grants, asks you to
approve, and on yes records the file's SHA-256. It then offers to add
`.agent-sandbox` to the repository's `.git/info/exclude`, since its contents
(your other project paths, your hosts) are machine-local and usually should not
be committed.

The approval is stored under `~/.config/agent-sandbox/trust/`, which is **never
bound into the sandbox**, so the agent can neither read nor forge it. If the
file changes afterward, the next launch finds a hash that no longer matches,
warns, and ignores the file until you run `claude --trust` again. The practical
consequence: a `.agent-sandbox` shipped by a cloned repo does nothing until you
review it, and the agent cannot widen its own permissions by writing the file,
it can only force a re-review.

## Memory scoping

Claude Code keeps per-project memory and session transcripts under
`~/.claude/projects/<project>`. By default the sandbox binds all of `~/.claude`
read-write, so every session can read every project's memory and transcripts.
That is convenient (one project can learn from another) but it also means
sessions are not independent and one project's notes can shape another's output.

Two modes:

- **`shared`** (the default) — every project's memory stays visible, the
  historical behavior. Upgrading changes nothing.
- **`scoped`** — `~/.claude/projects` is hidden and only the current project is
  rebound read-write (it keeps writing its own memory and transcripts), plus the
  `memory/` directory of each project you name in `share-memory`, read-only.
  Other projects are invisible.

Scoping covers `~/.claude/projects`. Other state under `~/.claude` (global
command history, session metadata) stays visible; this is about per-project
memory and transcripts, not a full identity reset.

Selecting the mode, from lowest to highest precedence:

1. **Built-in default:** `shared`.
2. **Global default:** `~/.config/agent-sandbox/config`, key `memory_default`:

   ```ini
   memory_default = scoped
   ```

   Set this to `scoped` to make new projects independent by default while your
   existing projects, which have no `.agent-sandbox`, keep whatever you set
   here. Set it to `shared` (or leave it unset) to keep today's behavior.
3. **Per-project:** a trusted `.agent-sandbox` with a `[share-memory]` section.
   Present but empty means this project only; the paths or `~/dir/*` wildcards
   listed add those projects' memory read-only; a single `all` keeps everything
   visible even when the global default is `scoped`.

## Where the machine-local state lives

Both the trust store and the global config are under `~/.config/agent-sandbox`,
the same host-only directory the installer uses for the proxy allowlist. None
of it is bound into the sandbox.

| Path | What |
|---|---|
| `<project>/.agent-sandbox` | the per-project policy (git-ignored by default) |
| `~/.config/agent-sandbox/config` | `memory_default` and future global settings |
| `~/.config/agent-sandbox/trust/` | approved dot-file hashes, one file per project |
