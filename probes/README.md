# Probes: testing the sandbox against what it promises

A probe is a prompt given to a Claude Code instance running *inside* a fresh
sandbox. The instance characterizes what it can see and do, and writes a
report. Comparing those reports with the guarantees and residual risks in
[docs/design.md](../docs/design.md) is how we check the tool against its own
claims, release after release.

The probes here are **report-only**: they inspect, they never attempt to
defeat a restriction, and they must not read the contents of private state
(the agent's own `~/.claude`). That rule is in each prompt; keep it there.

## Layout

| Path | What | Committed |
|---|---|---|
| `*.md` | probe prompts: `characterize.md` (filesystem, network, privileges, workaround tools, enforcement gaps) and `review.md` (adversarial review of the whole project, meant for a session run from a separate clone so the reviewer cannot read this project's transcripts) | yes |
| `run.sh` | runs one probe: fresh work dir outside the repo, sanitized launch, report collected | yes |
| `results/` | collected reports, `<probe>-<model>-<net>-<UTC time>.md`, with a metadata header | **no** (gitignored: reports describe this machine) |
| `work` | symlink to the work dirs (`~/.local/state/probe-runs/<UTC timestamp>`), one per run, kept for inspection | no (gitignored) |

## Running

```bash
probes/run.sh probes/characterize.md              # headless, proxy mode, model from settings
probes/run.sh -n strict probes/characterize.md    # the strict network mode
probes/run.sh -i probes/characterize.md           # interactive: watch it work
probes/run.sh -m claude-opus-5 probes/characterize.md
probes/run.sh -d probes/characterize.md           # dry run: show the plan
```

Run it on the host, not from inside a sandbox. Headless is the default so a
set of probes can run unattended; `-i` is for watching and demonstrating.
`none` is refused: with no route to the API a Claude instance cannot run, so
that mode needs a shell probe instead.

Claude Code's own permission gate is opened on purpose: it lives in the same
trust domain as the agent, so a probe that runs under it measures the gate, not
the sandbox. The first run of `characterize.md` did exactly that — most of its
facts were inferred from the `bwrap` command line because every read outside
the working directory was refused, and one inference (the uid map) was wrong.

It is opened with `--allowedTools`, not `--permission-mode bypassPermissions`.
The bypass is refused outright when the agent sees itself as root
(*"--dangerously-skip-permissions cannot be used with root/sudo privileges"*),
and that is precisely the case in `strict`, where the agent runs as uid 0
inside pasta's user namespace — so the tightest mode, the one most worth
probing, could not be probed at all. The same list goes to every mode, so a
difference between runs belongs to the sandbox rather than to the gate. A tool
outside the list is refused by Claude Code and not by the sandbox, which is why
`run.sh` prints the list in its plan.

## What the probes have found

Kept short, and deliberately without host specifics: reports may contain
addresses, paths and interface names, which is why `results/` is gitignored.

- **A default that was weaker than it read.** A strict-mode run reported
  "Seccomp is OFF" under enforcement gaps. It was right: a probe runs outside
  this repo, where no `.agent-sandbox` applies, so the harness had to gain `-s`
  before it could characterize the sandbox we actually ship.
- **The reason seccomp matters more than "defence in depth".** A run noticed
  that the AppArmor profile `install.sh` installs for bwrap is
  `flags=(unconfined)` with `userns,`, and that such a profile is inherited by
  children -- so everything under bwrap is exempt from the host restriction that
  would otherwise prevent creating a user namespace. With the filter off,
  nothing else prevents it. `tests/live/seccomp.bats` had asserted the
  behaviour for months; nobody had written down the cause. seccomp is on by
  default as of that finding.
- **What an inside observer cannot know.** Runs have concluded that the network
  namespace was shared with the host and that filtering was "harness-level"
  rather than kernel-level (both wrong -- pasta owns the namespace and nftables
  enforces in kernel), and that the sandbox ran as host root (wrong -- nested
  user namespaces). Each was a sound observation with an unsound inference about
  what lies outside. The briefing now states the topology for that reason.
- **Models differ at the same task.** On identical prompts, one run asserted the
  briefing's claims as its own verified findings; another marked them
  "inferred", said which commands had failed and why, and derived the uid
  mapping correctly from evidence. For a probe whose output reads as a security
  report, that distinction is the whole value.

## What the probe is not told, and what it can still learn

The instance is not told which tool sandboxes it. `run.sh` keeps the tool's
name out of the sandbox where a launcher can:

- the work dir is outside the repo, so neither the repo nor its docs are visible;
- the host environment is dropped (`env -i`, system `PATH` only), so no conda
  env name or repo path rides in on `PATH`/`PWD`/`CONDA_*`;
- the session base is `~/.local/state/probe-runs/.rt`, so the CA bundle path
  and the `bwrap` arguments carry no product name.

Inside the work dir the task is `TASK.md` and the report is `report.md`; the
model, mode and probe name appear only in `results/`.

What still identifies the setup, and would need engine or state changes:

- `ps` shows PID 1 as `bwrap` with its full argument list. The instance learns
  the whole mount and namespace layout in one command. That is not a secret
  (`/proc/self/mountinfo` says the same), but it is the end of any pretence
  about the mechanism.
- The proxy's `403` body for a non-allowed host names the tool.
- `~/.claude` is read-write and shared with your normal sessions: the global
  history and, in the default `shared` memory mode, every project's memory
  directory and transcripts, including this repo's. A probe can learn the
  tool's name and design from there, and one probe run can read the previous
  one's transcript. Memory scoping is per project via `.agent-sandbox`, which
  the probe would see, or a global `memory_default` in the engine config.
- The injected CA is mitmproxy's (`CN=mitmproxy`), which names the proxy
  software, not the tool.

## Reading a report

Compare each section with the table in `docs/design.md`. A finding that
matches a documented residual risk confirms the docs. A finding that
contradicts a guarantee is a bug. A finding that is neither is a doc gap. Note
whether a fact was *observed* or *inferred*; only observed values count.

Planned: `runall.sh` to run every probe across modes and models in one go.
