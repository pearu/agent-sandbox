# Glossary

The terms this project uses, one definition each. Written because the same word was
being read two ways in one design discussion ("session" as Claude's conversation and as
one launch of the engine), and a design argued in two vocabularies settles nothing.

Each entry carries a status:

- **shipped** — the engine does this today (0.3.0 and `main`)
- **agreed** — decided, not built
- **open** — under discussion; the entry records the question, not an answer

Where a word has two meanings, [Words that collide](#words-that-collide) at the end lists
them, and the entries say which one they mean.

## The things involved

**Host.** The machine and user account the engine runs on, outside every sandbox.
*shipped*

**Agent.** The program being sandboxed: Claude Code for the `claude` profile. The engine
itself is agent-agnostic; everything specific to one agent lives in its profile. *shipped*

**Profile.** `profiles/<name>.sh`: the agent-specific half of the engine — where the
agent keeps its state, which channels it has and which paths each maps to, how its argv is
routed, which subcommands run on the host. Selected with `--profile` or inferred from the
command name (`claude` → `profiles/claude.sh`). See [profiles.md](profiles.md). *shipped*

**Project.** The directory a launch is started from — the working tree — bound read-write
into the sandbox at the same path. It is one half of the sandbox key, and the one
connection every sandbox has by definition ([mandatory connections](#connections)). For a
background worker it is the worker's project, not the daemon's directory. *shipped*

**Launch.** One run of the engine: it builds one bwrap sandbox, runs one command inside
it, and cleans up when that command exits. Everything bound is decided at the start of
the launch and fixed for its lifetime. A launch runs the agent by default, or any command
with `--exec`. *shipped as behaviour* — the engine's code and older docs call this a
**session** (`_as_session_begin`, `AGENT_SANDBOX_SESSION_BASE`, "per-session scratch").
*agreed*: the user-facing word is **role**; a launch is a role's running instance, the
[keeper](#mechanisms) and what is joined into it, and "launch" stays internal.

**Claude session.** A Claude Code conversation: what `claude -r <uuid-or-name>` resumes,
identified by a UUID (`--session-id`) or a name. It is Claude Code's object, not the
engine's. A launch can contain **no** Claude session (`claude --exec pytest`), **one** (a
plain `claude`), or **several** (`claude --exec bash -l`, then `claude` started natively
inside it, twice) — and every Claude session inside one launch sees that launch's binds.
So the engine cannot give a Claude session storage of its own; it gives it to the role.
*agreed*: a Claude session id is derived from the role (the first session's), never the
reverse; `claude --role foo -r` lists foo's sessions and a bare `claude -r` native ones only.

**Sandbox.** An installation of one agent for one project and role: the policy that says
what crosses its boundary, channel by channel, and the state kept for it under
`~/.local/state/agent-sandbox/<profile>/<project slug>/<role>/`. That directory is a
[control path](#safety-terms): never bound into any sandbox. *shipped*. The state belongs
to the role; see [Instance storage](#instance-storage-decided).

**Sandbox key.** What identifies a sandbox: `<project slug>/<role>` under the profile's
state directory. *shipped* (role is always `default` today). The `<scope>` segment once
planned in #104 is withdrawn (#123): the key stays two segments.

**Role.** A named, persistent instance of a project under a policy: `claude --role impl-1`.
The second half of the sandbox key, and the thing you come back to: its stores persist
across runs, its policy is the variable part. Two roles on one project share the project
directory and nothing else unless connected (a reviewer that must not see the implementer's
accumulated memory is the motivating case,
[#55](https://github.com/pearu/agent-sandbox/issues/55)). Policy is selected by matching the
name against role-suffixed sections, `[sandbox:<glob>]` and `[connect:<glob>]`, applied after
the unsuffixed ones, later overriding earlier, per key; a name matching no suffixed section is
refused when suffixed sections exist. A role is not a security boundary beyond what
its channels close. *shipped as a key segment with the single value `default` (`[sandbox]
role`, `--role` and `AGENT_SANDBOX_ROLE` name it; the role sections are built; the role verbs are agreed, not built
(#121, #126).*

**Nesting.** Running the engine inside a sandbox, which creates a sandbox within it.
Every source and check resolves in the namespace where that engine runs, so an inner
engine can only bind what the outer shows it: nesting narrows, never widens. Persistence
across relaunches is **not** enforced when nesting — the inner engine's state directory is
under its `$HOME`, a tmpfs in the outer sandbox, so everything the inner sandbox keeps
lasts as long as the outer launch. By default a profile routes a launch *inside* a sandbox
to no sandbox (`none`), so nesting happens only when asked for. *shipped behaviour; the
persistence limit is documented in [connections.md](connections.md), from the design, not
measured.*

**Native.** The agent as installed on the host, run without the engine; and its state
(`~/.claude` for Claude Code). As a **source**, `native` means that state. As a **preset**,
see [Presets](#presets-and-principles). *shipped*

## Connections

**Channel.** One kind of thing that can pass between a sandbox and the outside, named by
what it carries, never by a path. The profile maps each channel to the agent's paths.
For the `claude` profile the channels the engine manages as connections are
`instructions`, `settings`, `skills`, `agents`, `workflows` and `plugins` (*shipped*);
`identity`, `project`, `tools`, `memory`, `transcripts` and `artefacts` are channels in the
model with machinery of their own, not yet folded in. The table of what each carries is
in [connections.md](connections.md#the-three-objects).

**`config`** is Claude Code's config file, `~/.claude.json`, as one file (*shipped*, #119):
seeded filtered at the seeding modes, then Claude Code's alone; the user-level MCP servers
are part of it, so `tools` is no longer a channel of its own (#132).

The model also treats the **network** as a channel (`own` = no network, then
`proxy`, then `open`), governed today by the network mode rather than by a connection. The
channels that carry agent *behaviour* rather than data — `instructions`, `skills`,
`agents`, `workflows`, `plugins`, `settings` (hooks) — have been called **capability
channels** informally; it is not a separate category in the engine.

**Storage.** Informally, the channels that are files on disk. In this glossary, *storage*
means the **sandbox-side storage** of a channel: what the sandbox keeps at that channel
instead of the source — an `own` slot, a `seed-only` or `copy` copy, a `copy-on-write`
upper layer. `read-only` and `read-write` have none. Each store belongs to `(role, path,
mode)`. *agreed*

**Source.** Where a connection reads from, and where a sandbox is created from.
*shipped*: `native` only. *agreed*: `sandbox:<project>[/<role>]` (another sandbox),
`outside:<path>` (a path one level out — the parent's filesystem when nested, never the
machine's), and `clone:<source>` (a throwaway, discardable copy of a source, made per
measurement or run and shared by every launch in it,
[#106 comment](https://github.com/pearu/agent-sandbox/issues/106)).

**Connection.** One channel, one mode, one source (and, when scopes land, one scope)
for one sandbox: `instructions = copy-on-write native`. A channel with no connection is
`own`. *shipped*

**Mandatory connections.** Two, fixed: `identity` is `read-write` to native (two agents
of one user are one login), and `project` is `read-write` to the working tree (it is
where agents are meant to communicate). *shipped*

**Path declaration.** A `[connect]` key containing `/`, naming a path instead of a
channel: `./scratch/ = own`. The key is the path inside the sandbox; relative keys are
relative to the project; the source is the same path outside. It is what `[ro]`/`[rw]`
become, before they are removed ahead of 1.0. *built on branch `feat/connect-paths`,
not merged* — see [connections.md](connections.md#path-declarations) there.

**Per-launch scratch** (the docs say *per-session scratch*). Parts of the agent's state
that are replaced for every launch and closed to other launches — for Claude Code,
`sessions/`, `session-env/`, `jobs/`, `shell-snapshots/`, `debug/`, `paste-cache/`,
`daemon/` — declared by the profile's **isolate spec**, with a launch's own new entries
merged back where the spec says so. It belongs to no channel. *shipped*; *agreed* (#120):
each of these paths gets a mode instead, and nothing is merged back when a launch ends.

**Server-owned state.** What the agent writes from its service or as caches
(`skills/synced/`, `plugins/synced/`, `cache/`, `telemetry/`, …). Private to each sandbox,
never connected. *shipped*

## Scales

**Scale.** The ordered set of **modes** a connection can take, by how much of the source
reaches the sandbox:

    own  <  seed-only  <  copy  <  copy-on-write  <  read-only  <  read-write

The order is how much of *your* files reach the sandbox, not what the sandbox may do: it
can write under `copy-on-write` and not under `read-only`, and `read-only` is still
higher, because it hands over the real file. *shipped*

**Mode.** One position on the scale. Each in one line (full definitions in
[connections.md](connections.md#the-scale)):

- **`own`** — the sandbox's own, from nothing; nothing of yours reaches it, nothing of its
  reaches you.
- **`seed-only`** — copied from the source once, when the store is first created, then the
  role's own; never refreshed, so never a conflict warning. Sits between `own` and `copy`.
  *shipped*
- **`copy`** — seeded from the source, refreshed at each launch for every file the sandbox
  has not changed, never written back.
- **`copy-on-write`** — the source reads through live until the sandbox writes a file,
  which then becomes the sandbox's. From outside it means the same as `copy`; it is `copy`
  implemented with an overlay, and falls back to `copy` where no overlay is available or
  the path is a file.
- **`read-only`** — the source, live; the sandbox cannot write there.
- **`read-write`** — the source itself, both ways.

The names changed in 0.3; the old ones (`none`, `cow`, `ro`, `live`) are refused.

**Widening / narrowing.** A step up the scale is a widening: trust-gated when it comes
from a dot-file, ungated from the flag or the environment. A step down is a narrowing and
is always free. *shipped*

## Presets and principles

**Preset.** A predefined position for every channel at once — a named set of modes.
`isolated < inherit < shared < native`, default `inherit`:

- **`isolated`** — every managed channel `own`.
- **`inherit`** — every managed channel `copy-on-write` from native: the sandbox reads your
  configuration live and keeps its own writes to itself.
- **`shared`** — every managed channel `read-write`: the engine before 0.3.
- **`native`** — sandboxed, but isolating no state: must behave identically to `--sandbox
  none`, so any difference is a bug. Flag only, never from a file or the environment.

A `[connect]` line then moves one channel and nothing else. A preset moves only the
channels the profile declares, never a path declaration. *shipped*. *agreed*: **`none`**,
a fifth preset, incomparable with the rest, meaning no sandbox at all.

The axis the ladder measures is **boundary permeability**, and it is direction-dependent:
`inherit` is the rung where reads pass in and writes do not pass out.

**Fidelity principle.** The sandbox reproduces the native experience faithfully, minus
what the user explicitly asked to change. `inherit` expresses it for configuration;
`native` asserts it absolutely. (Formerly "the transparency principle".) *agreed and
documented*

## Scopes

"Scope" was used for two axes. One is withdrawn; the other is decided.

**Invocation scope** (#104): `foreground`/`background` as a policy axis and key segment.
*Withdrawn* (#123): a background session runs inside its role's launch, so `x@background`
is `x`. What survives from #104 is the `none` preset, the role-suffix grammar and keying
trust on the project.

**Storage scope** (#125). Storage is keyed by the role, so the scope token of a connection
(`channel = mode [source] [scope]`) names only a *shorter* lifetime. *agreed, not built*:

| written | lifetime |
|---|---|
| *(nothing)* | the role: across keepers, until `--delete` or `--reset` |
| `run-scoped` | one keeper ([#105](https://github.com/pearu/agent-sandbox/issues/105)) |
| `process-scoped` | one joined process |

`sandbox-scoped`, `project-scoped` and `session-scoped` are withdrawn: the first is the
unnamed default, the second is a `sandbox:<project>/<role>` source at `read-write`, the
third is a role per conversation. `read-write` with any scope stays refused. (PR #117
parses the older set and is to be revised.)

### Instance storage (decided)

The question of 2026-09-23 — does a store belong to the sandbox or to each launch — is
settled by the role: `own`, `seed-only`, `copy` and `copy-on-write` exist so the inside can
write without modifying the outside, other instances are outside, and **the role is the
instance**. It is one launch that every app joins (the [keeper](#mechanisms)), so there is
never a second launch of a role to share a store with; sharing between roles goes through a
source. Two Claude processes in one role on one conversation behave as they do natively:
measured on 2.1.281, the second marks the first's in-flight tool call interrupted, the
conversation forks, and the next resume follows the branch of the process that exited last.

## Mechanisms

**Holder.** A long-lived bwrap process per sandbox that mounts the overlays for every
directory-shaped channel path, so that every launch of that sandbox joins one overlay
instead of mounting its own — two overlays over one upper layer are undefined. Recorded in
`<sandbox>/holder.id`; exits once that record is gone or names another process. Its set of
mounts is fixed when it starts. *shipped*; *agreed*: subsumed by the keeper (#121).

**Keeper.** *agreed, not built* (#121): a role's running instance — a process that holds
every namespace of the sandbox and does nothing else. Every app, the first included, is
joined into it; it exits when nothing is joined, after a grace of one or two seconds, under
a lock. Its policy is evaluated when it starts; a join under a changed dotfile warns and
joins. It mounts the channel overlays and the path declarations at their real paths, which
is what the holder did at staging paths.

**Join.** *agreed, not built* (#121): running a command inside the keeper as its equal —
same mounts, environment, working directory, uid and gid, capabilities, `no_new_privs` and
seccomp filter. Measured in net modes `none` and `strict` (`probes/join-launch.py`). It is
`setns` from `python3`, because bwrap nests a capability-less user namespace when given
`--dev /dev` and `nsenter` cannot reach the namespace that owns the mounts. A foreground
`claude`, `--exec`, `--bg` and the management verbs are all joins.

**Overlay.** overlayfs: a merged view of a read-only lower layer (the source) and a
writable upper layer (the sandbox's), which is how `copy-on-write` is implemented. Needs
bubblewrap 0.11 or newer; cannot stack on a single file. *shipped*

**Slot.** The directory or file under the sandbox's state that an `own` connection binds.
*shipped*

**Sync, manifest.** How `copy` refreshes: a three-way comparison of the source, the
sandbox's copy and a recorded manifest of what was last seeded
(`components/connect-sync.py`). *shipped*

**Reset.** `--reset-connection CHANNEL`: discard what the sandbox holds at a channel and
take the source's version again, then exit. Refused while a launch of that sandbox is
running. *shipped*; *agreed* (#126): renamed `--reset <channel|path>`.

**Role verbs.** *agreed, not built* (#126): `--status` (the keeper, what is joined, the
daemon's sessions), `--shutdown` (ends the keeper and everything in it), `--delete` (removes
the role's stores; refused while anything is joined, naming `--shutdown`), `--reset`.

**Briefing.** What the engine tells the agent about its sandbox: a document bound
read-only, and a hook summary re-read on every launch, resume and compaction. *shipped*

**Route.** The profile's decision, from the agent's argv, whether a launch is sandboxed
and how — including handing a `--bg` invocation off to the background machinery. *shipped*

**`--exec`.** Run a command other than the agent in the sandbox the profile would have
built: same binds, environment, network and state isolation. *shipped*

**Background worker, `--wrap`.** A process Claude Code spawns for `claude --bg`, sandboxed
by the engine acting as Claude Code's `CLAUDE_CODE_PROCESS_WRAPPER`. Opt-in. *shipped*;
*agreed* (#123): goes. `claude --role x --bg` joins x's keeper and runs `claude --bg` there,
so the daemon, its workers and the management verbs are inside; measured on 2.1.283.

**Try-run.** Run a launch against cloned sources, then inspect or discard the result.
*proposed* ([#115](https://github.com/pearu/agent-sandbox/issues/115)).

## Configuration

**Knob.** One setting, in three forms: a flag (`--preset`), an environment variable
(`AGENT_SANDBOX_PRESET`) and a dot-file key (`[sandbox] preset`). The flag beats the
variable, which beats the file. *shipped*

**Dot-file.** `.agent-sandbox` in the project: the project's knobs. Data only, never
executed. *shipped*

**Trust.** A dot-file is read only after the user approves its exact content with
`--trust`; approval is recorded as a hash, so any edit needs approval again. An unapproved
dot-file grants nothing. *shipped*

**State directory.** `~/.local/state/agent-sandbox/`: every sandbox's state. Persistent,
host-only, a control path. Distinct from the **session base** (runtime, per launch) and
from `~/.config/agent-sandbox/` (the trust store and global configuration). *shipped*

## Network

**Network mode.** `proxy` (the default: egress through a host-side mitmproxy with an
allowlist), `strict` (the sandbox's own network namespace, owned by `pasta`, where a
firewall rule allows only the proxy, and host ports only as named with `--host-port`),
`open` (no allowlist) or `none` (no network). *shipped* — see
[network.md](network.md).

**Allowlist.** The hosts a sandbox may reach in `proxy` and `strict`. *shipped*

## Safety terms

**Leak, channel (in the study's sense).** Anything by which one project's or launch's
material reaches another's. **Inference** is material that steers another agent's
behaviour; **disclosure** is content crossing without necessarily steering anything. Both
count. See [cross-project-channels.md](cross-project-channels.md).

**Secret store.** Paths holding credentials of services the sandbox keeps away from the
agent (`~/.ssh`, `~/.gnupg`, `~/.aws`, …). Refused as a bind in every mode, including
read-only. *shipped*

**Control plane.** The engine's own machinery on the host — the trust store, the proxy CA,
the runtime, the state directory, the launcher, user units. Refused as a bind, because
writable from inside it would let the agent change its own sandbox. *shipped*

## Testing

**Study.** The measurements of what crosses between projects and launches:
[cross-project-channels.md](cross-project-channels.md) (the leak study) and
[connections-study.md](connections-study.md) (whether each mode does what it says).

**Differential oracle.** Using `--preset native` against `--sandbox none`: any difference
is the sandbox distorting the agent rather than failing outright.

**Mutation check.** Breaking the thing a test is for, and confirming the test then fails.
A test that passes either way is recorded as proving nothing.

## Words that collide

| word | meanings | say instead |
|---|---|---|
| session | a **Claude session** (a conversation, `-r`-able); one **launch** of the engine (the code's `_session_dir`, "per-session scratch"), which is a **role**'s running instance | *Claude session*, *role* |
| scope | **invocation scope** (foreground/background, #104; withdrawn); **storage scope** (a shorter-than-role lifetime, #125) | *storage scope*, or name the lifetime |
| native | the host's unsandboxed agent and its state; the `native` **source**; the `native` **preset** (sandboxed, isolating nothing) | the source / the preset |
| none | the old name of `own` (refused since 0.3); a network mode; `--sandbox none`; the agreed fifth preset | the full context |
| shared | the `shared` preset; storage shared between launches; `memory_default = shared` | the preset by name |
| copy | the `copy` mode; the per-project copy of Claude Code's config file (0.2.1), now the `config` channel's store | *the `config` channel* |
