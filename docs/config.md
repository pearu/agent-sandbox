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
- **`[deny]`** (#221) — hosts taken out of what sessions in this project may reach,
  one per line, in the same form: out of the global allowlist and out of the
  session's own grant, for those sessions only. Never a host the agent's profile
  needs: a line that would take one (`.anthropic.com` for `claude`) is left out, and
  said. Ignored in `open` and `none` network modes, which have no proxy to refuse.
- **`[ssh]`** — hosts sessions in this project may reach over SSH through the
  broker, one per line, in the forms `--ssh HOST` takes: a hostname, `user@host`, or
  an alias from your `~/.ssh/config` (a line with any other character, a leading `-`
  or a space is said at the review and ignored). The same grant as `--ssh`, and the
  same path: a launch's hosts are this section's and its `--ssh` flags together, each
  checked against your `known_hosts`, the key loaded into the session's agent with a
  destination constraint per host, and in `strict` mode a firewall pinhole per host
  ([ssh.md](ssh.md)). Per role with `[ssh:<role>]`. A widening -- the role signs in as
  you there -- so the review names each host and the roles it is for, and `--check`
  and the briefing name each with its section. `--ssh-unrestricted`, `--ssh-key` and
  `--ssh-timeout` are launch-only: a project's file never picks your key or the
  escape hatch (with `--ssh-unrestricted` the key has no constraint, so the section's
  hosts are within it, and the launch says so). The hosts stand alone (#293): a role
  whose `[net] git` is `fetch` or `refuse`, or under `retrieve-only`, gets them all the
  same, and a push over SSH to a remote on one is possible where the account allows;
  the review, `--check` and the briefing say so per host. What the key may do there is
  the remote's rule ([ssh.md](ssh.md#what-the-key-may-do-on-a-host)).
- **`[permissions]`** — permission rules the agent gets without asking you, one per
  line, in the agent's own syntax: for `claude`, what its settings take under
  `permissions.allow` -- a tool name (`Read`), or a tool with a specifier
  (`Bash(git push:*)`, `Write(.asb/coord/gate/**)`). `#` starts a comment here as
  everywhere in the file, so a rule cannot contain one. The engine checks the shape
  only (a line that is not `Tool` or `Tool(...)` is said at the review and ignored);
  the profile hands the rules to the agent -- `claude` adds them to the `--settings`
  file the briefing already passes, after the rules of a `--settings` of yours, whose
  `deny` and `ask` rules still win. So they travel with the briefing: with
  `[briefing] mode = off` they are not passed, and the launch says so. Per role with
  `[permissions:<role>]`, a union with the unsuffixed section's. A widening -- what
  the agent would have asked you before, it now does -- so the review names each rule
  with its section and the roles it is for, and `--check` lists the role's. It changes
  nothing the sandbox enforces: a rule lets the agent run a command without asking,
  and the command then meets the same mounts, network and syscall filter. Applied
  under every preset, `native` included, as `[allow]` is.
- **`[serve]`** — what `asb --role ROLE --serve CMD` (#277) waits on and says, for a
  role with no terminal: `watch = PATH`, the file whose every change is a turn (an
  inbox), and `prompt = PATH`, the file whose text each turn is told; both relative to
  the project, with no `..`, and `prompt` required for `--serve` only. Per role with
  `[serve:<role>]`; the latest line of each key that matches the role wins. `--serve`
  runs on the host, in the foreground: it holds the role's launch open, polls the
  watched file every second, and at each change runs one turn of the role's own
  session as a join -- the agent with the profile's turn arguments (claude: `-p
  --session-id ID` the first time, `-p --resume ID` after, and `--permission-mode
  bypassPermissions`: nobody is there to answer a prompt, so Claude Code's prompts are
  off and the role is bounded by its policy alone) and the prompt's text. A turn that
  fails is one line in `.asb/coord/ROLE/messages.md`, written by a rename. The
  session's id goes to `.asb/coord/ROLE/session`, which a later `--serve` resumes, and
  the loop touches `.asb/coord/ROLE/alive` as a terminal role's watcher does. A turn
  waits while something else is joined into the role's launch -- a terminal on the
  session, most likely: two resumes of one session at once fork it. `--status` shows
  the loop; `--shutdown`, Ctrl-C or a TERM ends it with the launch. Nothing of the
  project runs on the host: the prompt is read through one open file whose real path
  must be in the project, plain text, at most 64 KiB. The review says what the loop
  will wait on and read; it widens nothing (the turns run in the role's sandbox, under
  its policy), and `--check` names the role's. **A reset**: a file
  `.asb/coord/to/ROLE.reset`, beside the role's inbox, makes the next turn a new session
  -- a fresh id, told the prompt as every turn is, recorded in `.asb/coord/ROLE/session`
  -- and the loop removes it (from inside the directory, a link removed and never
  followed; its content is not read). Only a turn looks for it, so it is written before
  the message it applies to. The old session's transcript stays on disk, resumable by
  its id. The roles model's Supervisor writes it to start a role's new Task fresh.
  **At a terminal**, `watch` also names the file a session of the role keeps a watcher
  on: the claude profile's `Stop` hook refuses, once, a turn that ends with no
  `inbox-wait` running (see [profiles](profiles.md)), and `--check` says so for the
  role. Not on a turn of `--serve` nor in a print run. A section with `watch` alone is
  a watch only: the watcher is enforced, the role is not served -- `--serve` refuses it
  ("names no prompt"), and the review and `--check` say "watch only".
- **`[share-memory]`** — see [Memory scoping](#memory-scoping). Project paths
  whose memory this project may read, one per line. A single line `all` keeps
  every project visible; the section present but empty is this project alone. An entry may be a shell wildcard (`~/git/acme/*`), which shares the
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
  `CONDA_PREFIX` and PATH agree; `prefix = <path>` (#221) does the same for an env
  given by its path -- relative to the project, under `~`, or absolute -- such as a
  clone in a role's own tree (`name` and `prefix` are one setting: the later wins); `write = 1` makes the active env writable;
  `pkgs = <dir>` is the sandbox-owned package cache (relative to the project, like
  `prefix`, under `~`, or absolute), persistent, where conda's
  downloads go whenever a conda env is active (the host's cache stays read-only and
  is searched after it), write mode or not -- an env written by path, `conda install
  -p`, downloads too.
  The conda base is bound read-only whenever the file names an env or prefix, an env
  active in your shell or not: a `prefix` that is not an env yet (no `conda-meta/`,
  such as the empty directory a role's tree declares for it) or a `name` not under the
  base gets the base, its config and the package cache, with `<base>/condabin` on PATH,
  so conda runs inside and the prefix can be created there. The base is found from
  `MAMBA_ROOT_PREFIX`, `CONDA_ROOT_PREFIX`, or `conda`/`mamba` on PATH (`info --base`).

  `base = host | sandbox` is whose conda that is. `host` is the host's, as above.
  `sandbox` is agent-sandbox's own micromamba, which `install.sh` installs (the mamba
  code base as one static executable, needing no base environment): its directory
  (`~/.local/share/agent-sandbox/micromamba/bin`) bound read-only and first on PATH,
  its conda root (`~/.local/share/agent-sandbox/conda`) bound read-only and named by
  `MAMBA_ROOT_PREFIX`, a `name` resolved under the root's `envs/`, a `prefix` as given,
  `write` and the package cache as above -- and nothing of the host's conda: not its
  base, not an env active in your shell, not its root-prefix variables. The command
  inside is then `micromamba` (`micromamba create -p PREFIX ...`, `micromamba install
  -p PREFIX ...`), not `conda`; the briefing names it. The default is
  `AGENT_SANDBOX_CONDA_BASE` from your shell, then this key (a role's `[conda:<role>]`
  over the file's), then `~/.config/agent-sandbox/conda` (the installer's question),
  then `host` where the host has conda and `sandbox` where it has none. `host` on a
  host without conda says so and uses the sandbox's; `sandbox` with micromamba not
  installed refuses the launch, naming `install.sh`. `--check` prints which one a
  role gets, and `--init --env NAME` makes the env's prefix under that one's base.
- **`[net]`** — key/value lines. `hosts = allowlist|public` (default allowlist):
  `public` lets the role reach every public host, the allowlist not applying -- for
  work whose sites are not known in advance (the `market` model). The proxy stays in
  the path: `[deny]`, `retrieve-only`, `git` and the refusal of non-public addresses
  (localhost, the LAN, cloud metadata) still apply. Said at the review, in the
  briefing and in `--check`; ignored in `open` and `none`.
  `retrieve-only = on|off` (#223, default off): every
  request but GET and HEAD is refused, to every host but the profile's own (the
  agent's API) -- a session that reads the web and GitHub and publishes nothing over
  HTTP (SSH is `[ssh]`'s). `gh`
  reads through POSTs to `api.github.com/graphql`, so there a query passes and a
  mutation (or a subscription, anywhere in the document) is refused, by the body.
  Git's fetch (a POST to `git-upload-pack`) passes where `git` is `fetch` or `allow`
  (#280); a push is refused whatever `git` says. It
  does not stop a secret carried out in a GET; a token that cannot write is the
  answer to that ([recipes.md](recipes.md), the `gh` section). Per role with
  `[net:<role>]`; ignored in `open` and `none`, which have no proxy.
  `git = allow|fetch|refuse` (#224, default allow): `fetch` lets git fetch over HTTPS
  and refuses a push (the `git-receive-pack` advertisement and endpoint), so a role
  reads repositories and never pushes over HTTPS; `refuse` stops git's smart-HTTP
  transport to every host -- the ref advertisement (`/info/refs?service=git-upload-pack`
  or `git-receive-pack`), the pack endpoints, and anything sent with git's own
  `git/...` user agent -- so the session neither fetches nor pushes over HTTPS, while
  the same host's pages still load. Neither reaches into SSH (#293): `--ssh` and the
  role's `[ssh]` hosts are honoured whatever `git` says, and git over SSH reaches
  them. Per role with `[net:<role>]`.
  `mode = proxy|strict|open|none` selects the
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
- **`[gpu]`** — key/value lines. `mode = on|off` (default on): the host's GPUs in the
  sandbox -- their device nodes (`/dev/nvidia*` and `nvidia-caps/`, AMD's `/dev/kfd`,
  the render nodes `/dev/dri`) bound in, and `/sys` read-only, which the driver's
  management library (NVML: `nvidia-smi`, a framework's device queries) reads. `off`
  keeps all of it out. Per role with `[gpu:<role>]`; `AGENT_SANDBOX_GPU` in your shell
  wins over the file; `asb --init MODEL --disable-gpu` (or `--enable-gpu`) writes the
  line for a model's roles. The driver's libraries are in `/usr`, already in view.
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
  resumed session is never told a policy that has since changed — and a hook
  after every Bash call that reports a host the proxy refused during it
  ([network](network.md#refusals-reach-the-session)). It also sets a status line
  (#287): a bar across the terminal in the state's colour, the role -- the
  project's name for the default role -- in bold, then what the session is doing:
  `WORKING` (yellow) while a turn runs; `NEEDS YOU` (blue, bold) at a permission
  prompt, an elicitation or a question for you (not the idle reminder); and after a
  reply, `ASKS YOU` (blue) when one of its last three lines ends with a question --
  blank lines, quotes (`>`, `▎`) and fenced code not counted -- else `RUNNING`
  (yellow) when a background command of the role's own is running; it wakes when that
  ends -- the suite it started in the background, not its watcher -- else `WAITING`
  (green) when a watcher runs -- a process named `inbox-wait`, the roles model's,
  so a message will wake it -- else `IDLE` (grey). Hooks on `SessionStart`,
  `UserPromptSubmit`, `Stop`, `PermissionRequest`, `Notification` and after any
  tool (`PostToolUse`, `PostToolUseFailure`) record it in the
  sandbox's `/tmp`, redrawn every second. `briefing.md` also says
  that what a session hands you to run is one line or a file -- the CLI prefixes
  every line of a reply, so a pasted heredoc or patch breaks -- and where its
  writable stores are on the host, a `copy-on-write` project's layer included, and that a
  file it names for you to read or open is named by its host path. It lists
  names and paths only, never the contents of anything shared. Turning it off
  grants and hides nothing; it only stops the sandbox describing itself.
  If you pass your own `--settings`, the two are merged (Claude Code honours
  only the last one, so adding a second would drop yours) — specifically the
  *last* `--settings` on your command line, the one that would have won anyway,
  so a wrapper that overrides an earlier one keeps working. Nothing of yours is
  overridden: the briefing's contribution is a list of hook entries and the
  status line, so the merge writes `hooks` only by appending, and `statusLine`
  only when yours has none -- a status line of your own wins. No other setting
  is read or rewritten, and a `hooks` shape it does not recognise is refused
  rather than coerced.
  `disableAllHooks`
  in your settings is respected, and the engine then says the briefing will not
  be injected; `briefing.md` stays bound and readable either way.

  **A role's purpose** (#222): `[briefing:<glob>]` briefs the roles the glob matches
  from a purpose file -- what the role is for, which no mount can say -- `file =
  PATH` (relative to the project, under `~`, or absolute; `{role}` is the role's
  name), `.asb/roles/{role}.md` when the section has no `file` line. A `file` line in
  the unsuffixed `[briefing]` briefs every role. The file's text follows the
  engine's own lines in the `SessionStart` hook (not `SubagentStart`: a subagent is
  the role's tool, not the role), and `briefing.md` has it under "Your role"; the
  file is read-only inside (any declared mode but `read-write`). It is part of the
  approval: the trust record covers every purpose file the dot-file can name --
  `{role}` read as the section's glob -- so an edit to one, or a new one the glob
  matches, re-opens the review, which shows it new or as a diff. A role whose file
  does not exist is refused. `mode` stays a key of the unsuffixed section. When the
  file differs from the one the role's previous launch was briefed from (its sha256
  is kept in the role's state directory, `purpose.sha256`), the hook and "Your role"
  add one sentence: the text is the current one and replaces whatever earlier turns
  of a resumed conversation followed; `--delete` drops that record with the rest.

  ```ini
  [briefing:reviewer-*]                  # .asb/roles/reviewer-1.md, ...
  [briefing:supervisor]
  file = docs/agents/supervisor.md
  ```

  **The first turn**: `start = PATH`, in `[briefing]` or `[briefing:<glob>]`, names a
  file in the project (relative to it, no `..`; `{role}` is the role's name, and the
  latest line matching the role wins) whose text the session runs as its first turn at
  every interactive start -- a new session, or one resumed with `--continue` or
  `--resume ID`, which otherwise sits at its prompt until you type. A role whose purpose
  file says "at start, arm your watcher" needs a turn to do it in. The profile decides
  how the text is handed over (`profile_start_args`; claude: the prompt after its own
  arguments, so a prompt you type yourself still wins) and declines where it is not a
  session start: `-p`, `--bg`, a subcommand. Not under `--serve` (its turns have their
  own prompt), `--exec`, a verb, or with `mode = off`. The file is read on the host at
  launch, plain text up to 64 KiB, and a launch whose file is missing is refused. It is
  not part of the approval, as a `[serve]` prompt is not: the review says which file a
  role starts with, and `--check` names it. The same text is a command, `/start`, in
  that session (claude: `.claude/commands/start.md` in the launch's briefing directory,
  added with `--add-dir`), so after `/clear` at the role's terminal `/start` runs it as
  a turn again without a relaunch; only where the first turn is given, and only for a
  role with a `start`.

  ```ini
  [briefing:planner-*]
  start = .asb/start/{role}.md           # .asb/start/planner-1.md, ...
  ```
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
  is a filtered view -- for `copy-on-write`, an overlay per join: the source read live,
  the join's writes in an upper layer that goes with the join (a file, or overlays off,
  gets a seeded copy per join instead) (#153) -- and for `read-only`, which is then the
  plain bind.

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

  **`project = read-only`** (#220) binds the working tree itself read-only, for a role
  that must not change it; `read-write`, the default, is the tree as it always was;
  **`project = copy-on-write`** mounts an overlay at the project's own path: the role
  reads the tree as it is -- built -- and its writes stay in a layer of its own, kept
  across its launches until `asb --delete` (a PR reviewer's checkout and rebuild). It
  needs an overlay (bubblewrap 0.11) and is refused under `native`; there is no copy
  fallback. Nothing else is accepted -- no other mode, no source, no scope. A read-write part of a read-only
  project is a declaration inside it, bound after it by depth:

  ```ini
  [connect]
  project = read-only
  [connect:implementer]
  .asb/impl-1/ = read-write
  [connect:supervisor]
  project = read-write
  ```

  bwrap cannot make a mount point in a read-only tree, so a declared path the project
  does not have yet (an `own` one, or one with a source elsewhere) gets its mount point
  made on the host before the launch, as bwrap would have made it in a read-write tree.

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
  | identity — your login, and `ide/` | `read-write` | `read-write` | `read-write` | `read-write` | always live; a sandbox without your login is not your sandbox |
  | gh — your gh login, `~/.config/gh/` | `own` | `own` | `own` | `read-write` | **the preset** (#88): no sandbox gets the token unless its file asks, `gh = read-only` -- your login, live; `gh = read-only outside:PATH` gives another; a missing directory is made, so a later `gh auth login` reaches a running session |
  | project — the working tree | `read-write` | `read-write` | `read-write` | `read-write` | always live; it is what you opened; `project = read-only` per role (#220) |
  | instructions — `CLAUDE.md`, `rules/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | settings — `settings.json`, `output-styles/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | skills — `skills/`, `commands/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | agents — `agents/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | workflows — `workflows/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | plugins — `plugins/` | `own` | `copy-on-write` | `read-write` | `read-write` | **the preset** |
  | config — `~/.claude.json`, the user-level MCP servers included | `own` | `seed-only` | `seed-only` | `read-write` | **the preset** ([below](#the-config-file-the-config-channel)) |
  | projects — `projects/`, every project's conversations and memory | `own` | `own` | `own` | `read-write` | **the preset**; `[share-memory] all` is `read-write` ([below](#memory-scoping)) |
  | memory — `projects/<slug>/memory/` | `own` | `own`, plus `read-only` per share | `read-write` | `read-write` | **the preset**, and `[share-memory]` for other projects' (#196) |
  | transcripts — this project's conversations, file history, plans, prompt history, `/insights` data (`usage-data/`) | `own` | `own` | `own` | `read-write` | **the preset** ([below](#transcripts-and-logs)) |
  | agent-memory — `agent-memory/`, subagents' persistent memory | `own` | `own` | `read-write` | `read-write` | **the preset** (#74) |
  | logs — `responses.log`, `alerts.log`, written by your own hooks | `own` | `own` | `own` | `read-write` | **the preset** |
  | artefacts — `downloads/`, `uploads/`, `tasks/` | `own` | `own` | `read-write` | `read-write` | **the preset** (#52, #76, #78) |
  | policy — `remote-settings.json`, `policy-limits.json` and its `.stamp.json` | `own` (from `{}`) | `seed-only` | `read-write` | `read-write` | **the preset** (#109): Claude Code refetches them inside and rewrites them, so `copy` would warn at every launch |
  | changelog — `cache/changelog.md` | `own` | `copy` | `read-write` | `read-write` | **the preset** (#109): only your side fetches it, so a copy refreshes cleanly; a sandbox cannot plant an entry you would read as the vendor's |

  Read the last column as the list of things left to fold in. When a row moves to
  the preset its mode columns do not change, because they were chosen to match
  what its own switch already does by default — with three exceptions, all
  deliberate and all worth knowing now:

  - **memory was your native memory under every preset, and is the role's own
    under `isolated` and `inherit` now** (#196). What you write — instructions,
    settings, skills — a sandbox inherits copy-on-write; what the agent writes —
    transcripts, logs, memory — is the role's own. A role starts with none of your
    native memory, and what it writes down stays its own; `memory = copy-on-write`
    under `[connect]` reads yours live, `seed-only` carries it over once.
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
  channels until the use case is met, or start at `isolated` and open them. The one
  PATH difference is the tools environment (below): on PATH under `native` as under
  every preset, absent under `none`, which runs outside the sandbox.

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
  `hide = todos statsig` for state you would rather not share.
  Hiding something the agent needs breaks that feature — which is the point of
  the default being short. `daemon` is hidden already (the background
  supervisor's control key and its roster of other sessions, a cross-session
  channel rather than this session's state); `ide` is deliberately **not**,
  because it exists to let Claude Code work from inside a sandbox. A gh login left in `gh/` by the gh channel's first design is blanked: the channel is
  your `~/.config/gh` (#88).
  `state-background = on` (default off) tints the terminal's background with the
  session's state, which the status line shows in any case (see `[briefing]`):
  `#203040` while it works or runs a background command, `#202840` while it needs
  you or asks you, and the terminal's own background (OSC 111) while it waits, when
  idle and at exit.
  Claude Code's hooks are detached from the terminal, so the claude profile's
  state hook writes the OSC 11 sequence to Claude Code's own stdout,
  `/proc/$CLAUDE_PID/fd/1`, only when that is a character device and never
  waiting on it. Measured under tmux 3.4, where the
  pane's background follows with no passthrough setting; how a GUI terminal
  repaints is unmeasured. Like the status line it comes with the briefing, so not
  with `[briefing] mode = off`.

`proxy-ca`, `profile-dir` and `session-base` are **not** accepted in the file,
on purpose: `proxy-ca` is a trust anchor, and `profile-dir` would point the
engine at code to source. They stay command-line/environment knobs; see
`asb --engine-help`. An unknown
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

**`asb --check`** is the same review, asking nothing and recording nothing: the file
(as a diff when it changed since you approved it), the notes, and whether it is
approved. Then, with a profile -- `asb --check claude`, or the only one installed --
what the file means, as a launch would apply it once approved, without starting
anything:

- **the policy** for the role the file names (`--role R` for another): every channel
  and declaration, its mode, its source, and what set it -- the preset, a `[connect]`
  line, a role's section, or a built-in;
- **the binds**, in the order a launch makes them (by depth, outer first), each with
  what is seen there: native, this role's own store, an overlay, a declared path (or
  that it does not exist yet, so a launch skips it), another role's store for a
  `sandbox:` source, or a per-launch blank. Paths read in the dot-file's own words:
  `./` in the project, `{slug}` for this project's slug. `--verbose` adds the stores'
  paths;
- **what crosses the boundary**, in two tables: what another session left that
  *reaches* this one, and what this one writes that another can read, each ordered by
  how it arrives -- `context` (in every session's context: instructions, settings,
  skill and agent descriptions, memory at this project's path), `searched` (found when
  the agent looks: downloads, another project's shared memory), `pointed` (a path you
  declared, reached when someone goes there) -- and `UNMEASURED` where the leak study
  has no row yet, printed as loudly as the rest. What stays this role's own is one
  sentence. The values are the profile's `reach` lines, from measurements
  ([profiles.md](profiles.md));
- **what is unclassified** in the agent's state directory: every entry no channel,
  `hide` line (the profile's or this project's `[claude] hide`) or `visible` line names
  -- the native path, read-write, and every project's, which is what an unknown path
  is by default (#82). Listed as loudly as `UNMEASURED`, so it gets decided;
- **where the role can act as you** (#226), per outside service: your agent's API (your
  login, always); GitHub -- no, when there is no credential (the `gh` channel is the
  role's own and no `GH_TOKEN` is forwarded) or no GitHub host is reachable; read only,
  under `retrieve-only`; yes, writes included, otherwise -- with whether git's transport
  is refused, and under `proxy` a note that those lines bind only the tools that use
  the proxy; SSH -- the file's `[ssh]` hosts for the role, each with its section, plus
  any a launch names with `--ssh`, and that `[net] git` and `retrieve-only` do not
  reach into them; and
  every forwarded variable named like a credential;
- **lines with no effect** for the role: a `[connect]` line at the preset's own rung
  (when it is the only line for that channel the role gets -- a role's line restating
  the preset over an unsuffixed one is an override), the same key twice in one section
  (the earlier never applies), and a `[share-memory]` path with nothing to share yet.
  Advice: they do not change the exit status.

It exits non-zero when a launch would refuse the file whatever you answer -- a control
character, an approved file that has gone, or a policy the launch refuses (an unknown
mode, a source it does not know) -- so an author can run it while writing the file, and
a CI job or a pre-commit hook can run it where nobody could answer a question.
`asb --trust` is the review, then the question, then the record.

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
are machine-local and usually should not be committed. A file the repository
tracks gets no such offer: a repository can ship its policy, and it is still
approved on every machine.

**`asb --apply '[SECTION]' LINE...`** adds lines and then runs that review: the
section header as the file writes it, brackets included (`'[allow]'`,
`'[allow:gh-setup]'`, `'[connect:gh-*]'`), then each line as it would appear in the
file -- `asb --apply '[allow]' pypi.org`, `asb --apply '[connect:impl-*]' 'skills =
read-only native'`. A missing file is created; a missing section is added at the end;
in a section that is there, a line it already has (compared without a trailing comment)
is left alone and the others go at the end of the section. Each line is said `added` or
`already there`, so running it twice adds nothing; when nothing is added and the file is
approved as it stands, nothing is asked either. What follows is `--trust`'s review on
the edited file -- the diff from what you approved, the question, the record -- and a
**no** leaves the edit in the file, unapproved, for you to look at. A section the
format does not have is refused; the lines are not checked beyond that, since the review
shows them with the parser's own warnings. The file's first role-suffixed section is
warned of ([Roles](#roles)), not refused. It runs on the host only: inside a sandbox it is
refused, as `--init` is. It is the command a blocked session prints for you to run
([recipes.md](recipes.md#when-you-need-something-that-is-blocked)); the change applies
at the next launch of the roles it names, and a running role keeps its policy until it
ends (`--shutdown`).

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

Claude Code keeps each project's conversations and memory under
`~/.claude/projects/<slug>/`, and loads a project's memory into every session of
that project. Without scoping every session could read every project's memory and
transcripts. That is convenient (one project can learn from another) but it also
means sessions are not independent and one project's notes can shape another's
output. So two channels cover that directory (#196), beside `transcripts`:

- **`projects`** — every project's state, `~/.claude/projects/`. `own` under every
  preset but `native`: the role has a store of its own there, and other projects'
  memory and conversations are not in view.
- **`memory`** — this project's memory, `projects/<slug>/memory/`. The role's own
  under `isolated` and `inherit`; your native memory under `shared` and `native`.

Channel paths nest, and the engine binds them by depth, outer first: `projects`,
then this project's conversations inside it (`transcripts`), then its memory inside
those, each at its own mode. To bring your native memory into a role:

```ini
[connect]
memory = copy-on-write   # read yours live; the sandbox's writes stay its own
# memory = seed-only     # carry yours over once
# memory = read-write    # your native memory, both ways, as under `shared`
```

**`[share-memory]`** opens other projects' memory, and is sugar for connections;
a project's own `[connect]` overrides it:

- **a path** P shares P's memory read-only. It means the declaration
  `{base}/projects/{slug:P}/memory/ = read-only sandbox:P`, where `{slug:P}` is P's slug
  in Claude Code's scheme: what P's default role wrote, or P's native memory if P never
  ran sandboxed ([connections.md](connections.md#another-sandboxs-store-sandbox)). To
  read another role of P, write the declaration with `sandbox:P@ROLE` under `[connect]`.
- **a wildcard** (`~/git/acme/*`) shares the projects directly under that directory
  whose memory resolves to something, a role's or a native one, expanded at each launch. It is matched at the path level, so it
  does not match a sibling `~/git/acme-notes` or descend past one level.
- **a single `all`** is `projects = read-write`: every project's state in view.
- **present but empty** is this project only, which is the default anyway.

A share naming this project is dropped: its memory is already there, at its own
mode.

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
  that session's memory to the repository root — not this project's `memory`
  channel, so the memory lands in the role's `projects` store instead of where
  its mode says. Run from the repository root if you want the repository's memory.

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
- **The project's memory is the `memory` channel**, inside the conversations'
  directory and bound on top of it (see [Memory scoping](#memory-scoping)).
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
changes `skills` and leaves every other channel as `[connect]` put it.
`[sandbox]` (its `preset`), `[connect]`, and (#221) `[allow]`, `[deny]`, `[env]`,
`[conda]`, `[net]`, `[gpu]`, `[ssh]`, `[permissions]`, `[briefing]` and `[serve]` take a suffix: a
key there overrides the unsuffixed one for the role, a list (`[allow]`, `[deny]`,
`[ssh]`, `[permissions]`, `[env]` names) adds to it --

```ini
[conda]
name = x-dev                      # every role
[conda:implementer-1]
prefix = .asb/impl-1/.env         # this one's own clone
[net:reviewer]
mode = none
[deny:reviewer]
pypi.org
[ssh:impl-*]
github.com                        # the implementers push over SSH
```

A suffix on any other section is said at the file's review and that section is
skipped. The review reads every role's lines, whichever role a launch runs.

**Once any suffixed section exists, a role name matching none of them is
refused**, since it is most likely a typo of one; add `[connect:*]` to accept
every name; `asb --apply` warns when the section it adds is the file's first. A
file without suffixed sections has one policy, and any role name
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
- **`own`** (the default under `isolated`) starts from
  `{"hasCompletedOnboarding": true}`. Claude Code runs on it beside your credentials
  and rebuilds the account block itself; on a bare `{}`, 2.1.285 runs its first-run
  onboarding, whose login step asks you to log in although the credentials are valid
  (measured 2026-10-12; 2.1.296 does not). What the role gives up is your app state
  and the project's trust and allowed tools, which it establishes again once.
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
A view that cannot be made refuses the launch rather than seeding the whole native
file, other projects' entries included. `--reset config` discards the role's copy; the next launch
seeds it again.

To keep your user-level MCP servers out of a project's sandbox, give it a config
file of its own: `config = own` under `[connect]`.

## Where the machine-local state lives

The trust store is under `~/.config/agent-sandbox`,
the same host-only directory the installer uses for the proxy allowlist. None
of it is bound into the sandbox.

| Path | What |
|---|---|
| `<project>/.agent-sandbox` | the per-project policy (git-ignored by default) |
| `~/.config/agent-sandbox/trust/` | approved dot-file hashes, one file per project |
| `~/.local/state/agent-sandbox/claude/<slug>/<role>/config/<mode>/` | the role's copy of Claude Code's config file (see above) |
| `~/.config/agent-sandbox/tools.txt` | the tools environment's packages (below); read by `install.sh` only |
| `~/.local/share/agent-sandbox/tools/` | the tools environment `install.sh` builds; its slot in use is the one exception to "never bound": read-only |

### The tools environment

`install.sh` builds a small conda-forge environment with its own micromamba, and every
sandbox finds its commands on PATH, under every preset, `--preset native` included. It
exists for command-line tools a distribution ships too old -- `gh` above all: Ubuntu's
2.46 lacks `gh pr checks --json` -- and that are not any project's requirement, so they
belong in no project's env.

`~/.config/agent-sandbox/tools.txt` lists its packages, one conda package spec per line
(`gh`, `gh >=2.60`, `conda-forge::ripgrep`); `#` starts a comment and blank lines are
ignored. With no such file the list is `gh`; a file listing none removes the
environment at the next run. The file is yours and `install.sh` never writes it. Every
`install.sh` run rebuilds the environment from conda-forge, so a change to the list,
and a newer release of a listed tool, takes effect at the next run.

Inside the sandbox the environment is read-only and its `bin/` goes after the conda env
(and micromamba, under `[conda] base = sandbox`) and after your own directories on
PATH, right before the first system directory (`/usr/...`, `/bin`, `/sbin`,
`/snap/bin`): a project's own `gh` wins, and the tools environment's wins over the
distribution's. That `bin/` holds links to the listed packages' own commands only, not
their dependencies' -- a tool that pulls in Python puts no `python3` ahead of
`/usr/bin/python3`.

It lives in two slots, `tools/a/` and `tools/b/`, and `tools/current` names the one in
use: a run builds the other one and switches only when the build worked, so a failed
update (no network, a spec conda-forge cannot solve) warns and changes nothing, and a
first build that fails leaves sandboxes as they were. A running sandbox keeps the slot
it started with until the second run after its start rebuilds that slot. `--uninstall` removes it with the rest of
`~/.local/share/agent-sandbox`.
