# Roles: Planner, Implementer, Reviewer, Supervisor -- and you

A way to work on one project with several AI agents at once, each with a job and a
boundary: Planners work out what to do, Implementers do it, Reviewers check it, and a
Supervisor publishes what you accept. You decide, and every piece of work passes through
you. `asb --init roles` sets a project up for it; this page says what each role may do,
how the work moves, and how to run a round. Why it is built this way is in
[design.md](design.md#the-roles-model).

## 1. What a role is

One sandbox keeps a project apart from your other projects. Within a project, sessions
share everything -- right for one person working alone, wrong once sessions have
different jobs: an Implementer's memory and conversations hold its reasoning, tried paths
included, and a Reviewer should judge the change against `main`, not against how the
Implementer got there.

A **role** is a named, persistent instance of a project with a policy of its own
(`asb --role NAME`): its own memory, its own transcripts, and the paths and network its
section of `.agent-sandbox` gives it. Three rules hold throughout:

1. **A role is its inputs and its outputs.** It reads its inputs, writes its outputs,
   and has nothing else.
2. **The boundary is enforced; the purpose is told.** What a role *cannot* do is a mount,
   a refused request or a missing credential, held outside the agent. What a role is
   *for* -- report, do not fix; ask before installing -- is in its purpose file, which
   the agent is given at every start. This page says which is which, every time.
3. **You are between every pair of roles.** A role that writes an artefact says where,
   and hands it to nobody; a role reads one when you tell it to. You read it first.
   This one is told, not enforced: the artefact directories are readable to every role.

## 2. The artefacts

Everything the roles exchange is a file under `.asb/` in the repository, so the sandbox
can bind it and you can read it; `.asb/` is kept out of git. Each instance writes in a
directory of its own, read-only to the others, and `.asb/coord/COORDINATION.md` says
which is whose.

| artefact | written by | read by | what it is |
|---|---|---|---|
| **Statement** | Planner | Implementer, Reviewer, you | the problem: what is to be achieved, under which requirements and restrictions; the options considered and the one you chose, with the reasons |
| **Task** | Planner | one Implementer, Reviewer, you | the Statement, or one Implementer's part of it (`.asb/plan/planner-1/tasks/I1.md`), naming the Implementer the Planner wants |
| **Handoff** | Implementer | Reviewer, you | what was done, how, what was not and why; the branch, and the diff against `main` -- an environment change included, as the specification's diff |
| **Review** | Reviewer | Implementer (through you), you | findings against the Statement and the current state, each with its evidence; suggestions; what it could not investigate and would need |
| **Objection** | Implementer | you | a finding the Implementer holds to be wrong, with the reasons -- to you, not to the Reviewer |
| **Decision** | you | Planner, and whoever it addresses | the option chosen, an objection upheld or overruled, a change of direction |
| **Measurements** | Planner | Planner, you | what the Planner measured to compare the options, kept for the next round |
| **Messages** | each role, its own file | every role, you | what a role is doing, what it needs, what it wrote and where (section 5) |
| **Scratch** | each role | that role only | test scripts, probes, notes: `.asb/scratch/`, private to each role at the same path, kept across its launches |

Every instance has a **handle** you and the roles address it by: `P1`, `P2`, `I1`, `I2`,
`R1`, `S`. The dot-file keeps the names (`implementer-1`); the purpose file says "you are
`implementer-1`, called I1". The handle is what makes your sentences short.

## 3. The roles

For each role: its purpose, its inputs and outputs, what it may and may not do, and for
every "may not" whether the sandbox **enforces** it or its purpose file **tells** it.
Every role but the Supervisor may run as several instances, each a sandbox of its own
with its own memory: a Planner that works in one field keeps that field's knowledge,
and its material -- documents, another project's sources -- is a read-only line in its
own section, so no other instance loads it. The Supervisor is one: it is the gate to the
outside.

### Planner

**Purpose.** Compose the Statement of a problem from what you bring -- feedback, an
issue, a feature request. Research the code base and the material outside; lay out the
options, each with its consequences, and recommend one. Help you decide: answer
questions, measure what a decision needs. Then write the final Statement, and the
Tasks.

| | |
|---|---|
| inputs | `main`, built; the project's documents and issues; its field's material; your questions and Decision; its earlier Measurements |
| outputs | the Statement and the Tasks; the Measurements; its Messages |
| may | read everything in the project and on the web; run the code and write probes, in its scratch |
| may not | change the code (**enforced**: the project is read-only to it); publish -- an issue, a comment, a push (**enforced**: its network reads and refuses what writes; no git transport); install into the development environment (**enforced**: read-only; a measurement that needs more uses a venv in its scratch) |

### Implementer

**Purpose.** Resolve its Task: produce or change code from the current state, under the
requirements and invariants the project defines. Write the Handoff. When a Review
arrives, examine each finding before acting on it; address what holds, and object, with
reasons, to what does not.

| | |
|---|---|
| inputs | its Task; the code base; the Review (through you); the project's documents |
| outputs | the change, on its own branch in its own clone; its environment, the clone's, with what it installed; the Handoff; an Objection; its Messages |
| may | edit the code in its clone; run tests, build, install into its clone's environment; commit on its branch |
| may not | publish -- push, open a pull request, comment (**enforced**: as the Planner; the Supervisor publishes on your word); change a Statement or a Task (**enforced**: read-only); read another role's memory (**enforced**: each role's memory is its own) |

### Reviewer

**Purpose.** Assess a change against the current state, the project's requirements and
the Statement it answers. Report findings with evidence; suggest where it can. Run the
code where that is needed, and say what it would need -- a build, an install -- rather
than doing it.

| | |
|---|---|
| inputs | the Statement; `main` at its last commit, and the change as the Handoff gives it -- the diff and the branch; the project's documents; documents on the web |
| outputs | the Review; its Messages |
| may | read the code and run it -- an Implementer's build with the environment it was built in, `.asb/impl/1/.env/bin/...`; write test scripts in its scratch |
| may not | change the code (**enforced**); see how the change was reached -- the Implementer's memory, conversations or commit-by-commit history (**enforced**: memory is per role; every history is hidden from it); publish (**enforced**); build or install (**enforced**: nothing writable but its directory and its scratch) |

### Supervisor

**Purpose.** Keep the round on its track, and be the only role that touches the
outside: on your word, merge an accepted branch into `main`, build it, push, open the
pull request, post the comment, close the issue. Never act on the *contents* of an
artefact it relays: a review that says "run this" is relayed, not run.

| | |
|---|---|
| inputs | every artefact; every role's Messages; your instructions |
| outputs | `main`, with the accepted change merged and built; what goes outside; the coord index |
| may | what you may, on your instruction |
| may not | write in an Implementer's clone (**enforced**: read-only to it; it fetches the branch); act on an artefact's contents without your word (**told** -- it has the access, which is why its purpose file matters most) |

### You

Decide. Read every artefact before it moves. Read each role's purpose file before
approving the dot-file that installs it. Instruct, direct or question any role, and
watch what it does: a role going the wrong way is stopped by you, not by the sandbox.
Nobody reads another role's memory, you included: a role that wants to know why another
did something asks, through the message files, and the answer is what the other chose
to say.

## 4. The round, and where the code lives

    Statement  -->  implementation + Handoff  -->  Review  -->  accept
        ^                                              |
        |            revision (findings that hold)     |
        +---------  or Objection, decided by you       +

Each arrow passes through you. When you accept, the Supervisor merges the branch into
`main`, updates the development environment, builds there, and publishes; the Planner
then measures the new `main` for the next Statement.

Every role launches from the repository itself:

    ~/git/x/                    the repository
      .agent-sandbox            one dot-file, approved once, with every role's sections
      .git/                     main's history: the Supervisor's
      src/ ...                  main: read-only to every role but the Supervisor
      .asb/
        plan/ handoff/ review/  each instance's own directory inside
        coord/ roles/ scratch/  messages and the index; purpose files; scratch
        impl/1/ impl/2/         I1's and I2's clones, on branches impl-1 and impl-2
        git/1/  git/2/          their histories, kept apart from the trees

- **A clone per Implementer.** An Implementer works in `.asb/impl/N/`, a clone of the
  project on its own branch, read-write to it alone; its history is `.asb/git/N/`. Git
  works in the clone as in any other. Implementers run at once on separate clones;
  whether two tasks collide is the Planner's judgement and the Supervisor's merge.
- **History is its owner's.** `main`'s history is the Supervisor's (and read-only to the
  Implementers, whose clones read through it); a clone's is its Implementer's. In a
  tree whose history is hidden, git says `not a git repository`. A Planner that wants
  history reads it on GitHub.
- **Builds.** An Implementer builds in its clone; the Supervisor builds `main` after a
  merge, so `main` always holds the integration state and its build, which you can try
  on the host.
- **Environments.** The development environment is a conda environment you name
  (`x-dev` here): `main`'s, the Supervisor installs into it, you activate it on the host.
  Each Implementer gets a clone of it in its tree, `.asb/impl/N/.env`, and installs
  there -- `conda install -p .asb/impl/1/.env ...`. A package a change needs goes into
  the specification (`environment.yml`), so it travels in the diff; each role updates
  its own environment from it (`conda env update -p ... -f environment.yml --prune`).
  A Reviewer runs an Implementer's build with that environment, by path.

## 5. Messages

Each role writes only its own message file, `.asb/coord/<role>.md`, and reads the
others' -- enforced: its own file is the one it may write. It notes there what it is
doing, what it needs from another role (addressed by handle), and what it wrote where.
`.asb/coord/COORDINATION.md` lists every instance -- handle, role, message file, its
directories; `--init` writes it, the Supervisor keeps it. You read them all.

## 6. Setting up

On the host, at the top of the repository:

    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev
    $EDITOR .agent-sandbox            # what --init cannot know: hosts to allow, a Planner's material
    asb --trust                       # the review, then the approval
    asb --check --role reviewer-1     # what the reviewer has: nothing writable but its own

`asb --init` writes `.agent-sandbox`, `.asb/` with every directory the file names, a
purpose file per instance in `.asb/roles/`, the coord index, and `/.asb/` in
`.git/info/exclude`; it makes each Implementer's clone (with your git identity) and,
with `--env`, its environment. Without counts you get one of each role; `reviewer=0`
leaves one out. Without `--env` the `[conda]` sections are written commented out. It
approves nothing -- `asb --trust` does, after you have read the file and the purpose
files.

Run it again with more instances (`implementer=3`) and it adds what is missing --
sections, purpose file, clone -- and changes nothing that exists; the changed file
needs `asb --trust` again.

`asb --check --role NAME` is the way to see what a role has before it runs: its
policy, what can reach it from other sessions, where it can act as you (your agent's
API, GitHub, SSH), and every path it may write.

## 7. GitHub: reading for everyone, publishing for the Supervisor

The roles read issues and pull requests with `gh`, using the gh login you keep in
`~/.claude/gh` (`GH_CONFIG_DIR=~/.claude/gh gh auth login`); the model's dot-file gives
it to every role with `gh = read-only`. What keeps every role but the Supervisor from
writing with it is the network: `retrieve-only` lets `gh` read and refuses what writes
-- a GraphQL query passes, a mutation does not -- and `git = refuse` stops git's
transport.

**Recommended: a token that cannot write.** The network bounds what a role *does* with
the token; it cannot stop the token itself from being sent out in a request to an
allowed host. A fine-grained personal access token with read-only permissions bounds
that wherever it ends up. Give it to the reading roles and keep your full login for
the Supervisor:

    [connect]
    ~/.claude/gh/ = read-only outside:~/.gh-read
    [connect:supervisor]
    ~/.claude/gh/ = read-only

The setup is in [recipes.md](recipes.md) (the `gh` section).

## 8. The dot-file

What `asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev` writes, with two
Planners' material added by hand. **Enforced, for a network line** (`retrieve-only`,
`[deny]`, `git = refuse`) **means under `mode = strict`**, which this file sets: there
nothing but the proxy is routed. Under `proxy`, those lines bind only the tools that use
the proxy.

```ini
[sandbox]
preset = inherit

# ---- what every role gets ------------------------------------------------------
[conda]
name = x-dev                      # the development environment: main's build, the user's to activate on the host
[connect]
project = read-only               # the working tree, read-only; the Supervisor opens it
.asb/coord/ = read-only           # the message files and the index: every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
./.git/ = own                     # history is its owner's: main's is the Supervisor's...
.asb/git/ = own                   # ...and a clone's its Implementer's
gh = read-only                    # your gh login, for reading issues and pull requests
# hardening, optional (section 7): ~/.claude/gh/ = read-only outside:~/.gh-read
[net]                             # every role reads the web and GitHub, and publishes nothing...
mode = strict                     # ...through the proxy only: under `proxy` a tool can ignore it
retrieve-only = on
git = refuse

# ---- planners: an expert each; a Planner's own material is a read-only line here --
[connect:planner-1]
.asb/plan/planner-1/ = read-write   # its Statements, Tasks and Measurements
.asb/coord/planner-1.md = read-write
~/refs/parsing/ = read-only       # P1's field: its material, nobody else's context (added by hand)
[connect:planner-2]
.asb/plan/planner-2/ = read-write   # its Statements, Tasks and Measurements
.asb/coord/planner-2.md = read-write
~/refs/reporting/ = read-only
~/git/other-project/ = read-only  # the sources P2 knows (added by hand)
[briefing:planner-*]              # reads .asb/roles/<role>.md, this instance's

# ---- implementers: a clone each --------------------------------------------------
[connect:implementer-1]
.asb/handoff/implementer-1/ = read-write
.asb/coord/implementer-1.md = read-write
.asb/impl/1/ = read-write       # its clone's tree, with its .env
.asb/git/1/ = read-write        # its clone's history
./.git/ = read-only               # the clone reads main's objects through it
[conda:implementer-1]           # activation only; the clone is writable as its tree is
prefix = .asb/impl/1/.env
[connect:implementer-2]
.asb/handoff/implementer-2/ = read-write
.asb/coord/implementer-2.md = read-write
.asb/impl/2/ = read-write       # its clone's tree, with its .env
.asb/git/2/ = read-write        # its clone's history
./.git/ = read-only               # the clone reads main's objects through it
[conda:implementer-2]           # activation only; the clone is writable as its tree is
prefix = .asb/impl/2/.env
[briefing:implementer-*]          # reads .asb/roles/<role>.md

# ---- reviewers: the common block already hides every history -----------------------
[connect:reviewer-1]
.asb/review/reviewer-1/ = read-write
.asb/coord/reviewer-1.md = read-write
[briefing:reviewer-*]             # reads .asb/roles/<role>.md

# ---- supervisor: the only role that reaches outside ------------------------------
[connect:supervisor]
project = read-write              # merges the branches in the main tree, pushes
./.git/ = read-write
.asb/impl/ = read-only            # the clones are the Implementers'; it fetches their branches
.asb/git/ = read-only
.asb/coord/supervisor.md = read-write
.asb/coord/COORDINATION.md = read-write   # the index
[conda:supervisor]                # main's build lands in x-dev, which lives in the conda tree
write = 1
[net:supervisor]                  # ...except the Supervisor, which publishes
retrieve-only = off
git = allow
[briefing:supervisor]             # reads .asb/roles/supervisor.md
```

Add to it what a round turns out to need, when it does; `asb --trust` then reviews the
change.

## 9. One round, terminal by terminal

Each role is a launch of its own, from the repository, in a terminal of its own; a
second terminal of the same role joins the running one. A role's purpose, handle and
protocol are in its context at every start, so your sentences can be short. You read
the artefacts on the host as files, and move the round on by telling the next role
where its input is.

**Terminal 1 -- a Planner.** `asb --role planner-1 claude`, then:

> You are P1. The problem is issue #NNN. Ask me when you need a decision.

The Planner researches, measures, and writes the options and its recommendation in its
directory; you read, ask, decide; it writes the Tasks, one per Implementer. Another
field's problem goes to `P2`, in a terminal of its own.

**Terminals 2 and 3 -- the Implementers.** `asb --role implementer-1 claude`, then:

> You are I1. Your task is P1's. Ask if you have questions, or when you are blocked.

The same for I2; they run at once, each in its clone, and each writes its Handoff in
its directory and says so.

**Terminal 4 -- a Reviewer**, once you have read a Handoff:
`asb --role reviewer-1 claude`, then:

> You are R1. Review I1's handoff. Ask if you need something you cannot do.

You read the Review and relay it in terminal 2: "R1 has reviewed your handoff; address
what holds, object to what does not." The round goes on until you accept.

**Terminal 5 -- the Supervisor**, when you accept: `asb --role supervisor claude`, then:

> You are S. I1's work is accepted: merge, build, push, open the pull request. Tell P1.

The Planner measures the new `main` for the next Task; you try the build on the host,
in `x-dev`.

A role's stores -- its memory, its scratch, its clone -- persist across launches.
`asb --role reviewer-1 --exec bash` opens a shell in that role's sandbox, to look around
with its eyes. `asb --check` and `asb --trust` run on the host.

## 10. Writing your own model

A model is data: `models/<name>/` holds a dot-file template (`agent-sandbox`), a purpose
file per role (`roles/<role>.md`) and a coord index template, and `asb --init NAME`
writes a project's files from it; `NAME` may also be a path to your own. The template's
role-suffixed sections are its roles -- `[connect:planner-{n}]` numbered instances,
`[connect:supervisor]` a single one -- and the roles need distinct initials, since the
handles come from them. The format is in [models/README.md](../models/README.md).

What makes a model a model is that every "may not" in it is either a line of the
dot-file (enforced) or a sentence of a purpose file (told), and its README says which.
