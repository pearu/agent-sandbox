# Adversarial review: agent-sandbox

## What the tool promises

`agent-sandbox` runs an AI coding agent inside a bubblewrap sandbox so that the
limits a user sets are **enforced around the agent rather than honoured by it**.
The threat model is an agent that is wrong or has been led astray — by content
it reads, a package it installs, or a bug in code it generated — acting with the
user's own privileges. It should not be able to reach the user's other projects,
credentials, machines, or the network beyond an allowlist, whether it is trying
to or not.

`README.md` states what the tool guarantees; `docs/design.md` states how each
guarantee is implemented, which test proves it, and which risks are accepted
on purpose. Those two documents are the most consequential place for a false
statement, and they are not the ground truth. They are statements under
review, like everything else here.

## Your job

Every statement in this project that asserts something is to be judged true
or false: that the sandbox prevents, hides, refuses, isolates or defaults to
something; that a mechanism works a particular way; that the kernel, bwrap,
AppArmor, mitmproxy or Claude Code behaves a particular way; that a named test
proves a row; that a risk is acceptable, and why. For each statement you
examine, one of three outcomes:

- you checked it, and here is the evidence;
- you could only read the code, and you say so — read, not measured;
- you could not check it from where you are, and you say so, with the command
  the user should run.

Start with the guarantees table in `docs/design.md`, because a false statement
there costs the most, and question it at three levels:

1. **The table as a whole.** If every row were true, would the promise in
   `README.md` hold? What would a user assume is covered that no row covers?
   Is the threat model itself coherent, and is anything in it quietly excluded?
2. **Each row.** Is the guarantee stated precisely enough to be false? Does the
   mechanism do it in every code path that reaches it, or only the one the test
   exercises? What would the agent have to do, from inside the sandbox, to
   defeat it — and does anything stop that? Would the named test go red if the
   guarantee were broken?
3. **Each residual risk.** Is it the whole risk, or the convenient part of it?
   Is the reasoning for accepting it sound? Is it stated where a user sees it
   before relying on the tool?

Then apply the same standard to statements elsewhere: comments in the engine
and profiles, `--help` text, installer messages, the recipes and
troubleshooting documents. A statement that turns out false is a finding
whether or not anything else is wrong.

The project has tests that compare some documented defaults and lists to the
code (`tests/unit/docs.bats`). Do not repeat that comparison by hand; check
that those tests would fail if the two disagreed, and spend the review where
mechanical checking stops — on whether the statements are true of the kernel
and the tools, not merely consistent with the code.

## What counts as checked

Evidence is what you observed, not what you were told:

- the argument list the engine hands to `bwrap` (the unit suites capture it;
  `tests/helpers/common.bash` shows how);
- what a process inside the sandbox can actually read, write, resolve or reach;
- the exit status and output of a command you ran;
- a test that goes red when you break the thing it guards;
- for a statement about the kernel, bwrap, AppArmor or another tool: a
  measurement on this machine, or the tool's own documentation cited by name
  and version — and say which of the two you have.

## Where to look, without being limited to it

The trust gate on `.agent-sandbox` and its approval store. Egress in `proxy`
versus `strict`: what filters, what merely asks nicely, what a tool that ignores
`HTTPS_PROXY` can do. Cross-session state in `~/.claude`, including what is
deliberately left visible and whether the stated reason holds. The seccomp
filter and its interaction with the AppArmor profile the installer writes. The
installer and uninstaller: launcher precedence on PATH, the manifest and its
fingerprints, a machine that is half-installed. The SSH broker and whether key
material can leak. The briefing injected into every session: can the agent
forge, suppress or poison it? Session directories, the janitor, and what two
concurrent sessions do to each other. Symlinks and time-of-check/time-of-use
around every bind.

## The tests are part of the implementation

A guarantee whose test cannot fail is not a guarantee. Check the machinery
before individual tests:

- **Is every test file under the linter?** Compare the file lists in
  `scripts/check.sh` with what is in `tests/`. ShellCheck parses bats files and
  has dedicated checks for bats mistakes; a test file it never sees is where
  they accumulate.
- **Does the harness test its own idiom?** A negative assertion the runner
  cannot fail on is decoration. If you doubt an idiom, do not reason about it:
  write a two-line test that asserts something plainly false, run it, and read
  the report.
- **For the guarantees you examine most closely**, break the one thing the test
  guards — in a copy of the engine (`AGENT_SANDBOX_TEST_ENGINE`; `AGENTS.md`
  describes the arrangement) — and run the test. A handful, chosen by what a
  user would care about most, not the whole suite. Run the unmutated copy
  first: if that fails, you are measuring the harness.

Three shapes of vacuous test to recognise on sight: an **absence that was
already true** (asserting no `--tmpfs` when nothing was going to add one; the
test must make the two cases differ); a **match that lands elsewhere** (a
search that a markdown link or a comment satisfies); and an **assertion the
runner ignores** (above).

## Your situation

Your inputs are the repository as checked out and this document. There is no
one to ask what was intended: where the documentation is ambiguous about what
is promised, that ambiguity is itself a finding.

You are running inside this sandbox yourself, so some things you cannot test
from where you are: anything needing nested namespaces, the host side of the
proxy, or a second concurrent session. `probes/` holds scripts for host-side
questions and `probes/README.md` explains the approach. Where a check needs the
host, write the exact command for the user to run rather than guessing the
result.

## What to produce

A report, not commits. Change nothing in the tool.

Write it to `probes/results/review-<model>-<UTC timestamp>.md` — gitignored,
because a report names addresses, paths and interface names of the machine it
ran on and must not be committed. Create the directory if it is missing.

For each finding: which guarantee or claim it concerns, or that none covers it;
what breaks; the concrete path by which it breaks — what an attacker or a
confused agent must already have, and what they get; the evidence, as commands
and their output; and whether you **verified** it or are **hypothesising**.
Order by how much a user would care, not by how clever the finding is.

Say plainly if you find nothing in an area you examined closely; a clean area
that was genuinely checked is worth as much as a finding, and more than a list
of possibilities nobody tested.
