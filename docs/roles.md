# Roles: Planner, Implementer, Reviewer, Supervisor -- and the User

**Status: a model under discussion, 2026-10-03.** This document defines the roles, what
each may and may not do, the artefacts they exchange and the round they follow, and only
then the mechanics -- what the sandbox already enforces, what it does not yet, and what
only an instruction can hold. It is the statement of the problem for the issues that
build the missing mechanics, and the specification of `models/roles/`, the directory
that holds the model for `asb --init` (section 10). It will be revised as the model is
tried.

## 1. Why roles

One sandbox isolates a *project* from the others: its files, memory and transcripts
reach no other project's session. Within a project, sessions share everything, which
is right for one person working alone and wrong as soon as sessions have different
purposes: an implementer's memory and conversations accumulate its reasoning, tried
paths included, and a reviewer should judge a change against the state it starts from
-- `main` at its last commit, and the diff of the current state against it -- not
against how the implementer got there (#55). A **role** is a named, persistent instance
of a project with a policy of its own
(`asb --role NAME`); two roles share the project directory and nothing else unless
connected ([glossary](glossary.md)).

The model here gives the roles a purpose each, and draws each one's boundary from its
purpose. Three principles hold throughout:

1. **A role is defined by its inputs and its outputs.** It reads its inputs, writes its
   outputs, and has nothing else. Everything below derives from that: the boundary is
   the inputs read-only, the outputs writable, and all other routes closed.
2. **The boundary is enforced; the purpose is briefed.** What a role *cannot* do is a
   mount, a refused host or a missing credential, held outside the agent. What a role
   is *for* -- report, do not fix; ask before installing -- is told to it in its
   briefing, and cannot be enforced. The document says which is which, every time.
3. **The user is between every pair of roles.** No artefact moves from one role to
   another without the user: a role that writes one reports it and hands it to nobody,
   and a role reads one when the user says so. The user reads it first. That is where
   decisions are made, and it is the filter: an instruction planted in a review would
   otherwise travel straight into the implementer. This one is **instructed**, not
   enforced: every artefact directory is readable to every role, and only the briefing
   and the user's sentence keep a role from reading early.

## 2. The artefacts

Everything the roles exchange is a file under `.asb/` in the project directory
(section 4), so that the sandbox can bind it and the user can read it. Each instance
writes in a directory of its own (`.asb/plan/planner-1/`, `.asb/handoff/implementer-1/`,
`.asb/review/reviewer-1/`), read-only to every other role, and the coord index
(section 5) says which is whose. Git never sees any of it: in the repository `.asb/`
is excluded, and its name cannot collide with a project's.

| artefact | written by | read by | what it is |
|---|---|---|---|
| **Statement** | Planner | Implementer, Reviewer, User | the statement of the problem: what is to be achieved, under which requirements, restrictions and invariants; the options considered and the one the user chose, with the reasons |
| **Task** | Planner | one Implementer, Reviewer, User | the Statement, or the part of it that is one Implementer's, addressed to it at an agreed place (`.asb/plan/planner-1/tasks/I1.md`), naming the Implementer the Planner wants and, if it has a preference, the Reviewer; nothing about trees, branches or environments, which are the role's standing facts (section 3) |
| **Handoff** | Implementer | Reviewer, User | what was done: the statement it answers, the method, what was achieved, what was not and why (blockers), the restrictions and features introduced; and the change itself: the branch, and the diff of the current state against `main`'s last commit -- an environment change included, as the specification file's diff |
| **Review** | Reviewer | Implementer (through the user), User | findings against the statement and the current state, each with its evidence; suggestions where the reviewer has the information to make them; what it could not investigate and would need (a build, an install, a run) to |
| **Objection** | Implementer | User | a finding the implementer holds to be wrong, with the reasons -- it goes to the user, not to the reviewer |
| **Decision** | User | Planner, and whoever the decision addresses | the option chosen, an objection upheld or overruled, a change of direction |
| **Measurements** | Planner | Planner (next round), User | what the planner measured or probed to compare the options; kept, so the next round does not repeat it |
| **Messages** | each role, its own file | every role, the user | coordination: what a role is doing, what it needs, what it changed that another depends on (section 5) |
| **Scratch** | each role, for itself | that role only | test scripts, probes, notes a role writes to do its task: `.asb/scratch/`, bound `own`, so every role has a private one at the same path, kept across its launches and reaching nobody (unlike `/tmp`, which is fresh at every launch) |

The Statement and the Handoff are a role's *inputs*, not its instructions. What a
reviewer does with a handoff in general is its purpose (section 3); what this handoff is
about is the artefact. Keeping the two apart is what lets one purpose serve every round.

Every role instance has a **handle** the user and the roles address each other by:
`S`, `P1`, `P2`, `I1`, `I2`, `R1`. The dot-file keeps the descriptive names
(`implementer-1`); the purpose file says "you are `implementer-1`, called `I1`", and
the coord index maps handle to name, coord file and directory. The handle is what makes
the user's sentences short.

## 3. The roles

Each role: its purpose, its inputs and outputs, what it may do and may not, and for
every "may not" whether the sandbox enforces it or the briefing instructs it.

**Instances.** Every role but the Supervisor may run as several instances -- `P1` and
`P2`, `I1` and `I2`, `R1` and `R2` -- each a sandbox of its own (`<project>/planner-1`),
with its own memory and transcripts. An instance accumulates: a Planner that works in
one field keeps that field's knowledge, and knows which Implementer it worked with on
what. An expert's material -- the documents of its field, another project's sources --
is declared as that instance's input, read-only, in its own section, so no other
instance loads it: what is context to one Planner is noise to another. A Task names the
Implementer the Planner wants, and a Planner may ask for a Reviewer; the user assigns.
The Supervisor is one, because it is the gate to the outside.

### Planner

**Purpose.** Compose the Statement of a problem from what the user brings -- feedback,
a reported issue, a feature request, the list of what is not yet built. Research the
code base deeply and collect the relevant material from outside; lay out the options
that would solve the problem, each with its consequences, and recommend one with the
argument for it. Help the user decide: answer questions, measure what a decision
needs, research further. When the user has decided, write the final Statement for the
Implementer.

| | |
|---|---|
| inputs | `main`, built: the integration state after the last accepted change; the project's documents and issues; its field's material, declared as its own (documents, other projects' sources); the user's questions and Decision; its own earlier Measurements |
| outputs | the Statement and the Tasks; the Measurements; its Messages |
| may | read everything in the project and on the web; run the code and write probes to measure, in its scratch; keep what it measured |
| may not | change the code base (**enforced**: section 4); publish anything -- an issue, a comment, a push (**enforced**: the retrieve-only network, which lets `gh` read issues and pull requests and refuses what writes them; no git transport); install into the development environment (**enforced**: read-only to it, as `main` is; what a measurement needs beyond it goes in its scratch -- a venv there, for instance) |

### Implementer

**Purpose.** Resolve the Statement: produce new code, or change existing code, from the
current state, under the requirements, restrictions and invariants the project defines
in its code, its tests and its documents. Write the Handoff. When a Review arrives,
examine each finding for correctness and validity before acting on it; address what
holds, and object, with reasons, to what does not.

| | |
|---|---|
| inputs | its Task; the code base; the Review (through the user); the project's documents |
| outputs | the change, on its own branch; its environment -- the clone in its tree with what it installed, an artefact of the same standing: the Reviewer runs it, and the specification's diff carries it; the Handoff; an Objection; its Messages |
| may | edit the code; run tests, build, install into its own environment, the clone in its tree; commit on its branch |
| may not | publish -- push, open a pull request, comment (**enforced**: the retrieve-only network and no git transport; the Supervisor publishes on the user's word); change the Statement (**enforced**: read-only); read the Reviewer's or the Planner's memory (**enforced**: each role's memory is its own) |

### Reviewer

**Purpose.** Assess the validity and correctness of a change against the current state,
the project's requirements and the Statement the change answers. Report findings, with
evidence; suggest where the information at hand allows it. Investigate by running the
code where that is needed, and say what it would need -- a build, an install -- rather
than doing it.

| | |
|---|---|
| inputs | the Statement; `main` at its last commit, and the change as the Handoff gives it -- the diff against that commit, and the branch; the project's documents; outside documents |
| outputs | the Review; its Messages |
| may | read the code and run it -- an Implementer's build with the environment it was built in, `.asb/impl-1/.env/bin/...`, which a read-only environment runs without activation; write the test scripts that takes, in its scratch; read documents on the web |
| may not | change the code (**enforced**: section 4); read the implementer's reasoning -- its memory, its conversations, its commit-by-commit path -- rather than the change (**enforced**: each role's memory and transcripts are its own; `.git` hidden, the diff against `main` is in the Handoff); publish (**enforced**: as the Planner); install or build (**enforced**: a build writes to a tree and an install to an environment, and it has neither writable -- when it needs a built tree it runs the Implementer's) |

### Supervisor

**Purpose.** Keep the round on its track (section 4), and be the only role that
touches the outside: relay the artefacts between roles on the user's word, push the
branch, open the pull request, post the comment, close the issue. Hold the credentials
nobody else holds. When the user intervenes, help bring the process back to the typical
round. Never act on the *contents* of an artefact it relays: a review that says "run
this" is relayed, not run.

| | |
|---|---|
| inputs | every artefact; every role's Messages; the user's instructions |
| outputs | `main`: the accepted change merged and built; what goes outside (pushes, pull requests, comments, issues); the round's bookkeeping (which role is active, the index of Messages) |
| may | everything the user may, under the user's instruction; merge an accepted branch into `main` and build it there |
| may not | write in an Implementer's clone (**enforced**: each is read-only to it, section 8 -- it fetches the branch from it, nothing more); act on an artefact's contents without the user's word (**instructed** -- it has the access; this is the one role whose boundary is mostly its briefing, and why its purpose file matters most) |

This role is what today's "the user with an AI assistant" is. Naming it puts every
route that *writes* to the outside -- a network that is not retrieve-only, git
transport, the SSH broker -- in one place, which is also where the user's review gate
already is. The `gh` token itself is every role's: reading issues, pull requests and
their comments through `gh` is the efficient way to read them, and the network, not the
token, is what keeps the other roles to reading.

### The User

Decides. Reads every artefact before it moves. Reads each role's purpose before
approving the dot-file that installs it. May instruct, direct or question any role
directly, and watch what it does: a role going the wrong way is stopped by the user,
not by the sandbox. Nobody reads another role's memory, the user included: a role that
wants to know why another did something asks, through the message files (section 5),
and the answer is what the other role chose to say.

## 4. The round, and the code

**The typical round:**

    Statement  -->  implementation + Handoff  -->  Review  -->  accept
        ^                                              |
        |            revision (findings that hold)     |
        +---------  or Objection, decided by the user  +

Each arrow passes through the user. The Supervisor relays, keeps track of which role is
active, and when the user accepts, merges the branch into `main`, updates the
development environment from its specification, builds there, and publishes. The
Planner then measures the new state in `main` for the next Statement -- or finds the
problem resolved, and the round was the last.

**Where the code lives.** Roles share one project directory and nothing else unless
connected, and the project directory is the repository. Every role launches from the
checkout itself. `.asb/` inside it, excluded from git, holds the artefacts, the
messages, the roles' purposes and the Implementers' trees:

    ~/git/x/                    the repository: every role launches here
      .agent-sandbox            one dot-file, approved once, with every role's sections
      .git/                     the main store; the Supervisor commits, merges, pushes
      src/ ...                  the integration state
      .asb/
        plan/ handoff/ review/ coord/ roles/
        impl-1/                 I1's clone, on branch impl-1
        impl-2/                 I2's clone, on branch impl-2

The Supervisor has the project read-write, but for the clones, read-only to it in turn.
Every other role has it read-only, and an Implementer has `.asb/impl-1/` read-write
inside that: a read-only mount, then a read-write mount on a subdirectory of it, which
bubblewrap allows and the engine's depth order makes expressible: `project = read-only` (#220).

**Clones with shared objects, not worktrees.** Separation is enforced only if an
Implementer's commits never touch the main `.git/`. A `git worktree` shares it: the
worktree's `.git` is a file pointing at the main store, where its refs and objects go,
so a committing Implementer would need the main `.git/` writable and could move `main`.
A clone with shared objects keeps the split: `git clone --shared . .asb/impl-1 && git
-C .asb/impl-1 switch -c impl-1` reads the main objects through an alternates file --
the path of `./.git/objects`, read-only to the Implementer and the same path inside --
and writes its own objects and refs under `.asb/impl-1/.git/`. The Supervisor collects
a branch with `git fetch .asb/impl-1 impl-1:impl-1` and merges it in the main tree;
the Handoff names the branch, and `git diff main...impl-1` in the main tree is the
diff the Reviewer gets: the current state of the change against `main`'s last commit,
whatever the commits in between were. History is its owner's: `main`'s `.git/` is
hidden from every role but the Supervisor and, read-only, the Implementers; a clone's
from every role but its Implementer and, read-only, the Supervisor. A Planner that
wants history reads it on GitHub.

**Concurrent Implementers, a clone each.** Independent tasks run in parallel, one
Implementer per clone, each clone read-write for its Implementer and nobody else. There
is nothing to partition inside a clone: an Implementer may change any file of its tree,
on its branch. Whether two tasks collide is the Planner's judgement when it cuts them
and the Supervisor's merge when they come back, as with any parallel work on one
repository. The per-file locks that concurrent sessions sharing one tree needed are
not needed when no tree is shared.

**Builds.** An Implementer builds in its own clone. When the user accepts a change, the
Supervisor merges it into `main` and builds there, into the development environment,
so that `main` always holds the integration state *and* its build: the Planner measures
against it, the Reviewer's baseline is a state that builds, and the user tries it on
the host without an agent. Nobody builds in a tree that is not theirs.

**Environments.** The project's development environment is a named conda environment,
`<project>-dev` (`x-dev` below), made from the project's specification: it is `main`'s,
the Supervisor installs the accepted build into it, and the user activates it on the
host to try that build without an agent. Every other role starts from it: the Planner
runs `main` in it, read-only; an Implementer gets **a conda clone in its tree**:

    conda create --clone x-dev -p .asb/impl-1/.env

It works for what conda manages, Python or not; the clone is independent of `x-dev`
and of every other clone; and it travels with the tree, so a read-only reader of the
clone -- the Reviewer -- runs what the Implementer built with the environment it was
built in. Measured 2026-10-02 on a 1.6 GB env: 11-15 s, and 255 MB of new disk -- the
files conda rewrites its prefix in; the other 1.35 GB are hardlinks into the package
cache, free as long as the clone sits on the cache's filesystem (on another one,
everything is copied). `conda` and `mamba` behave the same.

Two alternatives, for when the clone is the wrong size: a *venv per clone*
(`python -m venv --system-site-packages`) when only Python packages are installed;
and *the sandbox's own layer*, `<env>/ = copy-on-write` in a role's section (measured:
an overlay over the env, writes in the role's layer, the host env untouched), when a
role's installs must reach nobody else -- the layer lives in the role's state, not in
the tree, and the base must change only between rounds.

Installing into the clone needs nothing of the sandbox: the clone is in the
Implementer's tree, writable because the tree is, and conda and pip address it by path
-- `conda install -p .asb/impl-1/.env ...`, `.asb/impl-1/.env/bin/pip install ...` --
with no activation, which is also how the Reviewer runs it. Activating it, so that
`python` is the clone's, is the role's `[conda:<role>] prefix` line (section 8).

**Environment changes travel as text.** An Implementer that needs a new package or a
pinned version changes the environment's specification in its tree (`environment.yml`,
or a lock file), updates its own clone from it, and the specification's change is in
the diff like any other. No environment is ever copied from one role to another:
each clone is re-derived from its own tree, in place --

    conda env update -p .asb/impl-2/.env -f environment.yml --prune

-- which costs the delta, nothing when the specification is unchanged, and is
idempotent, so it is the first thing an Implementer does at a start ("sync your
environment", in its purpose file). The Reviewer runs the Implementer's build in a
clone the Implementer already updated; the Supervisor updates `x-dev` after a merge,
before building; an Implementer whose branch moves to the new `main` updates at its
next start. A fresh clone is the fallback when an in-place update refuses a conflicting
pin. Of this, the sandbox's part is small. An Implementer's clone is writable because
its tree is, and persists with it; what an install downloads goes to the sandbox-owned
package cache, which persists across launches too and is searched before the host's
read-only one (#219). The Supervisor's `x-dev` lives in the conda tree, read-only inside unless
`[conda] write = 1`, which makes the active environment writable, with the same cache.
The rest is a line in the briefings and a step in the Supervisor's round.

**Reading another role's tree.** A Reviewer tries an Implementer's build by reading its
clone: `.asb/impl-1/` is read-only to it, as the whole project is, and the tree holds
*what the build left in it*, since the build ran on the host filesystem. One condition:
the build and its environment live in the clone (a venv, an in-tree conda env), not in
the Implementer's own stores, or the Reviewer sees the sources and not the build. A
Planner reads the main tree, the integration state, and any `.asb/impl-*`, its history
excepted. The Reviewer sees `main` as the change starts from it and the change as one
diff against it, not the commits that led there: `.git/` is hidden from it, in the main
tree and in the clones, and what it needs of git's output is in the Handoff.

**Why not copy-on-write for a role that must not change the code.** The sandbox could
bind a tree `copy-on-write` for it, but for a large code base with a long build that
is the wrong tool: the role's layer goes stale, and a rebuild per round is the cost.
Clones on branches carry their builds with them, and a role that must not change code
has the tree read-only.

What this costs: a clone and an environment per Implementer. Nobody shares a checkout,
so no tree lock and no file lock is needed.

## 5. Communication

Adapted from the method in use between concurrent Claude Code sessions
(`COORDINATION.md` in another project): **per-role message files**. Each role writes
only its own, `.asb/coord/<role>.md`, and reads the others'. An index,
`.asb/coord/COORDINATION.md`, names every instance: its handle, its coord file and the
directory it writes its artefacts in; `--init` writes it, the Supervisor keeps it, and
nobody writes messages in it. A role notes in its own file what it is doing, what it
needs from another role, what it wrote and where, and any shared interface it changed.
There is no shared file for messages, which is what avoids contention.

What the sandbox adds to that method: "write only your own file" is a mount, not a
convention. The role's own file is a `read-write` declaration, the directory around it
`read-only`, so the cooperative guard that method needed (a hook refusing edits to
another session's file) is unnecessary here. The single-git-writer guard and the file
locks both become the checkout layout of section 4: a clone per writer.

The user reads every message file. The Supervisor keeps the index.

## 6. What the sandbox enforces today, and what it needs

What the model needs, against what the engine has on main (2026-10-02):

| need | today | status |
|---|---|---|
| a role per purpose, with its own policy | `--role`, `[sandbox:<glob>]`, `[connect:<glob>]` | built |
| each role's memory and transcripts its own | `own` under `inherit` (#196, #120) | built |
| inputs read-only, outputs writable, inside one tree | path declarations, bound by depth (#130, #196) | built |
| history its owner's: `main`'s hidden from every role but the Supervisor and, read-only, the Implementers; a clone's from every role but its Implementer and, read-only, the Supervisor | `./.git/ = own` and `.asb/impl-N/.git/ = own` in the common block, redeclared `read-only` or `read-write` where a role needs it | built |
| the project read-only for every role but the Supervisor, with an Implementer's clone read-write inside it | `project = read-only` / `read-write` per role (#220), declarations inside it bound by depth | built |
| the `gh` token for every role, with nothing to set up | `gh/` as a channel (#88), `own` unless asked; `gh = read-only` in the common block, `GH_CONFIG_DIR` pointed there | built. The token's mode cannot make `gh` read-only (a token that reads can write): the retrieve-only network does that, and a read-only token is the documented hardening (section 7), not the default |
| no publishing: hosts a role may not reach | `[deny]` and `[deny:<role>]` subtract hosts, the profile's own untouched; role suffixes on `[allow]`, `[env]`, `[net]`, `[conda]` (#221) | built |
| retrieve only: read the web and GitHub, publish nothing | `[net] retrieve-only = on`, per role (#223): every method but GET and HEAD refused, the profile's own hosts untouched; GitHub-aware: `gh` reads through POSTs to `api.github.com/graphql`, so there a query passes and a mutation is refused, by the body | built. What it does not stop: a token carried out in a GET to an allowed host |
| no git transport to a host that also serves pages | -- | **to build**: the proxy refusing git's HTTPS transport (`/info/refs`, `git-upload-pack`, `git-receive-pack`, the `git/` user agent) per role; `--ssh` refusable per role |
| the role's purpose told to the agent, at every start | `[briefing:<role>]` (#222): `.asb/roles/<role>.md`, or `file =`, injected by the SessionStart hook at every launch, resume and compaction after the engine's lines (which name what is writable and read-only), bound read-only inside, and part of the approval, so an edit re-opens the review. The round's specifics stay in the artefacts, which the purpose tells the role where to find, so a launch needs nothing typed | built |
| a Reviewer trying an Implementer's build | the clone read-only: the tree and what the build left in it | built; the build and its environment must live in the clone |
| the Planner's measurements persisting | a `read-write` declaration of the planner's, read-only for the others | built |
| a role installing without touching the shared environment | a conda clone in its tree (measured: 11-15 s, 255 MB new disk per 1.6 GB env); or `<env>/ = copy-on-write` in the role's section (measured) | built |
| an Implementer installing into its clone | the clone is in its tree, writable by the declaration; `conda install -p .asb/impl-1/.env`, `.asb/impl-1/.env/bin/pip`, no activation | built |
| the downloads of such an install persisting | the sandbox-owned package cache (`~/.cache/agent-sandbox/conda-pkgs`, `CONDA_PKGS_DIRS` set to it, the host's read-only cache after it), bound whenever a conda env is active (#219) | built |
| a role activating its own clone | `[conda:<role>] prefix = .asb/impl-1/.env`, an env by its path (#221) | built |
| the Supervisor installing into `x-dev`, in the conda tree | `[conda:supervisor] write = 1`: the active env writable for that role only (#221) | built |
| what a role has, shown before it runs | `asb --check --role NAME`: the policy, what crosses the boundary and how, the mount plan (#210-#213) | built; **to add**: "can act as you at" per outside service (the #114 outward routes) |
| the dot-file, `.asb/`, the purpose files and the clones written right, for a given set of roles | all by hand | **to build**: `asb --init roles implementer=2 --env x-dev` -- a model name, counts, the development environment. A model is a directory the engine ships (`models/roles/`: the dot-file template with the sections per role, a purpose file per role), or a path to the user's own. It writes `.agent-sandbox` with each instance's sections, the `.asb/` directories, one per instance where it writes, `.asb/roles/<instance>.md` with the names and handles substituted, the coord index, and the `.asb/` exclude line; makes each Implementer's clone (`--shared`, on its branch) and its environment clone from `--env`, on the host, where the clone hardlinks into the package cache; never overwriting; then prints what is the user's: `asb --trust`, `asb --check --role NAME`. It does not approve |

## 7. The `gh` token: the default, and the recommended hardening

**The default asks nothing of the user beyond the model's dot-file.** The engine gives
no sandbox the `gh` login unless its dot-file asks (#88); the model's common block asks,
`gh = read-only`, so every role holds the gh login the user keeps in `~/.claude/gh`, and
`gh` inside -- `GH_CONFIG_DIR` points there -- reads issues, pull requests and their
comments with it. What keeps the reading roles from writing with it is the
retrieve-only network (section 6), which the proxy enforces: a GraphQL query passes,
a mutation does not.

**The recommended hardening: a token that cannot write.** The network bounds what a
role *does* with the token; it cannot stop the token from leaving in a GET to an
allowed host. A fine-grained personal access token with read-only permissions, limited
to the repositories the roles work on, closes that wherever the token ends up, because
GitHub enforces the scope. The two are complementary: the token bounds what the
credential can do, the network what the role does with it. It is a dot-file matter
alone -- the reading roles get that login at the channel's path, the Supervisor the
user's own:

    [connect]
    ~/.claude/gh/ = read-only outside:~/.gh-read
    [connect:supervisor]
    ~/.claude/gh/ = read-only

The setup and the renewal are in [recipes.md](recipes.md) (the `gh` section). `asb
--check --role NAME` shows which directory each role's `~/.claude/gh` is, so the review
catches a role holding the wrong one.

## 8. The example dot-file

The repository's `.agent-sandbox` that holds this model, as far as today's
grammar reaches; a line marked `NEEDS` waits on section 6. The material lines
(`~/refs/...`) are an example, not the model's: the user adds such lines, and any other
a round turns out to need, when the need arises, and `asb --trust` re-opens the
review. The acceptance test of the mechanics is that `asb --check --role reviewer-1`
on this file shows nothing the reviewer may write but `.asb/review/reviewer-1/`,
`.asb/coord/reviewer-1.md` and its own `.asb/scratch/`, and nothing it can publish to.

```ini
[sandbox]
preset = inherit

# ---- what every role gets ------------------------------------------------
[conda]
name = x-dev                      # the development environment: main's build; the user's to activate on the host
[connect]
project = read-only               # the working tree, read-only (#220); the Supervisor opens it
.asb/coord/ = read-only           # the message files and the index: every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
./.git/ = own                     # history is its owner's: main's is the Supervisor's...
.asb/impl-1/.git/ = own           # ...and a clone's its Implementer's
.asb/impl-2/.git/ = own
gh = read-only                    # your gh login (#88), for reading issues and pull requests
# hardening, optional (section 7): ~/.claude/gh/ = read-only outside:~/.gh-read
[net]                             # every role reads the web and GitHub, and publishes nothing...
retrieve-only = on

# ---- planners: an expert each, with its own material --------------------
[connect:planner-1]
.asb/plan/planner-1/ = read-write # its Statements, Tasks and Measurements
.asb/coord/planner-1.md = read-write
~/refs/parsing/ = read-only       # P1's field: its material, nobody else's context (an example)
[connect:planner-2]
.asb/plan/planner-2/ = read-write
.asb/coord/planner-2.md = read-write
~/refs/reporting/ = read-only
~/git/other-project/ = read-only  # the sources P2 knows
[briefing:planner-*]              # reads .asb/roles/<role>.md, this instance's

# ---- implementers: a clone each -------------------------------------------
[connect:implementer-1]
.asb/handoff/implementer-1/ = read-write
.asb/coord/implementer-1.md = read-write
.asb/impl-1/ = read-write         # its clone, whole: the tree, its .git, its .env
.asb/impl-1/.git/ = read-write
./.git/ = read-only               # the clone reads main's objects through it
[conda:implementer-1]             # activation only; the clone is writable as its tree is
prefix = .asb/impl-1/.env
[connect:implementer-2]
.asb/handoff/implementer-2/ = read-write
.asb/coord/implementer-2.md = read-write
.asb/impl-2/ = read-write
.asb/impl-2/.git/ = read-write
./.git/ = read-only
[conda:implementer-2]
prefix = .asb/impl-2/.env
[briefing:implementer-*]          # reads .asb/roles/<role>.md

# ---- reviewers: the common block already hides every history --------------
[connect:reviewer-1]
.asb/review/reviewer-1/ = read-write
.asb/coord/reviewer-1.md = read-write
[briefing:reviewer-*]             # reads .asb/roles/<role>.md

# ---- supervisor: the only role that reaches outside ----------------------
[connect:supervisor]
project = read-write              # merges the branches in the main tree, pushes
./.git/ = read-write
.asb/impl-1/ = read-only          # the clones are the Implementers'; it fetches their branches
.asb/impl-1/.git/ = read-only
.asb/impl-2/ = read-only
.asb/impl-2/.git/ = read-only
.asb/coord/supervisor.md = read-write
.asb/coord/COORDINATION.md = read-write   # the index
[conda:supervisor]                # main's build lands in x-dev, which lives in the conda tree
write = 1
[net:supervisor]                  # ...except the Supervisor, which publishes; NEEDS (#224): git
retrieve-only = off
git = allow
[briefing:supervisor]             # reads .asb/roles/supervisor.md
```

The one line still marked `NEEDS`, `git = allow`, waits on #224 and is left out until
then; it changes nothing yet, since git's HTTPS transport is POSTs, which retrieve-only
already refuses to every role but the Supervisor. A reviewer under this file has its
own memory, no history, the tree read-only and one writable directory, reads the web
and GitHub and publishes nothing, and `asb --check --role reviewer-1` shows it.

## 9. Using the model: one round, terminal by terminal

Every role is a launch of its own, from the repository, in a terminal of its own; a
second terminal of the same role joins the running one. The user types into each
terminal, reads the artefacts on the host as files, and moves a round forward by
telling the next role where its input is: a role reads an artefact when told, and
reports what it wrote (section 1). With `[briefing:<role>]` (section 6) a role's
purpose, handle, standing facts and protocol are in its context at every start, so
`asb --role NAME claude` starts a role that knows what it is and where everything is.
`asb --check` and `asb
--trust` run on the host: inside a sandbox the trust store is not there, and `asb`
runs what it names as it is (#197).

**Setting up, once, on the host.** With `asb --init` (section 6) it is:

    cd ~/git/x
    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev
                                          # the dot-file, .asb/, the purposes, the index,
                                          # the exclude, the clones and their environments
    $EDITOR .agent-sandbox                # what --init cannot know: hosts to allow, a Planner's
                                          # material; later, whatever a round needs (then --trust again)
    asb --trust                           # the review, then the approval
    asb --check --role reviewer-1         # what the reviewer will have: nothing it may write
                                          # but its review directory, its coord file and its scratch

and until then, by hand, what `--init` writes and makes:

    $EDITOR .agent-sandbox                # section 8
    mkdir -p .asb/{coord,roles,scratch} .asb/plan/planner-{1,2} \
             .asb/handoff/implementer-{1,2} .asb/review/reviewer-1
    $EDITOR .asb/roles/{planner-1,planner-2,implementer-1,implementer-2,reviewer-1,supervisor}.md
                                          # section 3, as instructions, with the handles
    $EDITOR .asb/coord/COORDINATION.md    # the index: handle, coord file, directory, per instance
    printf '/.asb/\n' >> .git/info/exclude
    for i in 1 2; do
        git clone --shared . .asb/impl-$i && git -C .asb/impl-$i switch -c impl-$i
        conda create --clone x-dev -p .asb/impl-$i/.env
    done

The clones are made on the host, where the conda clone hardlinks into the package
cache (section 4).

The user's sentences are short because everything else is in the role's context
already: its purpose, its handle, its standing facts (tree, branch, environment, where
its inputs are and where its outputs go) and the protocol, all generated by `--init`
and injected at every start. What follows is what the user types; what each role does
with it is its purpose file's.

**Terminal 1 -- a Planner.** `asb --role planner-1 claude`, then:

> You are P1. The problem is issue #NNN. Ask me when you need a decision.

The Planner researches, measures, writes the options and its recommendation in its
directory and says so; the user reads, asks, decides; the Planner writes the Tasks, one
per Implementer, naming the Implementer it wants. Another field's problem goes to `P2`,
in a terminal of its own, with its own material and its own memory.

**Terminals 2 and 3 -- the Implementers.** `asb --role implementer-1 claude`, then:

> You are I1. Your task is P1's. Ask if you have questions, or when you are blocked.

The same for I2. They run at once. Each syncs its environment, works in its own clone
on its own branch, commits as it goes, writes its Handoff in its directory and says so.

**Terminal 4 -- a Reviewer.** When the user has read a Handoff:
`asb --role reviewer-1 claude`, then:

> You are R1. Review I1's handoff. Ask if you need something you cannot do.

The user reads the Review and relays it with one sentence in terminal 2: "R1 has
reviewed your handoff; address what holds, object to what does not." The round continues
until the user accepts.

**Terminal 5 -- the Supervisor, when the user accepts.** `asb --role supervisor claude`,
then:

> You are S. I1's work is accepted: merge, build, push, open the pull request. Tell P1.

The Planner, in terminal 1, measures the new `main` for the next Task, or reports the
problem resolved; the user tries the build on the host, in `x-dev`.

**What a terminal is.** A role's terminal is a session joined into the role's one
launch: closing it ends that session, the launch ends once nothing is joined, and the
role's stores -- its memory, its scratch, its clone's state -- persist for the next
`asb --role NAME claude`. `asb --role reviewer-1 --exec bash` opens a shell in the same
sandbox beside the agent, for the user to look around with the reviewer's eyes. What a
role writes lands only where its policy says: `asb --check --role NAME` says where.

## 10. Models

A development model -- a set of roles, what each may do, how they hand work to each
other -- is data, not something the engine knows. The engine ships a `models/`
directory, one model per subdirectory, and `asb --init NAME [ROLE=N ...]` writes a
project's files from one; `NAME` is a shipped model's directory or a path to any other,
so a user writes a model of their own the same way and may contribute it.

A model directory holds:

    models/roles/
      README.md             the model: this document's sections 1-5 and 9, or a pointer to them
      agent-sandbox         the dot-file template: the common block, then a block per role,
                            with {role} for an instance's name
      roles/
        planner.md          one purpose file per role, as instructions, a page each:
        implementer.md      what the role is for; its handle; its standing facts (its
        reviewer.md         tree, branch, environment, where its inputs are and where its
        supervisor.md       outputs go); the protocol (sync the environment at start, get
                            the task from the agreed place, ask by writing your coord file
                            addressed to a handle, when blocked write it and stop); what
                            it never does; its start procedure. Injected at every session
                            start by [briefing:<role>], so the user never types any of it
      coord/
        COORDINATION.md     the index template: the instances, their handles, coord files
                            and artefact directories, the rule

A role that may have several instances (`planner=2 implementer=2 reviewer=1`) gets its
block and its purpose file once per instance, the name and the handle substituted; the
template says which roles may, and here every role may but the Supervisor.

What makes a model a model is that every "may not" in it is either a line in the
dot-file template or a sentence in a purpose file, and the README says which. A model
whose promises are only in its purpose files is a set of instructions, not a model.
`models/roles/` is this document's; the first other one anyone writes is the test of
the format.

