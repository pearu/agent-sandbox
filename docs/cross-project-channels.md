# Cross-project data channels: a leak study

**Status: planning.** This enumerates every channel through which data — or
influence — can pass between Claude Code sessions in **different projects** of the
same user, and defines a canary-based test of each, with and without the sandbox.
The test harness is not built yet.

A *session* is one `claude` invocation and its process tree; a *project* is the
directory it launches from (see "Units" below). The adversary (the sandbox's threat
model) is a session that is wrong or has been led astray, writing something a
session in *another* project then reads or acts on.

Leaks **within a single project, between two sessions** — e.g. an implementer's
accumulated decision history reaching a reviewer that should judge only the current
state — are a related but distinct concern: the project is the sandbox's isolation
unit, so same-project sessions share by design. Those are tracked separately in
#55 (session-role sandboxing) and reserved for a future
`cross-session-channels.md`; this document only flags them.

## Two mechanisms

- **Data inference (passive).** Session A's records or artifacts that session B
  can read: memory, transcripts, plans, logs, downloads.
- **Instruction / code injection (active).** Shared configuration and extension
  points that B reads *as instructions* or runs *as code*: global memory,
  settings and the hooks they define, skills, slash commands, plugins, MCP
  servers, per-project trust flags. The sandbox does **not** close these, because
  they are the user's own global configuration, intentionally shared.

## Scope: three kinds of leakage

Not every channel is in scope. Sort by *who causes* the crossing:

1. **Accidental, via the model or its tools — the target.** Session A's work ends
   up somewhere session B's model ingests automatically, or an LLM-generated tool
   or study moves it, with no one intending the crossing: global and project
   memory injected into context, auto-loaded skills, hooks that run each session,
   connected MCP servers, a resumed transcript, side-effect writes a tool leaves
   behind. **This is what the study measures.**
2. **User-directed — out of scope, a control not a threat.** The user explicitly
   tells the agent to read or write a shared path we keep open for it (e.g.
   "summarize `~/.claude/…`"). The user controls and accepts this; it is a
   baseline that *should* succeed, useful as a positive control, not a leak to
   prevent.
3. **Malicious code, by a bad actor — separate topic, mention only.** A planted
   hook, skill, plugin, MCP server or script that deliberately reads or exfiltrates
   across sessions. This is a security concern the bwrap design and the egress
   proxy address; it rides the *same* channels as (1) but differs in intent. Not
   this study's target — noted so results are not misread as security claims.

The sharp split for kind (1): the sandbox isolates the **state** channels a
sandboxed reader ingests (memory, transcripts, plans, history — closed in [T2](#t2)), but
leaves the **configuration / extension** channels shared and writable in every
topology (`CLAUDE.md`, settings/hooks, skills, plugins, `mcpServers`). So an
accidental write there by A is auto-ingested by B *even under the sandbox* — those
are the experiments most likely to show a leak the sandbox does not stop.

## Units: project vs session

The isolation unit is the **project** — but Claude Code does not derive it the same
way for the two kinds of per-project state, so "different project" means two
different things and the experiments must respect both:

- **transcripts** are keyed to the **working directory**: *"`<project>` is your
  working directory path with non-alphanumeric characters replaced by `-`"*
  ([sessions](https://code.claude.com/docs/en/sessions)). Over 200 characters the
  name is truncated and a hash of the full path appended.
- **memory** is keyed to the **repository**: *"The `<project>` path is derived from
  the git repository, so all worktrees and subdirectories within the same repo
  share one auto memory directory. Outside a git repo, the project root is used
  instead."* ([memory](https://code.claude.com/docs/en/memory)). Measured: the
  concrete path is the **main** worktree's root, so a linked `git worktree` keeps
  its memory with the main repository, not with itself.

Two directories in one repository are therefore **different** projects for
transcripts and **the same** project for memory. For an experiment to measure
anything, project A and project B must be **separate repositories** (or
directories outside any repository) — not two subdirectories of one, and not two
worktrees of one, either of which would share memory by construction and make a
"leak" result meaningless.

A **session** is one `claude` run (its own session id and transcript).
`-n NAME`/`--name` only sets a *display* name (shown in the prompt box and
`/resume`); it does not change the slug or any state path. So `claude -n foo`
and `claude -n bar` from the same directory are two sessions of the **same
project**: they share `projects/<slug>/` — the project's memory and each other's
transcripts — and do so **even when each is separately sandboxed ([T2](#t2))**, because
the sandbox scopes to the project, not the session. `-n` is therefore **not** a way
to isolate two workstreams; different **repositories** are (different directories
suffice for transcripts, but not for memory).

**Inside the sandbox the repository is not visible.** The engine binds the session's
directory, not its parents, so a subdirectory of a repository has no `.git` above it
and Claude Code takes the no-repository branch: it keys memory to the **directory**.
Measured with real bwrap — `git rev-parse --show-toplevel` from a bound subdirectory
answers *"not a git repository"*. So the same session keys memory to its repository
natively and to its directory when sandboxed, which is why a row's canary placement
can differ between [T1](#t1) and [T2](#t2) even though the channel is the same.

Same-project sessions are thus a **positive control**: they are *expected* to share
([T1](#t1) and [T2](#t2)). A leak there is only surprising if `-n` were mistaken for project
isolation.

### Within-project, between-session leaks (out of scope here — flagged)

A real leak exists within one project, between two sessions: an **implementer** that
accumulates decisions over time (some later overruled) and a **reviewer** that
should judge only the current state. The implementer's history reaches the reviewer
through the shared project memory, the transcripts, and the **`.git` log** — all
shared because the project is the isolation unit, so even a git worktree (a
different slug) does not help (it shares `.git`). The sandbox does not stop this,
and it is **not this document's scope**. It is tracked in #55 (session-role
sandboxing) — a `--role` that applies a dot-file overlay hiding the accumulation
channels (`.git`, memory, transcripts) for a reviewer — and will be documented in a
future `cross-session-channels.md`.

## Content-bearing vs auxiliary channels (a study output)

Not every shared channel is a kind-(1) leak. Some carry only **auxiliary,
machine-local data** — UI preferences, telemetry, feature-flag caches, update
bookkeeping — from which another session's model can infer nothing about the first
session's work (a shared font size, or a "seen this tip" flag, transfers no
essential information). Such a channel is **safe even when fully shared across
projects**.

Classifying each channel this way is itself a result of the study: it shrinks the
set that isolation decisions must cover to the **content-bearing** channels — those
whose data (or instructions/code) could let one session's model learn from, or be
steered by, another's work.

- **Content-bearing (the set to isolate):** project memory, transcripts, plans, the
  prompt history, global `CLAUDE.md`, skills/commands/plugins and settings *hooks*,
  `~/.claude.json`'s per-project history, `mcpServers`, downloads.
- **Auxiliary only (safe fully shared — confirm by canary):** the UI/telemetry keys
  in `~/.claude.json` (impressions, spinner/tips/onboarding flags, update and
  experiment caches), `statsig`/telemetry/stat caches, the non-hook parts of
  `settings.json` (theme, keybindings), and housekeeping files.
- **Neither (a separate concern):** credentials (a security matter — kind 3, not
  work-inference) and the daemon roster (it reveals other sessions' *existence* and
  cwds — metadata, not content).

The canary method confirms the split: a token planted in an auxiliary channel
should produce no work-relevant signal in the reading session, while a token in a
content-bearing one should.

## Method: canaries

For each channel:

1. In session A, write a unique token to the channel — a data token for a read
   channel, a canary *instruction* / skill / hook for an injection channel.
2. Run session B and observe whether the token is **visible** to B (read
   channels) or **acted on** by B (injection channels).
3. Record four cells: A and B each **native** or **sandboxed**. Run A to
   completion before B (A's deferred state flushes at exit), and, for live
   channels, also concurrently.

A cell is a *leak* iff B sees or acts on A's token. Assert on the token, never on
prose.

### Three levels of "obtained"

"B obtained A's token" is not one question. Each level answers a different one, and a
row is only fully characterised once it is clear *which* was measured:

| level | question | needs |
|---|---|---|
| **reachable** | can B open A's data at all? | a scripted reader (`claude --exec`) — free |
| **taken** | did a *normal* B session actually touch it, unprompted? | a real session + `watch-reads.py` |
| **obtainable under direction** | how much does B get when asked to retrieve as much as it can? | a real session, and a longer one |

The third is not a new scope: it is **kind (2), user-directed**, which this document
already reserves as *a positive control, not a threat*. Its job is to make **negative
results interpretable**. Without it, a row where B never touched A's data cannot
distinguish *could not* from *had no reason to* — and every "no leak" verdict is
ambiguous in the same way a quiet `atime` column is. Directing B to try establishes
the upper bound of what is obtainable while the channel is open, which is what the
other two levels are then compared against:

- **reachable but not taken** — the channel is open and idle: little accidental
  exposure, but everything is available to a session that goes looking.
- **taken without direction** — a genuine kind-(1) leak, this study's target.
- **not obtainable even under direction** — the control holds against an active
  attempt, not merely against disinterest.

**A refusal is not isolation.** If B's model declines the request, that is recorded as
*not obtained — declined*, kept distinct from *not obtained — unreachable*, with the
model's response verbatim in the record. Conflating them would credit the sandbox for
something the model did, and the two have opposite implications: a declining model on
an open channel is still an open channel. The prompt is therefore a plain retrieval
instruction with no pressure applied — the measurement is of the container, not of the
model's willingness.

Level 3 is applied **selectively**, since it costs a real session each time: where
[T2](#t2) reports *isolated* (to show it holds against an active attempt) and where
[T1](#t1) reports *no leak* (to show that is not disinterest). A row where T1 leaks
freely and T2 blocks it does not need its upper bound measured.

### State snapshots: write-discovery and the noise floor

The canary tests **reads** (did B obtain A's token); a before/after snapshot tests
**writes** (what a session actually touched) and is a completeness net for channels
this document does not enumerate.

- **Validated instrument first.** The snapshot tool is the measurement device, so
  it ships with its own passing tests *before* any experiment uses it — a buggy
  manifest would silently corrupt every result. Its tests assert each change class
  against a synthetic tree (created / deleted / content-changed / touched-only /
  unchanged → empty diff), determinism (two snapshots of an unchanged tree are
  identical), and edge cases (symlinks recorded not followed; special, vanishing,
  and unreadable files handled, not crashed). Critically it must **not perturb what
  it measures**: capture atime via `stat` and hash with `O_NOATIME`, so the tool's
  own reads never bump the atime/mtime it records (a naive hasher pollutes exactly
  the signal it is supposed to observe). Where `O_NOATIME` is refused — it is the
  owner's privilege — hashing falls back to a plain read, which is why arming
  happens *after* the hash rather than in a separate pass that the fallback could
  silently undo.
- **Write-discovery (manifest diff).** Before and after each session, record a
  manifest over `~/.claude` and `~/.claude.json` (second tier: `/tmp`, `/dev/shm`,
  the project dir): per file `path, size, mtime, sha256`. Diff the two into
  *created / deleted / content-changed (hash) / touched-only (mtime)*. The hash is
  the real write signal; mtime alone is noisy. **Any changed path not in the
  catalog is a channel we missed.**
- **Records that explain, not just verdicts.** A row's record must be detailed enough
  to reconstruct **the path** a leak took, **what triggered or blocked it** within a
  fixed topology and channel, and what a user can do about it *in either direction*.
  Sharing is not always a fault: keeping one session current with another project's
  progress is a legitimate reason to want a channel open. So each row records the
  mechanism, the conditions, and both "to block it" and "to enable it deliberately" —
  a bare leak/no-leak verdict is not a result.
- **Noise floor → content vs auxiliary, measured.** A control session (nothing
  experiment-relevant) shows the files that change every run regardless —
  telemetry, `statsig`, `numStartups`, caches, bookkeeping: the *auxiliary* floor.
  Subtract it; what remains, correlated with the canary content, is
  *content-bearing*. This turns the content/auxiliary split from a-priori into
  measured.
- **Host-side around a sandboxed call.** Snapshot the host `~/.claude` around a [T2](#t2)
  session to see what the sandbox let *through* to shared host state (the
  copyout/append write-backs) — the write-back surface the dispositions describe.
- **Reads.** Detecting that a session *read* a file is worth doing, and a raw atime
  diff is **not** the way: under `relatime` (the Linux default) a read updates atime
  only if atime predates mtime/ctime or is >24h old, and `noatime` disables it — so
  a quiet atime column means "not read **or** read invisibly", which would
  manufacture false confidence. **Arming removes that ambiguity for the files we
  choose to watch:** `snapshot.py manifest --arm` sets each file's atime back to its
  own mtime while taking the baseline, which satisfies the `relatime` rule, so the
  *next* read is recorded. It is one-shot per file (after that read atime leads
  mtime again) and a file the tool could not re-time is reported by path, because an
  unarmed file reads as "not accessed" either way. Arming writes metadata, so it is
  never used on a run whose purpose is to prove a tree was left untouched. For a
  continuous read signal, for a run that must not write to the tree at all, or on
  a `noatime` mount where arming cannot work, use an `inotify` `IN_ACCESS` watch
  over `~/.claude` for the session's lifetime: a kernel read-event stream,
  independent of atime policy, not one-shot, and perturbing nothing. **Measured:
  a host-side `inotify` watch does see reads made inside the sandbox** — the watch
  follows the inode, so a bwrap session reading a bind-mounted file raises
  `IN_OPEN`/`IN_ACCESS` on the host, through read-only binds as well as read-write
  ones. It needs no privileges, unlike `fanotify`, whose mount-wide watch wants
  `CAP_SYS_ADMIN` and which is therefore worth it only for PID attribution.
  `inotify` watches are per-directory and not recursive (so directories created
  mid-run must be picked up), its queue can overflow — `IN_Q_OVERFLOW` means
  dropped events and must be reported, never swallowed — and a **symlink leaving
  the watched tree is a blind spot**: an open resolving to an inode outside the
  watched directories raises nothing, under neither the link path nor the target
  path, so such a tree must be watched too. Measured: `~/.claude` is ~5,600 files
  against a 16,384 queue cap, so overflow is not a realistic risk for it; a large
  project tree in the second tier is a different matter. A file being *opened* is
  still not the model *ingesting* it — for kind (1), the
  content-canary-in-output test stays the authoritative read-relevance signal.
- **Attribution.** Snapshot only around sequential sessions; concurrency blurs
  which session caused a change.

## Isolation dispositions

The sandbox binds `~/.claude` and `~/.claude.json` **read-write**, then applies
one disposition per path:

| Disposition | Inside at start | Written back at exit |
|---|---|---|
| **tmpfs** | empty | nothing (A's writes vanish) |
| **copyout** | empty | entries the session *created*, merged back, never overwriting |
| **append** | own / filtered view, or empty | new lines appended under flock |
| **scoped** | only the current project | that project's own records |
| **(none — default)** | the host's real content | everything (shared, live) |

The consequence matters for the study: for a **sandboxed reader**, tmpfs,
copyout, append and scoped all block reading *another* session's data. But
copyout and append still propagate the **writer's own** new data to the host — so
a **native** reader (or host inspection) can still see it. The isolation governs
what a session *reads*, not whether a session *writes back*.

## Channel catalog

Paths are under `~/.claude` unless noted. "Native" = every session reads and
writes it. "Sandbox" = the disposition applied.

Scope tags (per the three kinds above): **A** and **B** carry the accidental
kind (1) — the study's focus, with A closed by the sandbox in [T2](#t2) and B not.
**C** is mostly kind (2) or tool-side-effect. **D**, and the code-execution use
of **B**/**E**, are kind (3) — security, out of the main scope. **E** and **F**
bear on kind (1) only through LLM-generated tools.

### A. Session state (the sandbox's isolation target)

| Channel | Native | Sandbox |
|---|---|---|
| `projects/<slug>/` memory + `CLAUDE.md` | shared across projects | scoped |
| `projects/<slug>/*.jsonl` transcripts (`--resume`/`--continue`) | shared | scoped |
| `history.jsonl` (prompts, all projects) | shared | append (own, filtered) |
| `plans/` | shared | copyout |
| `file-history/` (undo) | shared | copyout |
| `shell-snapshots/`, `sessions/`, `session-env/`, `jobs/`, `debug/`, `paste-cache/` | shared | tmpfs |
| `daemon/` (roster of sessions, control key) | shared | tmpfs |
| `todos/`, `statsig/` (when present) | shared | shared unless `[claude] hide` |

### B. Global config & extensions — read by every session; writable → injection

All bound read-write and **not** isolated, so **shared in both modes**:

- `CLAUDE.md` — global memory injected into every session
- `settings.json` (and its backups) — including **hook** definitions (code run each session)
- hook scripts kept in the state dir (e.g. a `*-hook.sh` / `*-hook.py`)
- `skills/` — user skills
- `commands/` — custom slash commands
- `plugins/` — plugin code and marketplace
- `~/.claude.json` — per-project **trust** flags, **`mcpServers`**, per-project prompt history, account identity
- `remote-settings.json`, `policy-limits.json` — managed policy

### C. Shared artifacts and logs

Bound read-write, shared in both modes unless noted:

- `downloads/` — files the agent fetched (cross-project; per-project scoping tracked in #52)
- `feedback/` — queued feedback drafts
- daemon and audit logs, telemetry, stats caches
- `responses.log`, `alerts.log` — **append**-isolated (the exception here)

### D. Credentials

- the OAuth credential file, a bundled `gh` config/token dir, editor lockfiles —
  shared in both modes (the `gh`/`ide` dirs are deliberately not isolated so the
  agent can use them from inside a sandbox)

### E. Live IPC / background (not files)

- **Background daemon + workers** — roster plus rendezvous sockets under
  `/tmp/cc-daemon-<uid>/`. Sandbox: `daemon/` tmpfs'd, `/tmp` fresh.
- **MCP servers** — a long-lived server process can hold state across sessions.
- **`/proc/<pid>`** of another session (its `environ`/`cmdline` → secrets) and
  **signals**. Native: same-uid visible. Sandbox: `--unshare-all` (pid namespace,
  fresh `/proc`) closes it.
- **Abstract unix sockets, SysV/POSIX shared memory, message queues.** Sandbox:
  the IPC namespace closes shm/mq; **strict** (own net namespace) closes abstract
  sockets, but **proxy** mode shares the net namespace, so abstract sockets remain
  a channel there.

### F. Host filesystem & OS outside `~/.claude`

- `/tmp`, `/var/tmp`, `/dev/shm` — native shared; sandbox: fresh tmpfs
- `$HOME` dotfiles (`~/.bashrc`, shell history, `~/.gitconfig`, `~/.config/*`) —
  native shared; sandbox: `$HOME` is a read-only tmpfs and these are not bound → hidden
- **the shared project dir and its `.git`** — two sessions in the *same* project
  share these in **both** modes (the project is bound read-write by design);
  cross-*project* sharing is what memory scoping addresses
- **package environments** (pip, global npm, conda `site-packages`) — an install
  a later session imports; sandbox: read-only unless opted in (`[conda] write`)
- **persistent side-effects** — `cron`/`at`, systemd user units, journald: an
  agent schedules work that runs in or for another session; sandbox: no
  cron/systemd/dbus reach (capabilities dropped, default-deny filesystem)

### G. Network-mediated — an external medium both projects can reach

The only family where the **network mode is the independent variable** rather than a
nuisance one. Nothing here lives in `~/.claude`; the medium is outside the machine.

- **shared external medium** — session A publishes (a PR, an issue, a gist, a wiki
  page, a package release) and session B later retrieves it. The crossing is
  accidental in exactly the kind-(1) sense: A publishes as part of its own task and
  B finds it while researching. The sandbox cannot stop A publishing; what it
  decides is whether B can **reach** the medium.
- **remote-backed state** — an MCP server or a synced service that remembers
  per-account context, carrying data between sessions without either one
  publishing anything. Distinct from the `mcpServers` *config* channel (catalog B):
  there the shared thing is the configuration, here it is the remote state behind it.

Reachability by topology, measured:

| | medium reachable | allowlist |
|---|---|---|
| [T1](#t1) native, and `open` | all of the internet | none |
| `proxy` (the default) | allowlisted hosts for a client that honours the proxy variables; **anything at all via a raw socket** | advisory |
| `strict` | allowlisted hosts only | **enforced** by the nft firewall |

That `proxy` is advisory is documented, not a finding of this study
([network.md](network.md), and the guarantee in [design.md](design.md) is scoped to
"every client that honours `HTTPS_PROXY`"); measured here only to fix what the rows
mean. A direct connect to a public address from inside succeeds under `proxy` and
times out under `strict`.

This family is also the clearest case where a user may **want** the flow — a shared
medium is how one project's session is kept current with another's progress. So its
rows record how to get both outcomes, not merely whether a leak occurred.

## Running the study

### Topologies

A `claude` process is sandboxed one-per-bwrap, but a *shell* can be sandboxed once
and then invoke `claude` many times inside it — so several sessions can share one
sandbox. Four topologies:

- <a id="t1"></a>**T1 — two native sessions, shared host.** Two `claude` runs, no sandbox, both
  reading/writing the host `~/.claude`. Baseline; expect full leak on every shared
  channel.
- <a id="t2"></a>**T2 — two separate sandboxes, shared host.** Two `claude` runs, each its own
  bwrap, both binding the host `~/.claude` (the default deployment). The canary
  travels — or is blocked — through the shared host paths per their disposition.
- <a id="t3"></a>**T3 — two sessions inside one sandbox.** Sandbox a shell once
  (`claude --exec bash -l`) and call `claude` from two directories inside it. The
  agent binary stays bound read-only under `--exec`, so a session started inside
  runs natively there. Inside a sandbox the
  context-default is off, so a bare `claude` runs native *within that one sandbox*;
  the two sessions share that sandbox's single set of binds and tmpfs'd dirs, so a
  path isolated *between* sandboxes ([T2](#t2)) is shared *within* one ([T3](#t3)). This is what
  a user creates by running several agents in one shell sandbox, and it is where
  per-invocation isolation does not apply. Note both sessions write memory under
  the `projects/` **tmpfs** unless their own directory happens to be the bound one,
  so within one sandbox they share memory that then vanishes on exit — a result
  about co-residence, not about host state.
- <a id="t4"></a>**T4 — nested sandbox (note).** `AGENT_SANDBOX= claude` inside the shell sandbox
  clears the marker and asks the launcher to sandbox again; nesting bwrap needs the
  outer sandbox's seccomp to permit a new user namespace, so this is a variant to
  characterize, not assume.

**Shell-sandbox composition.** For [T3](#t3)/[T4](#t4) the shell sandbox must expose what a
profile needs. A `[bash]` section (or an engine arg / env) naming
`profiles = claude` would build the shell sandbox as a *subset of* the claude
sandbox — the same binds, ports and state-isolation the claude profile applies —
so `claude` runs inside correctly and inherits the claude profile's host-facing
isolation. Two limits to record:

1. **Memory scoping binds a set, not just one.** `profile_memory_scope` tmpfs's
   `projects/` and rebinds a chosen set (the current project plus each shared one),
   so a shell sandbox can bind exactly the projects it hosts — auto-discovered
   under its cwd (`foo/a`, `foo/b`) or declared — each scoped. The inner `claude`
   is native at its own cwd, so `cd a && claude` auto-loads only `a`'s memory. The
   residual limit is *physical co-residence*: those projects' memory is present in
   the one sandbox, so a deliberate read (kind 2/3) could cross; only separate
   sandboxes ([T2](#t2)) make one project's data physically absent from another's view.
   For the accidental kind (1), per-project auto-scope is what matters.
2. **Co-located sessions are one trust domain.** Two `claude` sessions in one
   shell sandbox share that sandbox's ephemeral state by construction, so
   isolation *between* projects still means separate sandboxes ([T2](#t2)), never
   co-location ([T3](#t3)).

So for the study, [T3](#t3) is the "one trust domain" case and [T2](#t2) is the isolation test;
`profiles = claude` is sufficient to *run* claude inside and inherit its
host-facing isolation, but does not (and cannot) isolate co-located sessions from
each other.

- **Sequencing.** copyout/append/scoped write back at exit, so run A to
  completion, then B, to exercise the write-back path. Run A and B concurrently to
  exercise the live channels (daemon, MCP, abstract sockets, `/proc`).
- **Determinism.** The read and IPC channels can be tested without an LLM by a
  scripted writer/reader run under the *same* sandbox machinery: `claude --exec CMD`
  applies the identical binds and dispositions and runs CMD instead of the agent,
  giving exit-code assertions. (This replaced a planned generic `<cmd>-sandbox`
  profile: the sandbox a shell needs *is* the agent's, with the entrypoint
  swapped, so no profile composition was required.) The **injection** channels need a real `claude` turn for
  the "B acts on it" half; a scripted reader can only confirm read-visibility.

## Experiment matrix

The finalized experiment list: the **content-bearing** channels only (auxiliary
channels are safe — see above), across the two topologies that decide cross-project
isolation — **[T1](#t1)** (two native sessions, shared host: the baseline, where a leak
should appear) and **[T2](#t2)** (two separate sandboxes, default scoped mode: the
isolation test). Each experiment plants a canary in project A's copy of the
channel, runs a session in project B (native for [T1](#t1), sandboxed for [T2](#t2)), and records
whether B **obtains or acts on** A's canary. "scripted read" = a deterministic
reader with no LLM, run as `claude --exec <cmd>` — the same sandbox the agent would
get, with the command swapped in; "real claude" = a reader session checked for
whether the canary reaches its context or behavior.

Reads are detected with `probes/watch-reads.py` (a host-side `inotify` watch, which
sees reads made inside the sandbox), falling back to `probes/snapshot.py --arm` when
no live collector can be attached. Writes are detected by a `snapshot.py` manifest
diff. **Every read-based row needs the symlink pre-check first** — a read through a
symlink leaving the watched tree raises nothing, so a null result is only meaningful
alongside evidence that nothing could have been read invisibly.

**Setup, or the rows measure nothing:** A and B are **separate repositories**; the
harness must not set `CLAUDE_CODE_PROJECT_DIR_NAME` (honoured whenever
`CLAUDE_CONFIG_DIR` is set, as it is here, and it collapses every session into one
project); and paths stay under 200 converted characters so no slug is truncated.

**Per-project state — the sandbox's project scoping should isolate these in [T2](#t2):**

| # | Channel | Expected [T1](#t1) (native) | Expected [T2](#t2) (sandboxed) | Probe |
|---|---|---|---|---|
| 1 | project memory (`projects/<slug>/memory/`) | reachable on disk; auto-ingested only if `memory_default = shared`. A's canary goes under the slug of **A's repository root**, which is where a native session keeps it | **isolated** — `projects/` tmpfs'd, only B's own slug rebound. Note B keys memory to its **directory** here, not its repository, since the repo is not visible inside: plant and look under the slug each reader actually uses | real claude + scripted read |
| 2 | transcripts (`projects/<slug>/*.jsonl`) | reachable | **isolated** (same scoping) | scripted read |
| 3 | plans (`plans/`) | reachable | **isolated** — copyout, empty at start | scripted read |
| 4 | prompt history (`history.jsonl`) | every project's prompts | **isolated** — append, own/filtered view | scripted read |

**Global / config — bound whole, not scoped; expected to leak in both:**

| # | Channel | Expected [T1](#t1) (native) | Expected [T2](#t2) (sandboxed) | Probe |
|---|---|---|---|---|
| 5 | global `CLAUDE.md` (`~/.claude/CLAUDE.md`) | shared | **shared** (bound rw) | real claude (auto-ingest) |
| 5b | **ancestor `CLAUDE.md`** — any parent directory's, e.g. `$HOME/CLAUDE.md` or a shared parent of A and B | **shared**: loaded *"from your current working directory and every directory above it"*, ordered filesystem-root down ([memory](https://code.claude.com/docs/en/memory)); no documented stop at the repository root | **isolated, expected** — the engine binds the session's directory, not its parents, so the cascade is truncated inside. The one row here where the sandbox is expected to *help* | real claude (auto-ingest) |
| 6 | `settings.json` hooks | shared | **shared** | real claude (hook fires) |
| 7 | `skills/` | shared | **shared** | real claude (skill offered/invoked) |
| 8 | `commands/` | shared | **shared** | real claude |
| 9 | `plugins/` | shared | **shared** | real claude |
| 10 | `mcpServers` (`~/.claude.json`) | shared | **shared** | scripted read + real claude |
| 11 | per-project history in `~/.claude.json` | shared | **shared** — `.claude.json` is bound whole, *not* scoped | scripted read |
| 12 | `downloads/` | shared | **shared** (until #52) | scripted read |

**Network-mediated — the rows where the network mode decides the answer ([G](#g-network-mediated--an-external-medium-both-projects-can-reach)):**

| # | Channel | Expected [T1](#t1) (native) | Expected [T2](#t2) (sandboxed) | Probe |
|---|---|---|---|---|
| 13 | shared external medium (A publishes; B fetches) | **reachable** — no allowlist at all | **depends on the mode, and this row is run in each**: `open` reachable; `proxy` reachable if allowlisted, and reachable regardless via a raw socket; `strict` only if allowlisted | scripted read (fetch a canary URL) |
| 14 | remote-backed state (an MCP server or synced service that remembers per-account context) | **shared** — same account, same remote state | **shared wherever the host is reachable**; the sandbox gates reach, not the remote's memory | real claude + scripted read |

Expected headline: the first group confirms the per-project scoping works ([T2](#t2)
isolates); the second is where the sandbox does **not** help — the leaks to decide
about, with row 5b the exception that should be isolated by the same property
(parents unbound) that makes a sandboxed subdirectory a non-repository. Row 11 is
the sharp one: it is per-project *data*, yet the monolithic
`~/.claude.json` is bound whole, so a sandboxed B still reads A's project history —
a per-project leak the project scoping misses because the data isn't under
`projects/`.

Each row is one checklist item in the tracking issue (#56) and one result row here
once measured (leak / no-leak, and a link if it opens a follow-up).

## Environment / running on the host

The experiments run **on the host** and are **user-triggered** — scripts under
`probes/`, host-only. Real `claude` needs credentials, the network and the API, and
the sandbox stack (bwrap/pasta/seccomp + the proxy) needs the host; none of it runs
in CI. This mirrors `tests/live` and the fake-vs-real probe.

**Isolate the study from real state — verified, not assumed.** Experiments write
canaries and run sessions that mutate claude state; they must not touch the real
`~/.claude`. Whatever isolation we use is **verified with the (validated) snapshot
tool**: snapshot the real `~/.claude`, `~/.claude.json` and `/tmp/cc-daemon-<uid>/`
before and after an isolated run and assert **zero changes** — the study does not
begin until this passes (this is what makes the snapshot tool's own validation a
prerequisite). Two candidate mechanisms:

- **Throwaway `HOME`** with the binary, proxy CA, seccomp filter and allowlist
  symlinked in — what `e2e/install.bats` already exercises.
- **`CLAUDE_CONFIG_DIR`** to relocate claude's state. Cleaner, but two unknowns:
  the engine binds `$HOME/.claude` literally (`profile_config_binds`), so it needs a
  small change to bind `CLAUDE_CONFIG_DIR` instead; and it is unverified that claude
  honors the variable for *every* write. Adopt it only once the snapshot check above
  shows the real `~/.claude` stays untouched; otherwise fall back to the throwaway
  `HOME`.

Either way, `/tmp/cc-daemon-<uid>/` is keyed by the real uid, not `HOME`, so the
daemon path is shared regardless — include it in the verification snapshot.

**Pin the claude version.** Results depend on the claude version, so pin it, disable
auto-update (a self-update would swap the binary mid-study), and **record the exact
version with every result**. The study is meant to be re-run against a newer pinned
version later to compare, so the version is part of each result, not a footnote.

**Network mode.** For rows 1–12 the mode is **not** a variable: the sandbox's bind
set is computed before the network is chosen, and a normalised argv diff shows the
modes are purely *additive* — `open` adds `--share-net`, `proxy` adds that plus the
proxy/CA `--setenv` block and (where the proxy CA is installed) one read-only bind of
the combined bundle over the system trust path; `strict` wraps the same argv in
pasta. **Nothing is removed and no `~/.claude` bind changes.** So rather than
tripling every row, **row 2 is run in all three modes as an invariance control** and
the result recorded; if it is invariant, the remaining filesystem rows are run in one
mode — `none` for the deterministic ones (fastest, no proxy or credentials needed)
and `proxy` for the real-claude ones (the default deployment, and the API must be
reachable). If it is *not* invariant, that is a more interesting result than any
single row and the plan changes.

Rows 13–14 are the exception and are run **per mode**, because there the mode is what
decides the answer.

**Stage by cost.** Rows 1–4 and 10–12 ("scripted read") need only the sandbox + the
isolated state + two separate project repositories + `claude --exec` — no
credentials, no network; run these first. Rows 5–9 (and the auto-ingest halves) need credentials in the isolated
state, the proxy on `:8888`, a cheap model, and in-project no-tool prompts.

**Tooling and stability.** `probes/snapshot.py` for writes (`--arm` when reads must
be detected without a live collector) and `probes/watch-reads.py` for reads — a
host-side `inotify` watch, measured to see reads made inside the sandbox, and
unprivileged, unlike `fanotify`'s mount-wide watch. Sequential sessions during any
snapshot window (neither instrument attributes an access to a process); a control
(noise-floor) run before each batch; and the **symlink pre-check** before any
read-based row, since a read through a symlink leaving the watched tree raises
nothing at all.

**Harness constraints**, each learned the hard way and each able to invalidate a
row silently:

- **Never set `CLAUDE_CODE_PROJECT_DIR_NAME`.** It is honoured whenever
  `CLAUDE_CONFIG_DIR` is set — which this study always sets — and it stores every
  session's transcripts *and* memory under one name, collapsing the independent
  variable.
- **Keep experiment paths short.** Past 200 converted characters the project slug is
  truncated and hashed, so a canary planted by path lands somewhere else.
- **A and B must be separate repositories**, not two subdirectories or two worktrees
  of one — those share memory by construction.
- **Use `--quiet`** so captured output carries results rather than policy banners.
