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

Also review the **tests themselves**. Several in this repo have been found to
pass without testing anything — asserting an absence that was already true, or
matching a string that appeared elsewhere in the file. A guarantee whose test
cannot fail is not a guarantee.

And read the list of things the project says it does *not* cover. Judge whether
each is honestly scoped or quietly convenient.

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
