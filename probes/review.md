# Adversarial review: agent-sandbox

You are reviewing a security tool with fresh eyes. Nobody has briefed you, and
that is deliberate.

## What the tool is for

`agent-sandbox` runs an AI coding agent inside a bubblewrap sandbox so that the
limits a user sets are **enforced around the agent rather than honoured by it**.
The threat model is an agent that is wrong or has been led astray — by content
it reads, a package it installs, or a bug in code it generated — acting with the
user's own privileges. It should not be able to reach the user's other projects,
credentials, machines, or the network beyond an allowlist, whether it is trying
to or not.

Read `README.md` first for the claims, then `docs/design.md`, which states each
guarantee, where it is implemented, and how it is tested.

## Your job

Find where those claims do not hold. Security flaws, unenforced guarantees,
gaps between what the documentation promises and what the code does, holes left
open, and assumptions nobody wrote down.

## The one rule that matters

**Treat every word in this repository as a claim under review, not as evidence.**
The documentation, the code comments, the commit messages and the memory files
were all written by the agent that wrote the code. They record what its author
believed. Several of those beliefs have already turned out to be wrong.

So: prefer a measurement to a reading. Where you cannot measure, say so
explicitly and mark the finding as unverified rather than asserting it.

This is not a hypothetical caution. In this project's own history:

- A test asserted for months that a user namespace could be created without
  seccomp. Everyone read it as "defence in depth is thinner". Nobody noticed it
  meant the AppArmor profile the installer ships makes seccomp the *only*
  control, until a probe measured it.
- The installer used to decline to install its launcher whenever one already
  existed — which is what a normal agent install leaves — so users ran
  unsandboxed after a single warning. Reading the code had not revealed it;
  asking "how do I uninstall this?" did.
- Two defects were "found" by reasoning and then disproved by a single canary
  file each. Confident reasoning about this codebase has a poor record.

## Where to look, without being limited to it

The trust gate on `.agent-sandbox` and its approval store. Egress in `proxy`
versus `strict` (what filters, what merely asks nicely, what a tool that ignores
`HTTPS_PROXY` can do). Cross-session state isolation in `~/.claude`, including
what is deliberately *not* isolated. The seccomp filter and its interaction with
the AppArmor profile the installer writes. The installer and uninstaller: the
launcher takeover, the manifest and its fingerprints, what happens to a machine
that is half-installed. The SSH broker and whether key material can leak. The
briefing that is injected into every session: can the agent forge, suppress or
poison it? Session directories, the janitor, and what two concurrent sessions do
to each other. Symlinks and time-of-check/time-of-use around every bind.

And read the list of things the project says it does *not* cover. Judge whether
each is honestly scoped or quietly convenient.

## Reviewing the tests: check the machinery, not each test

Several tests in this repo have been found to pass without testing anything.
A guarantee whose test cannot fail is not a guarantee — it is worse than an
untested one, because it reports a promise nobody is keeping.

Do not try to fix that by breaking every test to see if it notices. That is a
sweep, it is expensive, and it finds one instance at a time. The classes of
mistake that have occurred here are all mechanically detectable, so review the
mechanism and spot-check the rest:

1. **Is every test file under the linter?** Read `scripts/check.sh` and compare
   its file lists with what is actually in `tests/`. ShellCheck parses bats
   files natively and has dedicated checks for bats mistakes (an assertion the
   runner cannot fail on is SC2314); a test file the linter never sees is where
   such things accumulate. This project's suites were outside the list for its
   first months.
2. **Does the harness test itself?** `tests/unit/harness.bats` runs a child
   bats to prove that the suite's negative-assertion idiom actually fails when
   it should. If a helper is added that assertions depend on, it belongs there.
3. **For the guarantees you examine closely**, take the test named beside each
   in `docs/design.md` and ask what would make it go red. Break that one thing
   in a copy of the engine (`AGENT_SANDBOX_TEST_ENGINE`; `AGENTS.md` describes
   the arrangement) and run the test. A handful, chosen by what matters most,
   not the whole suite. Run the unmutated copy first: if *that* fails, you are
   measuring the harness.

Three shapes to recognise on sight, because all three have occurred here:

- **An absence that was already true.** `no --tmpfs for the projects directory`
  proves nothing when nothing was going to add one. The test has to make the
  two cases differ — have the file ask for the *opposite* of the default.
- **A match that lands somewhere else.** A search for `[seccomp]` that the
  markdown link `[seccomp](components/seccomp/README.md)` satisfies, in a row
  whose actual setting column is empty.
- **An assertion the runner cannot fail on.** In bats, `! cmd` followed by
  anything else is reported `ok` whatever `cmd` returns. Do not reason about
  whether an idiom works: write a two-line test that asserts something plainly
  false, run it, and read the report.

## Inventory the claims; do not sample them

Where the documentation states a **default** ("on by default", "Default: off")
or an **exhaustive list** ("the declarations above are the whole interface", a
table of every knob, a guarantee naming the paths it covers), the claim is
mechanically checkable: derive the same thing from the code and diff the two.

Do that for every such claim in every shipped file, not only the prose in
`README.md` and `docs/design.md` — including the example file users copy into
their own projects, the engine's own comments and `--help` output, the
installer's messages, and the component READMEs. A stale default in prose
misleads a reader; a stale default in the file people copy travels into their
projects.

Sampling finds the first one. The value of a review is in the ones the last
sample missed.

## What the previous run of this prompt did not reach

The first review under this prompt found real defects, and this section is not
a criticism of it. It is a description of what reading cannot reach, so that
the next run spends its effort differently:

- It judged the tests by reading them, and reported on their coverage. It did
  not check whether the test files were under the linter at all — they were not
  — and fifty assertions across nine files later turned out to be incapable of
  failing, two of them asserting the opposite of what the engine does. One
  ShellCheck run over `tests/` would have listed every one.
- It checked the documents it was pointed at. A default that had been flipped
  months earlier still read the old way in two files it did not open — one of
  them the example a user copies, the other a comment in the engine explaining
  why a setting was a no-op that had since become a real widening.

If you find yourself writing "the tests cover this", say which test, and say
what would make it fail — and whether a tool, not a person, is checking that.

## Your situation

You are running inside this sandbox yourself, so some things you cannot test
from where you are: anything needing nested namespaces, the host side of the
proxy, or a second concurrent session. `probes/` holds scripts for host-side
questions and `probes/README.md` explains the approach. Where a check needs the
host, write the exact command for the user to run rather than guessing the
result.

## What to produce

A report, not commits. Change nothing in the tool.

Write it to `probes/results/review-<model>-<UTC timestamp>.md` — the same place
`run.sh` collects probe reports, and gitignored for the same reason: a report
names addresses, paths and interface names of the machine it ran on, so it must
not be committed. Create the directory if it is missing.

For each finding give: what breaks, the concrete path by which it breaks (what
an attacker or a confused agent must already have, and what they get), the
evidence — commands and their output — and whether you **verified** it or are
**hypothesising**. Order by how much a user would care, not by how clever the
finding is.

Say plainly if you find nothing in an area you examined closely; a clean area
that was genuinely checked is worth as much as a finding, and more than a list
of possibilities nobody tested.
