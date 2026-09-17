# Cross-project leak study: results

Measured results for the experiment matrix in
[cross-project-channels.md](cross-project-channels.md). The plan lives there; what
was observed lives here, so the plan does not grow with every run.

Each row keeps a **table that gains one line per run** — read down a column to
compare a result with earlier ones — and an **analysis** that is updated in place
rather than duplicated per run. Raw records (per-cell JSON, instrument output) stay
on the machine that ran them, under `probes/results/`, which is git-ignored: they
are full of absolute host paths and are not published. Everything here is
host-generic, and a result is reproducible by re-running its script at the recorded
harness commit rather than by reading it back out of git history.

## Why this file starts again

Every result collected before 2026-09-17 was produced by a harness that gave each
**row** one throwaway HOME and one pair of project directories, shared by all of that
row's cells. Three defects follow from that, and they are defects of the instrument,
not of any row:

- **Cells could read each other.** Every cell of a row ran in the same project
  directory, so each session could read the transcripts of the sessions before it. A
  measured session did exactly that and answered from a previous cell's reply rather
  than from the channel under test — it said so itself: *"it only reached me because a
  previous session in this project printed it into its own transcript"*.
- **The paths announced the experiment.** A project's slug is its own path, so a
  session's working directory read `…-probes-results-leak-25-arithmetic-canary-…-b`.
  Row 24 had already measured a session declining once it recognised the harness.
- **The canaries announced it too.** Ten rows decided `obtained` by whether a
  `LEAK<runid>-…` string appeared in a reply, and a session had declined to quote one
  because it *"is shaped like a tracer"*.

The harness now builds **one tree per experiment**: a new HOME, a new config and new
repositories per cell, under `/tmp` with time-sortable hexid names, moved into the run
directory when the cell ends. Tokens are pure hex. No result from the old instrument is
carried over; the old file is kept verbatim as
[leak-results-old1.md](leak-results-old1.md) so the two can be compared, and a row is
recorded here only once it has been re-run.

Verdicts come from `probes/leak/record.py` and mean:

| verdict | meaning |
|---|---|
| `obtained` | the canary was read |
| `not-obtained-unreachable` | the file could not be opened (errno recorded) |
| `not-obtained-absent` | the file opened; the canary was not in it |
| `invalid-reader-output` | the reader produced nothing usable — a failed experiment, **not** a negative |

## Status

`./probes/leak/run-all.sh` runs every row below; `--free` runs the ones that cost
nothing. A row is listed as re-measured only when its run passed the validity gate.

| row | channel | re-measured |
|---|---|---|
| 1 | project memory | **yes** — 2026-09-17 |
| 2 | transcripts | **yes** — 2026-09-17 |
| 3 | plans | **yes** — 2026-09-17 |
| 4 | prompt history | **yes** — 2026-09-17 |
| 10–12 | `mcpServers`, per-project state, `downloads/` | **yes** — 2026-09-17 |
| 16 | session artefacts under `projects/` | **yes** — 2026-09-17 |
| 15, 17, 18 | `agent-memory/`, `backups/`, uncatalogued paths | re-measured, **held** (see below) |
| 5, 5b | global and ancestor `CLAUDE.md` | pending |
| 6 | `settings.json` hooks | pending |
| 7 | `skills/` | pending |
| 8 | `commands/` | pending |
| 9 | `plugins/` | pending |
| 13 | network media | pending |
| 14a | remote capability (MCP) | pending |
| 19–22 | `rules/`, `output-styles/`, `agents/`, `workflows/` | pending |
| 23, 24 | levels 2 and 3 | pending |
| 25 | levels 2 and 3, unremarkable canary | pending |
| 26 | which reachable paths a directed session reaches | pending |

---

## Row 1 — project memory

**Question (level 1, reachability):** can a session in project B open project A's
`projects/<slug>/memory/`? The reader contains no LLM, so this measures the container
alone and the result is model-independent.

**Script:** `probes/leak/row-01-memory.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-17 | 2.1.273 | n/a (no LLM) | T1 native — A's memory | n/a | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2 sandboxed — A's memory | `none` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-17 | 2.1.273 | n/a | T2 — **B's own** memory (control) | `none` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2-share — A's memory (`[share-memory]` names A) | `none` | `obtained`, write `EROFS`, source intact |
| 2026-09-17 | 2.1.273 | n/a | T2-share-all — A's memory (`[share-memory] all`) | `none` | `obtained` |

Validity gate: **7/7 pass**, 5 cells, 5 independent trees. Symlink pre-check clean per
cell. Noise floor: 0 ambient changes.

### Analysis (provisional)

> Interpretation is deferred until every row is collected.

A project's auto-memory lives at `<config>/projects/<slug>/memory/`, a sibling of that
project's transcripts under one shared `projects/` directory — so natively nothing
separates one project's notes from another's but the directory name. Under the sandbox
the default `memory = scoped` disposition tmpfs-hides `projects/` and rebinds only the
session's own slug, which is why A's memory is ENOENT while B's own is `obtained` in
the same sandbox.

`[share-memory]` naming A is the one **selective** lever the study has found: it
delivers exactly A's `memory/` and nothing else, read-only — a write attempt returns
`EROFS` and A's canary is byte-identical on the host afterwards.

### For users

Another project's memory is not readable from a sandboxed session, and sharing it is
an explicit, per-project, read-only opt-in.

---

## Row 2 — transcripts

**Question (level 1):** can a session in project B open project A's transcript
(`projects/<slug>/*.jsonl`)? Repeated in all three network modes, which is the
**invariance control** for the filesystem rows.

**Script:** `probes/leak/row-02-transcripts.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-17 | 2.1.273 | n/a (no LLM) | T1 native — A's transcript | n/a | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2 — A's transcript | `none` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-17 | 2.1.273 | n/a | T2 — A's transcript | `proxy` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-17 | 2.1.273 | n/a | T2 — A's transcript | `strict` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-17 | 2.1.273 | n/a | T2 — **B's own** transcript (control) | `none` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2 — **B's own** transcript (control) | `proxy` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2 — **B's own** transcript (control) | `strict` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2-share — A's **memory** (`[share-memory]` names A) | `none` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2-share — A's **transcript** (same entry) | `none` | `not-obtained-unreachable` (ENOENT) |

Validity gate: **7/7 pass**, 9 cells, 9 independent trees.

### Analysis (provisional)

The network mode changes nothing about a filesystem verdict — three modes, identical
results — so the remaining filesystem rows run one mode.

The share pair is the finding: the same `[share-memory]` entry that delivers A's
`memory/` does **not** deliver A's transcript, which sits beside `memory/` rather than
inside it. Memory can be shared selectively; transcripts cannot be shared at all.

### For users

Transcripts are all-or-nothing: there is no lever that exposes one project's
conversation history to another.

---

## Row 3 — plans

**Question (level 1):** can a session in project B open a plan A wrote to
`~/.claude/plans/`, a flat directory not keyed by project at all?

**Script:** `probes/leak/row-03-plans.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-17 | 2.1.273 | n/a (no LLM) | T1 native — A's plan | n/a | `obtained`, 1 entry in `plans/` |
| 2026-09-17 | 2.1.273 | n/a | T2 sandboxed — A's plan | `none` | `not-obtained-unreachable` (ENOENT), **0 entries** |
| 2026-09-17 | 2.1.273 | n/a | T2 — B writes its own plan inside, reads it back | `none` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2-share-all — A's plan | `none` | `not-obtained-unreachable`, 0 entries |
| 2026-09-17 | 2.1.273 | n/a | T2-writeback — B's plan, read from the **host** | n/a | `obtained`, 2 entries |

Validity gate: **7/7 pass**, 4 cells (the write and its host read are one experiment
and share one tree by necessity).

### Analysis (provisional)

A different mechanism from rows 1–2 with the same read outcome: `plans/` is **copyout**,
not scoped, so the directory a sandboxed session sees is *empty* rather than hidden —
one entry natively, zero inside. No lever reaches it: `[share-memory] all` leaves it
empty too.

And the first **outward** cell in the study: the plan B wrote inside the sandbox was on
the host after the session exited, readable by a native session in any project. Copyout
merges a session's new entries back.

### For users

Plans cannot be shared and cannot be hidden selectively — but a plan written inside a
sandbox does reach the host.

---

## Row 4 — prompt history

**Question (level 1):** can a session in project B read A's prompts from
`~/.claude/history.jsonl`? This is the first channel that is **filtered** rather than
removed, so the row also tests the filter's two plausible collisions.

**Script:** `probes/leak/row-04-history.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-17 | 2.1.273 | n/a (no LLM) | T1 native — A's prompt | n/a | `obtained`, 4 lines |
| 2026-09-17 | 2.1.273 | n/a | T2 — A's prompt | `none` | `not-obtained-absent`, 2 lines |
| 2026-09-17 | 2.1.273 | n/a | T2 — **B's own** prompt (control) | `none` | `obtained`, 2 lines |
| 2026-09-17 | 2.1.273 | n/a | T2 — sibling project whose path **extends** B's | `none` | `not-obtained-absent` |
| 2026-09-17 | 2.1.273 | n/a | T2 — A's line carrying `"project":"<B>"` **nested** | `none` | `obtained` |
| 2026-09-17 | 2.1.273 | n/a | T2-share-all — A's prompt | `none` | `not-obtained-absent` |
| 2026-09-17 | 2.1.273 | n/a | T2 — B appends a prompt inside | `none` | `obtained`, 3 lines |
| 2026-09-17 | 2.1.273 | n/a | T2-writeback — that prompt on the **host** | n/a | `obtained`, 5 lines |

Validity gate: **7/7 pass**, 7 cells.

### Analysis (provisional)

`history.jsonl` is `append` + a project filter, so the file is present inside the
sandbox and the verdict is `not-obtained-absent` rather than unreachable: B sees a
2-line file where the host has 4.

The engine's prefix claim **holds** — a sibling project whose path extends B's is
filtered out. The collision that does **not** hold is by position: the filter matches
the literal `"project":"<dir>"` anywhere on the line, so A's line carrying that string
nested inside `pastedContents` **was delivered**. Filed as
[#73](https://github.com/pearu/agent-sandbox/issues/73); a pasted *string* cannot
collide, because its quotes escape.

Write-back merges without duplication: 4 host lines plus 1 appended inside gives 5, not 6.

### For users

Another project's prompts are filtered out of the history a sandboxed session sees,
with one known gap (#73) for structured content that embeds a project path.

---

## Rows 10–12 — the channels bound whole

**Question (level 1):** three paths outside `projects/` — the global `mcpServers` block
and the per-project entries in `~/.claude.json`, and the flat `downloads/` directory.
Each cell carries an **isolation check** as well as a negative control: a read of A's
transcript, known scoped, from the same sandbox. A row expected to leak cannot use "B
reads its own data" as its control, because that is `obtained` whether or not the
sandbox applied at all.

**Scripts:** `probes/leak/row-10-mcpservers.sh`, `row-11-project-history.sh`,
`row-12-downloads.sh`

| date | Claude Code | row | cell | verdict |
|---|---|---|---|---|
| 2026-09-17 | 2.1.273 | 10 | T1 native — A's `mcpServers` entry | `obtained` |
| 2026-09-17 | 2.1.273 | 10 | T2 sandboxed — A's `mcpServers` entry | `obtained` |
| 2026-09-17 | 2.1.273 | 10 | T2 — B's own per-project `mcpServers` | `obtained` |
| 2026-09-17 | 2.1.273 | 10 | T2 isolation check — A's transcript | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | 11 | T1 native — A's `lastSessionFirstPrompt` | `obtained`, 2 projects visible |
| 2026-09-17 | 2.1.273 | 11 | T2 sandboxed — A's `lastSessionFirstPrompt` | `obtained`, **2 projects visible** |
| 2026-09-17 | 2.1.273 | 11 | T2 — B's own entry | `obtained` |
| 2026-09-17 | 2.1.273 | 11 | T2 isolation check — A's transcript | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | 12 | T1 native — A's downloaded document | `obtained`, 2 entries |
| 2026-09-17 | 2.1.273 | 12 | T2 sandboxed — A's downloaded document | `obtained`, **2 entries** |
| 2026-09-17 | 2.1.273 | 12 | T2 — B's own download | `obtained` |
| 2026-09-17 | 2.1.273 | 12 | T2 isolation check — A's transcript | `not-obtained-unreachable` |

Validity gate: **7/7 pass** on each row; 4 cells and 4 independent trees each.

### Analysis (provisional)

All three are bound whole. The isolation check is what makes that a statement about the
channel rather than about the harness: in the same sandbox, in the same cell, A's
transcript is ENOENT while A's `mcpServers` entry, A's last opening prompt and A's
downloaded file are all readable.

Row 11 is the sharpest of the three, because the leak is not a file the user chose to
keep — it is the **text of another project's last opening prompt**, sitting in
`~/.claude.json` beside a full list of that user's project paths, and a sandboxed
session sees the whole table.

### For users

Nothing outside `projects/` is scoped. A sandboxed session reads another project's MCP
configuration, its last prompt and its downloads as a matter of course.

---

## Row 16 — session artefacts under `projects/`

**Question (level 1):** the scoping of `projects/` was measured on transcripts and
memory. Does it reach the rest of a project's subtree — `subagents/`, `tool-results/`,
and the `.orphaned-*` / `.superseded-*` files? `tool-results/` matters most: it holds
file content spilled out of a transcript that grew too large.

**Script:** `probes/leak/row-16-session-artifacts.sh`

| date | Claude Code | cell | verdict |
|---|---|---|---|
| 2026-09-17 | 2.1.273 | T1 native — A's spilled tool output | `obtained` |
| 2026-09-17 | 2.1.273 | T2 — A's `subagents/` | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | T2 — A's `tool-results/` | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | T2 — A's `.orphaned-*` transcript | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | T2 — A's `.superseded-*` transcript | `not-obtained-unreachable` |
| 2026-09-17 | 2.1.273 | T2 — **B's own** spilled tool output (control) | `obtained` |

Validity gate: **7/7 pass**, 6 cells, 6 independent trees.

### Analysis (provisional)

The scoping covers a project's **whole subtree**, not just the transcript file. That is
a confirmation the study needed rather than a new finding, and it closes the most
worrying of the four: spilled tool output is file content, and it is as unreachable as
the conversation it came from.

---

## Rows 15, 17, 18 — re-measured, deliberately **not** recorded as results

These rows have been re-run under the per-cell harness and all three are valid. They are
not written up, for the reason they were held before: every path they reach has **no
disposition at all** in the engine, so what they describe is a decision not yet made
rather than behaviour to characterise. They are tracked as
[#74](https://github.com/pearu/agent-sandbox/issues/74)–[#81](https://github.com/pearu/agent-sandbox/issues/81)
and structurally as [#82](https://github.com/pearu/agent-sandbox/issues/82) — the default
for an unclassified `~/.claude` path is *exposed*. Results land here after the
dispositions settle and the rows are re-run against them.

What the runs do confirm, in one line each: `agent-memory/` is readable from another
project; `backups/` is readable and survives `claude project purge` (the purge itself
works — the live config no longer carries the canary); and every one of the nine
uncatalogued paths from the product documentation is readable, with the isolation check
ENOENT in the same cell.
