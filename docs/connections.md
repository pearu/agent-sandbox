# Sandboxes, sources and connections

**Status: the scale, the presets, roles, the keeper, background sessions inside a role, the role verbs, the `run-scoped` and `join-scoped` storage scopes and the `config`, `transcripts` and `logs` channels are implemented and under test (see [Roles, the keeper and storage](#roles-the-keeper-and-storage)).** A model for controlling what passes between agent
sessions on one machine, written after the cross-project leak study
([cross-project-channels.md](cross-project-channels.md)) had measured every channel it could
find under `~/.claude` and the per-project copy of Claude Code's config file had shipped in
0.2.1. It replaces "a disposition per path under the agent's state directory" with three
objects and one scale, so that the default for a path nobody has classified is *private to the
sandbox* rather than *shared*, and so that the same model serves two agents of the same kind,
two roles on one project, and two agents of different kinds.

The goal it serves is the one the study states: **control of the inference between projects
and sessions**. Inference here means one session's material steering another's behaviour;
disclosure means content crossing without necessarily steering anything. Both are channels;
the model treats them alike.

## Why not paths

The engine's isolation today is a list of paths under `~/.claude`, each with a disposition
(`tmpfs`, `copyout`, `append`, `scoped`, and since 0.2.1 `copy` for the config file). The
list is ours to maintain and lags what upstream adds; the study found six documented paths
the list had never heard of, all shared. Its default for an unknown path is *shared*, which
is the wrong direction for a sandbox, and every new path is a new decision. Undocumented
behaviour can only be measured for its effects, and missing an effect is likely.

Turned around: if a sandbox is an **installation** of the agent with its own state directory,
then an unknown path is private by construction, and only what the user **connects** needs
to be understood. The list of internals shrinks to the few paths a connection maps onto,
and the study measures connections and escapes instead of an inventory.

## The three objects

**A sandbox** is an installation of one agent: its own configuration and state directory,
created once from a source and then its own. Inside, it is bound where the agent expects
its state (`~/.claude` for Claude Code, with `CLAUDE_CONFIG_DIR` pointing there). On the
host it lives under the engine's state directory, `~/.local/state/agent-sandbox/<profile>/`,
which is a control path: never bound into any sandbox, refused by `[ro]`/`[rw]`.

A sandbox is keyed by **project and role**: `<project slug>/<role>`, with `default` as the
role nobody names. Two roles on one project are two sandboxes that share the project
directory and nothing else unless connected; that is issue #55, a reviewer that must not see
the implementer's accumulated memory, as a special case of this model rather than a feature
of its own. Sandboxes shared by several projects are not in this proposal; if they arrive,
the key gains a name and nothing else changes.

**A source** is where a sandbox is created from, and where a connection reads from: the
user's native installation (`~/.claude`), another sandbox (`<project>/<role>`), or a directory
the user curates for the purpose.

**A connection** opens one **channel** between a sandbox and a source, under a **mode** from
the scale below. A channel is named by what it carries, never by a path; the mapping from a
channel to the agent's internal path is the profile's business and appears nowhere else.
No connection for a channel means `own`.

| channel | what it carries | Claude Code path (profile's mapping) |
|---|---|---|
| identity | the login | `.credentials.json`; `gh/`, `ide/` as tooling that exists for sandboxed use |
| project | the working tree | `$CWD` |
| instructions | user-level instructions | `CLAUDE.md`, `rules/` |
| settings | user-level settings, hooks, style and model selection | `settings.json`, `output-styles/` |
| skills | skills and slash commands | `skills/`, `commands/` |
| agents | subagent definitions | `agents/` |
| workflows | agent-authored workflow scripts | `workflows/` |
| plugins | installed plugins and marketplaces | `plugins/` |
| config | the config file: app state, the account, the user-level MCP servers, this project's entry | `~/.claude.json`, bound inside at `~/.claude/.claude.json` (#119) |
| tools | user-level MCP servers | part of `config`: the `mcpServers` block of that file (#132) |
| memory | per-project auto memory | `projects/<slug>/memory/`; `agent-memory/` once its layout is known |
| transcripts | conversations, plans, file history, prompt history | `projects/<slug>/` (memory bound on top), `plans/`, `file-history/`, `history.jsonl` |
| logs | what the user's own hooks write | `responses.log`, `alerts.log` |
| artefacts | downloads, uploads, task lists | `downloads/`, `uploads/`, `tasks/` |

Two things in the state directory belong to no channel. **Per-session scratch** (`sessions/`,
`session-env/`, `jobs/`, `shell-snapshots/`, `debug/`, `paste-cache/`, `daemon/`) stays what
the isolate spec makes of it: replaced per launch, closed to other sessions, and discarded at
exit. (File history, plans, prompt history and the hook logs used to be merged back at exit;
since #120 they are the `transcripts` and `logs` channels.) **Server-owned state** (`skills/synced/`, `plugins/synced/`,
`cache/`, `telemetry/`, `backups/`, the usage and stats files) is written by Claude Code
itself from the service or as caches; it is private to each sandbox and never connected. A
sandbox syncs its own server skills on first start, measured at 3.6 MB on this host.

## The scale

> Why these names and not shorter ones: [Why these names](#why-these-names).

Every connection has a mode. The modes are ordered by how much of the source A reaches the
sandbox B, and whether anything of B reaches A:

```
own  <  seed-only  <  copy  <  copy-on-write  <  read-only  <  read-write
```

| mode | A → B | B → A | B's own state | needs |
|---|---|---|---|---|
| `own` | never | never | B's own, from nothing | nothing |
| `seed-only` | once, when B's store is first made | never | private, persistent | a seed |
| `copy` | at launch, where B has not changed the file | never | private, persistent | a seed and a three-way refresh |
| `copy-on-write` | live, for every file B has not written | never | private, persistent | an overlay, or its emulation |
| `read-only` | live | never | none | a read-only bind |
| `read-write` | live | live | shared with A | a read-write bind |

Definitions, so the sub-decisions stop multiplying:

- **`seed-only`**: B's store is copied from A once, when it is first created, and is B's
  from then on. A's later changes never arrive, so there is nothing to conflict and nothing
  to warn about; a `reset` discards the store and the next launch seeds it again. It is
  what `copy` amounts to on a file B writes at every launch, minus the warning `copy` would
  then give at every launch.
- **`copy`**: B's files are seeded once from A. At later launches A's changes arrive for
  every file B has not touched; a file B changed stays B's; when both changed, B's stays and
  the launch says so; a file A deleted goes from B if B never touched it; a file B deleted
  stays deleted. Nothing is ever merged textually, nothing is ever written back to A, and
  nothing of B's is overwritten without a word. A `reset` re-seeds a file, a channel or a
  sandbox from A on request. This is the rule the config file's `mcpServers` refresh already
  follows for one key, applied per file.
- **`copy-on-write`**: B reads A's files through until it writes one; the write creates
  B's private copy, which shadows A's file from then on. A's edits reach B live for every
  unshadowed file, so it needs no refresh step at all; a shadowed file is B's until B
  deletes its copy (which exposes A's again) or `reset`s it. The launch warns when a
  shadowed file has since changed in A. Between `copy` and `read-only` on the scale: it
  reads like `read-only`, writes like `copy`. A native edit to a shadowed file is the one thing it hides, and
  it hides it loudly.
- **`read-only`**: A's files, live. B cannot author at that channel; for `settings` this
  breaks `/model` and permission saves, the cost of choosing it for that channel.
- **`read-write`**: A and B steer each other with no delay. Races are the
  agent's own, exactly as between two native sessions; the sandbox adds no arbitration.
- **`own`**: no connection. B has whatever it created itself at that channel.

Two connections are **mandatory** and fixed:

- **identity** is `read-write` to native. Two agents of one user are one login; cloning a refresh
  token multiplies a race (the study's harness notes it), so the token stays one file. This
  is the floor of the scale: "completely independent" sandboxes of one user still share who
  they are. Full independence needs two accounts, which is outside this tool. `hide` keeps
  the tooling parts (`gh/`, `ide/`) out of a sandbox that should not have them.
- **project** is `read-write` to the working tree, by definition: it is where agents are meant to
  communicate, including agents of different kinds, through files and a document convention
  such as `AGENTS.md`. Roles on one project share it. Exclusions inside it (a reviewer that
  must not read `.git`, issue #55) are a detail of this connection, not a mode.

## Invariants

1. **A connection moves one channel along the scale and does nothing else.** No knob has a
   side effect on another channel, so positions compose without interaction.
2. **The independent extreme is reachable for every channel the study lists.** A channel
   with no `own` is a gap. An unclassified path is private by construction, which is how
   this invariant holds for paths nobody has classified yet.
3. **Every step up the scale from the default is a widening**: trust-gated in the dot-file,
   ungated at launch. Every step down is free. This is the rule the existing knobs follow.
4. **Agents communicate only through `read-write` connections and the project directory.** A
   `read-write` connection's interface is the agent's own file format; the sandbox neither adds
   nor promises arbitration. Network-mediated communication has no interface at all and is
   governed by the network mode alone.
5. **A mode is B's view of its source.** Two sandboxes at `read-write` see each other; one at
   `copy` beside one at `read-write` receives the other's writes at its next launch and sends
   nothing back. Asymmetric flows are predictable because each side's mode is its own.

## What each channel carries

The table below places each channel under each preset. This is the evidence for those
placements, taken from Anthropic's documentation rather than from reading our own code --
which matters, because two of these channels are consumed with **no user action at all**,
and one is explicitly exempted from the trust prompt Claude Code shows for project files.

| channel | how it reaches the model | what the docs restrict or promise |
|---|---|---|
| **instructions** — `CLAUDE.md`, `rules/` | loaded into **every session** | "User-scope memory files, such as `~/.claude/CLAUDE.md` and `~/.claude/rules/`, are files you wrote yourself... Claude Code loads their imports **without the dialog** and trusts them like the rest of your personal configuration" ([memory](https://code.claude.com/docs/en/memory)) |
| **agents** — `agents/*.md` | Claude **delegates automatically**, choosing by each subagent's description | a subagent runs "with a custom system prompt, **specific tool access, and independent permissions**" ([sub-agents](https://code.claude.com/docs/en/sub-agents)) |
| **settings** — `settings.json`, `output-styles/` | a style is chosen with `/output-style` and the **selection is persisted**, applying to later sessions | the command also works headless, in Agent SDK sessions, and over Remote Control ([output styles](https://code.claude.com/docs/en/output-styles)) |
| **skills** — `skills/`, `commands/` | invoked as `/name`; "Claude invokes some bundled skills automatically" | also loaded from `.claude/skills/` in the working directory **and every parent up to the repository root** ([skills](https://code.claude.com/docs/en/skills)) |
| **workflows** — `workflows/*.js` | "a JavaScript script that orchestrates many subagents... **Claude writes the script**" | `/deep-research` "runs only when you invoke it" -- and "Before v2.1.218, Claude could also start it on its own" ([workflows](https://code.claude.com/docs/en/workflows)) |
| **plugins** — `plugins/` | auto-load rules per plugin kind | carries its own **workspace-trust requirement**, so the agent already gates this one ([plugins](https://code.claude.com/docs/en/plugins-reference)) |

**This is why `inherit` is the default.** `instructions` and `agents` are consumed with no
user action, and the first is explicitly exempt from the trust dialog. A sandbox able to
write them does not merely leak across projects: it injects into channels Claude Code has
decided not to question, in every project, for every later session. `copy-on-write` is what
keeps the sandbox's writes its own.

### The channels are not independent

The table above reads as six separate things. Two of them reach into the others, both
measured rather than inferred (#112), and a preset is only as sound as the independence
it assumes -- which is the real cost of tagging a channel with a position: it requires
knowing what that channel is related to.

- **`skills` can supply `agents` and `commands`.** Any folder under a skills directory
  containing a `.claude-plugin/plugin.json` loads as a plugin, and such a plugin may
  bundle agents. Measured: with `agents = own`, `~/.claude/agents/` is empty inside as
  intended, while a plugin-bundled `skills/<plug>/agents/zorbagent.md` is still there.
  Closing the agents channel does not close agent definitions. A `plugin.json` may also
  declare `commands`, which *replaces* the default `commands/`.
- **`instructions` can reach outside itself.** A `CLAUDE.md` may `@import` other files,
  relative or **absolute**, expanded into context at launch. So the channel's effective
  extent is not the paths it declares. Measured: when the target is missing the import
  is **silent** -- no error, no warning, exit 0, and only the literal `@path` line
  remains in the instructions.

The silence is what makes the second one matter: splitting that group does not fail, it
produces quietly incomplete instructions.

A launch-time check is possible for it, but has to be narrow or it becomes noise. A
dangling import is often DELIBERATE -- a user may import a host-specific file precisely
so that it does not enter a sandboxed model. The case worth reporting is narrower: an
import whose target lies inside a channel positioned DIFFERENTLY from the importing one,
which is a split group rather than an intended exclusion. That is cheap to test and does
not fire on the intentional case.

**Two things this model does not cover, and should say so.**

- **A managed tier above the user's.** Instructions have a policy scope outside `~/.claude`
  entirely: `/etc/claude-code/CLAUDE.md` on Linux and WSL, with OS equivalents elsewhere. It
  is not a channel here. The engine binds `/etc` read-only, so an organisation's
  instructions do reach a sandboxed session and cannot be rewritten from inside -- the right
  outcome, arrived at incidentally rather than by design.
- **`skills` and `commands` are not purely user-level.** They also load from the project
  tree, walking up to the repository root, so part of that channel arrives through the
  always-live project bind rather than through the channel at all.

## Presets

A preset is a position for every channel at once. Three are worth naming; everything in
between is a preset plus overrides. Running without a sandbox is not one of them: that is
`--preset none`, the flag only (see [Background sessions](#background-sessions-123)).

| channel | `isolated` | `inherit` | `shared` |
|---|---|---|---|
| identity | read-write native | read-write native | read-write native |
| project | read-write | read-write | read-write |
| instructions, settings, skills, agents, workflows, plugins | own | `copy-on-write` from native, `copy` where no overlay | read-write native |
| config (tools part of it) | own | `seed-only` from native, this project's entry only | `seed-only` from native, this project's entry only |
| memory | own only | own, plus `read-only` from named sandboxes (`[share-memory]`) | read-write (`memory_default = shared`) |
| transcripts (conversations, file history, plans, prompt history) | own | own | own |
| logs (the user's hook logs) | own | own | own |
| artefacts | own | own | read-write |
| network | `own` | `proxy` | `proxy` or `open` |

**This table is where the model is going, not what the engine does today.** The rows
implemented are the channels the engine manages as connections — `instructions, settings,
skills, agents, workflows, plugins`, `config`, `transcripts` and `logs` — and a preset moves
them and nothing else. `transcripts` is `own` under `shared` as well: its prompt history
holds every project's prompts, and `shared` is "the engine before 0.3", which filtered them.
identity, project, memory and artefacts each still have machinery
of their own and keep their own controls until they are folded in, one at a time, with the
study to show it. `docs/config.md` documents the rows that are live, so a user reading it
is never told a channel is positioned when it is not.

### `native`, the fourth preset, and why the ladder needs both ends

`shared` is the widest position that is *useful*, not the widest that exists. Native
Claude Code additionally shares a good deal that nobody chose to share: the configuration
file bound whole, the daemon control directory, session environments, shell snapshots, the
paste cache, prompt history, plans, file history. Those are open because nothing closed
them, and the leak study measured what each of them carries. `shared` deliberately leaves
them shut.

`native` is the preset that does not. Its contract is exact and is the reason to build it:

> **`--preset native` must behave identically to `--preset none`, while going through
> every sandbox mechanism.** A difference between the two is a bug in agent-sandbox.

That makes it a differential oracle, which is a test this repository does not otherwise
have: it catches the sandbox quietly *distorting* the agent rather than failing outright.
It also bisects a failure — something that breaks under `native` but works under
`--preset none` is broken by a mechanism (binds, seccomp, the proxy) rather than by state
isolation, because `native` holds state at "hide nothing".

And it makes the scale a workflow rather than a taxonomy. With both extremes genuinely
reachable, a policy can be built from either end: start at `native` and close channels
until it is tight enough, or start at `isolated` and open them until the job runs.
That only works if the ends are real positions rather than approximations.

Two requirements, both from what it reopens, and both as built:

- **Loud on every launch**, not a suppressible line. It turns isolation off wholesale.
- **The `--preset` flag only.** The design said trust-gated from the environment; what
  shipped is stricter, because a trust gate answers "is this project allowed to" and the
  problem here is different — `AGENT_SANDBOX_PRESET=native` in a shell profile reopens
  every measured channel for every project, silently and forever, and there is no project
  to approve. Refusing the environment and the project file outright costs a user who
  genuinely wants it one flag per launch, which is the right price. The refusal says why.

`native` means parity of STATE; the egress proxy, the syscall filter and the working-tree
bind still apply, exactly as `[net] mode = open` means no allowlist rather than no sandbox.

#### What parity actually cost

Every channel at `read-write` was the easy part and was not nearly enough. Writing the
differential test (`tests/integration/native-parity.bats`) found three divergences that
the preset, believed finished, still had — each one invisible from inside a single run:

- **`--clearenv` dropped the user's environment.** The engine re-exports a locale, network
  and profile allowlist; everything else was gone. No allowlist can predict what an agent
  reads — its own knobs, an `EDITOR`, some tool's token — and a variable that vanishes
  changes behaviour without a message. `native` now forwards every exported name except
  the five the engine pins (`HOME`, `USER`, `PATH`, `TERM`, `AGENT_SANDBOX`).
- **`$HOME` was still a tmpfs.** Channels cover the state a profile declares; `~/.gitconfig`,
  `~/.npmrc`, `~/.ssh/config` and everything else are exactly the state it does not, and
  they simply did not exist inside. `native` binds the host's own `$HOME`, writable — which
  also removes the read-only remount, and with it the `CLAUDE_CONFIG_DIR` relocation that
  exists only because a lock and a rename beside a read-only config file are lost (#91).
- **`/tmp` and `/var/tmp` were private.** Work left there by an earlier native run, or by
  anything else on the host, was invisible.

One gap remains, knowingly: `/run` stays a tmpfs with only `$XDG_RUNTIME_DIR` bound
through. It is root-owned, so binding it whole leaves nowhere to create the sandbox's own
briefing, and the launch dies. The rest of `/run` is system sockets a user-level agent does
not reach.

The pattern in all three is the same and is the argument for the preset existing: they are
not failures. Nothing crashed, nothing warned, and every other test passed. They are the
sandbox quietly handing the agent a different world, which is the one class of bug this
repository had no way to see.

`inherit` is the fidelity principle stated as connections: a sandbox created from native
with these connections behaves like a native Claude Code whose configuration is the user's,
read live, with its own writes kept to itself. `isolated` is the two mandatory
connections and nothing else. `shared` is the engine before 0.2.

**`shared` deserves more warning than "the engine before 0.2" gives it.** At
`read-write`, a sandboxed session can write `~/.claude/rules/` or an `agents/*.md`
carrying its own tool access -- and per the table above, both are consumed
automatically, in every project, and the instruction files are trusted *without the
dialog Claude Code shows for project files*. That is not only a cross-project leak; it
is a write into a channel the agent has decided not to question. `shared` is for
restoring old behaviour deliberately, not for convenience.

## Why these names

**Implemented in 0.3.** The names used everywhere in this document are the ones the engine
uses. This section keeps the reasoning, which is the part that would otherwise be lost: a
name that reads oddly gets renamed again by someone who cannot see why it was chosen.

The scale never shipped under its old names -- v0.2.1 contains no `--preset`, no
`AGENT_SANDBOX_PRESET` and no connections parser at all -- so the rename cost nobody a
migration. It had to land before 0.3.0 for exactly that reason.

### The ladder is boundary permeability, and it is direction-dependent

A preset says how permeable this sandbox's boundary is, not which files are listed. That
reframing is what makes the ends belong on one axis:

| today | becomes | what it means |
|---|---|---|
| `independent` | `isolated` | the boundary is sealed: nothing of yours reaches the sandbox, nothing of the sandbox reaches you |
| `default` | `inherit` | one-way: your files are read live, the sandbox's writes stay inside |
| `shared` | `shared` | both directions, for everything the boundary covers |
| `native` | `native` | the whole boundary open, including the parts no channel declares |
| `--preset none` | `none` | there is no boundary object at all |

```
isolated  <  inherit  <  shared  <  native        ordered
none                                              incomparable
```

`none` is deliberately outside the order rather than below `isolated`: it is not a
permeability, it is the absence of the thing that has one. `native` and `none` are
different positions and the differential test depends on the difference — `native` is a
sandbox that isolates nothing, `none` is no sandbox.

`inherit` earns its name from the direction. `isolated` and `shared` say what crosses;
only the middle rung needs to say *which way*, and inheritance already means "comes from
the parent, does not go back".

### Why the mode is `own`, and why the abbreviations are spelled out

    own  <  seed-only  <  copy  <  copy-on-write  <  read-only  <  read-write

The scale says what the sandbox has at a path in relation to yours: a copy, a
copy-on-write layer, read-only access, read-write access -- and, at the bottom, its own,
with no relation at all. `none` answered that question with "nothing", which is true and
tells the reader less than "its own". `closed` was considered and answers a different
question, in an open/closed metaphor the other four do not share.

Spelling out `cow`, `ro` and `live` follows the same rule as the scope names: no
abbreviations and no aliases. A dotfile is written once and read by people who did not
write it.

Renaming off `none` is also what frees that word for the terminal preset, which is not
built yet. With both in play, `preset = none` (no sandbox at all) and `skills = none`
(nothing of yours) would be the same word at opposite ends of one model, and the failure
mode is someone writing `preset = none` for maximum isolation and getting none of it.

The old spellings are refused rather than aliased, and each refusal names its replacement
(`_as_mode_renamed`, `_as_preset_renamed`). That is a courtesy to anyone tracking `main`
between 0.2.1 and 0.3.0, not a compatibility promise -- there is no released version to be
compatible with.

**The order is how much of YOUR files reach the sandbox, not what the sandbox may do.**
Spelled out, that reads oddly at one step -- a sandbox can write under `copy-on-write` but
not under `read-only`, yet `read-only` is the higher rung -- because `read-only` hands it
the real file while `copy-on-write` gives it only a shadow of one.

Two candidates were rejected. `blocked` already means *egress denied* here: there is a
`~/.config/agent-sandbox/blocked.log`, the leak study uses it throughout for refused calls,
and the agent's own briefing says "A blocked action is deliberate, so do not retry it". A
channel at this mode denies nothing -- the sandbox gets a working, writable, persistent
directory at that path; it simply is not yours. And `private` reads as *per session*, when
this slot is per sandbox and persists across every session of it.

### Why the transparency principle became the fidelity principle

The word is needed for a preset, and the principle was under-placed anyway. It is not a
property of one rung: the sandbox should reproduce the native experience faithfully, minus
what the user explicitly asked to change. `inherit` expresses that for configuration and
`native` asserts it absolutely, which is why a difference between `--preset native` and
`--preset none` is a bug rather than a preference.

## Path declarations

A `[connect]` key that contains `/` names a **path** instead of a channel, with the same
modes ([#106](https://github.com/pearu/agent-sandbox/issues/106)):

```ini
[connect]
./scratch/ = own         # a directory of the sandbox's own, at ./scratch
./AGENT.md = read-only   # a file
/data = read-only        # what [ro] /data does today
instructions = copy-on-write native   # no slash: a channel name, exactly as before
```

**The lexical rule** is what keeps a typo safe. A key with no `/` is a channel name, so
`instrutions = own` still refuses the launch instead of declaring something; `AGENT.md =
own` is refused the same way and `./AGENT.md = own` is the path form. A trailing `/` says
the path must be a directory. A mistyped *path* can still declare an unwanted one, which
is the exposure `[ro]` already carries.

**The key is always a path inside the sandbox**, and with no source given the source is
the same path outside. A relative key is relative to the project, whichever form it came
from; `~` is `$HOME`. Inside, `$HOME` is empty, so `~/notes/ = own` is sandbox-only storage
while `~/notes = read-only` puts your real one there; a key under `$HOME`, outside the
project and every channel, says which of the two it is at launch. No explicit source is
accepted yet: `outside:<path>` is a follow-up.

**Every mode is checked alike, `own` included**, although `own` exposes nothing — one
rule is easier to state and to trust, and loosening it later breaks no one. It is
`[ro]`/`[rw]`'s rule (not `/`, `$HOME` or a parent of it; nothing that is, is inside or
contains a secret store or the sandbox's control plane) plus one of its own: **not the
project or a parent of it**, because a declaration is bound after the project and would
cover it. Both the key and what it resolves to are checked, and the resolved path is
checked again at bind time, so a symlink repointed in between cannot mount a refused
target. Two declarations one inside the other are refused; the same path declared twice
is an override, later wins, as for a channel.

**A path that does not exist is skipped**, with a notice, and takes effect at the first
launch after it does — every mode but `own` promises something about the path outside,
and the engine creating it there to have something to bind would break that. The one
exception is a trailing `/` under `own`, which needs nothing outside and creates the
sandbox's directory. bwrap still needs a mount point for it, so an empty directory
appears at that path outside too — in the project, for `./scratch/` — the same side
effect a narrowed channel has.

**A file** is allowed, with two permanent limits said at launch: it is a mount point, so
it cannot be deleted or renamed from inside, and `copy-on-write` on a file is `copy`,
since overlayfs cannot stack on one file.

**Inside a channel, or over one**, a declaration is allowed, says so, and wins there:
`~/.claude/rules/team/ = own` under `instructions = read-only` gives the sandbox its own
`team/` and leaves the rest of `rules/` read-only.

**Presets never move a declaration.** A preset positions the channels the profile
declares; a path has no position until someone writes one.

Declarations are bound with the `[ro]`/`[rw]` binds they are meant to replace — after the
working tree, which would otherwise cover every declaration inside the project. That was
measured the first time this ran under the real bwrap: bound earlier, `./data =
read-only` was writable and `./scratch/ = own` showed the project's files.

A directory path at `copy-on-write` is an overlay the keeper mounts at the declared path,
as it does a channel's: the project's files read through, live, and a write lands in the
role's upper layer and shadows the source's file from then on. Where the overlay is off or
this bubblewrap cannot mount one, it is `copy` with a message saying so. `--reset ./scratch/` takes a
declaration back to its source, as `--reset <channel>` does a channel (#126). A per-role scratchpad is already what
`./scratch/ = own` gives, since a role is the instance.

### Nested sandboxes: persistence is not enforced

Every source and check resolves in the namespace where the engine runs, so an engine
inside a sandbox applies these rules to the `/`, `$HOME` and project it sees, and can
only bind what the outer sandbox shows it. Nesting only narrows.

It also means **persistence across relaunches cannot be enforced when nesting.** The inner
engine's state directory is under its `$HOME`, which in the outer sandbox is a tmpfs, and
the outer never binds its own state directory in. So everything an inner sandbox keeps —
`own` slots, `copy` copies, `copy-on-write` upper layers, for paths and channels alike —
lasts as long as the outer session and no longer.

## Roles, the keeper and storage

**Built:** roles, the keeper, background sessions inside the role, the role verbs, `seed-only`,
the config file, no merge-back and the storage scopes (`join-scoped` for `own`, #147). The section records the decisions of 2026-09-24 to 28, filed
as [#119](https://github.com/pearu/agent-sandbox/issues/119),
[#120](https://github.com/pearu/agent-sandbox/issues/120),
[#121](https://github.com/pearu/agent-sandbox/issues/121),
[#123](https://github.com/pearu/agent-sandbox/issues/123),
[#125](https://github.com/pearu/agent-sandbox/issues/125) and
[#126](https://github.com/pearu/agent-sandbox/issues/126), in the vocabulary of
[glossary.md](glossary.md). It replaces the earlier "Scope and roles" section: the
foreground/background scope axis and the `<scope>` key segment it planned are withdrawn.

### A role is one launch

- A **role** is a named, persistent instance of a project under a policy: `asb --role
  impl-1 claude`. The sandbox key stays `<project slug>/<role>`, and `default` is the unnamed role.
  What the engine calls a launch is the role's running instance; "launch" stays internal.
- **Policy is selected by glob and section order.** *Built* for `[sandbox]` and `[connect]`:
  any section may take a role suffix, `[<section>:<glob>]`, which is that section for the
  role names the glob matches, applied after the unsuffixed one, later overriding earlier,
  per key. That is all the inheritance there is: general sections first, specific ones last.
  A name matching no suffixed section is refused, but only when suffixed sections exist;
  `[connect:*]` accepts every name. `[sandbox] role` names the project's default role. There
  is no `[role:…]` section: it would say nothing the suffix does not.
- **The name is the identity; the policy is the variable part.** A role's policy may change
  between runs. A store belongs to `(role, path, mode)`, so a channel that changes mode
  switches to that mode's store; the previous store is kept, unbound, until `--reset` or
  `--delete`. A snapshot before a policy change is what `clone:` is for (#115).
- **Claude is an app like any other.** A Claude session id is derived from the role (the
  first session's), never the reverse, and one role can hold several Claude sessions
  (`/clear`, `/branch`, `--fork-session`, `claude` started inside `--exec bash`).
  `asb --role foo claude -r` lists foo's sessions; a bare `claude -r` lists native ones only.

### The keeper: one running instance per role (#121)

*Built.*

- The running instance is a **keeper**: a process that holds every namespace of the sandbox
  and does nothing else. Every app, the first included, is **joined** into it. The keeper
  exits when nothing is joined, after a grace of two seconds (`AGENT_SANDBOX_KEEPER_GRACE`),
  under a lock, so a join in progress is never cut off and commands run one after another
  share one launch.
- A joined app is the keeper's equal: the same mounts, working directory, uid and gid,
  capabilities, `no_new_privs` and seccomp filter. The join is `setns` from `python3`
  (`components/join.py`): bwrap nests a capability-less user namespace when it is given
  `--dev /dev`, so no process inside lives in the namespace that owns the mounts and
  `nsenter` has nothing to target. `python3` is therefore needed on `PATH` to launch at all,
  and the engine says so before it builds anything.
- **The environment is the keeper's**, except what describes the terminal the join came
  from: `TERM` and the locale group (`LANG`, `LC_*`, `TZ`, `COLORTERM`, `NO_COLOR`,
  `FORCE_COLOR`), set or unset as in the joining shell. Everything else — `HOME`, `PATH`,
  the conda variables, the proxy and CA variables, the profile's own, the
  `AGENT_SANDBOX_FORWARD` names — describes the sandbox. A join's environment is fixed when
  it starts; a later join never changes an earlier one's. The working directory needs no
  rule: the sandbox key is the invocation's directory, so a join from another directory is
  another project's keeper.
- **Policy is fixed when the keeper starts.** A join may *repeat* it, not change it: only the
  knobs this invocation set, by flag or environment, are compared with the keeper's, and a
  different value is refused, naming the knob; a listed grant (`--allow`, `--ssh`, ports,
  `[ro]`/`[rw]` paths) must be one the keeper has. A bare join always joins. A dot-file
  changed since the keeper started warns and joins: it is standing policy and applies at
  the next keeper by itself, whereas a flag is a request for this invocation, with no next
  keeper to apply to. Both rules protect what is joined: a keeper in its grace, with nothing
  joined, is ended and replaced by an invocation with another policy or under a changed
  dot-file, so running commands one after another with different flags just works.
- **A join reads the keeper's dot-file.** The keeper keeps a copy of the approved
  `.agent-sandbox` it started with, and a join parses that copy. So an edit to the live
  file that is not yet approved does not refuse a join: the trust gate exists because an
  ignored file would fall back to the defaults, and a join falls back to nothing — its
  policy is the keeper's. `--trust` matters at the next keeper, where the live file is
  read again. The live file is still read to find the role when no `--role` or
  `AGENT_SANDBOX_ROLE` names it, and then only an approved file is read, so there an
  unapproved edit refuses the join as it refuses a launch.
- **A file bound on its own shows the file as it was when the keeper started.** A bind
  holds the inode it was made on, and a native save by temp file and rename (how editors
  and Claude Code write) makes a new one, so `read-only` file paths (`CLAUDE.md`,
  `settings.json`) and the relocated `config = read-write` do not see such a save until
  the next keeper; a save in place is seen at once. Directories, and a `read-write` file
  that is its own source (served by the directory bind around it, with no bind of its
  own), are live. This was already true within one launch; with the keeper a later
  terminal is inside that launch too. Rebinding a replaced file from the keeper's host
  side is a follow-up.
- **Per-launch state is per keeper**: the session directory, the proxy token, the `--allow`
  include, the ssh agent and its `--ssh-timeout`, the briefing. A join's own hook settings
  (when it passes `--settings`) get a file of their own beside the briefing.
- `native` has a keeper too: it is a preset, and parity is about what the agent sees. The
  bypass is `none`, which has no bwrap.
- Two running instances of one role never exist, so `--exec` beside a running agent is a
  join, and the undefined case of two overlays over one upper directory has nowhere to
  arise. Two Claude processes on one conversation behave as they do natively — measured: the
  second marks the first's in-flight tool call interrupted, the conversation forks, and the
  next resume follows the branch of the process that exited last — and the consequences
  are the user's.
- The keeper subsumes the holder: it mounts the channel overlays at their real paths, and
  the overlays of directory paths declared `copy-on-write`.
- Ctrl-C at a join ends that join's command, not the launch: the join passes the
  terminal's signals to its own process group, and the keeper ignores them.
- `--reset` is refused while anything is joined; an idle keeper is ended first.
- Its host side is a supervisor, a background copy of the engine that started it: it owns
  the launch's exit (the session directory, the ssh agent, the mount-point files) and writes
  `<sandbox>/keeper.log`, which a launch that fails to start prints.

### Background sessions (#123)

*Built.*

- `asb --role x claude --bg` is "ensure x's keeper, join it, run `claude --bg` there". The daemon,
  its spare workers and pty hosts start inside (measured on 2.1.283), and `agents`, `attach`,
  `logs`, `stop`, `rm` and `daemon` join too. Each role has its own daemon. A `--bg` is
  sandboxed by default; `--preset none --bg` runs one natively.
- **The daemon holds the keeper**, as a join does: the keeper ends when no join remains *and*
  no daemon runs in its namespace (the profile says what one looks like). The daemon does not
  exit on its own when idle (measured), so a role with one ends by `--shutdown`.
- **A verb with no keeper starts none.** `agents` and `logs` answer that the role is not
  running (exit 0); `attach`, `stop`, `rm` and `daemon` refuse. A verb needs the dot-file
  only to find the role: when an unapproved edit keeps the file from being read and exactly
  one role of the project is running, that one is meant; with several, `--role` is asked for.
- **Workspace trust** is recorded in the role's own config file on `--bg`, when it is not
  there: a `--bg` cannot answer the prompt, and the user running it in the folder is the
  consent the prompt asks for.
- The wrapper machinery went: `--wrap`, `CLAUDE_CODE_PROCESS_WRAPPER`, the per-`--bg` project
  record and the pool clearing compensated for a daemon on the host. With it went `--sandbox`,
  `AGENT_SANDBOX_CLAUDE_SANDBOX` and `[claude] sandbox` (each refused, naming `--preset none`),
  the `@background` qualifier and the `<scope>` key segment: `x@background` is `x`. Native
  foreground and background sessions are meant to find each other (`--continue` loads a
  finished background session; `attach`; cross-session messaging), so they share the role.
- **`none`** is the fifth preset: no sandbox at all, the flag only (it drops the network
  policy and the syscall filter too, so no file or environment may set it), acted on before
  any project machinery.
- What survives from #104: the `none` preset, the glob grammar above, and keying the trust
  record on the project rather than the daemon's directory.

### The role verbs (#126)

*Built.* Each takes `--role x` (the default role when omitted), does its work and exits.

| verb | does | refused when |
|---|---|---|
| `--status` | the keeper (running since when, under which dot-file), the processes in its namespace (a host-side view), and the daemon's sessions (a joined `agents`); for a role not running, where its stores are | — |
| `--shutdown` | ends the keeper, every joined process, and the daemon with its pool | — |
| `--delete` | removes the role's stores, all of them; the next launch starts from the source | anything is joined, or a daemon runs: it names `--shutdown`. An idle keeper is ended first |
| `--reset <channel\|path>` | discards one store, in whatever mode, and takes the source's version again (for `own`, the empty start), keeping the rest; renamed from `--reset-connection`, which is refused with the new name, and takes a path declaration too | the same as `--delete` |

### Storage scope (#125)

Storage is keyed by the role, so the scope token of a connection (`channel = mode [source]
[scope]`) names only a *shorter* lifetime:

| written | lifetime |
|---|---|
| *(nothing)* | the role: across keepers, until `--delete` or `--reset` |
| `run-scoped` | one keeper: created when it starts, gone when it exits (#105). *Built*: the stores live under `<sandbox>/@run/`, cleared at every cold start (so a run killed with `-9` leaves nothing for the next) and by the supervisor once the launch has ended |
| `join-scoped` | one join: a joined command and everything it starts. *Built* for `own` (#147): the join gets a mount namespace of its own and binds its store over the path; the keeper shows an empty read-only mount point there. The stores reach the sandbox through a staging directory the keeper binds, and each moves out of it before its command starts, so no join can reach another's -- not even through the keeper payload's `/proc/<pid>/root`. Removed when the join ends, or at the supervisor's sweep for a join killed with `-9`. A seeded store per join is not built. Renamed from `process-scoped`, which is refused with the new name |

`sandbox-scoped` is not nameable (the default needs no word); `project-scoped` is a
`sandbox:<project>/<role>` source at `read-write`, not a scope; `session-scoped` is a role per
conversation. `read-write` with any scope stays refused: there is no store to scope.

### Modes and channels decided alongside

- **`seed-only`** (#120) is built: see [The scale](#the-scale).
- **No merge-back at exit** (#120) is built: `transcripts` (this project's conversations,
  `file-history/`, `plans/`, `history.jsonl`) and `logs` (the hook logs) are channels, `own`
  under every preset but `native`. A role starts with none of the native history;
  `transcripts = seed-only` seeds it once, the prompt history filtered to this project's
  records. The project's memory is bound on top of the role's store by its own machinery.
  Undo and plans work wherever the conversation can be resumed, which is the role.
- **The config file** (#119) is built: the `config` channel, see
  [config.md](config.md#the-config-file-the-config-channel). `seed-only` under `inherit` and
  `shared`, `own` under `isolated`; `user-mcp` is removed and `tools` is part of it (#132).

## Mechanisms

What exists: read-write and read-only binds of a source path at an inside path
(`profile_config_binds` with `SRC<TAB>DEST`, and the layered `profile_rw_binds`/`_ro_binds`);
`tmpfs` over a path for per-launch scratch; the engine's state
directory and its control-path protection; a seeded, filtered, refreshed copy of one file
(the config file, 0.2.1); the mount-point cleanup a file bind inside a read-write directory
needs. Measured on this host: the whole user-owned configuration copies into the session
tmpfs in under 0.1 s and under 20 MB, hashes in under 0.1 s, and a stat walk takes 20 ms.

What `copy-on-write` needs. bubblewrap gained `--overlay-src`, `--overlay`, `--tmp-overlay` and
`--ro-overlay` in release 0.11.0. Ubuntu 24.04 ships 0.9.0, which rejects them (measured);
26.04 ships 0.11.1. Measured on this host after a local no-change rebuild of Ubuntu's own
0.12.0-1 source for 24.04 (kernel 6.8, the installer's AppArmor profile, the engine's own
flags: `--unshare-all`, uid and gid mapping, `--cap-drop ALL`): an overlay mount inside
bubblewrap's user namespace works. Reads fall through to the lower directory, a write lands
in the upper directory and the lower file is untouched, `--tmp-overlay` discards the writes,
and the engine's integration suite passes unchanged on 0.12.0. So `copy-on-write` has two
implementations with one semantics:

- **real**: `--overlay-src <A> --overlay <upper> <work> <inside>` where bubblewrap allows it;
  reads live, writes to the upper directory, which is the sandbox's persistent private layer;
- **emulated**: a per-launch snapshot of A into the session tmpfs with the private layer
  copied over it, bound read-write; at exit, files that differ from the snapshot go to the
  layer. This is `copy` with a fresh seed every launch. It reads live only at launch, and
  its exit step is a failure point (the janitor runs it for orphans at the next launch, but a
  reboot first loses that session's changes). The measured costs above are its costs.

Claude Code on the real overlay, measured (2.1.274, bubblewrap 0.12.0, this host): a lower
layer holding a seeded config file, an instruction file and an empty `skills/`; the
credential file and `projects/` bound live over it; one `-p` turn. The turn succeeded and the
reply carried the token the lower layer's `CLAUDE.md` asked for, so reads through the overlay
reach the model. The config file was rewritten thirteen times by temp file and rename, all
inside the overlay, none failing; `settings.json` was copied up on first touch; the
server-synced skills and plugin markers, `backups/`, `sessions/` and the policy and
remote-settings files all landed in the upper layer, which is the per-sandbox privacy the
model wants for server-owned state; the lower layer was byte-identical afterwards; the
transcript went through the live `projects/` bind. The only failing calls were the skill
sync's unlink-then-rmdir on its staging directories, and the native trace shows the same
sequence. One mechanical detail for the engine: bubblewrap creates the mount points for
binds placed inside the overlay in the upper layer (an empty `.credentials.json`, a
`projects/` directory), so the placeholder cleanup that exists for file binds applies to the
upper directory as well.

Built: the **keeper** replaced the holder (see above). It holds every namespace of the
sandbox, not only the mounts, and apps are joined into it with `setns`
(`components/join.py`, from the measured recipe in `probes/join-launch.py`: the
user-namespace chain from the outermost down, each namespace right after entering its owner,
then the capability bounding set emptied, `no_new_privs` and the same seccomp filter, then
the keeper's environment and working directory).

`copy` needs the seed, a base manifest of what was last synced, and the three-way step at
launch; it has no exit step, since B writes its persistent copy directly. `read-only` and `read-write` are
binds. Every mode is per channel, and a channel that maps to several paths applies its mode to
each.

## The profile contract under this model

A profile declares four things and no dispositions:

1. where the agent keeps its state, and how to point the agent at the sandbox's copy of it
   (Claude Code: `~/.claude`, `CLAUDE_CONFIG_DIR`);
2. the **identity** paths, always connected `read-write` to native (Claude Code: `.credentials.json`;
   `gh/`, `ide/` as hideable tooling);
3. the **channel → path** table above, including what is server-owned state;
4. the **per-session scratch** the isolate spec replaces per launch (until #120 gives those
   paths modes of their own).

Everything else in today's profile, memory scoping and `[claude] hide`, becomes a connection statement or falls out of "private by
construction". A second profile fills in the same four items; nothing about the engine's
connection machinery is agent-specific.

## Knobs

The three forms every knob has today, in sketch. Existing keys stay as sugar for the
connection they mean.

```ini
[sandbox]
role = reviewer            # the project's default role; --role overrides it
preset = inherit           # isolated | inherit | shared

[connect:impl-*]           # [connect] for every role the glob matches;
skills = read-only         # later sections override earlier ones, per key

[overlay]
mode = auto                # auto | off -- what copy-on-write is implemented with

[connect]                  # channel = mode [source] [scope]; source: native | sandbox:<project>[/<role>] | outside:<path>
                           # scope: nothing (the role) | run-scoped | join-scoped
                           # a key with a `/` is a path: see "Path declarations"
instructions = copy-on-write native
skills = copy native
memory = read-only sandbox:~/git/acme/app   # what [share-memory] means today
config = own                                # what user-mcp = none meant (removed, #132)
artefacts = read-write native
./scratch/ = own                            # a path, not a channel
```

Launch-time forms: `--connect 'memory=read-only sandbox:...'` repeated, `AGENT_SANDBOX_CONNECT` with
the same syntax, `--role`, `--preset`, and `--overlay auto|off` with
`AGENT_SANDBOX_OVERLAY`, which wins if set in the shell as `AGENT_SANDBOX_SECCOMP` does.

**What the trust gate does and does not cover here.** The dot-file is parsed only when
approved, so `[connect]` grants nothing from an unreviewed file, and a step *up* the scale
written there is a widening the `--trust` review exists to show. The flag and the
environment variable are not gated and never have been, for any knob: they are the user's
own shell, and a user who can set them can equally run the agent unsandboxed. That
distinction costs nothing while every channel defaults to `read-write`, since no launch-time
form can widen anything. It starts to matter the day the `inherit` preset lowers those
defaults, because then `AGENT_SANDBOX_CONNECT` in a shell profile can quietly put a
channel back at `read-write` for every project. Whoever lands presets decides whether that stays
true and says so here.

`--reset skills` re-seeds one channel, and `--reset ./scratch/` one declared path; `--status`,
`--shutdown` and `--delete` are the role's own verbs (#126).

## What the study measures under this model

The experiments are planned in [connections-study.md](connections-study.md), whose
level-1 cells are this model's acceptance suite: one assertion per mode promise, scripted
and free, failing until the engine implements the mode. In outline:

- **Connections**: for each channel and mode, does content flow as the mode says, in each
  direction and at the stated time (launch or live)? The study's rows map directly: rows 5–9
  and 19–22 measured instructions, settings, skills, agents, workflows and plugins at `read-write`
  (T5 `obtained`, and T2/T6 `obtained` for the write half by construction); the same rows at
  `copy` and `copy-on-write` are the post-fork arm. Rows 1–4 and 16 measured memory and transcripts at
  `own` with memory's `read-only` share. Rows 10 and 11 measured tools and the config file, now at
  `copy`.
- **Escapes**: whatever reaches another sandbox outside any connection. Known: the daemon's
  directory keyed by uid (row 15's neighbour, issue #45), the MCP logs under `~/.cache` (a
  fresh tmpfs inside, so closed), the network (rows 13, 14a, 14b). New ones are the study's
  job; the model does not make them go away, it makes them the only thing left to find.

Results stay versioned by Claude Code major.minor and engine release, one document per
class, as decided for the study.

## Agents of different kinds

A `codex` profile declares its own four items. Between kinds, `identity` is per agent (two
logins), `project` is the shared channel and the only one with a common interface, the
working tree and its documents. Content-level channels do not translate: Claude Code's
auto memory and a `CLAUDE.md` have no counterpart another agent reads, so a connection from a
`claude` sandbox to a `codex` one is limited to what can be projected onto a path the target
reads, such as an instruction file bound where `AGENTS.md` is expected. That limit is stated
here rather than designed around; the project directory is where different agents meet.

## Migration from 0.2.1

- The per-project config file copy became the `config` channel's `seed-only` store of the
  `default` role (#119), moved there at the first launch that finds it.
- `[share-memory]` becomes `memory = ro sandbox:<project>`; `memory_default = shared` becomes
  the `shared` preset's memory row; `[claude] hide` becomes `own` for identity's tooling
  parts. `user-mcp` is removed and refused, naming `config = own` (#132).
- The isolate spec keeps the per-session scratch and drops everything that "private by
  construction" now covers.
- Existing measured results keep their meaning: they describe the `shared` preset.

## Settled while writing this

- **Overlay availability per host.** Real `copy-on-write` needs bubblewrap 0.11 or later. Ubuntu
  26.04 ships 0.11.1; 24.04 ships 0.9.0 and gets 0.12.0 through the rebuild recipe in
  [troubleshooting.md](troubleshooting.md#bubblewrap-older-than-0120-ubuntu-2404), which
  `install.sh` points at when it finds an older bubblewrap (0.12.0 also carries the fix for
  CVE-2026-87766, a setup-time symlink escape through directories the sandboxed process
  controls, which noble-security's 0.9.0-1ubuntu0.3 dropped again). Measured in CI:
  26.04 has overlay support, 24.04 ships 0.9.0 and 22.04 ships 0.6.1, so two of the three
  supported releases take the fallback unless their bubblewrap is upgraded. Nothing may
  therefore be designed as if the overlay path were the usual one.
- **Where there is no overlay, `copy-on-write` is `copy`** — not a separate emulation to write and
  keep in step. Compare the two definitions above and they differ in exactly one place.
  Across launches they are identical: a source change to an untouched file arrives, a
  touched file stays the sandbox's, a delete inside persists while the source keeps its
  copy, a conflict warns. The only divergence is *within* a running session, where an
  overlay reads through live and a snapshot cannot. So the fallback costs a branch and a
  notice rather than a subsystem, and the launch says which one it used. Nothing stops
  working on an old host, which is why no channel needs widening to `read-write` to accommodate
  one.

  Its cost is storage: `copy` duplicates the channel's files per sandbox where `copy-on-write`
  stores only what was written. Measured on one developer machine, the channels a
  connection covers came to 45 MB, dominated by `plugins/` at 7.4 MB and `skills/` at
  4.3 MB; instructions and settings are kilobytes.

  **`[overlay] mode = off`** forces the fallback on a host that could use an overlay. It
  exists because overlayfs is not usable everywhere bubblewrap supports it — some
  filesystems, some container hosts — and because a path that only ever runs on old
  machines is a path that rots. It can only move `copy-on-write` to `copy`, a step *down* the scale,
  so it needs no trust gate. It is also what lets the study compare the two
  implementations on one host, which is W8.
- **`plugins/`**: `copy-on-write`, like the rest of its group. Not `read-only`: Claude Code writes into
  `plugins/` at every start (the `synced/` markers and manifest, a rename onto
  `installed_plugins_v2.json`, a lock beside `known_marketplaces_claudeai.json`), and under
  `read-only` those fail silently at every launch, measured. Not `read-write`: a plugin bundles hooks and
  skills, and row 9 measured a plugin's hook firing in another project's sandbox, so the
  channel carries inference like `skills` does and `read-write` would keep T2 and T6 open for it.
  If overlay use is to be minimised, `copy` is the alternative that keeps the channel closed:
  plugins change rarely, so a refresh at launch loses nothing that matters.
- **Two sessions of one sandbox at once, under `copy-on-write`: there is one launch.** A
  sandbox is keyed by project and role, so two terminals on one project are two sessions of
  one sandbox; that is the ordinary case, and refusing it or serialising behind an
  interactive session would break a daily workflow to avoid a problem that can be dissolved
  instead. What overlayfs documents as undefined is two *independent mounts* over one upper
  directory, not many users of one mount. The first answer was the holder: mount a
  sandbox's overlays once, at staging paths, and let each session's bwrap inherit them
  (measured, and asserted on every platform CI covered, by a test now retired with it). The
  keeper replaced it: the second session is a process joined into the first one's launch,
  so it is in the same mount namespace and there is no second mount of anything —
  `tests/integration/keeper.bats` asserts that one mount namespace and one superblock are
  what both see.

  **Teardown must chmod before it deletes**: once anything has been written through an
  overlay, its workdir keeps a mode-000 directory that removal cannot enter even as its
  owner, which `reset` and sandbox deletion both meet. And a reset of a running role is
  refused, because it removes the very layers the keeper has mounted and the conflict
  warning actively invites the user to run it; an idle keeper is ended first.

  Under `copy` the question does not arise, since two sessions write one persistent directory as
  two native sessions do.

  Measured while implementing `copy-on-write`: an overlay mounts and reads through normally
  under the `strict` network mode, where bubblewrap runs inside pasta's user
  namespace. That was an open question and is not one.
- **A channel path that names a FILE cannot be deleted from inside, and that is a
  limitation this model INTRODUCES.** Narrowing such a channel binds that one file, so
  the path inside is a mount point in a directory the sandbox does not own, and a mount
  point cannot be unlinked from within. Measured on this host: under `read-write`, where the
  whole state directory is bound, a sandboxed session deletes `CLAUDE.md`,
  `settings.json` and `rules/topic.md` without trouble; under `copy` the first two are
  refused with `EBUSY` while the third, being an ordinary file inside a bound directory,
  still goes. The config file has behaved this way since 0.2.1 for the same reason.

  So `copy`'s promise that *a file the sandbox deleted stays deleted* holds for
  directory-shaped paths and is unreachable for file-shaped ones. The study says so
  rather than pretending otherwise: C7 asserts the promise on `rules/`, and a second
  cell asserts what actually happens on `CLAUDE.md` — the delete is refused and the
  source is untouched. When the fix below lands, that second cell fails, and that
  failure is the prompt to change the specification deliberately.

  What it costs in practice looks like nothing. Claude Code does not appear to delete
  either file: of 64 delete call sites in 2.1.278, none is within 1500 bytes of either
  name, which in a minified bundle with constructed paths is evidence of absence rather
  than proof. A user deleting their own `CLAUDE.md` does it natively, where it works.

  **The real fix is the architecture, not a workaround.** The end state of this model is
  a sandbox with its OWN state directory, into which connections deliver content; there
  the file is the sandbox's own and deletes like any other. That arrives with the preset
  cutover, which is when unconnected paths stop being visible anyway. Interposing a
  directory to bind instead would only move the mount point up one level, and treating
  truncation as deletion would help nobody: the agent's own `rm` would still fail, so the
  rule would exist only for whoever had been told about it.

  **The same two paths settle `copy-on-write`.** Overlayfs mounts a directory and cannot stack on a
  single file, so `copy-on-write` on a file-shaped path is `copy` whatever bubblewrap supports —
  not a fallback for old hosts but a permanent property of the mechanism.
- **Warning granularity.** File names at launch, one line per shadowed or conflicting file,
  and the differing lines on demand (`--connection-diff <channel>`). Warnings are never
  suppressed by `--quiet`, so a diff at every launch would be noise, and a warning is not
  the place to print instruction content into a terminal log.

## Open questions

- **Named sandboxes** beyond roles, shared by several projects.
- **Cross-kind projection** of instruction files, if a second profile ever wants it.
