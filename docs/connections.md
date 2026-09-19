# Sandboxes, sources and connections

**Status: proposed, not implemented; `cow` measured end to end on this host.** A model for controlling what passes between agent
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
No connection for a channel means `none`.

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
| tools | user-level MCP servers | the `mcpServers` block of the config file |
| memory | per-project auto memory | `projects/<slug>/memory/`; `agent-memory/` once its layout is known |
| transcripts | conversations, plans, file history, prompt history | `projects/<slug>/*.jsonl`, `plans/`, `file-history/`, `history.jsonl` |
| artefacts | downloads, uploads, task lists | `downloads/`, `uploads/`, `tasks/` |

Two things in the state directory belong to no channel. **Per-session scratch** (`sessions/`,
`session-env/`, `jobs/`, `shell-snapshots/`, `debug/`, `paste-cache/`, `daemon/`) stays what
the isolate spec makes of it today: replaced per launch, closed to other sessions, a session's
own new entries merged back. **Server-owned state** (`skills/synced/`, `plugins/synced/`,
`cache/`, `telemetry/`, `backups/`, the usage and stats files) is written by Claude Code
itself from the service or as caches; it is private to each sandbox and never connected. A
sandbox syncs its own server skills on first start, measured at 3.6 MB on this host.

## The scale

Every connection has a mode. The modes are ordered by how much of the source A reaches the
sandbox B, and whether anything of B reaches A:

```
none  <  copy  <  cow  <  ro  <  live
```

| mode | A → B | B → A | B's own state | needs |
|---|---|---|---|---|
| `none` | never | never | B's own, from nothing | nothing |
| `copy` | at launch, where B has not changed the file | never | private, persistent | a seed and a three-way refresh |
| `cow` | live, for every file B has not written | never | private, persistent | an overlay, or its emulation |
| `ro` | live | never | none | a read-only bind |
| `live` | live | live | shared with A | a read-write bind (today) |

Definitions, so the sub-decisions stop multiplying:

- **`copy`**: B's files are seeded once from A. At later launches A's changes arrive for
  every file B has not touched; a file B changed stays B's; when both changed, B's stays and
  the launch says so; a file A deleted goes from B if B never touched it; a file B deleted
  stays deleted. Nothing is ever merged textually, nothing is ever written back to A, and
  nothing of B's is overwritten without a word. A `reset` re-seeds a file, a channel or a
  sandbox from A on request. This is the rule the config file's `mcpServers` refresh already
  follows for one key, applied per file.
- **`cow`**: copy-on-write. B reads A's files through until it writes one; the write creates
  B's private copy, which shadows A's file from then on. A's edits reach B live for every
  unshadowed file, so `cow` needs no refresh step at all; a shadowed file is B's until B
  deletes its copy (which exposes A's again) or `reset`s it. The launch warns when a
  shadowed file has since changed in A. Between `copy` and `ro` on the scale: it reads like
  `ro`, writes like `copy`. A native edit to a shadowed file is the one thing it hides, and
  it hides it loudly.
- **`ro`**: A's files, live, read-only. B cannot author at that channel; for `settings` this
  breaks `/model` and permission saves, which is the cost of choosing `ro` for that channel.
- **`live`**: today's behaviour. A and B steer each other with no delay. Races are the
  agent's own, exactly as between two native sessions; the sandbox adds no arbitration.
- **`none`**: no connection. B has whatever it created itself at that channel.

Two connections are **mandatory** and fixed:

- **identity** is `live` to native. Two agents of one user are one login; cloning a refresh
  token multiplies a race (the study's harness notes it), so the token stays one file. This
  is the floor of the scale: "completely independent" sandboxes of one user still share who
  they are. Full independence needs two accounts, which is outside this tool. `hide` keeps
  the tooling parts (`gh/`, `ide/`) out of a sandbox that should not have them.
- **project** is `live` to the working tree, by definition: it is where agents are meant to
  communicate, including agents of different kinds, through files and a document convention
  such as `AGENTS.md`. Roles on one project share it. Exclusions inside it (a reviewer that
  must not read `.git`, issue #55) are a detail of this connection, not a mode.

## Invariants

1. **A connection moves one channel along the scale and does nothing else.** No knob has a
   side effect on another channel, so positions compose without interaction.
2. **The independent extreme is reachable for every channel the study lists.** A channel
   with no `none` is a gap. An unclassified path is private by construction, which is how
   this invariant holds for paths nobody has classified yet.
3. **Every step up the scale from the default is a widening**: trust-gated in the dot-file,
   ungated at launch. Every step down is free. This is the rule the existing knobs follow.
4. **Agents communicate only through `live` connections and the project directory.** A
   `live` connection's interface is the agent's own file format; the sandbox neither adds
   nor promises arbitration. Network-mediated communication has no interface at all and is
   governed by the network mode alone.
5. **A mode is B's view of its source.** Two sandboxes at `live` see each other; a sandbox at
   `copy` beside one at `live` receives the other's writes at its next launch and sends
   nothing back. Asymmetric flows are predictable because each side's mode is its own.

## Presets

A preset is a position for every channel at once. Three are worth naming; everything in
between is a preset plus overrides.

| channel | `independent` | `default` | `shared` (today) |
|---|---|---|---|
| identity | live native | live native | live native |
| project | live | live | live |
| instructions, settings, skills, agents, workflows, plugins | none | `cow` from native, `copy` where no overlay | live native |
| tools | none | `copy` from native (`user-mcp = none` is its `none`) | live native |
| memory | none (own only) | none, plus `ro` from named sandboxes (`[share-memory]`) | live (`memory_default = shared`) |
| transcripts | none | none | live |
| artefacts | none | none | live |
| network | `none` | `proxy` | `proxy` or `open` |

`default` is the transparency principle stated as connections: a sandbox created from native
with these connections behaves like a native Claude Code whose configuration is the user's,
read live, with its own writes kept to itself. `independent` is the two mandatory
connections and nothing else. `shared` is the engine before 0.2.

## Mechanisms

What exists: read-write and read-only binds of a source path at an inside path
(`profile_config_binds` with `SRC<TAB>DEST`, and the layered `profile_rw_binds`/`_ro_binds`);
`tmpfs` over a path; `copyout` and `append` for per-session scratch; the engine's state
directory and its control-path protection; a seeded, filtered, refreshed copy of one file
(the config file, 0.2.1); the mount-point cleanup a file bind inside a read-write directory
needs. Measured on this host: the whole user-owned configuration copies into the session
tmpfs in under 0.1 s and under 20 MB, hashes in under 0.1 s, and a stat walk takes 20 ms.

What `cow` needs. bubblewrap gained `--overlay-src`, `--overlay`, `--tmp-overlay` and
`--ro-overlay` in release 0.11.0. Ubuntu 24.04 ships 0.9.0, which rejects them (measured);
26.04 ships 0.11.1. Measured on this host after a local no-change rebuild of Ubuntu's own
0.12.0-1 source for 24.04 (kernel 6.8, the installer's AppArmor profile, the engine's own
flags: `--unshare-all`, uid and gid mapping, `--cap-drop ALL`): an overlay mount inside
bubblewrap's user namespace works. Reads fall through to the lower directory, a write lands
in the upper directory and the lower file is untouched, `--tmp-overlay` discards the writes,
and the engine's integration suite passes unchanged on 0.12.0. So `cow` has two
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

`copy` needs the seed, a base manifest of what was last synced, and the three-way step at
launch; it has no exit step, since B writes its persistent copy directly. `ro` and `live` are
binds. Every mode is per channel, and a channel that maps to several paths applies its mode to
each.

## The profile contract under this model

A profile declares four things and no dispositions:

1. where the agent keeps its state, and how to point the agent at the sandbox's copy of it
   (Claude Code: `~/.claude`, `CLAUDE_CONFIG_DIR`);
2. the **identity** paths, always connected `live` to native (Claude Code: `.credentials.json`;
   `gh/`, `ide/` as hideable tooling);
3. the **channel → path** table above, including what is server-owned state;
4. the **per-session scratch** the isolate spec replaces per launch.

Everything else in today's profile, memory scoping, `[claude] hide`, `user-mcp`, the config
file copy and its exclusion list, becomes a connection statement or falls out of "private by
construction". A second profile fills in the same four items; nothing about the engine's
connection machinery is agent-specific.

## Knobs

The three forms every knob has today, in sketch. Existing keys stay as sugar for the
connection they mean.

```ini
[sandbox]
role = reviewer            # the sandbox key's second half; default: default
preset = default           # independent | default | shared

[overlay]
mode = auto                # auto | off -- what `cow` is implemented with

[connect]                  # channel = mode [source]; source: native | sandbox:<project>[/<role>] | dir:<path>
instructions = cow native
skills = copy native
memory = ro sandbox:~/git/acme/app          # what [share-memory] means today
tools = none                                # what user-mcp = none means today
artefacts = live native
```

Launch-time forms: `--connect 'memory=ro sandbox:...'` repeated, `AGENT_SANDBOX_CONNECT` with
the same syntax, `--role`, `--preset`, and `--overlay auto|off` with
`AGENT_SANDBOX_OVERLAY`, which wins if set in the shell as `AGENT_SANDBOX_SECCOMP` does.

**What the trust gate does and does not cover here.** The dot-file is parsed only when
approved, so `[connect]` grants nothing from an unreviewed file, and a step *up* the scale
written there is a widening the `--trust` review exists to show. The flag and the
environment variable are not gated and never have been, for any knob: they are the user's
own shell, and a user who can set them can equally run the agent unsandboxed. That
distinction costs nothing while every channel defaults to `live`, since no launch-time
form can widen anything. It starts to matter the day the `default` preset lowers those
defaults, because then `AGENT_SANDBOX_CONNECT` in a shell profile can quietly put a
channel back at `live` for every project. Whoever lands presets decides whether that stays
true and says so here.

`reset` is an engine verb: `--reset-connection skills`, or the whole sandbox.

## What the study measures under this model

The experiments are planned in [connections-study.md](connections-study.md), whose
level-1 cells are this model's acceptance suite: one assertion per mode promise, scripted
and free, failing until the engine implements the mode. In outline:

- **Connections**: for each channel and mode, does content flow as the mode says, in each
  direction and at the stated time (launch or live)? The study's rows map directly: rows 5–9
  and 19–22 measured instructions, settings, skills, agents, workflows and plugins at `live`
  (T5 `obtained`, and T2/T6 `obtained` for the write half by construction); the same rows at
  `copy` and `cow` are the post-fork arm. Rows 1–4 and 16 measured memory and transcripts at
  `none` with memory's `ro` share. Rows 10 and 11 measured tools and the config file, now at
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

- The per-project config file copy is the `tools` and config-file channel at `copy`,
  already at `~/.local/state/agent-sandbox/claude/<slug>/`; the directory becomes
  `<slug>/default/` when roles arrive, or stays as the default role's home.
- `[share-memory]` becomes `memory = ro sandbox:<project>`; `memory_default = shared` becomes
  the `shared` preset's memory row; `[claude] hide` becomes `none` for identity's tooling
  parts; `user-mcp = none` becomes `tools = none`. All four keys stay accepted.
- The isolate spec keeps the per-session scratch and drops everything that "private by
  construction" now covers.
- Existing measured results keep their meaning: they describe the `shared` preset.

## Settled while writing this

- **Overlay availability per host.** Real `cow` needs bubblewrap 0.11 or later. Ubuntu
  26.04 ships 0.11.1; 24.04 ships 0.9.0 and gets 0.12.0 through the rebuild recipe in
  [troubleshooting.md](troubleshooting.md#bubblewrap-older-than-0120-ubuntu-2404), which
  `install.sh` points at when it finds an older bubblewrap (0.12.0 also carries the fix for
  CVE-2026-87766, a setup-time symlink escape through directories the sandboxed process
  controls, which noble-security's 0.9.0-1ubuntu0.3 dropped again). Measured in CI:
  26.04 has overlay support, 24.04 ships 0.9.0 and 22.04 ships 0.6.1, so two of the three
  supported releases take the fallback unless their bubblewrap is upgraded. Nothing may
  therefore be designed as if the overlay path were the usual one.
- **Where there is no overlay, `cow` is `copy`** — not a separate emulation to write and
  keep in step. Compare the two definitions above and they differ in exactly one place.
  Across launches they are identical: a source change to an untouched file arrives, a
  touched file stays the sandbox's, a delete inside persists while the source keeps its
  copy, a conflict warns. The only divergence is *within* a running session, where an
  overlay reads through live and a snapshot cannot. So the fallback costs a branch and a
  notice rather than a subsystem, and the launch says which one it used. Nothing stops
  working on an old host, which is why no channel needs widening to `live` to accommodate
  one.

  Its cost is storage: `copy` duplicates the channel's files per sandbox where `cow`
  stores only what was written. Measured on one developer machine, the channels a
  connection covers came to 45 MB, dominated by `plugins/` at 7.4 MB and `skills/` at
  4.3 MB; instructions and settings are kilobytes.

  **`[overlay] mode = off`** forces the fallback on a host that could use an overlay. It
  exists because overlayfs is not usable everywhere bubblewrap supports it — some
  filesystems, some container hosts — and because a path that only ever runs on old
  machines is a path that rots. It can only move `cow` to `copy`, a step *down* the scale,
  so it needs no trust gate. It is also what lets the study compare the two
  implementations on one host, which is W8.
- **`plugins/`**: `cow`, like the rest of its group. Not `ro`: Claude Code writes into
  `plugins/` at every start (the `synced/` markers and manifest, a rename onto
  `installed_plugins_v2.json`, a lock beside `known_marketplaces_claudeai.json`), and under
  `ro` those fail silently at every launch, measured. Not `live`: a plugin bundles hooks and
  skills, and row 9 measured a plugin's hook firing in another project's sandbox, so the
  channel carries inference like `skills` does and `live` would keep T2 and T6 open for it.
  If overlay use is to be minimised, `copy` is the alternative that keeps the channel closed:
  plugins change rarely, so a refresh at launch loses nothing that matters.
- **Two sessions of one sandbox at once, under `cow`: mount once, and let every session
  join that mount.** A sandbox is keyed by project and role, so two terminals on one
  project are two sessions of one sandbox; that is the ordinary case, and refusing it or
  serialising behind an interactive session would break a daily workflow to avoid a
  problem that can be dissolved instead. What overlayfs documents as undefined is two
  *independent mounts* over one upper directory, not many users of one mount. So the
  engine mounts a sandbox's overlay once and each session inherits it.

  Measured, and now asserted on every platform CI covers by
  `tests/integration/overlay-sharing.bats`: two concurrent independent mounts over one
  upper really are two superblocks, which is what makes the rest of the measurement
  meaningful; a session joining the holder's user and mount namespaces reports the
  holder's superblock, and so does a full bubblewrap sandbox built inside that join. Two
  such sandboxes at once saw each other's writes and each other's whiteouts coherently,
  and the source was untouched. The study asserts that behaviour as W9; the superblock
  identity is a platform premise and is asserted in the test rather than in a cell, which
  inspects no layout.

  **NOT YET BUILT, and `cow` ships before it.** Today each session mounts its own
  overlay, so two sessions of one sandbox are the undefined arrangement above. It
  is safe to ship in that state only because nothing selects `cow` by default and
  nothing will until the preset cutover; it must not still be true then. Two
  things stand in for the holder meanwhile: a launch that finds another live
  session of the same sandbox says so, once, rather than a notice on every launch
  that people learn to skip; and `--reset-connection` refuses outright while a
  session is live, because it removes the very layers that session has mounted
  and the conflict warning actively invites the user to run it.

  Detecting a live session is not the obvious check. Measured: bubblewrap passes
  the upper layer as `/proc/self/fd/N`, so the path appears in no mountinfo and
  scanning `/proc` for it finds nothing. What works is the engine's own session
  stamp, the owner's PID and start-time that the janitor already uses to tell a
  live session from an orphan.

  Three consequences for the implementation. A **short lock** is needed, but only around
  *creating* the holder, because two sessions racing to create one would make the two
  mounts this avoids; it is held for milliseconds, not for the life of a session, which is
  what made serialising unattractive. **No long-lived daemon is required**: the mount is
  held by namespace membership, so once a session has joined, the holder may exit and the
  session keeps reading and writing at the same superblock; killing the holder mid-session
  did not pull the filesystem out from under it. And **teardown must chmod before it
  deletes**: once anything has been written through an overlay, its workdir keeps a
  mode-000 directory that removal cannot enter even as its owner, which `reset` and
  sandbox deletion will both meet.

  Bubblewrap takes an existing user namespace as a file descriptor, not a path. Under
  `copy` the question does not arise, since two sessions write one persistent directory as
  two native sessions do.

  Measured while implementing `cow`: an overlay mounts and reads through normally
  under the `strict` network mode, where bubblewrap runs inside pasta's user
  namespace. That was an open question and is not one.
- **A channel path that names a FILE cannot be deleted from inside, and that is a
  limitation this model INTRODUCES.** Narrowing such a channel binds that one file, so
  the path inside is a mount point in a directory the sandbox does not own, and a mount
  point cannot be unlinked from within. Measured on this host: under `live`, where the
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

  **The same two paths settle `cow`.** Overlayfs mounts a directory and cannot stack on a
  single file, so `cow` on a file-shaped path is `copy` whatever bubblewrap supports —
  not a fallback for old hosts but a permanent property of the mechanism.
- **Warning granularity.** File names at launch, one line per shadowed or conflicting file,
  and the differing lines on demand (`--connection-diff <channel>`). Warnings are never
  suppressed by `--quiet`, so a diff at every launch would be noise, and a warning is not
  the place to print instruction content into a terminal log.

## Open questions

- **Named sandboxes** beyond roles, shared by several projects.
- **Cross-kind projection** of instruction files, if a second profile ever wants it.
