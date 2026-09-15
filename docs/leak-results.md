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

Verdicts come from `probes/leak/record.py` and mean:

| verdict | meaning |
|---|---|
| `obtained` | the canary was read |
| `not-obtained-unreachable` | the file could not be opened (errno recorded) |
| `not-obtained-absent` | the file opened; the canary was not in it |
| `invalid-reader-output` | the reader produced nothing usable — a failed experiment, **not** a negative |

---

## Row 1 — project memory

**Question (level 1, reachability):** can a session in project B open project A's
`projects/<slug>/memory/`? The reader contains no LLM, so this measures the container
alone and the result is model-independent. Whether a real session *ingests* another
project's memory is the "real claude" half of this row's probe and is not yet measured.

**Script:** `probes/leak/row-01-memory.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-15 | 2.1.272 | n/a (no LLM) | T1 native — A's memory | n/a | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2 sandboxed — A's memory | `none` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-15 | 2.1.272 | n/a | T2 — **B's own** memory (control) | `none` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2-share — A's memory (`[share-memory]` names A) | `none` | `obtained`, write `EROFS` |
| 2026-09-15 | 2.1.272 | n/a | T2-share-all — A's memory (`[share-memory] all`) | `none` | `obtained` |

Validity gate: **6/6 pass**, 5 cells. Symlink pre-check clean. Noise floor: **0**
ambient changes — no conversation was in progress during this run, which is what an
idle control window can actually capture (contrast row 2, where two of the observing
session's own event-driven writes had to be classified).

### Analysis (provisional)

> Interpretation is deferred until every row is collected; what follows is the
> mechanism this row's data supports, to be revisited against the full set.

**The path.** A project's auto-memory lives at `<config>/projects/<slug>/memory/`, a
sibling of that project's transcripts under one shared `projects/` directory — so
natively nothing separates one project's notes from another's but the directory name.
Which slug a session uses differs between the topologies (repository natively,
directory inside the sandbox, since the engine binds the session's directory and not
its parents), and that is documented behaviour rather than a finding of this row; here
A and B are separate repositories at their own roots, so the two keys name the same
slug and the canary is planted once.

**What blocks it.** The same mechanism as row 2: `memory = scoped`, the default, puts
a tmpfs over `<config>/projects` and rebinds only the current project. **ENOENT, not
EACCES** — A's directory is absent inside, not present-and-forbidden, which does not
depend on the reader's privileges. Both controls fired: T1 `obtained` (the canary was
really reachable with nothing isolating it) and B's own memory `obtained` inside the
same sandbox (the config *is* mounted in there, so the ENOENT is the scoping and not
an empty sandbox).

**Memory is the one channel with a working selective-sharing lever.** An approved
`[share-memory]` entry naming A gives B exactly A's memory — and the same entry, in
row 2, did *not* give B A's transcript. So for memory the choice is genuinely
per-project, while for transcripts it is all projects or none. The blunt levers
(`[share-memory] all`, or the global `memory_default = shared`) also return
`obtained`, as expected, and are the wrong tool when one project is what you meant.

**The share is read-only, measured.** A write into the shared memory from inside B's
sandbox failed with **EROFS**, and A's canary file was verified byte-identical on the
host after the run. So B can *learn from* A's notes without being able to *corrupt*
them — which matters because the read verdict alone would leave a user who opens a
share unable to tell whether they had also granted write access.

### For users

**To keep memory isolated:** nothing to do. `scoped` is the default and is what
produces this result.

**To share one project's memory deliberately:** put `[share-memory]` naming that
project in the reading project's `.agent-sandbox` and approve it with `--trust`. It
grants that project's `memory/` read-only, and nothing else — not its transcripts, not
any other project. This is the lever that does not exist for transcripts.

**Reach for `all` or `memory_default = shared` only if you mean every project**, since
both also expose every project's transcripts.

### Not yet measured

Level 2 — whether a real session ingests another project's memory into its context
unprompted, which is the `memory_default = shared` case the matrix flags — and level 3.
Both need real sessions.

---

## Row 2 — transcripts

**Question (level 1, reachability):** can a session in project B open project A's
transcript? The reader contains no LLM, so this measures the container alone and the
result is model-independent. Whether a real session would *look* (level 2), and what
one obtains when told to try (level 3), are separate and not yet measured.

**Script:** `probes/leak/row-02-transcripts.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-15 | 2.1.272 | n/a (no LLM) | T1 native — A's transcript | n/a | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2 sandboxed — A's transcript | `none` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-15 | 2.1.272 | n/a | T2 sandboxed — A's transcript | `proxy` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-15 | 2.1.272 | n/a | T2 sandboxed — A's transcript | `strict` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-15 | 2.1.272 | n/a | T2 — **B's own** transcript (control) | `none` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2 — **B's own** transcript (control) | `proxy` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2 — **B's own** transcript (control) | `strict` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2-share — A's `memory/` (`[share-memory]` names A) | `none` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2-share — A's transcript (same share) | `none` | `not-obtained-unreachable` |

Validity gate: **6/6 pass**, 9 cells. Symlink pre-check clean. Noise floor: 2
ambient changes, both classified as the observing session's own event-driven writes
(`responses.log` from its `Stop` hook, `history.jsonl` atime) — a conversation was
in progress during the run, which an idle control window cannot capture by
construction.

### Analysis (provisional)

> Interpretation is deferred until every row is collected. Reading one row's story
> into the next is how a study drifts, and the findings that matter — which channels
> the sandbox closes and which it leaves open — are visible only across rows. What
> follows is the mechanism this row's data supports, to be revisited against the
> full set.

**The path.** A transcript is written to `<config>/projects/<slug>/<session-id>.jsonl`,
where the slug is the **working directory** with non-alphanumerics replaced by `-`.
Every project's transcripts live side by side in one config directory, so natively
any process running as the user can read any project's — nothing separates them but
the filename.

**What blocks it.** `memory = scoped`, the default, puts a tmpfs over
`<config>/projects` and rebinds only the current project. Another project's directory
therefore does not exist inside the sandbox. The errno is the evidence: **ENOENT, not
EACCES** — the directory is *absent*, not present-and-forbidden, which is a stronger
property than a permission check and does not depend on the reader's privileges.

**Why the result is trustworthy.** Both controls fired. The positive control (T1)
returned `obtained`, so the canary really was reachable when nothing isolated it — a
broken plant would have shown up here rather than masquerading as isolation. The
negative control — B reading **its own** transcript inside the same sandbox —
returned `obtained`, so the config *is* present inside and the ENOENT is the scoping
at work rather than an empty sandbox. Without that second control, "unreachable" and
"nothing is mounted in there at all" are the same observation.

**Network mode makes no difference**, as the bind-set comparison predicted: the
sandbox's binds are computed before the network is chosen, and `none`, `proxy` and
`strict` gave identical verdicts. This is the invariance control for rows 1–12; the
remaining filesystem rows need not repeat all three modes.

### For users

**To keep transcripts isolated:** nothing to do. `scoped` is the default, and it is
what produces this result.

**To share them deliberately** — a legitimate goal, e.g. to let one session learn
from another project's history — the only lever is `memory_default = shared` or a
dot-file `[share-memory] all`, both of which expose **every** project's memory *and*
transcripts.

**There is no way to share one project's transcripts selectively — measured.** With
an approved `[share-memory]` entry naming project A, a reader inside B's sandbox
obtains A's `memory/` and not A's transcript (cells `T2-share`, both above). The
memory cell is what makes the transcript cell mean something: without it, "the
transcript did not come through" would be explained equally well by the share never
taking effect. The entry binds `projects/<slug>/memory` read-only, and transcripts are siblings of
`memory/` rather than inside it. So the choice is all projects or none, and reaching
for `shared` to solve a single-project problem grants far more than intended.

### Not yet measured

Level 2 (does a normal session read another project's transcript unprompted) and
level 3 (what one obtains when asked to retrieve as much as it can). Both need real
sessions, and level 3's negative result would be model-relative — see the Method
section on the three levels.

---

## Row 3 — plans

**Question (level 1, reachability):** can a session in project B open project A's plan
documents in `plans/`? The reader contains no LLM, so this measures the container alone.

**Script:** `probes/leak/row-03-plans.sh`

| date | Claude Code | model | cell | net | verdict |
|---|---|---|---|---|---|
| 2026-09-15 | 2.1.272 | n/a (no LLM) | T1 native — A's plan | n/a | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2 sandboxed — A's plan | `none` | `not-obtained-unreachable` (ENOENT), `plans/` empty |
| 2026-09-15 | 2.1.272 | n/a | T2 — B writes a plan inside, reads it back (control) | `none` | `obtained` |
| 2026-09-15 | 2.1.272 | n/a | T2-share-all — A's plan under `[share-memory] all` | `none` | `not-obtained-unreachable` (ENOENT) |
| 2026-09-15 | 2.1.272 | n/a | T2-writeback — B's plan read from the **host** after exit | n/a | `obtained` |

Validity gate: **6/6 pass**, 5 cells. Symlink pre-check clean. Noise floor: 0 ambient
changes.

### Analysis (provisional)

> Interpretation is deferred until every row is collected; what follows is the
> mechanism this row's data supports, to be revisited against the full set.

**A different mechanism from rows 1–2, with the same read outcome.** `plans/` is not
scoped — it is **copyout**: the engine binds an *empty* staging directory over it and
at exit merges back the entries the session created, never overwriting. So A's plan is
unreachable because the directory B sees is **empty**, not because A's subtree was
hidden. The directory listing is the evidence, and the reason the reader reports it:
`plans/` held one entry natively and **zero** inside, in every sandboxed cell.

**The control had to change shape, and that is itself a property of copyout.** B has no
plan of its own inside, because the directory starts empty for *every* session — so
unlike rows 1–2 there is nothing of B's to read back as a negative control. Instead B
**wrote** a plan inside and read it back: `obtained`, with the listing empty beforehand.
That is what distinguishes "A's plan is absent" from "`plans/` is not mounted in there
at all".

**No lever reaches plans.** `[share-memory] all` — the blunt lever that exposes every
project's memory *and* transcripts — leaves `plans/` empty. It adds read-only binds
under `projects/<slug>/memory` and switches the memory mode; the copyout of `plans/` is
applied independently of both. So plans cannot be shared at all, deliberately or
otherwise.

**Isolation here governs reads, not write-back — measured.** The plan B wrote inside the
sandbox was on the **host** after that session exited, where a native reader in any
project found it (`plans/` then held two entries: A's and B's). This is by design —
copyout exists so a session's own plans and undo history survive a resume — but it makes
"isolated" only half the story for this channel, and it is the first cell in the study
where data crosses in the **outward** direction.

### For users

**To keep another project's plans out of a session:** nothing to do. Copyout is
unconditional, with no knob, and it is what produces this result.

**To share plans deliberately: not possible.** No configuration exposes another
project's `plans/` — not `[share-memory]`, not `memory_default = shared`. Copy the
document into the project if you want it there.

**Be aware of the outward direction.** A plan written inside a sandbox is *not* confined
to it: at exit it is merged into the host's `plans/`, where any native session can read
it. Sandboxing a session limits what it can read, not what it leaves behind.

### Not yet measured

Level 2 — whether a real session reads another project's plans unprompted — and level 3.
