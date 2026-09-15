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
