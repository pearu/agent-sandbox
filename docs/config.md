# Per-project config and memory scoping

A project can carry a `.agent-sandbox` file that sets policy for sessions run
from that directory: egress hosts, memory scoping, extra paths, forwarded
variables, conda settings and, for the strict network mode, ports.
Because the file lives in a directory the sandboxed agent can write, and a
project may come from a repository you do not control, it is **honored only
after you approve it**. Approval is bound to the file's exact contents: after
any later edit, by you or by the agent, or if the file disappears, launches
from that directory are refused until you review it again.

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

- **`[env]`** — names of environment variables to carry from your shell
  into the sandbox (the values come from your shell, not this file), one or more
  per line, on top of the built-in set. A line `NAME = VALUE` sets a variable and
  `-NAME` refuses one; both are a profile's (its own dot-file), so in a project's
  file the review warns of them and they are ignored. Do not list secrets for unrelated services.
  Names the profile pins inside are refused with a message rather than
  forwarded, since a forwarded value would override the profile's: for `claude`
  that is `DISABLE_AUTOUPDATER`, `CLAUDE_CONFIG_DIR` and
  `CLAUDE_CODE_PROJECT_DIR_NAME` (the last would move memory and transcripts
  out from under the scoping).
- **`[conda]`** — key/value lines: `name = <env>` runs in that conda env
  (resolved under the active or a discoverable conda base) instead of the one
  active in your shell, and its `bin/` takes that env's place on PATH inside, so
  `CONDA_PREFIX` and PATH agree; `write = 1` makes the active env writable;
  `pkgs = <dir>` is the sandbox-owned package cache used in write mode.
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
- **`[seccomp]`** — key/value lines. `mode = on|off` asks for the default-deny
  syscall filter for sessions in this project, the same grant as
  `AGENT_SANDBOX_SECCOMP` (which wins if set in your shell). The value is the
  state, not a profile name: there is one filter, compiled per machine by
  `install.sh`. The filter is **on by default**, so `mode = off` in a project
  file is a real widening -- which is what the `--trust` review is for, and why
  deleting an approved file refuses the launch rather than falling back. See
  [seccomp](../components/seccomp/README.md).
- **`[briefing]`** — key/value lines. `mode = on|off` (default on) controls
  whether the sandbox tells the session what it may and may not do. When on,
  the engine writes a briefing per launch and binds it read-only at
  `/run/agent-sandbox/briefing.md`, and the claude profile installs
  `SessionStart`/`SubagentStart` hooks that inject a compact summary — so a
  resumed session is never told a policy that has since changed. It lists
  names and paths only, never the contents of anything shared. Turning it off
  grants and hides nothing; it only stops the sandbox describing itself.
  If you pass your own `--settings`, the two are merged (Claude Code honours
  only the last one, so adding a second would drop yours) — specifically the
  *last* `--settings` on your command line, the one that would have won anyway,
  so a wrapper that overrides an earlier one keeps working. Nothing of yours is
  overridden: the briefing's whole contribution is a list of two hook entries,
  so the merge writes only `hooks` and only by appending — no other setting is
  read or rewritten, and a `hooks` shape it does not recognise is refused
  rather than coerced.
  `disableAllHooks`
  in your settings is respected, and the engine then says the briefing will not
  be injected; `briefing.md` stays bound and readable either way.
- **`[connect]`** — key/value lines, one per channel: `channel = mode [source] [scope]`.
  A **channel** is named by what it carries (`instructions`, `settings`,
  `skills`, `agents`, `workflows`, `plugins` for the `claude` profile); a
  **mode** says how much of the source reaches this project's sandbox, on the
  scale `own < seed-only < copy < copy-on-write < read-only < read-write`, lower being more
  isolated. `own` gives the sandbox nothing of yours and keeps what it writes
  there private and persistent; `seed-only` copies your files once, the first time,
  and never refreshes them, so it never warns; `copy` seeds it from your files and
  refreshes anything it has not touched; `copy-on-write` lets reads fall through until it
  writes; `read-only` gives it your files, live, and refuses its writes;
  `read-write` is one directory, both ways. The preset decides where each channel
  starts. The only **source** so far is `native`, your own `~/.claude`, which is
  also the default.

  The order is how much of *your* files reach the sandbox, not what the sandbox
  may do — it can write under `copy-on-write` but not under `read-only`, and
  `read-only` is still the higher rung, because it hands over the real file where
  `copy-on-write` gives only a shadow of one.

  A third token, the **scope**, names a lifetime *shorter* than the role's for the
  sandbox's side of a channel. Written nothing, a channel's storage belongs to the role:
  it persists across runs, the behaviour you already have. **`run-scoped`** is one run of
  the role's launch: the store is made fresh when the launch starts and removed when it
  ends, so `own` starts empty, `copy` re-seeds and `copy-on-write` gets a fresh upper
  layer every run -- for what the agent itself authored and should not run again later
  (`workflows`, `agents`). Everything joined into that run shares it; at `read-only` it
  changes nothing, since nothing is written. **`join-scoped`** is one join -- a joined
  command and everything it starts: `./scratch/ = own join-scoped` gives every `asb
  --exec` or session joined into a running role a scratch of its own, empty when it
  starts and removed when it ends, which no other join can see. It is built for `own`,
  for `copy` and `seed-only` (#153) -- one thing per join: the store is seeded from the
  source when the join starts, since a store new at every join has nothing earlier to
  refresh or conflict with; not for the `config` and `transcripts` channels, whose seed
  is a filtered view -- and for `read-only`, which is then the plain bind. An overlay per
  join, `copy-on-write join-scoped`, is refused as not built yet (#153).

  Source and scope may appear in either order — every scope ends in `-scoped` and no
  source does. And `read-write` with any scope is refused permanently rather than
  pending: at `read-write` the sandbox writes the source itself, so there is no
  sandbox-side storage for a scope to apply to.

  Narrowing a channel needs nothing beyond this file's own approval. Widening
  one back toward `read-write` is what the `--trust` review is for, the same as
  `[net] mode = open`. The same syntax works as `--connect 'instructions=read-only'`
  and, semicolon-separated, as `AGENT_SANDBOX_CONNECT`; the flag beats the
  variable, which beats this file. A channel name the profile does not carry
  refuses the launch instead of being ignored, because a typo that quietly left
  a channel at `read-write` would read to you as a channel you had closed.

  A key that contains **`/`** is a **path declaration** rather than a channel:
  `./scratch/ = own` gives the sandbox a directory of its own at `./scratch`,
  `/data = read-only` shows the outside `/data` read-only, `~/cache/ = read-write`
  shares a directory both ways. This is how any path outside the project is exposed.
  The key is the path inside the sandbox, relative keys are relative to the project,
  `~` is `$HOME`, and the source is the same path outside -- or another, written
  `outside:<path>` after the mode (`~/.agent/config.json = seed-only
  outside:~/templates/config.json`): absolute or under `~`, never with `own`, and not
  bound at all under `--preset native`. Every mode is checked alike, key and source:
  secret stores (`~/.ssh`, `~/.aws`, ...), the sandbox's own configuration, any
  directory containing one of them, `/`, `$HOME`, any parent of `$HOME`, and the
  project or a parent of it are refused. A path that does not exist is skipped until it does,
  except under `own`, which creates the sandbox's own: a directory when the key ends in
  `/`, else a file (#189). Where the path exists, its kind is the host's, and a `/` on a
  file is refused. A key with no `/` is still a
  channel name, so a typo still refuses the launch. See
  [connections.md](connections.md#path-declarations).

  One small side effect worth knowing rather than reporting: where a narrowed
  channel names a **directory** your `~/.claude` does not have, an empty one is
  left there. Empty files are cleaned up, because an empty `CLAUDE.md` is a
  channel that silently parses as nothing, while an empty directory is
  indistinguishable from one you made yourself. See
  [connections.md](connections.md).

- **`[sandbox]`** — key/value lines. `preset = isolated|inherit|shared`
  (default `inherit`) sets where every channel sits before any `[connect]`
  override. `isolated` gives the sandbox nothing of your native install;
  `inherit` lets it read your instructions, settings, skills, agents, workflows
  and plugins live while keeping its own writes to itself; `shared` is one
  directory in both directions, which is what the engine did before 0.3 and what
  to set if you want that back. A fourth, `native`, is the `--preset` flag only
  and is described below.

  What each preset means, channel by channel, in the modes of the scale
  `own < seed-only < copy < copy-on-write < read-only < read-write`. The mode columns are the whole model, not only
  the part the engine drives from a preset today; the last column says what
  actually governs each row now, so nothing here claims more than it does.

  | channel | `isolated` | `inherit` | `shared` | `native` | governed today by |
  |---|---|---|---|---|---|
  | identity — your login, and `gh/`/`ide/` | `read-write` | `read-write` | `read-write` | `read-write` | always live; a sandbox without your login is not your sandbox |
  | project — the working tree | `read-write` | `read-write` | `read-write` | `read-write` | always live; it is what you opened |
  | instructions — `CLAUDE.md`, `rules/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | settings — `settings.json`, `output-styles/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | skills — `skills/`, `commands/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | agents — `agents/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | workflows — `workflows/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | plugins — `plugins/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | config — `~/.claude.json`, the user-level MCP servers included | `own` | `seed-only` | `seed-only` | `read-write` | **the preset** ([below](#the-config-file-the-config-channel)) |
  | memory — `projects/<slug>/memory/` | `own` | `own`, plus `read-only` per share | `read-write` | `read-write` | `memory_default` (`scoped` by default) and `[share-memory]` |
  | transcripts — this project's conversations, file history, plans, prompt history | `own` | `own` | `own` | `read-write` | **the preset** ([below](#transcripts-and-logs)) |
  | logs — `responses.log`, `alerts.log`, written by your own hooks | `own` | `own` | `own` | `read-write` | **the preset** |
  | artefacts — `downloads/`, `uploads/`, `tasks/` | `own` | `own` | `read-write` | `read-write` | **the preset** (#52, #76, #78) |
  | policy — `remote-settings.json`, `policy-limits.json` and its `.stamp.json` | `own` (from `{}`) | `seed-only` | `read-write` | `read-write` | **the preset** (#109): Claude Code refetches them inside and rewrites them, so `copy` would warn at every launch |
  | changelog — `cache/changelog.md` | `own` | `copy` | `read-write` | `read-write` | **the preset** (#109): only your side fetches it, so a copy refreshes cleanly; a sandbox cannot plant an entry you would read as the vendor's |

  Read the last column as the list of things left to fold in. When a row moves to
  the preset its mode columns do not change, because they were chosen to match
  what its own switch already does by default — with two exceptions, both
  deliberate and both worth knowing now:

  - **artefacts were `read-write` whatever the preset, and are `own` under
    `inherit` now.** Downloads, uploads and task lists were visible across every
    project ([#52](https://github.com/pearu/agent-sandbox/issues/52),
    [#76](https://github.com/pearu/agent-sandbox/issues/76),
    [#78](https://github.com/pearu/agent-sandbox/issues/78)); folding them in closed
    that, and it is a behaviour change rather than a no-op: a role starts with none of
    your downloads, uploads or task lists, and what it gets there stays its own.
    `artefacts = read-write native` under `[connect]` gives a role yours again.
  - **`shared` gives `config` `seed-only`, not `read-write`.** The original model
    said `read-write`, which was the pre-0.2 behaviour: the config file bound whole,
    so every project's entries and the user's MCP servers were readable from any
    sandbox. 0.2.1 closed that deliberately
    ([#90](https://github.com/pearu/agent-sandbox/issues/90)), and `shared` will
    not reopen it. `shared` means "the engine before 0.3", not "before 0.2". Under
    `inherit` it is `seed-only` for the same reason as every file Claude Code
    rewrites at every launch: `copy` would warn at every launch. `native` does
    reopen it — the file whole, every project's entries readable — because that is
    what `--preset none` gives, and parity is the point of that preset and the
    reason it is flag-only.

  `copy-on-write` means reads fall through to your files until the sandbox
  writes one, and the write goes to a private layer that shadows it from then on.
  Where an overlay is unavailable — bubblewrap older than 0.11, `[overlay] mode =
  off`, or a channel path naming a single **file**, which overlayfs cannot stack
  on — it behaves as `copy`: seeded from your files and refreshed at each launch
  for anything the sandbox has not touched. The two differ only *within* a
  running session.

  **`native` is the fourth preset, and it is not a fourth step on the same
  ladder.** Its contract is parity: `--preset native` must behave exactly as
  `--preset none` does, while still going through bubblewrap, the network mode
  and the syscall filter — so any difference between the two is a bug in
  agent-sandbox, and `tests/integration/native-parity.bats` runs the same agent
  both ways and fails when they disagree. That makes it a bisector as much as a
  position: something that breaks under `native` but works under `--preset none`
  is broken in the sandbox mechanism, not in the isolation. It is also the far
  end for building a policy from either direction — start at `native` and close
  channels until the use case is met, or start at `isolated` and open them.

  State isolation is off, which is more than every channel at `read-write`:

  | | `shared` | `native` |
  |---|---|---|
  | the declared channels | `read-write` | `read-write` |
  | the rest of `$HOME` — `.gitconfig`, `.npmrc`, `.ssh/`, anything no channel names | hidden behind a tmpfs | the host's own, writable |
  | `/tmp`, `/var/tmp` | private to the session | the host's own |
  | the environment | an allowlist | every exported variable |
  | the configuration file | per project | the host's own, at its own path, `CLAUDE_CONFIG_DIR` unset |
  | memory and the per-session scratch | scoped | unscoped, not applied |

  Unchanged under `native`: the network mode, the syscall filter, the CWD bind,
  and `DISABLE_AUTOUPDATER` — engine policy rather than state, in the same class
  as the proxy. `$XDG_RUNTIME_DIR` is bound through but the rest of `/run` stays
  private, because binding it whole leaves nowhere to create the sandbox's own
  briefing.

  Because that is the whole of the isolation switched off, `native` is accepted
  **only as the `--preset` flag** — never from `AGENT_SANDBOX_PRESET` or a project
  file, either of which could set it for every launch without anyone noticing —
  and every launch prints a notice saying so. See
  [connections.md](connections.md#native-the-fourth-preset-and-why-the-ladder-needs-both-ends).

  `role` is parsed and reserved; only `default` exists. `AGENT_SANDBOX_PRESET` and
  `--preset` are the other two forms.

- **`[overlay]`** — key/value lines. `mode = auto|off` (default auto) says what
  `copy-on-write` is implemented with, not whether anything is shared. `auto` uses a real
  copy-on-write overlay where bubblewrap supports one (0.11 or newer) and falls
  back to `copy` where it does not, saying so at launch; `off` takes the fallback
  everywhere, which is worth doing if overlayfs is unhappy on your filesystem.
  It can only move `copy-on-write` to `copy`, so it is never a widening. The two are
  identical across launches and differ only *within* a running session, where an
  overlay picks up an edit you make to your own copy and a snapshot does not. A
  channel path naming a **file** always uses the fallback, because overlayfs
  mounts directories and cannot stack on a single file. `AGENT_SANDBOX_OVERLAY`
  and `--overlay` are the other two forms.

- **`[claude]`** — key/value lines, read by the `claude` profile rather than by
  the engine (a section named after the active profile; a `[codex]` section in
  a claude run is an unknown section and does nothing). `hide = <paths>` is a
  space-separated list of paths under `~/.claude` to blank inside the sandbox,
  on top of the cross-session state the sandbox already replaces per launch.
  Each is relative to `~/.claude`; an absolute path or one containing `..` is
  refused. The directory is bound read-write because the agent needs its own
  state, so this is how you keep a particular thing in it out of reach:
  `hide = gh` if you put a GitHub token there and do not want this project's
  agent using it, `hide = todos statsig` for state you would rather not share.
  Hiding something the agent needs breaks that feature — which is the point of
  the default being short. `daemon` is hidden already (the background
  supervisor's control key and its roster of other sessions, a cross-session
  channel rather than this session's state); `gh` and `ide` are deliberately
  **not**, because both exist to let Claude Code work from inside a sandbox.

`proxy-ca`, `profile-dir` and `session-base` are **not** accepted in the file,
on purpose: `proxy-ca` is a trust anchor, and `profile-dir` would point the
engine at code to source. They stay command-line/environment knobs; see
`asb --engine-help`. An `[ssh]`
section is not accepted yet either; use `--ssh` on the command line. An unknown
section, or a line before any section, is ignored with a warning.

A ready-to-copy [agent-sandbox.example](agent-sandbox.example) lists every
section with commented examples.

## Trust

The file is inert until you approve it, and the approval is part of the launch
(#143). Run `asb claude` in a project whose `.agent-sandbox` is new, has changed
since you approved it, or has gone although you approved one, and the launch
shows it and asks:

- **new**: the whole file;
- **changed**: what changed, as a diff from the content you approved to what is
  there now — the approved content is kept for this, not only its hash;
- **gone**: what you approved, and whether to forget it and use the defaults.

Before the question, the review says what follows from the file's text alone, so
that a launch need not repeat it: a line it will ignore (malformed, an unknown
section or key, a role suffix a section does not take, a bad host, an unknown mode),
a widening (network mode `open`, seccomp `off`), a `[<profile>]` key that profile
does not read, and per path declaration what it gives -- over a profile's channel, it
wins there; under `$HOME`, outside the project, `own` is sandbox-only storage and any
other mode shows your real one; a file is bound over, so it cannot be deleted or
renamed inside. It reads every profile, so `asb --trust` checks `[claude]` without a
profile named. What depends on the host or the moment -- a path that does not exist
yet, an overlay this bubblewrap cannot mount, a conflict -- is still said at launch.

Everything is shown through `cat -v`, so a control character or a byte outside
ASCII shows escaped instead of acting on your terminal; a file containing a
control character other than tab and newline is refused outright, at review and
again at launch — the format never needs one, and nothing can hide a line from
you. **Yes** records the approval and the launch goes on under it. **No** records
nothing and launches nothing.

Asking needs someone to answer: a terminal on stdin and stderr, whatever the
agent's flags (`asb claude -p …` typed at a shell is asked). **Without one** — a
script, a pipe, a service — a launch under a new, changed or missing file is
**refused**, naming the way to approve it. That includes a new file, such as one a
cloned repository ships: ignoring it would give whoever wrote it the defaults with
a note they may never see. The same review without a launch is

```sh
asb --trust              # asks on stdin: printf y | asb --trust approves without a terminal
```

which also offers to add `.agent-sandbox` to the repository's
`.git/info/exclude`, since its contents (your other project paths, your hosts)
are machine-local and usually should not be committed.

A launch that **joins** a running role is asked the same way, and joins under the
policy the role's keeper started with whatever the answer: a running role's
policy does not change. The answer applies at the next keeper. The management
verbs (`--status`, `--shutdown`, `agents`, …) are never asked or refused over the
file: stopping what runs needs no policy.

The approval is stored under `~/.config/agent-sandbox/trust/`, which is **never
bound into the sandbox**, so the agent can neither read nor forge it. Refusing
rather than ignoring a changed or missing file matters because ignoring would
fall back to the defaults, and for memory scoping the default is wider than a
scoped policy.

**Inside the sandbox the file is read-only** (#143): the agent is never an author
of its own policy, whoever wrote the rest of the project. A declaration can give
the sandbox a copy of its own instead — `./.agent-sandbox = copy` under
`[connect]`, for an inner engine or a `git pull` run inside — and any mode but
`read-write`, which is refused. Two exceptions, both deliberate: under
`--preset native`, which differs from `none` in nothing, the file is left as the
project has it (a declaration still applies); and a project with **no** dot-file
gets no mount point for one, which would leave an empty `.agent-sandbox` in your
repository. A file the agent creates there is new at the next launch, and
reviewed.

**Inside a sandbox there is no gate.** An engine run in a sandbox honours the
dot-file it sees without approval: the file there is the one the outer launch
approved, bound read-only, or a copy of its own, and a nested sandbox can only
narrow the one it is in. The engine counts itself inside only when pid 1 is
bubblewrap, not from the `AGENT_SANDBOX` marker alone, which any process on the
host could set.

## Memory scoping

Claude Code keeps per-project memory and session transcripts under
`~/.claude/projects/<project>`. The sandbox binds `~/.claude` read-write, so
without scoping every session could read every project's memory and
transcripts. That is convenient (one project can learn from another) but it
also means sessions are not independent and one project's notes can shape
another's output. Scoping is therefore the default, and sharing is something
you ask for.

Two modes:

- **`shared`** — every project's memory stays visible, how agent-sandbox
  behaved before 0.2. An explicit opt-out now.
- **`scoped`** (the default) — `~/.claude/projects` is hidden and only the current
  project's `memory/` is bound, read-write, plus the `memory/` directory of each
  project you name in `share-memory`, read-only. Other projects are invisible.

Scoping is about memory. The project's conversations beside it are the
`transcripts` channel ([below](#transcripts-and-logs)): the role's own, with the
project's native memory bound on top, under either mode. Only at
`transcripts = read-write` is the project's whole native directory bound, as
before 0.4.

### What counts as "the project" inside the sandbox

Claude Code decides where a project's memory lives from what it can see. With a
git repository in view it uses the repository, so every subdirectory and linked
worktree of one repository shares a single memory directory; with no repository
in view it uses the directory itself. See
[Auto memory](https://code.claude.com/docs/en/memory).

Inside the sandbox the second case is the normal one. The engine binds the
session's directory, not its parents, so a subdirectory of a repository has no
`.git` above it and is simply a directory. A session started in `repo/sub`
therefore keeps its own memory, and a session in a sibling `repo/other` cannot
see it. That is the isolation you would want from a sandbox, and it follows
from the environment the sandbox provides rather than from the engine
predicting Claude Code's choice.

Two consequences:

- A sandboxed session and a native session started in the same subdirectory do
  not share memory: the sandboxed one keeps memory per directory, the native
  one shares it across the repository. Sandboxed and native runs already differ
  in more fundamental ways, so treat this as one more of them.
- **Known limitation.** If a path declaration exposes a parent directory
  that contains `.git`, the repository is visible again and Claude Code keys
  that session's memory to the repository root — a directory the engine does
  not bind, so the memory does not survive the session. Run from the repository
  root if you want the repository's memory.

Selecting the mode, from lowest to highest precedence:

1. **Built-in default:** `scoped` — a session sees its own project's memory and
   transcripts and no other's.
2. **Global default:** `~/.config/agent-sandbox/config`, key `memory_default`:

   ```ini
   memory_default = shared
   ```

   Set this to `shared` to let every project see every other project's memory,
   which is how agent-sandbox behaved before 0.2. Leaving it unset keeps the
   isolated default. It lives outside the sandbox, so an agent cannot widen
   its own view by writing it.
3. **Per-project:** a trusted `.agent-sandbox` with a `[share-memory]` section.
   Present but empty means this project only; the paths or `~/dir/*` wildcards
   listed add those projects' memory read-only; a single `all` keeps everything
   visible even when the global default is `scoped`.

## Transcripts and logs

A role's history is its own. The **`transcripts`** channel is this project's
conversations (`~/.claude/projects/<slug>/`), `file-history/` (what makes undo
work), `plans/` and the prompt history, `history.jsonl`; the **`logs`** channel
is what your own hooks write, `responses.log` and `alerts.log`. Both are `own`
under every preset but `native`, and nothing is merged back into your native
`~/.claude` when a launch ends.

- **A role starts with none of your native history.** `asb --role foo claude -r`
  lists foo's conversations; a plain `claude -r`, not sandboxed, lists your
  native ones. To give a role its project's native history once, write
  `transcripts = seed-only` under `[connect]`: the conversations, file history
  and plans are copied, and the prompt history is filtered to this project's
  records, never another project's.
- **The project's memory is still its native memory**, bound on top of the
  role's conversations, and shared by the project's roles, until memory is a
  channel of its own (see [Memory scoping](#memory-scoping)).
- **`transcripts = read-write`** is your native files themselves, including the
  whole prompt history with every project's prompts in it: valid, not advocated.
- The role's stores are under
  `~/.local/state/agent-sandbox/claude/<slug>/<role>/{transcripts,logs}/`, where a
  watcher of a hook log points.

## Roles

A **role** is a named, persistent instance of the project: `asb --role impl-1 claude`.
It has its own state, kept under
`~/.local/state/agent-sandbox/claude/<slug>/<role>/`, so two roles of one
project share the working tree and nothing else unless you connect them. The
name comes from `--role`, then `AGENT_SANDBOX_ROLE`, then `[sandbox] role` in
this file, else `default`. A name is a letter or digit followed by letters,
digits, `.`, `_` or `-`, at most 200 characters; `--role default` is the same as
no `--role`.

What a role gets comes from **role-suffixed sections**:

```ini
[connect]
skills = copy-on-write native     # every role

[connect:impl-*]
skills = read-only native         # every role whose name matches impl-*

[sandbox:reviewer]
preset = isolated                 # the reviewer role

[connect:*]                       # accept any other role name too
```

`[<section>:<glob>]` is that section for the roles the glob matches (`*` and
`?` as in the shell). It applies after the unsuffixed section, in file order,
and a later line overrides an earlier one **per key**: `[connect:impl-*]` above
changes `skills` and leaves every other channel as `[connect]` put it. Only
`[sandbox]` (its `preset`) and `[connect]` take a suffix so far; a suffix on any
other section is said at the file's review and that section is skipped.

**Once any suffixed section exists, a role name matching none of them is
refused**, since it is most likely a typo of one; add `[connect:*]` to accept
every name. A file without suffixed sections has one policy, and any role name
runs under it as a separate instance. `--preset` and `--connect` apply to
whichever role is launched. A role with `--bg` is refused for now: background
sessions do not carry a role yet (#123).

## The config file: the `config` channel

Claude Code's top-level config file, `~/.claude.json`, holds app state
(onboarding, tips, caches), the account, the user-level `mcpServers`, and one
entry per project: folder trust, allowed tools, MCP servers added for that
project, the last opening prompt. Bound whole into every sandbox it was two
channels at once: a sandboxed session could read every other project's entry,
and what it wrote reached every other session.

It is the **`config` channel**, one file following its mode like any other
channel. Inside the sandbox it is at `~/.claude/.claude.json`, and
`CLAUDE_CONFIG_DIR` points Claude Code there, so there is nothing at
`~/.claude.json` inside. Its source is your native `~/.claude.json`.

- **`seed-only`** (the default under `inherit` and `shared`) is the role's own
  copy, made once: every top-level key, and of the per-project entries only
  this project's. After that it is Claude Code's alone. The engine never reads
  or writes anything inside it again, so a user-level MCP server added from
  inside the sandbox stays, and one you add natively later does not arrive. If
  the native file has no entry for the project yet, Claude Code asks about
  folder trust once, inside, and records the answer in the role's copy.
- **`copy`** is seeded the same way and takes your native file's changes only
  while the role's copy is unchanged, which in practice is never: Claude Code
  rewrites the file at every launch, so `copy` would warn at every launch.
- **`own`** (the default under `isolated`) starts from `{}`. Claude Code runs on
  it beside your credentials and rebuilds the account block itself (measured,
  2.1.283); what the role gives up is your app state and the project's trust and
  allowed tools, which it establishes again once.
- **`read-only`** and **`read-write`** are the native file itself, whole: every
  project's entry is readable inside. Under `read-only` Claude Code's own writes
  to it fail silently, so it is valid but not advocated; to change your user-level
  MCP servers, type `claude mcp add` at your shell, which is Claude Code itself. Under
  `read-write` the sandbox writes your native file.
- Under `--preset native` nothing is copied or relocated: Claude Code reads your
  native `~/.claude.json` as it would outside.

The role's copy is kept on the host under
`~/.local/state/agent-sandbox/claude/<slug>/<role>/config/<mode>/`, part of the
sandbox's control plane: never bound into any sandbox, refused as a path declaration.
A background worker
(`asb claude --bg`) is keyed by the project it was launched for, not by the daemon's
directory, and is pre-trusted in the role's copy as it is in the native file.
Without a working `python3` the seed is the whole native file, and the launch
says so. `--reset config` discards the role's copy; the next launch
seeds it again.

To keep your user-level MCP servers out of a project's sandbox, give it a config
file of its own: `config = own` under `[connect]`.

## Where the machine-local state lives

Both the trust store and the global config are under `~/.config/agent-sandbox`,
the same host-only directory the installer uses for the proxy allowlist. None
of it is bound into the sandbox.

| Path | What |
|---|---|
| `<project>/.agent-sandbox` | the per-project policy (git-ignored by default) |
| `~/.config/agent-sandbox/config` | `memory_default` and future global settings |
| `~/.config/agent-sandbox/trust/` | approved dot-file hashes, one file per project |
| `~/.local/state/agent-sandbox/claude/<slug>/<role>/config/<mode>/` | the role's copy of Claude Code's config file (see above) |
