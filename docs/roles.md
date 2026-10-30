# Roles: Planner, Implementer, Reviewer, Supervisor, Gate -- and you

A way to work on one project with several AI agents at once, each with a job and a
boundary: Planners work out what to do, Implementers do it, Reviewers check it, a
Supervisor coordinates them, and a Gate publishes what you accept. You decide, from the
Supervisor's terminal, and every message between the roles passes your approval there:
one by one, or, for the revisions between an Implementer and its Reviewer within a Task,
once, when the Task opens; two notices to the Planner, the Reviewer's acceptance and a
merged step's green CI run, go on their own (section 5).
`asb --init roles` sets a project up for it; this page says what each role may do, how
the work moves, and how to run a round. Why it is built this way is in
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
   and hands it to nobody; a role reads one when its inbox tells it to, and only the
   Supervisor writes the inboxes, each message after you approved it, or, within a Task
   you opted in to the relay, on the word you gave when it opened, but for two notices
   to the Planner that go on their own (section 5). You read the artefact first, or,
   under the relay, as it goes by. The inboxes' writer is enforced (section 5); the rest
   is told: the artefact directories are readable to every role.

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
| **Review** | Reviewer | Implementer (through you, or relayed: section 5), you | findings against the Statement and the current state, each with its evidence; suggestions; what it could not investigate and would need |
| **Objection** | Implementer | you | a finding the Implementer holds to be wrong, with the reasons -- to you, not to the Reviewer |
| **Decision** | you | Planner, and whoever it addresses | the option chosen, an objection upheld or overruled, a change of direction |
| **Measurements** | Planner | Planner, you | what the Planner measured to compare the options, kept for the next round |
| **Messages** | each role, its own file | every role, you | what a role is doing, what it needs, what it wrote and where; `ack N` and `done N` for its inbox (section 5) |
| **Instructions** | the Supervisor, each one approved by you, or relayed on the word you gave for the Task (section 5) | the role it is for | the next step for one role, numbered `## N`, in that role's inbox `.asb/coord/to/<role>.md` (section 5) |
| **Scratch** | each role | that role only | test scripts, probes, notes: `.asb/scratch/`, private to each role at the same path, kept across its launches |

Every instance has a **handle** you and the roles address it by: `P1`, `P2`, `I1`, `I2`,
`R1`, `S`, `G`. The dot-file keeps the names (`implementer-1`); the purpose file says "you are
`implementer-1`, called I1". The handle is what makes your sentences short.

## 3. The roles

For each role: its purpose, its inputs and outputs, what it may and may not do, and for
every "may not" whether the sandbox **enforces** it or its purpose file **tells** it.
Every role but the Supervisor, the Gate and setup may run as several instances, each a
sandbox of its own with its own memory: a Planner that works in one field keeps that
field's knowledge, and its material -- documents, another project's sources -- is a
read-only line in its own section, so no other instance loads it. The Supervisor is one:
the terminal you stay in. The Gate is one: the only way out.

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
| inputs | its Task; the code base; the Review (through you, or relayed); the project's documents |
| outputs | the change, on its own branch in its own clone; its environment, the clone's, with what it installed; the Handoff; an Objection; its Messages |
| may | edit the code in its clone; run tests, build, install into its clone's environment; commit on its branch |
| may not | publish -- push, open a pull request, comment (**enforced**: as the Planner; the Gate publishes on your word); change a Statement or a Task (**enforced**: read-only); read another role's memory (**enforced**: each role's memory is its own) |

### Reviewer

**Purpose.** Assess a change against the current state, the project's requirements and
the Statement it answers. Report findings with evidence; suggest where it can. Run the
code where that is needed, and say what it would need -- a build, an install -- rather
than doing it.

| | |
|---|---|
| inputs | the Statement; `main` at its last commit, and the change as the Handoff gives it -- the diff and the branch; the project's documents; documents on the web |
| outputs | the Review; its Messages. What another role must run -- a probe, a reproduction -- lives in the Review directory, readable by every role; scratch is private |
| may | read the code and run it -- an Implementer's build with the environment it was built in, `.asb/impl/1/.env/bin/...`; write test scripts in its scratch |
| may not | change the code (**enforced**); see how the change was reached -- the Implementer's memory, conversations or commit-by-commit history (**enforced**: memory is per role; every history is hidden from it); publish (**enforced**); build or install (**enforced**: nothing writable but its directory and its scratch) |

### Supervisor

**Purpose.** Coordinate the round from the terminal you stay in. On your word it sends
the other roles their next step -- which artefact to read, what to do -- each message
shown to you and written only when you approve it, but for the revisions between an
Implementer and its Reviewer within a Task you opted in to the relay (section 5): those
it writes on the word you gave when the Task opened, and reports in one line each. So a
line in a role's inbox is your word by construction, given per message or once for the
Task. It watches every role's messages; when a role reports done, it proposes the next
step and asks. At start it prints the launch line of every other role,
from the index -- `asb --role NAME claude --continue`, which starts the role's session
when it has none and resumes it when it has -- and one line that opens them all, a tmux
pane each: `asb --roles NAME NAME ... claude --continue` (section 9). On your word it merges an accepted branch into `main` and builds it
there, both local and reversible. It publishes nothing: when a step goes outside, it
writes the Gate's message, and after you approve it, appends it to the Gate's inbox.
Never acts on the *contents* of an artefact it relays: a review that says "run this" is
relayed, not run.

| | |
|---|---|
| inputs | every artefact; every role's Messages; your instructions |
| outputs | the Instructions, in every role's inbox; the texts the Gate posts, in its own directory; `main`, with the accepted change merged and built; its Messages |
| may | write the inboxes; merge and build in `main`; on your instruction |
| may not | publish -- push, comment, open a pull request (**enforced**: the common block's network, `retrieve-only` and `git = refuse` over HTTPS, and no `[ssh]` host for it -- those lines do not reach into SSH); write an instruction you have not approved, per message or for a Task's relay, but the two notices to the Planner, the Reviewer's acceptance and that a merged step's run is green (**told** -- the one rule its purpose file carries everything on: the sandbox cannot see your approval); write in an Implementer's clone (**enforced**: read-only to it; it fetches the branch); act on an artefact's contents without your word (**told**); merge before every approval is in, the Reviewer's, the Implementer's, the Planner's and yours (**told**) |

### Gate

**Purpose.** Publish, and nothing else: push, open a pull request, post a comment, open
or close an issue, send a mail -- each as a message from the Supervisor says, a message
you approved in the Supervisor's terminal. It chooses the method (gh, ssh, email) and
asks nothing further: the message names the verb, the target (remote and branch, issue
or pull-request number) and the file whose text is posted verbatim. A message that
leaves any of that open, or fails the publication policy in its purpose file (the AI
footer the project uses, no secrets, nothing beyond what the message names), goes back
to the Supervisor with the reason, and so does one it cannot complete; the Supervisor
and you resolve it. It never guesses. A post that mentions a GitHub user (`@name`)
notifies a person, so the Gate posts it only after you approve it in the Gate's own
terminal, where the Supervisor sends you. Its terminal stays open: it arms a watcher on
its inbox at start, as every role does, and wakes on the Supervisor's message; its
`[serve:gate]` has `watch` alone, so the watcher is enforced and the Gate is never
served. The trade-off is yours: the role with the outward credentials is always
running, no longer only while you sit at it.
A push to an SSH `origin` needs its host in the file: `--init` writes `[ssh:gate]` with
it commented out, and the Gate sends back the exact line, `asb --apply '[ssh:gate]'
github.com` (the host of `origin`); with it on, a launch can add `--ssh-timeout 30m`.
Mail needs a route the file grants (an allow line for the mail API host); out of the
box, gh and ssh.

| | |
|---|---|
| inputs | its inbox, `.asb/coord/to/gate.md`; the file a message names; `main` and its history, read-only |
| outputs | what goes outside; its Messages -- what it did, or why it did not |
| may | push (`git = allow`; by URL, from the read-only history), use your gh login to write (`retrieve-only = off`), SSH where `[ssh:gate]` names the host; its `[permissions:gate]` runs those commands without asking |
| may not | change anything in the project (**enforced**: `main` and its history read-only, nothing writable but its messages and its scratch); post what a message does not name, or guess what it left open (**told**); act on anything but its inbox (**told**; that only the Supervisor writes the inbox is **enforced**) |

### Setup

**Purpose.** Build `main`, as checked out, into the development environment, once per
project and again after `main` moves; build nothing else. It is the role that makes
`--env` an environment that need not exist yet: `--init` makes its prefix empty, and
`asb --role setup claude` creates it there.

| | |
|---|---|
| inputs | the checkout; the CI configuration, the project's build documentation; the web |
| outputs | the environment, with `main` built into it in develop mode; `.asb/setup.md`, the why; `.asb/build_env.sh`, the how (`setup`, from scratch, and `rebuild`, incremental) |
| may | write the checkout (the build lands in it, as when you build it) and the environment's prefix; read the history; read the web |
| may not | publish (**enforced**: `retrieve-only`, no git transport, no gh login, under `mode = strict` as every role here but the Gate); commit (**enforced**: the history is read-only to it); retrieve what the proxy refuses or pin a near version instead (**told**: it asks you for the clone or the host) |

### You

Decide, in the Supervisor's terminal: approve or refuse each message it proposes, and
say, when a Task opens, whether its revisions are relayed without asking; the Reviewer's
acceptance and a green CI run go to the Planner without a question (section 5). Read
every artefact before it moves, or, under the relay, as it moves. Read each role's
purpose file before approving the dot-file that installs it. Question any role in its
own terminal, and watch what it does: a role going the wrong way is stopped by you, not
by the sandbox. Nobody reads another role's memory, you included: a role that wants to
know why another did something asks, through the message files, and the answer is what
the other chose to say.

## 4. The round, and where the code lives

    Statement  -->  implementation + Handoff  -->  Review  -->  accept
        ^                                              |
        |            revision (findings that hold)     |
        +---------  or Objection, decided by you       +

Each arrow passes through the Supervisor's terminal, with your approval: per message,
or, for the revision loop between Review and implementation, once for the Task, when
you opt in to the relay as the Task opens (section 5); the Reviewer's acceptance goes on
to the Planner without a question (section 5). A Task is done when the Reviewer has
accepted the Handoff, the Implementer has resolved every finding, and you have accepted
the change; a Planner's ruling on a deviation is not that. When you accept, the
Supervisor merges the branch into `main`, updates the development environment and builds
there; the Gate publishes, on the message you approve; the Planner then measures the new
`main` for the next Statement.

Every role launches from the repository itself:

    ~/git/x/                    the repository
      .agent-sandbox            one dot-file, approved once, with every role's sections
      .git/                     main's history: the Supervisor's
      src/ ...                  main: read-only to every role but the Supervisor
      .asb/
        plan/ handoff/ review/  each instance's own directory inside
        coord/ roles/ scratch/  messages, inboxes and the index; purpose files; scratch
        bin/                    the inbox watcher, inbox-wait
        serve/                  the prompt of a role run with no terminal (--serve)
        tests                   the project's test commands (Test economy, below)
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
  on the host. The Supervisor re-runs the suite only when `main` moved since the
  branch's base; otherwise the merged tree is the branch's own, already tested by the
  Reviewer, and it says so. After the Gate's push it watches the CI run and, in the same
  turn, proposes the Planner's next step, ending on that or on a question, never on the
  watch alone; the step is done when the run is green, and the Supervisor tells the
  Planner so on its own, with the commit and the run's URL -- one of the two messages
  outside a Task's relay you do not approve (section 5), since it closes a step you
  approved, the merge and the push. A red run is a finding on `main` for the
  Implementer, proposed to you as before; and the next Task of that Implementer or its
  Reviewer opens only once the run is green, so a red run finds both with their context.
  A Task the Planner has already written for that Implementer is asked about while the
  run is in, and on your yes it goes at green without another question; red lapses that
  yes.
- **Environments.** The development environment is a conda environment you name
  (`x-dev` here): `main`'s, the Supervisor installs into it, you activate it on the host.
  Each Implementer gets a clone of it in its tree, `.asb/impl/N/.env`, and installs
  there -- `conda install -p .asb/impl/1/.env ...`. A package a change needs goes into
  the specification (`environment.yml`), so it travels in the diff; each role updates
  its own environment from it (`conda env update -p ... -f environment.yml --prune`).
  A Reviewer runs an Implementer's build with that environment, by path.
- **An Implementer's build.** Its environment is a clone of `x-dev`, and a clone copies
  the editable install too: the project in it points at the parent checkout, not at
  `.asb/impl/N/`. A Python-only change is seen once the clone's environment imports from
  the clone (reinstall it there in develop mode); a compiled change (C++, CUDA) needs a
  build in the clone, into its environment. One checkout, one build: a second
  environment over the same checkout serves Python-level roles only, since its compiled
  parts are the checkout's one build.

### Test economy

Every revision of a change is tested by the Implementer and again by the Reviewer, so
which tests a round runs is a cost that multiplies (#301). The model's policy, told in
the purpose files:

- **Iterating rounds run the affected tests only.** The Implementer runs the tests its
  change affects and the Handoff lists what ran; the Reviewer runs the same selection on
  the Handoff's changed paths and says whether it matches.
- **The whole suite runs once**, when the Reviewer would accept with zero findings,
  before it accepts; that Review reports it, and a failure there is a finding, not an
  acceptance. The Supervisor may ask the Reviewer for that run at any point.
- **The Supervisor's merge rule is unchanged**: the suite again only when `main` moved
  since the branch's base. CI is unchanged too.

What "affected" means is the project's, so the project supplies the commands:
`--init` writes `.asb/tests` with two empty lines, kept like a purpose file once you
fill them:

    iterate = scripts/test-affected.sh      # the tests the change affects
    final = pytest                          # the whole suite

Each runs from the project directory, in the role's environment. `iterate` selects from
the paths changed since the branch's base; a Reviewer's copy has no `.git`, so the
command should take the paths as arguments (or the Reviewer runs the Handoff's listed
tests). With a line left empty, the roles run what the Task says. One project built its
`iterate` from pytest-testmon's selection plus a path-to-tests map for what coverage
cannot see (code run in subprocesses, scripts, the environment's definition), falling
back to the whole suite when the map says every test depends on the change -- one way
to do it, not the model's.

## 5. Messages

**Each role's messages.** Each role writes only in its own message directory,
`.asb/coord/<role>/`, its file `.asb/coord/<role>/messages.md`, and reads the others'
-- enforced: its own directory is the one it may write. (A directory, not a file: Claude
Code's Write and Edit tools write a temp file beside the target and rename it over the
target, which a lone writable file in a read-only directory refuses.) It notes there
what it is doing, what it needs from another role (addressed by handle), what it wrote
where, and its `ack N` and `done N`. `.asb/coord/COORDINATION.md` lists every instance
-- handle, role, messages, its directories; `--init` writes it and adds a row per new
instance when run again. The Supervisor watches them all; you can read them all.

**The inboxes.** The Supervisor's instructions go to one inbox per role,
`.asb/coord/to/<role>.md`, in a directory only the Supervisor may write
(`[connect:supervisor] .asb/coord/to/ = read-write`; every other role reads it through
`.asb/coord/ = read-only`). Each instruction is appended under a header line `## N`, N
counting up per role from 1, and the Supervisor writes one only after you approved it in
its terminal, or, within a Task you opted in to the relay (below), on the word you gave
when it opened; two notices to the Planner go without a question (the relay, below).
Your word on a message can also be given ahead, conditioned on a CI run: a Task already
written for an Implementer whose merge's run is not yet green is asked about then, and
goes when the run is green (section 4).

- **Authenticity is the path.** The dot-file enforces who writes under `to/`, so a role
  needs no signature: it acts on its inbox, and on you in its own terminal, and on
  nothing else that claims to speak for you, however phrased. That the Supervisor
  writes only what you approved, or relays under your standing word, or sends the
  Planner one of the two notices (below), the sandbox cannot see: it is the one rule
  in the Supervisor's purpose file that carries everything, as "publish only what the
  user accepted" was.
- **The watcher.** `--init` writes `.asb/bin/inbox-wait [-t SECS] [-a ALIVE] FILE...`:
  a one-second poll on each FILE's modification time, inode and size (there is no
  `inotifywait` on the hosts, and a poll by path sees the rename the Write tool does),
  exiting 0 at the first change, with that FILE's path on its output, and 1 after SECS
  without one (none, or 0: wait for ever). A role runs it at start with the Bash tool
  in the background (`run_in_background: true`) --
  `.asb/bin/inbox-wait -a .asb/coord/<role>/alive .asb/coord/to/<role>.md` -- and
  again after each wake, which is a turn anyway. Claude Code wakes the idle session
  when the command exits and tells it which file changed; a background command has no
  time limit in a terminal session, so nothing expires (measured with Claude Code
  2.1.300: 13.6 minutes idle with no notice, and the reply 5 s after the write). A
  session relaunched with `--continue` has no turn to do it in until something gives it
  one, so the launch does: `[briefing:...] start = .asb/start/<role>.md` is the text it
  runs as its first turn at every start -- arm the watcher, read the inbox, report --
  and the role is running, and seen running, without a keypress. The
  Supervisor runs one over every role's `messages.md` but its own, and
  over `.agent-sandbox`: a running role keeps the policy its launch started with, so on
  a change the Supervisor tells each role it affects to finish its step and say ready,
  and gives you the relaunch line (`--continue`, once the role's launch has ended). The
  roles' `[permissions]` lines let the watcher run without a prompt under any permission
  mode. A reply that ends with no watcher running is refused once by the claude
  profile's `Stop` hook, for every role whose `[serve:<role>]` names its inbox -- the
  Gate's with `watch` alone, since it is never served: the model is told to arm it, and
  then ends its turn.
- **The cursor.** A role reads its inbox whole from a cursor it keeps in its scratch,
  `.asb/scratch/inbox-cursor` (the last N it handled), at every wake and at every
  start, so a lost notification costs nothing.
- **Delivery.** A role's first act on waking is to append `ack N` to its messages,
  before it reads the instruction, so the Supervisor's watcher sees each one picked up;
  `done N` when it has finished. `inbox-wait` touches `.asb/coord/<role>/alive` at each
  poll, and the touches end with the session: the Supervisor reads the file's age
  before it sends and while it waits. Stale means the role is not running, said at once
  with its launch line from the index; live with no `ack` within a minute means the
  role has not picked it up -- reported, never sent again on the Supervisor's own.
- **The closing line.** A role that has finished ends with "done; in my file; S has
  it", so you need not look at its terminal.
- **Disapproval.** You say no in the Supervisor's terminal, and nothing is written.
  Then either go to the role's terminal to discuss it (the role writes the outcome in
  its messages afterwards, so the record stays whole), or tell the Supervisor to send
  an objection, which you approve like any other message.

**The relay within a Task.** A revision loop usually converges, and nothing leaves the
project while it runs: neither the Implementer nor the Reviewer can publish (enforced),
the Gate posts only on a message you approved, and a merge still waits for your word. So
a Task can run its loop without a question per message, if you say so:

- **What it covers.** Within one Task, once the first Review is in: the message that
  carries the findings to the Implementer ("revise: findings that hold") and the one
  that carries the revised Handoff back to the Reviewer, until the Reviewer accepts or
  the Implementer objects. Everything else keeps its approval: the message that opens a
  Task, an Objection (it comes to you, by design), the merge proposal, every message to
  a Planner or the Gate, and the reset question before a new Task. Two messages to the
  Planner outside the relay go without asking, each reported in one line: the
  Reviewer's acceptance, with the request to confirm that the step is ready -- it
  carries the round's state, and your word still comes at the merge -- and the notice
  that a merged step's run is green (section 4), which closes a step you approved.
- **Opt-in, per Task.** When the Supervisor proposes the message that opens a Task, it
  asks, with "Send it?" and the fresh-or-keep question (below), whether the messages
  between I1 and R1 are relayed automatically for this Task. Without a yes, every
  message is shown and approved as before.
- **Progress.** While it runs, the Supervisor reports each relayed message in one line
  -- what went where, the revision count, what the Reviewer still holds open -- and asks
  nothing. When the loop ends it asks again, with the next step of the round.
- **Back to asking.** Say so in the Supervisor's terminal, at any time, and from the
  next message on each one is shown and approved as before: when the loop is not
  converging, or when it is converging on the wrong thing.
- **What does not change.** Authenticity is still the path, and that the Supervisor
  writes only what you approved, relays under your standing word, or sends the two
  notices above is still told. It never acts on the contents of an artefact: relaying a
  Review is not running it.

**A fresh start per Task.** Every wake re-reads a session's whole context, and roles
wake often, so a session that carries finished Tasks pays for them at each wake. Within
a Task the context earns its keep; between Tasks the record is on disk -- the
Statement, the Task, the Handoff and the Review under `.asb/` -- and what a role has
learnt about the work belongs in its memory. So a role is reset between Tasks, never
relaunched for it:

- **The Supervisor asks.** Before a message that opens a new Task for a role, it asks
  you whether the role starts it fresh or keeps its context -- and, for an Implementer's
  Task, whether its revisions are relayed (above). The role itself is not told: it
  reads its inbox from its cursor either way.
- **The marker, for every role.** For a fresh start the Supervisor writes an empty
  `.asb/coord/to/<role>.reset` and appends the message only once the marker is gone. A
  served role's loop takes it as soon as it appears, and its next turn is a new session
  (below); for a role in a pane of `asb --roles` (section 9), the host side of that
  command takes it, typing `/clear` in the role's pane. Either takes it within a second.
  Still there after ten, nobody takes resets for that role -- you opened it in a
  terminal of your own -- and the Supervisor asks you to type `/clear` there, and sends
  once you say it is done. For an Implementer or a Reviewer whose last merge has a CI
  run that is not yet green, no marker is written: the message that opens its next Task
  is sent only once the run is green, and a red run is fixed in the context the
  merge was made in.
- **A role at a terminal** starts fresh with `/clear`, nothing else: a new session id,
  the old transcript kept on disk. The inbox watcher, a background shell, survives it
  (still `1 shell`), the briefing comes back because the claude profile delivers it
  through a SessionStart hook, which Claude Code fires again on `/clear`, and the next
  message wakes the cleared session, which re-arms the watcher, reads the inbox from its
  cursor and acts (measured, Claude Code 2.1.314). `/clear` sent while the role is in
  a turn is queued and runs when that turn ends (measured, 2.1.314); the marker goes
  only once it is typed, so the message is written after the `/clear` is in the role's
  queue. The start text keeps "unless one is already running (a background shell of
  yours)", for a relaunch: `/start` after `/clear` once armed a second watcher, and at
  the next message both woke the session.
- **What carries over** is what each Planner, Implementer and Reviewer writes to its
  memory before it reports a Task done: how the build behaves, what the tests need,
  what the Reviewer tends to raise.

## 6. Setting up

On the host, at the top of the repository:

    asb --init roles planner=2 implementer=2 reviewer=1 --env x-dev
    $EDITOR .agent-sandbox            # what --init cannot know: hosts to allow, a Planner's material
    asb --trust                       # the review, then the approval
    asb --check --role reviewer-1     # what the reviewer has: nothing writable but its own

`asb --init` writes `.agent-sandbox`, `.asb/` with every directory the file names, a
purpose file per instance in `.asb/roles/`, the coord index, an empty inbox per role in
`.asb/coord/to/`, the watcher `.asb/bin/inbox-wait`, the per-turn prompt of each
Planner, Implementer and Reviewer in `.asb/serve/` (for `--serve`, below), the first
turn of every start of each Planner, Implementer, Reviewer, the Supervisor and the
Gate in
`.asb/start/` (`[briefing] start`: a relaunched role arms its watcher and reads its
inbox without a keypress), the project's test commands in `.asb/tests` (two empty
lines for you to fill: Test economy, section 4), and
`.asb/.gitignore`
(`.asb/` is never committed); it makes each Implementer's clone (with your git identity) and,
with `--env`, its environment. Without counts you get one of each role; `reviewer=0`
leaves one out. Without `--env` the `[conda]` sections are written commented out. It
approves nothing -- `asb --trust` does, after you have read the file and the purpose
files.

`--env x-dev` need not exist yet: `--init` then makes its prefix as an empty directory,
under the conda base that applies, and says to launch the setup role,
`asb --role setup claude`, which builds `main` into it. The Implementers' environments
are clones of it, so until it is built there is nothing to clone: `--init` says so and
skips them, and run again once setup is done, it makes them.

The model's common block -- what every role gets -- is written once per role pattern
(`[connect:planner-*]`, `[connect:supervisor]`, ...), never unsuffixed, so the file can
hold another model too: `asb --init github` in the same checkout adds the `gh-*` roles,
which keep the github model's policy. Two models whose role names overlap are refused.

**Another project's environment.** A project with no build of its own -- a benchmark
or a test harness -- often runs against an environment another checkout builds, a
PyTorch development environment for example. `--shared-env NAME` in place of `--env NAME`
says so: every role activates NAME read-only, nothing clones or builds it (no setup
role, no Implementer environments, no `write = 1` for the Supervisor), and the
Implementers and the Supervisor get `NAME/ = copy-on-write`, so what they install for
this project lands in a layer of their own and reaches neither the other project nor
each other. The source trees NAME's editable installs import from (its `direct_url.json`,
`.egg-link` and `.pth` entries) are declared read-only for every role, so its imports work
inside. NAME must be built; `--init` refuses one that is not. `asb --check` names an
active environment's editable source a role cannot read, with the `asb --apply` line that
declares it, whichever way the file was written.

Run it again with more instances (`implementer=3`) and it adds what is missing --
sections, purpose file, clone -- and changes nothing else that exists, except a purpose
file it wrote that you have not changed since: that one takes the model's current text.
One you changed is kept, and said so. The changed files need `asb --trust` again.
A section the file has is never changed, so a line the model gained since (a key that
section lacks, a host or rule not in it) is reported at the end, loud, with one
`asb --apply '[SECTION]' LINE...` per section to add it; a line you commented out, or a
key whose value you changed, is yours and is not.
A role relaunched after its purpose file changed is told so at session start: a resumed
conversation would otherwise keep to the rules its earlier turns followed, so the
briefing says the current text replaces them (the hash is kept in the role's state, not
the project).

`asb --check --role NAME` is the way to see what a role has before it runs: its
policy, what can reach it from other sessions, where it can act as you (your agent's
API, GitHub, SSH), and every path it may write.

**A role with no terminal (#277).** A Planner, Implementer or Reviewer can run without
a terminal of its own:

    asb --role implementer-1 --serve claude

in a spare pane or tmux window you need not watch. It runs on the host, in the
foreground: it starts the role's launch and holds it open, then waits on the role's
inbox and, at each change, runs one turn of the role's session in its sandbox --
`claude -p` told one fixed line, "A message arrived in your inbox. Follow your purpose
file's inbox rule ...", under `--permission-mode bypassPermissions`. Nobody is there to
answer a prompt, so Claude Code's prompts are off: **a served role is bounded by its
policy alone** -- its mounts, its network, the syscall filter -- which the sandbox
enforces outside the agent whatever the agent decides. The `[permissions]` lines are
for the roles at a terminal, where a prompt has you to answer it. That is why the Gate,
whose policy can publish, is never served. The purpose file's inbox rule does the work -- `ack N`, act, report,
`done N` -- and the turn ends. What it waits on and what it says is the role's
`[serve:implementer-1]` section, which `--init` writes (`watch =
.asb/coord/to/implementer-1.md`, `prompt = .asb/serve/implementer-1.md`, the prompt
file from the model's `serve/`); the loop touches `.asb/coord/<role>/alive` each second,
as the watcher in a terminal does, so the Supervisor sees the role running.

- **The session id.** The first turn makes the session with a fresh id and writes it to
  `.asb/coord/<role>/session`; every later turn, and the next `--serve`, resumes it, so
  the role remembers its earlier messages. To talk to it yourself, open that session in
  a terminal: `asb --role implementer-1 claude --resume $(cat .asb/coord/implementer-1/session)`.
- **A reset.** An empty `.asb/coord/to/<role>.reset` -- in the inboxes' directory,
  which only the Supervisor writes -- makes the next turn a new session: a fresh id,
  told the prompt as every turn is, written to `.asb/coord/<role>/session`, and the
  marker removed (from inside the directory; a link is removed, never followed). The
  loop takes the marker as soon as it appears, while it waits and while a turn runs,
  and says so; the marker alone is no turn, and the Supervisor appends its message once
  the marker is gone. Not the `[briefing] start` text: that one says to arm the
  watcher, and a `-p` turn that runs one in the background does not end (measured).
  The old session's transcript stays on disk, resumable by its id with `--resume`.
- **The pause.** While anything else is joined into the role's launch -- that terminal,
  most likely -- a turn waits until it has gone: two resumes of one session at once
  fork it (measured with Claude Code 2.1.281).
- **A turn that fails.** A turn that exits non-zero, or is killed, is one line in the
  role's messages -- `turn failed (exit N) for a change to WATCH at TIME; the loop waits
  for the next message` -- which the Supervisor's watcher sees; the loop then waits for
  the next message.
- **Ending it.** `asb --role implementer-1 --shutdown claude`, Ctrl-C in its pane or a
  TERM ends the loop and the launch with it; `asb --role implementer-1 --status claude`
  shows it serving, with its session id. A message written while no loop ran is a turn
  as soon as the next one starts.

The Supervisor and the Gate are never served this way: they are where you work, and
the Gate publishes. A `[serve:ROLE]` section with `watch` alone, as `[serve:gate]` is,
keeps the Stop hook's watch path for the role at its terminal and serves nothing:
`--serve` refuses it ("its [serve] names no prompt"), and the review and `asb --check`
say "watch only".

## 7. GitHub: reading for everyone, publishing for the Gate

The roles read issues and pull requests with `gh`, using your gh login (`gh auth login`
on the host); the model's dot-file gives it to every role with `gh = read-only`. What keeps every role but the Gate from
writing with it is the network: `retrieve-only` lets `gh` read and refuses what writes
-- a GraphQL query passes, a mutation does not -- and `git = refuse` stops git's
transport.

**Recommended: a token that cannot write.** The network bounds what a role *does* with
the token; it cannot stop the token itself from being sent out in a request to an
allowed host. A fine-grained personal access token with read-only permissions bounds
that wherever it ends up. Give it to the reading roles and keep your full login for
the Gate: in the common block's copies for `planner-*`, `implementer-*`, `reviewer-*`
and `supervisor`, the `gh` line becomes

    gh = read-only outside:~/.gh-read

The setup is in [recipes.md](recipes.md) (the `gh` section).

## 8. The dot-file

What `asb --init roles planner=2 implementer=2 reviewer=1` writes, verbatim. Without
`--env` the `[conda]` sections and the lines naming the environment are written
commented out; with `--env x-dev` they name its prefix. A Planner's material is a
read-only line you add in its own section -- `~/refs/parsing/ = read-only` under
`[connect:planner-1]` -- so no other instance loads it. **Enforced, for a network
line** (`retrieve-only`, `[deny]`, `git = refuse`) **means under `mode = strict`**, which
this file sets for every role: there nothing but the proxy is routed. Under
`proxy`, those lines bind only the tools that use the proxy.

```ini
# ---- written by asb --init roles ----
# .agent-sandbox for the roles model (docs/roles.md), written by `asb --init roles`.
# Planners, Implementers and Reviewers are numbered instances; the Supervisor and the
# Gate are one each: the Supervisor coordinates, the Gate publishes.
# Review it, add what this project needs -- hosts to allow, a Planner's material --
# and approve it with `asb --trust`; `asb --check --role NAME` shows what a role has.

# ---- what every role gets: --init writes it per role, [connect:planner-*] and so on --
[sandbox:planner-*]
preset = inherit
# [conda:planner-*]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:planner-*]
project = read-only               # the working tree, read-only; the Supervisor opens it
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
./.git/ = own                     # history is its owner's: main's is the Supervisor's...
.asb/git/ = own                   # ...and a clone's its Implementer's
gh = read-only                    # your gh login, for reading issues and pull requests
[net:planner-*]                   # every role reads the web and GitHub, and publishes nothing...
mode = strict                     # ...through the proxy only: under `proxy` a tool can ignore it
retrieve-only = on
git = refuse
[permissions:planner-*]           # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)
[sandbox:implementer-*]
preset = inherit
# [conda:implementer-*]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:implementer-*]
project = read-only               # the working tree, read-only; the Supervisor opens it
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
./.git/ = own                     # history is its owner's: main's is the Supervisor's...
.asb/git/ = own                   # ...and a clone's its Implementer's
gh = read-only                    # your gh login, for reading issues and pull requests
[net:implementer-*]               # every role reads the web and GitHub, and publishes nothing...
mode = strict                     # ...through the proxy only: under `proxy` a tool can ignore it
retrieve-only = on
git = refuse
[permissions:implementer-*]       # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)
[sandbox:reviewer-*]
preset = inherit
# [conda:reviewer-*]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:reviewer-*]
project = read-only               # the working tree, read-only; the Supervisor opens it
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
./.git/ = own                     # history is its owner's: main's is the Supervisor's...
.asb/git/ = own                   # ...and a clone's its Implementer's
gh = read-only                    # your gh login, for reading issues and pull requests
[net:reviewer-*]                  # every role reads the web and GitHub, and publishes nothing...
mode = strict                     # ...through the proxy only: under `proxy` a tool can ignore it
retrieve-only = on
git = refuse
[permissions:reviewer-*]          # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)
[sandbox:supervisor]
preset = inherit
# [conda:supervisor]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:supervisor]
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
gh = read-only                    # your gh login, for reading issues and pull requests
[net:supervisor]                  # every role reads the web and GitHub, and publishes nothing...
mode = strict                     # ...through the proxy only: under `proxy` a tool can ignore it
retrieve-only = on
git = refuse
[permissions:supervisor]          # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)
[sandbox:gate]
preset = inherit
# [conda:gate]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:gate]
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/git/ = own                   # ...and a clone's its Implementer's
[permissions:gate]                # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)
[sandbox:setup]
preset = inherit
# [conda:setup]
# prefix = ENVPATH                # the development environment, ENV: main's build, the user's to activate on the host
[connect:setup]
.asb/coord/ = read-only           # the message directories and the index (--init keeps it): every role reads all of them
.asb/scratch/ = own               # every role's private scratch, at the same path, kept across launches
.asb/git/ = own                   # ...and a clone's its Implementer's
[permissions:setup]               # what a role runs without asking you: its inbox watcher
Bash(.asb/bin/inbox-wait:*)

# ---- planners: an expert each; a Planner's own material is a read-only line here --
[connect:planner-1]
.asb/plan/planner-1/ = read-write   # its Statements, Tasks and Measurements
.asb/coord/planner-1/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
[serve:planner-1]               # no terminal: asb --role planner-1 --serve claude
watch = .asb/coord/to/planner-1.md
prompt = .asb/serve/planner-1.md
[connect:planner-2]
.asb/plan/planner-2/ = read-write   # its Statements, Tasks and Measurements
.asb/coord/planner-2/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
[serve:planner-2]               # no terminal: asb --role planner-2 --serve claude
watch = .asb/coord/to/planner-2.md
prompt = .asb/serve/planner-2.md
[briefing:planner-*]              # reads .asb/roles/<role>.md, this instance's
start = .asb/start/planner.md     # its first turn: arm the watcher, read the inbox

# ---- implementers: a clone each --------------------------------------------------
[connect:implementer-1]
.asb/handoff/implementer-1/ = read-write
.asb/coord/implementer-1/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
.asb/impl/1/ = read-write       # its clone's tree, with its .env
.asb/git/1/ = read-write        # its clone's history
./.git/ = read-only               # the clone reads main's objects through it
# [conda:implementer-1]           # activation only; the clone is writable as its tree is
# prefix = .asb/impl/1/.env
[serve:implementer-1]           # no terminal: asb --role implementer-1 --serve claude
watch = .asb/coord/to/implementer-1.md
prompt = .asb/serve/implementer-1.md
[connect:implementer-2]
.asb/handoff/implementer-2/ = read-write
.asb/coord/implementer-2/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
.asb/impl/2/ = read-write       # its clone's tree, with its .env
.asb/git/2/ = read-write        # its clone's history
./.git/ = read-only               # the clone reads main's objects through it
# [conda:implementer-2]           # activation only; the clone is writable as its tree is
# prefix = .asb/impl/2/.env
[serve:implementer-2]           # no terminal: asb --role implementer-2 --serve claude
watch = .asb/coord/to/implementer-2.md
prompt = .asb/serve/implementer-2.md
[briefing:implementer-*]          # reads .asb/roles/<role>.md
start = .asb/start/implementer.md # its first turn: arm the watcher, read the inbox

# ---- reviewers: the common block already hides every history -----------------------
[connect:reviewer-1]
.asb/review/reviewer-1/ = read-write
.asb/coord/reviewer-1/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
[serve:reviewer-1]              # no terminal: asb --role reviewer-1 --serve claude
watch = .asb/coord/to/reviewer-1.md
prompt = .asb/serve/reviewer-1.md
[briefing:reviewer-*]             # reads .asb/roles/<role>.md
start = .asb/start/reviewer.md    # its first turn: arm the watcher, read the inbox

# ---- supervisor: coordinates, on your word; merges and builds main; publishes nothing --
[connect:supervisor]
project = read-write              # merges the branches in the main tree
./.git/ = read-write
.asb/impl/ = read-only            # the clones are the Implementers'; it fetches their branches
.asb/git/ = read-only
.asb/coord/supervisor/ = read-write   # its messages.md, in a directory: Write and Edit rename a temp file over it
.asb/coord/to/ = read-write       # the inboxes, one per role: only the Supervisor writes them
# [conda:supervisor]                # main's build lands in ENV, which lives in the conda tree
# write = 1
[permissions:supervisor]          # the commands its purpose file names for a merge and a build
Bash(git fetch:*)
Bash(git merge:*)
Bash(conda env update:*)
[briefing:supervisor]             # reads .asb/roles/supervisor.md
start = .asb/start/supervisor.md  # its first turn: launch lines, watcher, messages

# ---- gate: publishes what the Supervisor sends on your word, and nothing else --------
#   its terminal stays open: it wakes on its inbox, as every role does
[connect:gate]
project = read-only               # reads the file a message names; changes nothing
./.git/ = read-only               # main and its history: a push from it needs nothing more
gh = read-only                    # your gh login: the pull request, the comment, the issue
.asb/coord/gate/ = read-write     # its messages.md: what it did, or why it did not
.asb/scratch/ = own
[net:gate]                        # ...except the Gate, which publishes
mode = strict
retrieve-only = off
git = allow
[ssh:gate]
# github.com                      # SSH as you, for a push to an SSH origin: off; for it:
#   asb --apply '[ssh:gate]' github.com
[permissions:gate]                # the verbs it executes, each from an approved message
Bash(git push:*)
Bash(gh pr create:*)
Bash(gh pr comment:*)
Bash(gh issue comment:*)
Bash(gh issue create:*)
Bash(gh issue close:*)
[serve:gate]                      # watch only: the watcher is enforced; the Gate is never served
watch = .asb/coord/to/gate.md
[briefing:gate]
file = .asb/roles/gate.md
start = .asb/start/gate.md        # its first turn: arm the watcher, read the inbox

# ---- setup: builds the environment, once per project, again after main moves ----
#   asb --role setup claude
[connect:setup]
project = read-write              # the build lands in the tree, as when you build it yourself
./.git/ = read-only               # a build reads its version from the history; it commits nothing
# ENVPATH/ = read-write           # the environment it creates and installs into
gh = own                          # no login: it publishes nothing
[net:setup]
mode = strict                     # as the rest of this model: through the proxy only
retrieve-only = on                # GET and HEAD only; asb --apply '[net:setup]' 'git = fetch' lets it fetch submodules or a git dependency over HTTPS, a read; a push stays refused
git = refuse
[briefing:setup]
file = .asb/roles/setup.md
```

Add to it what a round turns out to need, when it does; `asb --trust` then reviews the
change.

## 9. One round, terminal by terminal

Each role is a launch of its own, from the repository, in a terminal of its own; a
second terminal of the same role joins the running one. You stay in the Supervisor's:
the others report there, and you go to one only to talk to it. A role's purpose, handle
and protocol are in its context at every start, so your sentences can be short. You
read the artefacts on the host as files.

**Terminal 1 -- the Supervisor.** `asb --role supervisor claude --continue`. It prints
the launch line of every other role; open a terminal for each of P1, I1, I2, R1 and G and
run its line there (a role arms its inbox watcher at start, and waits) -- or run
`asb --role NAME --serve claude` in panes you need not watch, a turn per message
(section 6). The last line it prints opens them all at once, in a second terminal:

    asb --roles planner-1 implementer-1 implementer-2 reviewer-1 gate claude --continue

is one tmux session named after the project directory, with a pane per role, in the
order given, five to a window: the first role of a window has the top pane, full width
and half the height, and the others share the bottom half in one row, so here P1 is on
top and I1, I2, R1 and G are below it. A sixth role starts the next window, laid out the
same way. A window is named by its first role, each pane's border shows its role, and
the first window opens with its top pane active. Every pane starts in the project and
runs `asb --role ROLE claude --continue`. The roles end at the first word that starts
with `-` or names a profile, and every engine flag around them reaches each pane
(`asb --roles planner-1 reviewer-1 --serve claude` is two served roles). It reviews
`.agent-sandbox` once, there, before the panes open -- launched together, every pane
would ask -- and attaches; not at a terminal, it prints the attach command instead. A
pane whose launch ends drops to a shell, so its last output stays readable. A session
of that name already open is refused, naming `tmux attach -t NAME` to return to it and
`tmux kill-session -t NAME` to end it; ending it hangs up every launch in it, and each
role's sandbox then ends after the keeper's grace, as when you close its terminal.
Beside the session it starts one process on the host that takes the Supervisor's reset
markers for those roles (section 5): each second it looks for
`.asb/coord/to/ROLE.reset`, and for one it types `/clear` and Enter in that role's pane
-- the pane whose tmux option `@role` is the role -- and removes the marker. It types
nothing else, outlives the terminal you ran `--roles` in, ends when the session does,
and logs to `~/.local/state/agent-sandbox/claude/<project slug>/.roles-resets.log`;
the line `--roles` prints names it. It is not started for served roles, whose loop
takes its own marker, nor in a project without `.asb/coord/to/`. tmux
is the host's, else the tools env's, where `install.sh` installs it by default
([config.md](config.md)). `--continue` in a directory with no conversation starts a new
one (measured with Claude Code 2.1.311), so the one line both starts a round and
resumes it.

The Supervisor's line leaves itself out, as it is already running in a terminal of its
own. A round with the Supervisor on top is started from a plain terminal instead, not
from the Supervisor's own:

    asb --roles supervisor planner-1 implementer-1 reviewer-1 gate claude --continue

is one window, the Supervisor on top and four panes below. Three tmux keys move around
it, with nothing of ours behind them: `C-b C-o` (`rotate-window`) moves every role one
pane along while the layout stays, so the second role takes the top pane; `C-b M-o`
rotates the other way; and `C-b z` zooms the active pane to the whole window and back.
Then, in terminal 1 (or the Supervisor's pane):

> The problem is issue #NNN. Tell P1 to work out the options with me.

S shows you the message for P1; you approve it, S writes it to P1's inbox, and P1 picks
it up (`ack 1` in its messages). The Planner researches, measures, and writes the
options and its recommendation in its directory; it reports done, and S brings it to
you. Read them, and when you need to ask P1 something, go to its terminal; it writes the
outcome in its messages. Once you have decided:

> Tell P1 the decision is option B, and to write the Tasks, one per Implementer.

**The Implementers.** When P1 reports the Tasks done:

> Send I1 and I2 their tasks.

S proposes one message per Implementer; you approve each, and say for each whether its
revisions are relayed (section 5). They run at once, each in its clone, and each writes
its Handoff in its directory and reports done.

**The Reviewer**, once you have read a Handoff:

> Ask R1 to review I1's handoff.

You read the Review; then "Send it to I1: address what holds, object to what does
not." With the relay on for that Task, S sends that message itself, and each revision
after it, a line each, until R1 accepts or I1 objects. The round goes on
until you accept.

**When you accept:**

> I1's work is accepted: merge it into main and build. Then a pull request for it.

S merges and builds, and writes the Gate's message -- `push` of the branch to
`origin`, then `gh pr create` with the text in a file of its own, which you read --
and, once you approve it, appends it to the Gate's inbox. **The Gate**, in its terminal
since the start, wakes on it, publishes and reports done, and S brings you its report.
Back in terminal 1, S tells P1 to measure the new `main` for the next Task; you try the
build on the host, in `x-dev`.

A role's stores -- its memory, its scratch, its clone -- persist across launches.
`asb --role reviewer-1 --exec bash` opens a shell in that role's sandbox, to look around
with its eyes. `asb --check` and `asb --trust` run on the host.

## 10. Writing your own model

A model is data: `models/<name>/` holds a dot-file template (`agent-sandbox`), a purpose
file per role (`roles/<role>.md`), a coord index template, scripts the roles run
(`bin/`) and the prompts of roles run with no terminal (`serve/`), and `asb --init NAME`
writes a project's files from it; `NAME` may also be a path to your own. The template's
role-suffixed sections are its roles -- `[connect:planner-{n}]` numbered instances,
`[connect:supervisor]` a single one -- and the roles need distinct initials, since the
handles come from them. A `#@ scope = roles` line makes the unsuffixed sections after it
the model's common block, written per role pattern so that models compose in one file;
a model's role names must not overlap another's already there. The format is in
[models/README.md](../models/README.md).

What makes a model a model is that every "may not" in it is either a line of the
dot-file (enforced) or a sentence of a purpose file (told), and its README says which.

The other model shipped is [github](../models/github/README.md): review, triage and fix,
one instance per pull request or issue (`asb --role gh-review-1234 claude`), each
working on your built checkout through a layer of its own, and posting only when you
say so. And [market](../models/market/README.md): research for a purchase or a tender,
one instance per topic (`asb --role market-laptops claude`), reaching every public
website with nothing of yours in reach.
