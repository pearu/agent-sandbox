# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com); the project
uses [Semantic Versioning](https://semver.org). Pre-1.0, minor versions may
break compatibility.

## Unreleased

Roles, the keeper, and the claude profile as data. Several defaults change and several
names are gone; there are no aliases for removed names before 1.0.

### Breaking

- **The proxy serves sandbox sessions only**: every proxied launch carries a token, and a
  request without a live session's token gets `407` with a Basic challenge, where it got
  the global allowlist. A session's `[deny]` and `retrieve-only` hang on that token, and
  a client that did not send it -- git, until challenged -- or an agent that dropped it
  from the proxy URL escaped both. A host tool pointed at the proxy by hand is refused.
- **A gh login in `~/.claude/gh` is no longer visible to every project** (#88): it is
  blanked. gh is the `gh` channel, at `~/.config/gh` where `gh auth login` keeps it: the
  role's own (empty) under every preset but `native`, and `gh = read-only` in `[connect]`
  hands your login to a sandbox, live. `gh = read-only outside:PATH` gives another one.
- **The sandbox is invoked explicitly** (#151): `asb [OPTIONS] CMD [AGENT OPTIONS]`, with
  `agent-sandbox` the canonical name. Nothing shadows `claude` any more: `claude` is
  Claude Code itself, unsandboxed, everywhere. Engine options come before the command.
- **Memory is the role's own under `inherit`** (#196). A sandboxed session no longer
  writes your native `~/.claude/projects/<slug>/memory/`, and starts with none of it;
  `memory = copy-on-write` (read yours live) or `seed-only` (carry it over once) under
  `[connect]` brings it in. Other projects' state is out of view under every preset but
  `native`. The global `memory_default` is gone: `[share-memory] all` says the same per
  project, and is reviewed.
- **`[forward]` is `[env]`** (#177): `NAME` forwards, `NAME = VALUE` sets (a profile's
  only), `-NAME` refuses.
- **`[ro]`, `[rw]`, `AGENT_SANDBOX_RO` and `AGENT_SANDBOX_RW` are gone** (#161): a path is
  declared under `[connect]`, `./data = read-only`, with every mode a channel has.
- **`--engine-version` is `--version`** before the command (#159); after it, `--version`
  is the agent's. **`--quiet` is gone**: quiet is the default, `--verbose` shows the
  routine status lines (#162).
- **The host-side subcommands are gone** (#178), and so is the 0.3 config-copy migration
  (#179, #167).
- **The claude profile is a directory**, `profiles/claude/`, with `profile.sh` and its
  dot-file `agent-sandbox` (#181); `profiles/claude.allowlist` is the dot-file's
  `[allow]`, opened per launch.
- **A config or history view that cannot be made refuses the launch** (#207), rather than
  seeding the whole native file.
- **No empty `~/.claude.json` is created** (#204): Claude Code calls a 0-byte one corrupted.

### Added

- **`docs/sshd.md`, the operator's guide to the `sshd` profile** (#335, step 5 of its
  plan): the policy line by line, the recipe on a shared host (a dedicated ordinary
  account, `install.sh` as it, the launch in the background) and on a cloud instance,
  the roles' side (`[ssh] ALIAS`, and `[net] host-port` when they run on the same host),
  what a session sees and never sees, operations and limits, measured on an Ubuntu 24.04
  host. `docs/design.md` gains the profile's mechanism and its residual risks: an escape
  lands in the launching account, every GPU's bus is listed, the keys file is the next
  launch's, the host key is readable by sessions, and the proxy of its own is orphaned
  with the sandbox by a SIGKILL of the keeper's supervisor.
- **The `sshd` profile: a sandboxed ssh login** (#335, step 4 of its plan).
  `asb --profile sshd --role NAME`, run in a project directory, runs an OpenSSH server as
  the role's agent, in the foreground (background it: nohup, tmux; `--shutdown` ends it
  and every job in it), so another machine logs in to this account inside the role's
  sandbox: commands, `bash -s`, sftp, rsync, detached jobs, pty sessions, egress only
  through the sandbox's proxy, the project's `.agent-sandbox` the policy. It needs the
  `strict` mode and exactly one agent port (`--agent-port [ADDR:]PORT` or its other
  forms), which is where sshd listens, and `[sshd] authorized-keys = PATH`, the keys that
  may log in, copied at each launch; the review warns when that file is inside the
  project. Every session gets the launch's environment (the proxy URL with its token,
  the CA variables, the policy's `[env]`, PATH) but what sshd sets per session itself.
  The profile is self-contained: every launch runs a proxy of its own -- the installed
  mitmdump and addon with the unit's options, on the account's port when nothing
  listens there, else the next free one, said at launch -- a child of the role's keeper,
  and keeps its session directory in the role's store instead of `$XDG_RUNTIME_DIR`,
  which logind removes at the account's last logout; so no linger, unit or root is
  needed, and the launch outlives the owner's login. A project's `[env] NAME = VALUE` is
  set under this profile (the review says for which roles; still ignored under
  `claude`). `install.sh` on an account with no user manager writes the unit, says so
  and goes on. New profile-contract declarations: `profile_ro_binds`,
  `profile_self_contained`, `profile_project_env_set`, `profile_by_name_only` and the
  `profile_trust_notes` hook; `AGENT_SANDBOX_MITMDUMP` names the proxy's binary. See
  `docs/profiles.md` and `docs/config.md`.
- **`--agent-port ADDR:PORT` publishes an agent's port at an address of the host, not
  only its loopback** (#335, step 3 of its plan): `0.0.0.0` for every IPv4 address, or
  one IPv4 literal; the same token in `AGENT_SANDBOX_AGENT_PORTS` and `[net] agent-port`.
  A bare `PORT` is the host's `127.0.0.1` as before. A hostname, a CIDR and IPv6 are
  refused, and so is one port named with two addresses. It is said loudly at launch,
  in the review, `--check` and the briefing, and the keeper's policy carries the
  address. In `strict` mode the nft chain lets out the replies on those ports
  (`tcp sport { ... } ct state established accept`): a client that is not on the
  host's loopback was answered through the namespace's interface, which the chain
  dropped. See `docs/network.md`.
- **`[gpu] devices = NODE ...` names a role's GPUs** (#335, step 2 of its plan), so the
  Implementer and the Reviewer on a two-GPU host get a card each instead of both landing
  on GPU 0. It is the dot-file form of `AGENT_SANDBOX_GPU_DEVICES` (which wins over it):
  paths or globs under `/dev/`, replacing the default list -- one card for CUDA is
  `/dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidiaN` -- and per role in
  `[gpu:<role>]`, where it replaces the unsuffixed list. An entry outside `/dev/` or
  with `..` is said at the review and ignored; a node the host lacks is said and
  skipped. The review prints each list, `--check` the nodes and the list's source, and a
  join that names another list than its running role's is refused. See `docs/config.md`.
- **The proxy's port is chosen per account** (#335, step 1 of its plan), so a second
  install in another account on the same host has a proxy of its own. `install.sh` takes
  `8888`, or, when a listener that is not this account's proxy holds `8888`, the next
  free port above it, or `--proxy-port N`; it records the port in
  `~/.config/agent-sandbox/proxy-port`, fills the unit's `--listen-port` from it, and a
  re-run keeps it. The engine reads the file at each launch, `AGENT_SANDBOX_PROXY_PORT`
  overrides it, and the port goes into the proxy URL and, in `strict` mode, the nft rule;
  `--status` names a port that is not `8888`. See `docs/network.md`.
- **After the Gate's push the roles model's Supervisor proposes the Planner's next step
  in the same reply, and a Task already written for the waiting Implementer is asked
  about ahead and goes when the run is green** (#333). Only the Implementer's and the
  Reviewer's next Task wait for the CI run; the Planner's step -- the next Task to plan,
  or, where it is already written, planning ahead -- is proposed with the watch, and the
  reply ends on that proposal or on a question, never on the watch alone. When the
  Planner has already written the waiting Implementer's next Task, the Supervisor says
  so and asks then, with the fresh-or-keep and relay questions as for any Task; on your
  yes, at green, it writes the `.reset` marker if fresh, sends the message once the
  marker is gone and reports it in one line, with no second question. A red run lapses
  that yes: the finding goes to the Implementer as before, and the Task is asked about
  again once the fix is merged and its run is green. It is your word on that one
  message, given ahead, not a message that goes without asking. `docs/roles.md` says so
  in section 4's builds and section 5's inboxes; `asb --init roles` run again takes the
  new purpose file where you have not changed it.
- **The roles model's Supervisor tells the Planner on its own that the Reviewer accepted
  and that a merged step's CI run is green, and an Implementer's next Task waits for the
  run** (#331). Two messages to the Planner outside a Task's relay go without asking,
  each reported in one line: the Reviewer's acceptance of a Handoff, with the request to
  confirm that the step is ready -- it carries the round's state, and your word still
  comes at the merge -- and, when the run on a merge the Gate pushed is green, the
  notice with the merged commit, the run's URL and that the step is done, which closes
  a step you approved. The message that opens the next Task for an Implementer or a
  Reviewer whose merge has a run not yet green waits for the run, and no `.reset`
  marker is written before; a red run is still proposed to you as a finding for the
  Implementer, which keeps its context, as does the Reviewer, and the waiting Task
  opens after the fix is merged and green. The Planner plans on the merged `main`
  meanwhile. Everything else stays asked. `docs/roles.md`, `docs/design.md`, the model's
  README, the coord index and the Supervisor's purpose file say so wherever they state
  that every message passes your approval; `asb --init roles` run again takes the new
  purpose file where you have not changed it.
- **The host takes resets for the roles in `asb --roles` panes; a fresh start at a
  terminal is `/clear` alone** (#329). Beside the tmux session it opens, `--roles`
  starts one host process that, every second, looks for the Supervisor's
  `.asb/coord/to/ROLE.reset`, types the profile's `[agent] clear` (claude: `/clear`) and
  Enter in that role's pane, and removes the marker (a link removed, never followed);
  it types nothing else, outlives the terminal, ends with the session, and logs to
  `.roles-resets.log` in the project's state directory. A `--serve` loop takes the
  marker as soon as it appears, not only when a message arrives. The Supervisor has one
  rule for every role: write the marker, send once it is gone, and ask you for `/clear`
  in the role's terminal only when nobody took it in ten seconds. `/start` after
  `/clear` is gone from the docs: the inbox watcher survives `/clear`, the briefing
  comes back through the SessionStart hook, and the next message wakes the cleared
  session (measured, Claude Code 2.1.314); `/clear` sent mid-turn is queued and runs
  when the turn ends.
- **The roles model's Supervisor relays the revisions within a Task, on your opt-in**
  (#326): with the message that opens a Task it asks too, beside "Send it?" and the
  fresh-or-keep question, whether the messages between the Implementer and its Reviewer
  are relayed for this Task. With a yes, once the first Review is in, the findings to
  the Implementer and the revised Handoff back to the Reviewer go on that word, each
  reported in one line (what went where, the revision count, what the Reviewer still
  holds open), until the Reviewer accepts or the Implementer objects; then it asks
  again, with the next step. Opening a Task, an Objection, the merge proposal, every
  message to a Planner or the Gate and the reset question keep their approval, and you
  return to asking at any time by saying so in its terminal. `docs/roles.md`, the
  Supervisor's purpose file and the coord index describe it; `asb --init roles` run
  again takes the new purpose file where you have not changed it.
- **`asb --roles ROLE... [OPTIONS] CMD [AGENT OPTIONS]`: one tmux session with a pane
  per role** (#317, #320), five to a window: in each window the first role has the top
  pane, full width and half the height, and the others share the bottom half in one
  row; a sixth role starts the next window, laid out the same way. The session is named
  after the project directory; a window is named by its first role, a pane's border
  shows its role, and each pane starts in the project and runs `asb --role ROLE` with
  the rest of the command line, then drops to a shell when its launch ends. The roles
  end at the first word that starts with `-` or names a profile. The dot-file review
  runs once, in the terminal that runs `--roles`, before the panes open; then it
  attaches with the first window's top pane active, or, not at a terminal, prints the
  attach command. A session of that name already open is refused, naming
  `tmux attach -t NAME` and `tmux kill-session -t NAME`; so are `--role`, a verb,
  `--exec`, a review and a sandbox. tmux is the host's, else the tools env's:
  `install.sh` now installs `gh` and `tmux` there by default. The roles model's
  Supervisor prints the one line besides the per-role ones, and every launch line says
  `claude --continue`, which starts a session or resumes it.
- **`asb --list [WORD]` and `asb --list-all [WORD]`: the role sessions you can resume**
  (#314): one block per project -- this one's, or every project's from any directory --
  and in it one entry per role store, newest activity first: running or stopped,
  created and last active, and a one-line summary; one last line names the command that
  resumes one, `asb --role ROLE claude --continue` (`cd PROJECT_DIR && ` before it for
  `--list-all`). The summary is the store's own line when present
  (`summary/line`), else the title Claude Code recorded in the newest conversation
  (`custom-title`, then `ai-title`), else its first prompt. WORD keeps the roles whose
  name, summary or conversations mention it. Every launch now writes the project's path
  to the store's `project` file, since the store's slug does not keep it; an older store
  falls back to its history's first record.
- **Every session keeps a one-line summary of itself, which `asb --list` shows** (#314):
  the role store's `summary/`, made at keeper start, is bound read-write at
  `/run/agent-sandbox/summary/`, and the briefing tells every session to keep
  `summary/line` current -- what it is about and where it stands -- and not to mention
  it to the user. The claude profile's `Stop` hook refuses once a turn that ends with
  the line missing or empty; not in a print run, `--serve`'s turns included; `--check`
  says it. `asb --list` and `--list-all` colour role names cyan on a terminal (not with
  `NO_COLOR`).
- **`asb --role R --summarize claude`: a stopped role's summary, from all its work**
  (#314): one headless turn of a new session in the role's sandbox, under its policy, as
  a `--serve` turn runs (`-p`, a fresh `--session-id`, `--permission-mode
  bypassPermissions`), reads the role's conversations, memory and files and writes its
  summary line and a description, `<store>/summary/description.md`: what the sessions
  worked on, what they found, what is left open, and the files they produced by their
  host paths. It prints both, then deletes the turn's own transcript, so `--continue`
  resumes the role's conversation and `--list` never sees the summarizer. One model
  call; refused while the role runs, when it has no conversation, and under `--preset
  native`. `asb --list` shows the description under the role's line, its first 5 non-blank lines and then `full description: PATH` when there is more; `asb --list-all` names it, `description: PATH`. Both print each project's line bold on a terminal (not with `NO_COLOR`).
- **A tools environment on every sandbox's PATH**: inside a sandbox `gh` was the host's
  `/usr/bin/gh`, and Ubuntu ships 2.46 even in its newest series, without `gh pr checks
  --json`. `install.sh` now builds a conda-forge environment with its own micromamba at
  `~/.local/share/agent-sandbox/tools` and rebuilds it at every run, so it stays
  current. Its packages are `~/.config/agent-sandbox/tools.txt`, one conda spec per line,
  and `gh` without that file. A sandbox binds it read-only with its `bin/` after the
  conda env and before the system directories, so a project's own `gh` still wins; only
  the listed packages' commands are on PATH, not their dependencies'. A failed rebuild
  warns and keeps the previous environment, and without one a sandbox is unchanged; it
  applies under every preset, `--preset native` included. `--uninstall` removes it.
- **A test policy per project in the roles model** (#301). Nothing told the roles which
  tests a round runs, so the Implementer and the Reviewer each ran the whole suite on
  every revision -- eight full GPU runs across four rounds that changed one plotting
  module. Iterating rounds now run only the affected tests, and the Reviewer runs the
  whole suite once, when it would accept with zero findings; the Supervisor's merge rule
  and CI are unchanged. The project supplies the two commands in `.asb/tests` (`iterate`,
  `final`), which `--init roles` writes empty and keeps once filled; left empty, a role
  runs what the Task says.
- **`--init` run again says which lines the model gained that an existing section
  lacks**. It never changes a section the file has, so a key a model added later -- the
  `start = .asb/start/gate.md` of `[briefing:gate]` -- was silently absent after an
  upgrade: the Gate launched with no first turn and showed `IDLE` until the user found
  the line and applied it by hand. A re-run now ends with one loud block, before "Next,
  yours:", that counts the missing lines and gives one `asb --apply '[SECTION]' LINE...`
  per section. A key is compared by name only (a value you changed is yours), a
  commented-out line counts as there, and only the model being initialised is checked.
- **A turn does not end without the role's watcher**. An Implementer ended a reply with
  its inbox watcher spent, re-armed by nothing, so the Supervisor's next message would
  have gone unnoticed. For a role whose `[serve:ROLE] watch` names its inbox, the engine
  hands the profile that path, and the claude profile's `Stop` hook refuses a turn that
  ends with no `inbox-wait` running under Claude Code -- once: not when the input's
  `stop_hook_active` is true -- telling the model the watcher on PATH is not running
  and to arm it in the background. Not in a print run, nor on a turn of `--serve`.
  `--check` says it for the role (a new optional profile hook, `profile_check_notes`).
- **A Task may start fresh: a served role's reset marker, and `/start` at a terminal**.
  Every wake re-reads a session's whole context, so a role carrying finished Tasks paid
  for them at each one. A file `.asb/coord/to/ROLE.reset` beside a served role's inbox
  makes the loop's next turn a new session -- a fresh id in `.asb/coord/ROLE/session`,
  the marker removed (a link removed, never followed), the old transcript left on disk,
  resumable by its id. The claude profile gives a role with a `[briefing] start` the
  text as a command, `/start` (`.claude/commands/start.md` in the briefing directory,
  added with `--add-dir`), so after `/clear` at its terminal `/start` re-arms it. The
  roles model's Supervisor asks you before each new Task whether the role starts it
  fresh, and resets a served role by the marker or asks you for `/clear` and `/start`;
  the Planner, Implementer and Reviewer write what the next session needs to their
  memory before they report a Task done.
- **A relaunched role runs a first turn without a keypress: `[briefing] start = PATH`**.
  After every role was launched, the Supervisor read them all as not running: a session
  relaunched with `claude --continue` sits at its prompt until something gives it a turn,
  so the purpose file's "at start, arm the watcher" never ran, no `alive` file was
  touched, and the user typed "hi" in each terminal. `start = PATH`, in `[briefing]` or
  `[briefing:<glob>]`, names a file in the project (`{role}` its name) whose text the
  session runs as its first turn at every interactive start; the profile hands it over
  (`profile_start_args`; claude: the prompt after its own arguments, behind a `--`, which
  `--continue` and `--resume ID` take as the first turn -- measured with Claude Code
  2.1.300 -- and a prompt you type wins). Not under `--serve`, `--exec`, a verb, `-p`,
  `--bg` or `[briefing] mode = off`. Read on the host at launch; a missing file refuses
  the launch; the review and `--check` name it. The roles model's `--init` writes one for
  the Planners, Implementers, Reviewers and the Supervisor, `.asb/start/<role>.md`, from
  the model's `start/`, kept as the purpose files are.
- **A role's status line shows which role it is and what it is doing** (#287). Six role
  terminals looked alike, the one that needed you included. The claude profile now sets
  Claude Code's `statusLine` in the `--settings` it builds: the role (the project's name
  for the default role) in bold, then `working` (yellow), `waiting` (green) or `needs
  you` (red, bold), in reverse video, redrawn every second. Hooks on `SessionStart`,
  `UserPromptSubmit`, `Stop`, `PermissionRequest`, `Notification` (a permission
  prompt, an elicitation, a question; not the idle reminder) and after any tool
  (`PostToolUse`, `PostToolUseFailure`) write the state to the
  sandbox's `/tmp`; your own hooks on those events run beside them, and a `statusLine`
  in your `--settings` wins. `[claude] state-background = on` also tints the terminal's
  background per state over Claude Code's own stdout, reset while it waits and at exit.
  Both come with the briefing, so not with `[briefing] mode = off`; and no hook fires
  on an Esc interrupt, so an interrupted turn shows `working` until the next event.
- **A session is told when its role's purpose file changed** since the role's previous
  launch. A relaunched role that resumed its conversation kept to the rules its earlier
  turns followed, though the `SessionStart` hook carried the new text, until told by hand
  to re-read it. The engine now keeps the purpose file's sha256 in the role's state
  directory (`purpose.sha256`, beside `record.tsv`; never in the project) and, when it
  differs, adds one sentence after the purpose text in the hook and in `briefing.md`'s
  "Your role": the text is the current one and replaces what earlier turns followed.
  Nothing on a first launch or when unchanged; `--verbose` names it on the host too.
- **A role with no terminal: `asb --role R --serve claude`** (#277). A host-side loop, in
  the foreground, that holds the role's launch open and runs one turn of the role's
  session per change to a file: the agent with the profile's turn arguments (claude:
  `-p`, the session named by id -- `--session-id` the first time, `--resume` after --
  and `--permission-mode bypassPermissions`: with nobody to answer a prompt, Claude
  Code's prompts are off and the role is bounded by its sandbox's policy alone) and a
  fixed prompt, joined into the launch like any other session. A new
  `[serve]` / `[serve:ROLE]` section says what to wait on and what to say, `watch =
  PATH` and `prompt = PATH`, both in the project; reviewed (as information), listed by
  `--check`, accepted by `--apply`. The session id goes to `.asb/coord/R/session`, which
  a later `--serve` resumes; a turn waits while a terminal is joined into the role; a
  turn that fails is one line in the role's `.asb/coord/R/messages.md`;
  `--status` shows the loop, and `--shutdown`, Ctrl-C or a TERM ends it with the launch.
  Refused without `--role`, under `--preset native`, and for a role with no section.
  The profile contract gains `[agent] serve-new` and `serve-resume`.
  In the roles model, `--init` writes `[serve:...]` for every Planner, Implementer and
  Reviewer (not the Supervisor, the Gate or setup), with the one-line prompt from the
  model's `serve/` as `.asb/serve/<instance>.md`; the Supervisor's launch lines name
  both forms, and how to open a terminal on a served role by its session id.
- **The roles model's Supervisor coordinates, and a Gate publishes** (#274). You stay in
  the Supervisor's terminal: it sends each role its next step in the role's inbox,
  `.asb/coord/to/<role>.md` (a directory only it may write), each message shown to you
  and written only on your approval, numbered `## N` per role; a role acknowledges
  `ack N` and reports `done N` in its messages, which the Supervisor watches. `--init`
  ships the watcher, `.asb/bin/inbox-wait FILE [SECS [ALIVE]]` (a one-second poll by
  path; ALIVE touched each poll, so a stale file says the role is not running), which
  a role arms with Claude Code's Monitor tool, the `[permissions]` that let it run
  without a prompt, and an empty inbox per role. The new Gate role (`G`) publishes --
  push, pull request, comment, issue -- exactly as an approved message names it, and
  nothing else: `main` and its history read-only, your gh login, `retrieve-only = off`,
  `git = allow`, `[ssh:gate]` with origin's host commented out. A template's
  `#@ inbox = PATH` line and a model's `bin/` directory are how a model says so.

- **`[permissions]` and `[permissions:<role-glob>]` in `.agent-sandbox`** (#274): agent
  permission rules a role gets without asking, one per line in the agent's own syntax --
  for claude, its settings' `permissions.allow` (`Bash(git push:*)`, `Read`) -- a union
  across the sections that match the role. The claude profile adds them to the
  `--settings` file the briefing passes, after a `--settings` of yours; with the
  briefing off they are not passed, and the launch says so. A widening: the review names
  each rule with its section, and `asb --check` lists the role's.

- **`asb --init MODEL --shared-env NAME`** (#268): a project whose roles run against an
  environment another project owns -- a test harness against a PyTorch development
  environment. Every role activates NAME read-only; nothing clones or builds it (the
  roles model drops its setup role, the Implementers' environment clones and the
  Supervisor's `write = 1`); the Implementers and the Supervisor get a copy-on-write layer
  over it; the source trees of its editable installs are declared read-only. Templates
  mark such lines `#@own` / `#@shared`, and `{editable}` names the sources. `asb --check`
  names an active environment's editable source a role cannot read, with the
  `asb --apply` line that declares it.

- **Models compose in one `.agent-sandbox`** (#267): a template's `#@ scope = roles` line
  makes its common block -- for `roles`, the `[sandbox]`, `[conda]`, `[connect]` and
  `[net]` every role gets -- written once per role pattern of the model
  (`[connect:planner-*]`, ..., `[connect:supervisor]`) instead of unsuffixed, where it
  reached every role of the file, a second model's included: `asb --init roles` in a
  checkout set up with `github` gave gh-review `retrieve-only` and hid its `.git`. Now
  `--init github` and `--init roles` share one file, in either order. `--init` refuses a
  model whose role patterns meet another's already in the file (the same, or one glob
  matching the other), naming both. **Breaking, pre-1.0**: a file the earlier
  `--init roles` wrote has that block unsuffixed, and `--init` refuses it until those
  blocks are removed (or the file started afresh); nothing is rewritten for you.
- **A setup role for `roles`** (#267): `asb --role setup claude` builds `main` into the
  `--env` environment, as `github`'s gh-setup does, so `--init roles --env NAME` takes a
  NAME not built yet; the Implementers' clones of it are made by `--init` run again
  after. The roles' `[conda]` line names the environment by its prefix now.
  docs/roles.md says what an Implementer's environment is: a clone of `{env}` whose
  editable install points at the parent checkout, so a compiled change needs a build in
  the clone.

- **Codecov reports per component** (`codecov.yml`): engine, proxy addon, Python
  components, claude profile, each its own number in the PR comment; every status is
  informational, so coverage movement never blocks a PR.
- **agent-sandbox's own micromamba**: conda inside a sandbox is the sandbox's concern, so
  a host needs no conda and a broken host install does not break a role. `install.sh`
  installs a pinned micromamba (2.9.0-0, checked against SHA-256 sums pinned per
  architecture and the release's own `.sha256`) at
  `~/.local/share/agent-sandbox/micromamba/bin/micromamba`, and an empty conda root at
  `~/.local/share/agent-sandbox/conda`; where the host has conda it asks once which one
  sandboxes use (`~/.config/agent-sandbox/conda`). **`[conda] base = host | sandbox`**
  (role-suffixable; `AGENT_SANDBOX_CONDA_BASE` wins) picks per project: under `sandbox`
  micromamba and the root are bound read-only, `MAMBA_ROOT_PREFIX` is the root, an env
  `name` resolves under its `envs/`, and nothing of the host's conda is bound. `--check`
  and the briefing name the command (`micromamba` or the host's `conda`); `--init --env
  NAME` makes the prefix under the base that applies. `--uninstall` asks before removing
  the conda root (`--yes` keeps it).
- **What a session hands you to run is one line or a file**: the CLI prefixes every line
  of a reply, so a heredoc, a patch or a commit message pasted from it breaks. The
  briefing says so, and names where the session's writable stores are on the host --
  `.asb/scratch/` under the role's state directory, a `copy-on-write` project's layer --
  so the message can give `git apply PATH` or `git commit -F PATH` with a path that works.
- **`[ssh]` and `[ssh:<role-glob>]` in `.agent-sandbox`**: SSH hosts for a project's
  sessions, per role, one per line in the forms `--ssh HOST` takes. Honoured only once
  approved; the review names each as a widening, and `--check` and the briefing name
  each host with its section. At a launch they join the `--ssh` hosts in one list
  through the broker (destination constraint, `known_hosts`, strict mode's pinholes);
  `--ssh-unrestricted`, `--ssh-key` and `--ssh-timeout` stay launch-only, and a role
  whose `[net] git` is `fetch` or `refuse` gets none of them. The github model writes
  `[ssh:gh-fix-*]` with `github.com` commented out and the line that turns it on,
  `asb --apply '[ssh:gh-fix-*]' github.com`, for ghstack; a ghstack fixer without SSH
  asks for exactly that.
- **A refused host reaches the session as it happens**: the proxy also appends each
  refusal of a session to that session's own `refused.log`, bound read-only at
  `/run/agent-sandbox/refused.log`, and the claude profile's hook after every Bash call
  reports a new one next to the command's result -- the host, that a mirror or another
  tool for the same thing is going on without it, and the `asb --apply` line to ask
  for. `blocked.log`, which records every session, is never bound in.
- **`asb --apply '[SECTION]' LINE...`**: adds the lines to that section of the project's
  `.agent-sandbox` -- creating the file or the section, leaving a line already there
  alone -- then runs `--trust`'s review of the result. Host only; it warns at a file's
  first role section. The briefing prints it, e.g. `asb --apply '[allow]' example.com`,
  where it asked the user to type lines into the file and re-run `asb --trust`.
- **A refused host, path or project is the user's call**: the briefing tells the session
  to stop and ask also when it could go on without it -- what it needs, what for, what it
  would do without it, and the lines to add (`[allow:ROLE]` under a role) -- and to
  continue without it only when the user says so. A session used to report the refusal
  and carry on with less.
- **`./install.sh --rebuild-bwrap`** builds Ubuntu's own bubblewrap 0.12.0-1 source
  package locally, checked against pinned SHA-256 sums, with the local version
  `0.12.0-1~<codename>1`, and installs it; `--dry-run` prints the plan and runs nothing.
  Ubuntu 26.04 is exposed to CVE-2026-87766 like 24.04: its resolute-security
  0.11.1-1ubuntu0.3 dropped the fix too. The installer's warning below 0.12.0 now names
  the route that applies: `sudo apt install bubblewrap` when apt has 0.12.0 or newer,
  this option on Ubuntu otherwise, `docs/troubleshooting.md` elsewhere.
- **The `market` model** and **`[net] hosts = public`**: `asb --init market --env NAME`
  in any directory, then `asb --role market-<topic> claude` -- research for a purchase
  or a tender (makers, shops, review and test sites, prices), reaching every public
  website by any method, POST included, through the proxy; localhost, the LAN and
  `[deny]` stay refused. Nothing of yours is in reach: `preset = isolated`, no `gh`,
  `git = refuse`, GPUs off. `hosts = public` is any role's to set. `--init` needs a git
  repository only for a model that clones the project; any other runs in any
  directory, a repository's subdirectory included, and `.asb/` keeps itself out of git
  with a `.gitignore` of its own (no longer a line in `.git/info/exclude`).
- **Roles** (#136): `asb --role NAME`, a persistent instance of a project under a policy
  of its own, selected by `[sandbox:<glob>]` and `[connect:<glob>]` sections. Each role's
  stores are its own; two roles share the project directory and nothing else unless
  connected.
- **One launch per role -- the keeper** (#121, #139): the first command starts the role's
  sandbox, and every later one joins it, with the same mounts, network and filter.
  Background sessions run inside the role (#123), and `--shutdown` ends it. The role
  verbs: `--status`, `--delete`, `--reset CHANNEL|PATH` (#126).
- **Path declarations** (#130, #106): a `[connect]` key with a `/` names a path, at any
  mode, including `copy-on-write` on a directory (#150) and `own` on a file that does not
  exist yet (#189). Declarations nest, bound by depth with channels (#196).
- **`seed-only`** (#131): seeded once, the role's own after that.
- **Storage scopes** (#105, #125, #147): `run-scoped` (one run of the role's launch) and
  `join-scoped` (one joined command, in a mount namespace of its own), for `own`, `copy`,
  `seed-only` (#153), `copy-on-write` as an overlay per join (#153) and `read-only`.
- **More channels**: `config` (Claude Code's config file, filtered to this project's
  entry, #119), `transcripts` and `logs` (#120; nothing is merged back at exit),
  `artefacts` (downloads, uploads, tasks, #154), `policy` and `changelog` (#109),
  `projects` and `memory` (#196).
- **Sources other than native**: `outside:<path>` (#174) and `sandbox:[PROJECT][@ROLE]`,
  another role's store (#200); `[share-memory] P` now reads P's role store.
- **`asb --check`** (#210-#213): the dot-file's review without the question or the
  record -- usable in CI or a pre-commit hook -- then, for a role, the policy, what
  crosses the boundary ordered by how it reaches a session (`context`, `searched`,
  `pointed`, or `UNMEASURED`), what in `~/.claude` no channel, `hide` or `visible` line
  classifies (#82), lines with no effect, and the mount plan.
- **The dot-file review is part of the launch** (#143): a new, changed or missing file is
  shown (a changed one as a diff) and asked about at a terminal, and refused without one.
  The file is read-only inside the sandbox.
- **The claude profile as data** (#173): `[agent]` (base, base-env, hide, verbs),
  `[env]`, `[allow]`, `[channel:<name>]` sections and `[preset:<name>]` rungs in its
  dot-file, with `{base}`, `{slug}`, `{slug:PATH}` and `{profile}`; Claude Code's file
  formats in `profiles/claude/profile.py`.
- `~/.local/bin` may be declared read-only (#168).
- **The host's GPUs are in the sandbox** by default: their device nodes and `/sys`
  read-only, for CUDA, ROCm and the driver's tools; `[gpu] mode = off` (per role with
  `[gpu:<role>]`, or `AGENT_SANDBOX_GPU=off`) keeps them out, and `asb --init MODEL
  --disable-gpu` writes that for a model's roles.
- **The `github` model**: `asb --init github --env NAME` appends, once, sections for
  `gh-review-<N>`, `gh-triage-<N>` and `gh-fix-<N>` -- a reviewer, a triager and a fixer
  per pull request or issue, each seeing your built checkout and environment through a
  layer of its own. Review and triage never push; the fixer publishes over HTTPS with
  your gh login, or with ghstack; every post is on your word, after the project's AI policy.
- **`gh-setup` in the `github` model**: one per project, it builds `main` as checked out
  into the `--env` environment from the project's CI and documentation, records why in
  `.asb/setup.md` and how in `.asb/build_env.sh` -- `setup` for the full build,
  `rebuild` for the incremental one the other `gh-*` roles run -- and those roles layer
  over that build. A model's `#@ setup = ROLE` marker lets `asb --init MODEL --env NAME`
  take an environment not built yet: its prefix is made empty, and ROLE builds it.
  gh-setup asks you for a dependency it cannot retrieve (built from git, or from a
  refused host): a clone under `~/git/<org>/<repo>`, `copy-on-write` to the `gh-*`
  roles, installed into the environment.
- **gh-review's briefing** says it once: what is on record for the PR is linked, not
  restated; a reply answers its question; what the draft leaves out is listed for the
  user to opt in; a one-line reply the user takes as their own carries no footer where
  the project's policy allows. It files a new issue for a problem the review finds beyond
  the PR, on your word: it looks for it on record first, shows you the draft, and runs
  `gh issue create` when told.
- **gh-triage files a new issue for a problem the triage finds beyond the issue**, on
  your word, as gh-review does: it lists such findings with the triage, looks for each
  on record first, shows you the draft, and runs `gh issue create` when told. Labels,
  assignees and mentions only when you name them.
- **`[net] git = fetch`**: git fetches over HTTPS, a push and `--ssh` are refused.
- **`project = copy-on-write`**: an overlay at the project's own path, the role's writes in
  its own layer, kept until `asb --delete`.
- **`asb --init MODEL [ROLE=N ...] [--env NAME]`** (#225) and `models/roles/`: a project's
  `.agent-sandbox`, `.asb/`, a purpose file per role instance, the coord index, and a
  clone per Implementer (its tree under `.asb/impl/N/`, its history under `.asb/git/N/`)
  written from a development model; run again with more instances, it adds what is
  missing, and a purpose file it wrote that you have not changed since takes the
  model's current text (one you changed is kept). It approves nothing.
- **`--check` says where a role can act as you** (#226): per outside service -- your
  agent's API, GitHub, SSH, forwarded credentials -- whether the role holds a credential
  there, and what its `[net]` lines leave it able to do with it.
- **`[net] git = refuse`** (#224), per role: git's smart-HTTP transport refused to every
  host (pages still load), and `--ssh` refused for the role.
- **`[net] retrieve-only = on`** (#223), per role with `[net:<role>]`: every request but
  GET and HEAD is refused, but to the profile's own hosts -- a session that reads and
  publishes nothing. A GraphQL query to `api.github.com` passes, a mutation does not.
- **A role's purpose** (#222): `[briefing:<glob>]` briefs those roles from a purpose file
  (`.asb/roles/{role}.md`, or `file =`), injected after the engine's own lines at every
  session start, read-only inside, and part of the approval -- an edit to it re-opens the
  review.
- **More role-suffixed sections** (#221): `[allow:<role>]`, `[env:<role>]`, `[conda:<role>]`
  and `[net:<role>]`, as `[connect:<role>]` -- a key overrides the unsuffixed one, a list
  adds to it. **`[deny]`**, also per role, takes hosts out of the global allowlist and the
  session's grant, never the profile's own. **`[conda] prefix = PATH`** activates an env by
  its path, such as a clone in a role's tree.
- **`project = read-only`** (#220): the working tree read-only for a role, with a
  read-write declaration inside it for the part it may change; `--check` shows the
  project's mode.
- The sandbox-owned conda package cache is bound whenever a conda env is active, not only
  in write mode (#219): an env written by path, `conda install -p`, keeps its downloads
  across launches.
- Coverage now measures the Python components: `components/join.py` and
  `components/connect-sync.py`, reported at 0%, are measured by coverage.py where they
  run -- in the engine's joins and copy syncs, and in their unit tests -- through
  `AGENT_SANDBOX_TEST_PYTHON`, and uploaded to Codecov with the engine's and the addon's.

### Changed

- **install.sh builds the proxy's environment with its own micromamba**, from
  conda-forge, as it builds the tools env, and no longer with the host's conda or a venv
  from the host's python: a host needs neither conda nor `python3-venv`. Found at #335's
  live step: an install as a dedicated account with no conda on its PATH and a system
  python 3.12 without `ensurepip` stopped at the proxy with `no way to run mitmproxy`.
  The micromamba is now fetched before the proxy step. A working `proxy-env` or
  `proxy-venv` an earlier run made is kept; a broken one is recreated, now with
  micromamba, and a create that fails stops the install with micromamba's last line and
  its log.
- **The github model's fixer pushes over HTTPS, as you, with your gh login; SSH is for
  ghstack.** The model's file already gave fixers `[net:gh-fix-*] git = allow` and
  `[connect:gh-*] gh = read-only`, so a fixer could push over HTTPS with no opt-in, yet
  its purpose file said to push over SSH or stop and ask for `[ssh:gh-fix-*]`: some
  fixers pushed over HTTPS, others stopped. `gh-fix` now pushes to the HTTPS URL of the
  remote the fork rule picks, whatever its scheme, with `gh auth git-credential` as
  git's credential helper, and says once when that remote is SSH. `[ssh:gh-fix-*]
  github.com` stays a reviewed opt-in, for ghstack, which pushes through `origin` as it
  is. Measured 2026-10-25 on a private scratch repository: with `git = allow` and the
  gh login, an HTTPS push from inside the sandbox created the branch (no SSH agent
  inside); with `git = fetch` the proxy refused it, HTTP 403.
- **gh-setup ends with a readiness check, recorded under `## Readiness` in
  `.asb/setup.md`**, which gh-review, gh-triage and gh-fix read at start: a current `gh`
  (`gh pr checks --json`; else re-run `install.sh` on the host), the user's gh login,
  the fixers' push path (fork or direct, the HTTPS URL; for a ghstack project the two
  `--apply` lines), and, when the build used CUDA, the missing `/dev/nvidia-uvm` after a
  host reboot (`nvidia-smi` lists the GPUs, CUDA says "unknown error"; on the host
  `nvidia-modprobe -u -c 0`, then the role's restart). It fixes what is in its reach and
  names the host-side command for the rest, so an issue is found before a role trips on
  it.
- **A gh-review, gh-triage or gh-fix instance re-syncs its layer when `main` moved under
  it; nothing is deleted or reset after a pull.** The github model's docs said to delete
  or reset every live instance after `main` moved on the host, since their
  copy-on-write layers lie over the old tree: impractical with many instances. Measured
  2026-10-25 on a scratch repository: a fixer's next launch after `main` moved had its
  branch checked out with its commit, `main` at the host's new commit, and the host's
  changes showing through as changes it did not make; `git reset --hard` to the branch,
  removing the untracked files `main` tracks, and a rebase put its commit on the new
  `main`. The three purpose files now say so in step 1: a fixer rebases its branch, a
  reviewer without one re-applies the PR's diff on `main`, a triager resets to `main`,
  and each rebuilds. The rebase is `git rebase --fork-point main`: when the host
  rewrote `main`'s history, a plain `git rebase main` replayed the rewritten-away commit
  too and conflicted, while `--fork-point` (the host's reflog of `main` shows through)
  replayed only the fixer's commit. Such a branch keeps its old base only as long as the
  host's reflog does (30 days by default, `gc.reflogExpireUnreachable`; an expired
  reflog plus `git gc --prune=now` broke one), so an unpublished fixer is launched or
  published within that window. An instance running while `main` moves -- including
  one that exited within its keeper's two-second grace -- is shut down first
  (`asb --role R --shutdown claude`): a lower tree changing under a mounted overlay is
  undefined, and a session joined in the grace kept seeing the old `main`. The four
  purpose files (gh-setup's too) also say once that `main` is the project's default
  branch, `master` where that is its name.
- **The status line's `ASKS YOU` and `NEEDS YOU` are blue, and `ASKS YOU` looks at the
  reply's last three lines** (the red bar was found ugly; and a Supervisor that asked
  for the user's yes in prose above a quoted message ending "Report done 22." showed no
  question). `needs you` stays bold; with `[claude] state-background = on` both tint
  `#202840` instead of `#402020`. The question may end any of the last three lines,
  not counting blank lines, quotes (`>`, `▎`) and fenced code. The roles model's
  purpose files make the question the last line: the Supervisor ends the reply that
  shows a message with `Send it?`, and every other role's file says "When you stop for
  the user's word, your last line is the question."
- **The status line says `RUNNING` when a background command of the role's own is still
  going; `WAITING` is the watcher alone** (a Reviewer whose CUDA suite ran in the
  background, beside its inbox watcher, ended a turn and its bar read `WAITING`, as if
  it waited for the Supervisor, while it was at work and would wake when the suite
  ended). After a reply, and after `ASKS YOU`, the state is `running` (yellow, as
  `working`) when the `Stop` input's `background_tasks` holds a task whose command does
  not name `inbox-wait` -- or, without that field, Claude Code runs a Bash tool wrapper
  other than the watcher's; then `waiting`, then `idle`. With `[claude]
  state-background = on`, `running` tints like `working`.
- **The roles model's Gate watches its inbox like every other role, and the Supervisor
  watches the Gate's messages**. In a live roles project the Gate's status bar read
  `IDLE` at start and stayed so after it had pushed: it had no watcher, its terminal
  being opened only on its turn. And the Supervisor never heard the Gate's reports: its
  watcher ran over every role's messages "but the Gate and yourself", so
  `.asb/coord/gate/messages.md` was not watched. The Gate now arms `inbox-wait` at start
  and after each wake, its terminal stays open, and `--init` writes it a `[briefing]
  start` file and a `[serve:gate]` with `watch` alone, so the Stop hook keeps its
  watcher armed; the Supervisor's watcher includes the Gate's messages, and a stale
  `alive` gets the Gate's launch line as any role's. The role with the outward
  credentials is now always running. The engine takes a `[serve:ROLE]` with `watch`
  alone as a watch only: the review and `--check` say so, and `--serve` refuses the
  role ("its [serve] names no prompt"); `prompt` is required for `--serve` only. (And
  a turn cut short -- an Implementer's ended with "API Error: Connection lost
  mid-response", then "I'll carry on unless you want something else", and its Task sat
  idle until the user typed "carry on" -- is now resumed at the next wake or prompt
  without asking: the Planner's, Implementer's, Reviewer's and Gate's purpose files say
  so.)
- **The roles model's closing line comes with the `done N` write, never before**. An
  Implementer ended a reply with "done; in my file; S has it" while its suite still ran
  and its Handoff was unwritten, so nothing had reached the Supervisor. The Planner's,
  Implementer's, Reviewer's and Gate's purpose files now say the line once, in the reply
  that appends `done N`, and a reply with work pending ends by naming what is pending
  and what follows.
- **The roles model's Reviewer puts what another role must run in its Review
  directory** -- a probe, a reproduction, a measurement script -- named in the Review,
  never in its scratch, which no other role can read; the Implementer runs it from
  `.asb/review/<reviewer>/` instead of rewriting it from its description. (A Reviewer
  asked the Implementer to run a probe from its private `.asb/scratch/`; the Implementer
  could not read it and rewrote it from the Review, and the Reviewer then asked for its
  own to be run as well.)
- **`[ssh]` stands alone from `[net] git`** (#293). `git = fetch` and `git = refuse`
  no longer refuse `--ssh` or drop the file's `[ssh]` hosts: they govern git over
  HTTPS, what the proxy can see, and `[ssh]` governs hosts, which the broker enforces.
  This widens: a role under `git = fetch` (or `retrieve-only`) with an `[ssh]` host now
  reaches it, and can push over SSH to a remote there where the account allows. The
  `--trust` review, `--check` and the briefing say so per host; `--check`'s `git
  transport` lines drop ", and --ssh", and the briefing's "this role's [net] git closes
  SSH" is gone. What the key may do on a host is the remote's rule: `authorized_keys`
  (a forced command, `restrict`) or an account without push rights
  ([ssh.md](docs/ssh.md#what-the-key-may-do-on-a-host)).
- **The status line is a bar across the terminal, and tells "asks you" from "waiting"**
  (#287). A Supervisor that had asked "Send it?" and a Reviewer idle with its watcher
  armed both showed `waiting`, and the one-word tag was easy to miss across six
  terminals. After a reply the state is now `ASKS YOU` (red) when the reply's last line
  ends with a question, `WAITING` (green) when a watcher runs in the session -- a
  process named `inbox-wait` -- and `IDLE` (grey) otherwise; a session that starts
  with no watcher is `IDLE`. The line is one row in reverse video of the state's
  colour, the role in bold and the state in capitals, padded to the terminal's width
  (Claude Code shows `COLUMNS` less 4 of it). With `[claude] state-background = on`,
  `asks you` tints like `needs you`, and `idle` resets like `waiting`.
- **The roles model's Supervisor watches `.agent-sandbox`**. A change made with
  `asb --apply` while the roles ran reached none of them -- a running role keeps the
  policy its launch started with -- and nobody told them or the user. The Supervisor's
  watcher now names `.agent-sandbox` first; on a change it reads which sections changed
  (`[x:ROLE]` one role, a pattern every role it matches, an unsuffixed section all),
  tells each affected role to finish its step, record its state and say ready, and gives
  the user the relaunch, one line per role: exit the session (`asb --role R --shutdown`
  for a served one), then the launch line with `--continue`. The new policy applies only
  to a launch that starts fresh, not to a join of one still running.
- **The roles model's watchers are background waits, not Monitors** (#288): every role
  runs `.asb/bin/inbox-wait` with the Bash tool in the background and runs it again after
  each wake, so nothing expires -- a Supervisor with a Monitor per role got three expiry
  notices and three re-arms every 30 minutes; an interactive session puts no time limit
  on a background command (measured with Claude Code 2.1.300: 13.6 minutes idle with no
  notice, the reply 5 s after the write). `inbox-wait [-t SECS] [-a ALIVE] FILE...` takes
  several files and prints the one that changed, so the Supervisor runs one over every
  role's `messages.md`; the old `FILE [SECS [ALIVE]]` form is refused. `Bash(tail:*)`
  leaves the roles' `[permissions]`: no purpose file runs `tail` any more.
- **The roles model's Planner and Supervisor are told when a Task is done and when a
  merge may be proposed**: the Reviewer accepted the Handoff, the Implementer resolved
  every finding, the Planner confirmed the step, the user accepted; not at the Planner's
  own ruling, and not bundled with a message still waiting for its answer; and the
  Supervisor re-runs the suite after a merge only when `main` moved since the branch's
  base, watches CI after the Gate's push without holding the round, and the Gate
  reports the run's URL and stops (seen on a live project: a Planner declared a step
  ready for merge while the review was in progress, and a Supervisor proposed the merge
  before the Planner's confirmation and the user's acceptance).
- **`retrieve-only` admits git's fetch where `[net] git` permits one** (#280): the
  `git-upload-pack` advertisement and endpoint pass under `git = fetch` or `git = allow`,
  so a retrieve-only role can `git clone`, `git fetch` and `pip install git+https://...`;
  `git-receive-pack` stays refused whatever `git` says, and `git = refuse` refuses both
  as before. This widens what `retrieve-only` lets through, on purpose: a fetch reads, as
  a GraphQL query does. The roles model keeps `git = refuse` in its common block; a role
  that needs a repository gets `asb --apply '[net:ROLE]' 'git = fetch'` instead of
  `retrieve-only = off`.
- **The roles model's Supervisor publishes nothing** (#274): its `[net:supervisor]` and
  `[ssh:supervisor]` sections are gone, so it runs under the common block's
  `retrieve-only = on` and `git = refuse` like every other role; it still merges into
  `main` and builds there. Publishing is the Gate's, and `[ssh:supervisor]`'s opt-in is
  `[ssh:gate]`'s. A file an earlier `--init` wrote keeps its sections: remove its
  `[net:supervisor]` sections and `[ssh:supervisor]`, and run `--init` again, which
  writes the common block's `[net:supervisor]`, the inboxes and the Gate's sections;
  the Supervisor's inbox directory is then
  `asb --apply '[connect:supervisor]' '.asb/coord/to/ = read-write'`.

### Fixed

- **A strict sandbox keeps the host's name on a 2026 passt.** passt as of git20260120
  (Ubuntu 26.04) names the namespace it makes `pasta-<host>` unless told otherwise, so
  `hostname` inside said `pasta-ey`, and a tool there that records the host's name
  recorded that; the 2024 passt (24.04) left the name alone. The engine now passes
  `--hostname` with the host's name to a pasta whose `--help` lists the option
  (measured 2026-11-01 on both; found at #335's live step).
- **A tool's own telemetry stopped a session** (#304): gh sends usage telemetry to
  `cafe.github.com`, which the proxy refused, and the refusal hook reported it beside an
  ordinary `gh` call that had succeeded; the session stopped to ask for the host. The
  engine now keeps a table of the tools env's telemetry: gh's host joins the agent's own
  in `telemetry-hosts`, so the hook leaves it out of its note, and every sandbox but
  `--preset native` gets `GH_TELEMETRY=false` and `DO_NOT_TRACK=1`, so gh does not send
  it; under `native` an opt-out is your state, so the values are your shell's, and the
  host is still refused. `--check` says so in one line; an `[allow]` line and a
  forwarded `GH_TELEMETRY` opt in. And the hook now
  reports refusals only after a command that failed: on `PostToolUse` it counts them as
  seen and says nothing, for every reason. They are still in `refused.log` and
  `blocked.log`.
- **A file a session named for you to read was named by its inside path** (#311): "the
  draft is ready in .asb/scratch/x.md", a path you cannot open on the host. The briefing
  now says a file named to the user is named by its host path, from the list of where
  the session's stores are on the host, and the short form at session start says so too.
- **A running role whose proxy CA the host had taken away failed every HTTPS request
  without a word**. The CA is a single-file bind over
  `/etc/ssl/certs/ca-certificates.crt`, and a `ca-certificates` upgrade (unattended, at
  06:00) replaced the host's file by a rename, which detached the bind in the role's
  long-lived keeper: no mount at that path in its `mountinfo`, the host's new bundle
  showing through, and `x509: certificate signed by unknown authority` for everything
  until the role was restarted. Each join into a running role, and `--status`, now
  check the keeper's bind and say so, loud, naming the fix
  (`asb --role R --shutdown claude`); the join goes on. A bind still there over a host
  bundle that changed since the launch is a one-line note, since HTTPS works. Silent
  outside the proxy modes. See [network.md](docs/network.md#the-proxy-ca).
- **The refusal of a join that would change a running role's policy names
  `--shutdown`**: "exit what is joined into it (or `asb --role R --shutdown claude` from
  any terminal, when its own is out of reach), then launch again" -- a role joined from a
  terminal that is gone, or from `--serve`, has nothing to exit by hand. **So does every
  message whose change reaches a running role only at its next keeper**: a role asked for
  a host, the user ran `asb --apply '[allow:R]' HOST` and relaunched, but a morning session
  of the role in another terminal was still joined, so the relaunch joined the old keeper
  under the old policy, and the role went on being refused and recommending the same
  `--apply`. The join's "`.agent-sandbox` has changed" line now counts the other sessions
  still joined and ends "To apply it now, end the role from any terminal:
  `asb --role R --shutdown claude`, then launch it again."; the briefing's "ask them to
  relaunch" and its SSH line, the refusal hook's note on an allowlist refusal (from a new
  `restart` file beside the briefing, checked against the engine's shape), and the Gate's
  and `gh-fix`'s purpose files name that restart instead of "a relaunch".
- **An SSH host whose config says `IdentitiesOnly yes` refused the broker's key**: a
  `~/.ssh/config` stanza with `IdentityFile ~/.ssh/tob_ex` and `IdentitiesOnly yes`, the
  host named under `[ssh:implementer-1]`; the engine loaded `~/.ssh/tob_ex` into the
  session agent, and inside the sandbox `ssh tob-ex true` failed with "no such
  identity: ... No such file or directory" and "Permission denied (publickey)" (OpenSSH
  10.2, Ubuntu 26.04). Only `config` and `known_hosts` were bound, so ssh could read
  neither the key nor its `.pub`, offered only the identities the config names, and
  never matched the agent's. The public half, `KEY.pub`, of each key the broker loads is
  now bound read-only at its path (never the private file); a key without one is said
  with `--verbose`. Measured against a local sshd inside the sandbox: "Will attempt key:
  .../k explicit" then "no such identity" before, "explicit agent" and "Authenticated"
  after.

- **mamba did not trust the proxy's CA**: mamba 2.x and micromamba (libmamba) read
  neither `SSL_CERT_FILE` nor `CONDA_SSL_VERIFY`, the variables the engine points at the
  bundle with the proxy CA, so under `proxy` and `strict` they failed TLS on every
  download -- measured by an Implementer role on Ubuntu 26.04, where setting
  `MAMBA_SSL_VERIFY` to the sandbox's bundle made mamba work. That includes the
  engine's own micromamba (`[conda] base = sandbox`). `MAMBA_SSL_VERIFY` is now set
  beside `CONDA_SSL_VERIFY`, and forwarded when you set it yourself.

- **A relative `[conda] pkgs` path landed in the wrong place**: `pkgs =
  .asb/scratch/conda-pkgs` was taken as written, so the engine created and bound it
  relative to its own working directory and `CONDA_PKGS_DIRS` carried the relative
  path, which conda resolved against *its* working directory -- from an Implementer's
  clone, `.asb/scratch/.asb/scratch/conda-pkgs`. A relative `pkgs` is now the
  project's, as a `prefix` already was, and the bind and `CONDA_PKGS_DIRS` carry the
  absolute path; so is a relative `AGENT_SANDBOX_CONDA_PKGS`.

- **The agent's own telemetry was reported as a blocked action** (#276): Claude Code
  flushes telemetry on its own schedule, and a flush inside a Bash call was refused (as
  it should be) and reported by the refusal hook next to the result, with an `--apply`
  line inviting the user to allow it; in a headless loop every reply ended with a
  sentence about the refused Datadog intake. The profile now names its agent's telemetry
  hosts (`profile_telemetry_hosts`: `.datadoghq.com` and `browser-intake-us5-datadoghq.com`,
  from Claude Code's network requirements), the engine writes them beside the briefing,
  and the hook leaves a refusal of one out of its note. It is still refused and still in
  `refused.log`; `--check` says so in one line, and the briefing in one sentence.

- **A role's Write and Edit tools could not write its message file** in the `roles`
  model: the file was bound read-write inside the read-only `.asb/coord/`, and Claude
  Code's Write and Edit write a temp file beside the target (`NAME.tmp.PID.HEX`) and
  rename it over the target, so the temp file failed with "read-only file system"; only a
  shell redirect could write it (measured with Claude Code 2.1.300). Each role's
  messages now live in a directory of its own, `.asb/coord/<role>/messages.md`, bound
  read-write inside the read-only `.asb/coord/`, where Write and Edit work and the other
  roles' directories stay read-only. The coord index is `--init`'s alone: it writes it
  and adds a row per new instance, so the Supervisor no longer declares it read-write.

- **The briefing said `$HOME` is "a fresh tmpfs"**, which reads as writable; it is
  remounted read-only, so a tool that writes under `~` (Triton's `~/.triton`) failed and
  a role took it for a policy question. The briefing now says `$HOME` is read-only, that
  `~/.cache` (session-private) and `/tmp` are writable, and to point such a tool there,
  or at the role's scratch, with its variable in the role's own shell; the session-start
  summary says it in one clause.

- **SSH failed inside every sandbox on Ubuntu 26.04**: OpenSSH 10.2 refuses an
  included config file owned by neither root nor you, and in the sandbox's user
  namespace root's `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` belongs to
  "nobody", so every `ssh` exited 255 before connecting, `[ssh]` or `--ssh` granted.
  A launch with SSH now binds each `/etc/ssh/ssh_config.d/*` as a copy owned by you,
  made fresh in the session directory (at a symlink's target: bubblewrap 0.12 refuses a
  mount on a symlink). Verified on Ubuntu 26.04: `ssh -T git@github.com` authenticates.
- **A role without SSH could not say how to get it**: the briefing's SSH line said
  "none", and its `--apply` examples covered `[allow]` and `[connect]` only, so a
  Supervisor whose push to an SSH `origin` failed offered to hand the push to the user
  instead. The SSH line now names the exact command for the role --
  `asb --apply '[ssh:ROLE]' HOST`, with the host of `origin` when it is an SSH remote --
  or says the role's `[net] git` closes SSH. The roles model writes `[ssh:supervisor]`
  with the host commented out, and the Supervisor's purpose file says to ask for that
  line rather than switch the remote or hand the push over.
- **The github model's fixer no longer gets `~/.ghstackrc` in every project**: the file
  carries a GitHub token, and only a project that uses ghstack needs it. The line is
  written commented out; `asb --apply '[connect:gh-fix-*]' '~/.ghstackrc = read-only'`
  turns it on for one project.
- **The role verbs need no command** when one profile is installed:
  `asb --role R --reset config` (and `--status`, `--shutdown`, `--delete`) used to stop
  at "no command. Name the agent to run"; with several profiles the refusal names the
  verb. `--reset` says what comes back per store -- an `own` store "starts from the
  profile's template", a copy "taken from yours again" -- where it said "from your own
  copy" for all of them.
- **An `isolated` role asked for a login** on Claude Code 2.1.285: its own config
  started from `{}`, and that version's first-run onboarding asks for a login method
  although the credentials are valid. An `own` config now starts from
  `{"hasCompletedOnboarding": true}`.
- Two cross-project leaks, each with a regression test written first (#111).
- Three paths every project's sandbox could read: `image-cache/` is blanked every
  launch (#77), `usage-data/` goes with the role's transcripts (#79), and
  `agent-memory/` is a channel at memory's rungs (#74).
- bwrap runs with no environment of its own, and its options reach it through a file,
  not its command line, so neither is readable from inside (#170, #171).
- The overlay check could misread a racing `bwrap --help` as "no overlay", and a
  copy-on-write channel then read a fresh copy (#203).
- `--preset native` with an active conda env under a symlinked `$HOME` path (#205).
- A joined command keeps the terminal where the kernel blocks TIOCSTI (#166), and its exit
  status is right on Python older than 3.9 (#164).
- **No conda inside when no env was active in the launching shell**: a dot-file `[conda]`
  env that is not there yet -- a role's empty `prefix`, for `gh-setup` to create -- got
  no conda at all from a shell with `MAMBA_ROOT_PREFIX` set and nothing activated, and
  the prefix was "ignoring"-ed. The conda base is now bound read-only whenever the file
  names an env or prefix, active env or not, with its config, the package cache and
  `<base>/condabin` on PATH, so the env can be created; a host with no conda base is
  said. The briefing also shows that `asb --apply` takes any section, e.g.
  `asb --apply '[connect]' '~/data/ = read-only'`, where it showed `[allow]` only.
- **`--trust` offered to git-ignore a tracked `.agent-sandbox`**: it asked whether the
  file was ignored, not whether it was tracked, and an exclude line does nothing for a
  tracked file. A repository that ships its policy now gets no offer; the file is still
  approved on every machine.

## 0.3.0 — 2026-09-21

### Added

- `install.sh` warns when bubblewrap is older than 0.12.0. That release fixes
  CVE-2026-87766, a sandbox escape during setup: a symlink in a directory the
  sandboxed process controls could redirect the files and directories bwrap
  creates as mount points onto the host, and this sandbox creates mount points
  inside the agent's writable state directory. Ubuntu 24.04 ships 0.9.0, and
  its noble-security update 0.9.0-1ubuntu0.3 dropped Canonical's backport of
  the fix again. `docs/troubleshooting.md` gains the recipe for a no-change
  rebuild of Ubuntu's own 0.12.0 source on 24.04, with pinned checksums;
  measured on such a host, the engine's integration suite passes unchanged and
  overlay mounts work inside bubblewrap's user namespace.

- **Connections**: what of your native Claude Code install reaches a project's
  sandbox, per channel, under a mode from the scale
  `own < copy < copy-on-write < read-only < read-write`. A **channel** is named
  by what it carries (`instructions`, `settings`, `skills`, `agents`,
  `workflows`, `plugins`); a **mode** says how much of the source reaches the
  sandbox; the only **source** so far is `native`, your own `~/.claude`. The
  order is how much of *your* files reach the sandbox, not what the sandbox may
  do: it can write under `copy-on-write` but not under `read-only`, and
  `read-only` is still the higher rung, because it hands over the real file
  where `copy-on-write` gives only a shadow of one. Set with `[connect]` in an
  approved `.agent-sandbox`, `--connect 'channel=mode [source]'`, or
  `AGENT_SANDBOX_CONNECT` (`;`-separated), in that precedence. A channel name
  the profile does not carry refuses the launch rather than being ignored,
  because a typo that quietly left a channel open would read to you as a
  channel you had closed. `--reset-connection CHANNEL` throws the sandbox's copy
  away and re-seeds it from your files, which is the supported way back.
- **`copy` and `copy-on-write`**, the two modes that let a sandbox read your
  files without writing back. `copy` seeds from the source and refreshes
  anything the sandbox has not touched, comparing source, copy and a manifest of
  what the source held at the last sync; nothing is ever merged textually and
  nothing is ever written back, and when both sides changed a file the sandbox
  keeps its own and the launch says which file, at every launch until a reset.
  `copy-on-write` layers an overlay instead, so reads fall through until the
  sandbox writes. Where an overlay is unavailable — bubblewrap older than 0.11,
  `[overlay] mode = off`, or a channel path naming a single **file**, which
  overlayfs cannot stack on — it behaves as `copy`, and the launch says so. The
  two differ only *within* a running session. `[overlay] mode = auto|off`,
  `--overlay` and `AGENT_SANDBOX_OVERLAY` choose the implementation, never
  whether a channel is shared.
- **The holder**: one bubblewrap process per sandbox that mounts every overlay
  the sandbox could need and then sleeps, which each session joins. Without it,
  two sessions of one sandbox were two independent overlay mounts over one upper
  directory — an arrangement overlayfs documents as undefined. They now report
  the same superblock. No behavioural test can see this: both arrangements let
  each session read the other's writes, so only the superblock tells them apart,
  and it is asserted in `tests/integration/connect-holder.bats`. Where the
  holder cannot run (no `nsenter`, no `flock`, or the `strict` network mode) the
  per-session overlay remains, with the concurrency warning it always had.
- **Presets**: one position for every channel at once. `isolated` gives the
  sandbox nothing of your install; `inherit` lets it read your instructions,
  settings, skills, agents, workflows and plugins live while keeping its own
  writes to itself; `shared` is one directory in both directions. Set with
  `[sandbox] preset`, `--preset` or `AGENT_SANDBOX_PRESET`; a `[connect]` line
  overrides the preset for its own channel and nothing else, which is the whole
  vocabulary. An unknown name is refused rather than defaulted, because a preset
  positions everything at once and guessing is the one thing it must never do. A
  preset moves only the channels the engine manages as connections; memory,
  transcripts, the configuration file and the rest keep their own controls until
  they are folded in, and `docs/config.md` carries the full twelve-row table
  naming what governs each row today.
- **`--preset native`**, whose contract is an equality: it must behave
  identically to `--sandbox none` while still going through bubblewrap, the
  network mode and the syscall filter, so a difference between the two is a bug
  in agent-sandbox. It is a test instrument rather than a way to run — state
  isolation is off, including the host's own `$HOME`, `/tmp` and the full
  environment — and it is accepted as the `--preset` flag only, never from the
  environment or a project file, with a notice on every launch that `--quiet`
  does not suppress. `tests/integration/native-parity.bats` runs the same agent
  both ways and diffs the whole report; writing it found four divergences that
  nothing else had, none of which failed anything at the time.

### Changed

- **A sandboxed session's writes to your instructions, settings, skills,
  agents, workflows and plugins no longer reach your own files.** The engine
  now starts every one of those channels at `copy-on-write` (the `inherit`
  preset) instead of binding the state directory through. A session still reads
  your files live; what it writes stays in the sandbox, so a model choice or a
  permission save made inside no longer edits your own settings. This is the
  behaviour change in this release. `preset = shared`, in any of its three
  forms, restores exactly what 0.2.1 did.

## 0.2.1 — 2026-09-18

### Added

- **`user-mcp`**: whether the host's user-level MCP servers (the `mcpServers`
  block of `~/.claude.json`) reach a project's sandbox. `inherit`, the default,
  carries them into the project's copy of the config file and refreshes them
  at every launch; `none` leaves them out, closing the one MCP channel that
  copy keeps open (a server configured natively is otherwise live in every
  project's sandbox, and a stdio server is a command that runs at session
  start). Set with `--user-mcp`, `AGENT_SANDBOX_CLAUDE_USER_MCP` or
  `[claude] user-mcp` in an approved dot-file, in that precedence. A launch that
  asks for `none` without a working `python3` is refused rather than run with
  the block in.
- The engine has a **wrapper role** (`--wrap`), the mechanism for opt-in
  sandboxing of background `claude` workers (issue #45). Invoked as Claude
  Code's `CLAUDE_CODE_PROCESS_WRAPPER`, it runs the discovered native binary
  (discarding the launcher path Claude passes) and switches on the spawned
  process's own argv: the supervisor (`daemon run`) and the PTY provider
  (`--bg-pty-host`) pass through to the host — trusted infra that must stay
  host-side to spawn, and themselves wrap, their children — while the pooled
  worker (`--bg-spare`, and any unknown verb, fail-safe) is sandboxed, with only
  the rendezvous-socket directories named in its argv bound in. Not yet wired to
  a knob: the opt-in delivery, the host e2e confirming the pty-host/spare split,
  and CI via an extended `fake-claude.sh` are the remaining pieces of #45.

### Changed

- **Claude Code's config file is per project inside the sandbox.** `~/.claude.json`
  holds the account, the user-level `mcpServers`, app state, and one entry per
  project (folder trust, allowed tools, project MCP servers, the last opening
  prompt). Bound whole it was two channels at once (leak study rows 10 and 11):
  a sandboxed session read every other project's entry, and what it wrote
  reached every other session. Each project's sandbox now gets its own copy,
  kept under `~/.local/state/agent-sandbox/claude/<slug>/claude.json` (a new
  control path, refused by `[ro]`/`[rw]`), seeded from the host file with every
  top-level key and only that project's entry, and refreshed at each launch in
  the user-level `mcpServers` alone -- manage those natively. Trust, allowed
  tools and app state a session changes inside persist for that project and
  reach neither the host file nor another project; a native session in the
  same directory keeps using `~/.claude.json`. Background workers are keyed by
  the project they were launched for and pre-trusted in the copy. Without a
  working `python3` the copy is the whole file, made once, and the launch says
  so. `docs/config.md` has the details.

### Fixed

- **Every write a sandboxed Claude Code made to its own `~/.claude.json` was
  silently lost.** Claude Code writes the file through a lock directory and a
  temp file created *beside* it, then a rename over it. The engine bound the
  file at `$HOME/.claude.json`, and beside it is the read-only `$HOME` tmpfs:
  the lock and the temp file failed with EROFS, no fallback ran, and the
  session reported success (measured with strace and against the real
  launcher, Claude Code 2.1.274). Folder trust accepted inside, per-project
  allowed tools, MCP servers added with `claude mcp add`, tips and app state:
  none of it persisted. The claude profile now binds the host's `~/.claude.json`
  *inside* the state directory, at `~/.claude/.claude.json`, and sets
  `CLAUDE_CONFIG_DIR=$HOME/.claude` so Claude Code looks for it there (with the
  variable at its own default value nothing else moves). The rename onto the
  bind mount fails and Claude Code then rewrites the file in place, which
  reaches the host. Visible from inside: the file is at
  `~/.claude/.claude.json` and there is nothing at `~/.claude.json`.
  `profile_config_binds` entries may now be `SRC<TAB>DEST`, and the engine
  removes the empty mount-point file bwrap leaves on the host for such a bind
  once no session uses it. Names a profile pins (`profile_env_set`, and a new
  `profile_env_refuse`) are no longer forwardable through `[forward]` or
  `AGENT_SANDBOX_FORWARD`; they are refused with a message. The claude profile
  refuses `CLAUDE_CODE_PROJECT_DIR_NAME`, which Claude Code honours once
  `CLAUDE_CONFIG_DIR` is set and which would move memory and transcripts out
  from under the per-project scoping.

## 0.2.0 — 2026-09-12

### Fixed

- The repository checks scanned the working tree, so an untracked local note or
  a gitignored review artifact could fail an otherwise-clean tree: a file
  containing "seccomp opt-in" failed the drift test, an unformatted stray script
  failed `shfmt -d .`, while CI on a fresh checkout stayed green. `scripts/check.sh`
  now derives its file lists from `git ls-files` and runs `shfmt` on that list,
  and the docs drift scan uses `git grep`; both see only tracked files. A real
  edit to a tracked file is still caught, staged or not. (Adversarial-review
  finding F2.)

- **The egress allowlist could be bypassed for plain HTTP with a spoofed `Host`
  header, and could be pointed at host-local services.** The addon decided on
  `pretty_host`, which returns the `Host` header, while mitmproxy connects to
  the request-line authority: `GET http://<any-dest>/` with `Host: <allowlisted>`
  reached `<any-dest>` -- any external host, the LAN, or cloud metadata --
  through the proxy, unlogged. Verified reproduced against the shipped mitmproxy
  12.2.2. The request hook now gates `request.host`, the address actually dialed
  (`http_connect` already did). Separately, the allowlist gates a destination's
  *name* but never the address it resolves to, so an allowlisted name that
  resolves to a non-public address (`localhost`, or a public name under DNS
  rebinding) reached host-local services; a new `server_connect` hook refuses to
  dial any destination that resolves to a loopback, private, link-local or other
  non-public address, before the socket opens, whatever the allowlist says about
  its name. Both are covered by unit tests (stubbed mitmproxy, mutation-checked)
  and an end-to-end test against the real installed proxy; the residual zero-TTL
  rebinding race is documented in `docs/design.md`. (Adversarial-review finding
  F1, refined by measurement: the reviewer's literal-IP framing did not
  reproduce -- literal IPs are not on the allowlist, so they were already
  refused -- but the `Host`-header and resolved-address paths did.)

- Two documented lists had fallen behind the code, both of them the kind a
  reader checks a claim against. `docs/profiles.md`'s contract table says "the
  declarations above are the whole interface" and was missing four hooks the
  engine calls -- `profile_memory_scope`, `profile_isolate`,
  `profile_briefing_args`, `profile_fallback_hint` -- so a second profile would
  be written without knowing they exist. `docs/design.md`'s isolation guarantee
  named nine paths where the profile isolates eleven; the two it left out are
  the logs a user's own hooks write (`responses.log`, `alerts.log`), which is a
  guarantee nobody knew they had. Both lists are now derived from the code by a
  test -- the hooks from the engine's own `declare -F` guards, the paths from
  `profile_isolate` -- so neither can drift again without a red suite.

- Two more places still described seccomp as off by default, both missed when
  #29 fixed the five the review found: `docs/agent-sandbox.example`, the file
  people copy into a project, said `Default: off`, and the engine's own comment
  on the `[seccomp]` dot-file section explained why `mode = off` was "a no-op
  today" -- the opposite of the truth, in the source a reviewer reads to check
  what the trust gate is for. The drift check no longer takes a hand-written
  list of files: it derives one from every shipped file that mentions seccomp
  (the changelog excepted, since its history is meant to say the filter used to
  be opt-in), and a second test derives each `on|off` default from the engine
  and requires the example file's block to state it.

- **50 negative assertions in the test suite could not fail.** `! cmd` does
  not fail a bats test unless it is the test's last line: bash suppresses
  `errexit` -- and the `ERR` trap bats fails on -- for a negated command, so
  `! true` followed by any other statement is reported `ok` (measured, bats
  1.14.0). 62 had accumulated across nine files; 12 happened to be last lines
  and worked, 50 did not. They cover the things this project most needs to
  prove *absent*: no `--share-net` in `none` mode, no `HTTPS_PROXY`, no
  `AWS_SECRET_ACCESS_KEY` forwarded, another project's memory not bound, a
  secret canary not in the briefing. All now use bats' own `run ! cmd`, with
  the 1.5.0 floor it needs declared in the shared helper; the nine that were
  followed by a message check are reordered, since `run` replaces `$output`.
  Two were asserting the opposite of what the engine does: with seccomp on by
  default since #28, an unknown `[seccomp] mode` value or a malformed line
  leaves the filter **on**, and an unapproved file cannot turn it off -- which
  is what those tests now check.
- **The `.bats` suites are under ShellCheck.** They never were: `scripts/check.sh`
  listed every shell file in the repository except the tests, and ShellCheck
  has a dedicated error for the bug above (SC2314, "In Bats, ! does not cause
  a test failure") that would have failed CI on the first one. The 37 other
  findings it raised are fixed or waived with a stated reason; two were real if
  small -- `rm -rf "$V"/*` with nothing stopping `$V` from being empty, and a
  drift-test failure message that split its items on spaces.
  `tests/unit/harness.bats` proves `run !` is live on the bats actually
  running, by running it in a child bats and reading the report.

### Added

- `[claude] hide` in `.agent-sandbox`: a space-separated list of paths under
  `~/.claude` to blank inside the sandbox, on top of the cross-session state
  that is already replaced per launch. `~/.claude` is bound read-write because
  the agent needs its own state, which makes the directory a catch-all -- a
  `GH_CONFIG_DIR` kept there is a working way to give a sandboxed agent GitHub
  access, and someone who does not want *this* project's agent reaching it now
  has a way to say so. Paths are relative to the state directory; absolute or
  `..` is refused, an unknown key warns, and the pairs reach the profile only
  from an **approved** dot-file. `daemon/` is hidden unconditionally (the
  background supervisor's control key and its roster of other sessions -- a
  channel between sessions, not this session's state); `gh/` and `ide/` stay
  visible on purpose, since both exist to let Claude Code work from inside a
  sandbox.
- The dot-file accepts a section named after the **active** profile. The engine
  does not interpret it: it checks each line is `key = value` and hands the
  pairs to the profile, which is the only thing that knows what its agent keeps
  where. A section naming another profile is unknown and ignored, so `[codex]`
  says nothing in a claude run. See [docs/profiles.md](docs/profiles.md).
- `probes/`: the harness that runs a probe prompt in a fresh sandbox and
  collects its report (`run.sh`), plus `netdiag.sh` and `claude-state-probe.sh`.
  The permission gate is opened with `--allowedTools` rather than
  `--permission-mode bypassPermissions`: the bypass is refused outright when the
  agent sees itself as root, which is the case in `strict` where it runs as
  uid 0 inside pasta's user namespace -- so the tightest mode, the one most
  worth probing, could not be probed at all. The same list goes to every mode,
  so a difference between runs belongs to the sandbox rather than to the gate.
- `docs/recipes.md`: ordinary tools from inside the sandbox. Most things that
  "don't work in the sandbox" are one of five boundary crossings -- egress,
  credentials, loopback, paths, host config -- so the doc names the crossing
  for each tool rather than only the fix, which is what lets someone solve a
  tool it does not list. Covers finding out what is blocking you
  (`blocked.log`, the briefing, the launch messages), `git` over the SSH broker,
  the git-identity trap (`~/.gitconfig` is not bound), `gh` with a forwarded
  token and what that costs, package indexes, dev servers and local services in
  `strict` mode, extra paths, conda environments, and editors.
- `probes/whats-running.sh`, plus the VS Code and startup-timing probes. The
  first answers "is this session actually sandboxed?" by reading process
  ancestry rather than by assurance, and is what the README and recipes point at
  for checking an editor.
- `install.sh` refuses to run through `sudo`, and says why. agent-sandbox is a
  **single-user tool**: the proxy is a systemd *user* unit, and the allowlist,
  trust store and launcher belong to one account, so there is nothing for a
  system-wide install to mean. Through sudo it would either install for root (a
  launcher not on the caller's PATH) or leave root-owned files in their home
  that later runs and the proxy itself cannot write -- and `--uninstall` under
  sudo would inspect root's home, find nothing, and report success while the
  real install sat untouched. `SUDO_USER` with euid 0 is the signal; plain root
  with no `SUDO_USER` is a container image and is allowed through. The check
  calls `id -u` rather than reading `$EUID`, because bash keeps `$EUID`
  readonly and always set, which would make the guard impossible to test
  without actually being root.
- `install.sh --uninstall` (issue #22). It shows exactly what it will touch and
  asks before touching it (`--dry-run` only prints, `--yes` skips the question).
  It **repoints** `~/.local/bin/claude` at the agent's own binary rather than
  deleting it -- the symlink is the engine, so removing it would leave no
  `claude` on PATH, the dead end the previous entry exists for. It stops and
  removes the proxy unit, deletes `~/.local/share/agent-sandbox`, keeps
  `~/.config/agent-sandbox` (your allowlist and trust approvals) unless
  `--purge-config`, and never touches the agent, `~/.mitmproxy`, or the
  AppArmor profiles, printing the command for those instead. Anything it did
  not create is left alone and reported, and if the agent's own binary is
  missing it refuses to repoint into nothing and says the launcher is now
  broken.
  What it undoes is read from `~/.local/share/agent-sandbox/install.manifest`,
  written at install time with a fingerprint per path (a symlink's target, a
  file's sha256). An entry whose fingerprint no longer matches is **not acted
  on**: it is listed with what was recorded and what is there now, and the
  state directory is kept so a later run can finish the job. Re-running is
  safe -- a path that is already gone is reported, not an error.
- **The launcher now actually wins on PATH.** Previously, if `claude` already
  existed at `~/.local/bin/claude` -- which is what Claude Code's own installer
  leaves -- `install.sh` declined with a warning and the agent ran
  **unsandboxed**, which is the one outcome this project exists to prevent. The
  installer now takes the name: a launcher in a writable directory is moved
  aside to `<cmd>.pre-agent-sandbox` (never overwriting an existing backup, the
  only copy of your original), one in a read-only directory such as `/usr/bin`
  is shadowed from the first writable PATH directory before it, and with no
  launcher at all the first writable PATH directory is used. If none of those
  is possible it stops and shows how to fix PATH, rather than installing
  something that would lose. `--dry-run` reports the move without making it: a
  preview must not move a command you depend on.
- An emergency exit is documented, and pointed at from the engine. The
  launcher on `PATH` is the engine itself, so a sandbox that will not start
  leaves no working agent to repair it with. `docs/troubleshooting.md` opens
  with "The sandbox will not start", naming the agent's own binary under
  `~/.local/share/claude/versions/`, which agent-sandbox never touches; and
  when `bwrap` cannot be executed (exit 126 or 127) the engine prints that path
  itself, resolved by the profile. No `--no-sandbox` flag, deliberately: the
  way out should be discoverable, not ergonomic.
- Cross-session state in `~/.claude` is now isolated, unconditionally and with
  no knob. Scoping `projects/` (the default since the previous entry) left the
  rest of the state directory readable, and most of it is keyed by session
  rather than by project. Measured on one developer machine: `file-history`
  held **40M of verbatim file contents** from twelve sessions across thirty
  projects, and `history.jsonl` held every prompt typed in any of them; also
  `plans/`, `paste-cache/`, `session-env/`, `sessions/`, `jobs/`,
  `shell-snapshots/`, `debug/`. None of it was ever asked for.
  Each launch gets its own view: the throwaway parts behind a tmpfs, the rest
  staged empty and merged back on exit, so a session keeps its own undo history
  and prompt history across a resume without seeing another session's.
  `history.jsonl` comes in filtered to this project's records. The user's own
  hook logs in the same directory (`responses.log`, `alerts.log`) start empty
  and are appended back, so they stay complete on the host. A session killed
  before its cleanup runs has its pending appends flushed by the janitor at the
  next launch. `.claude.json` and `telemetry/` are deliberate gaps, recorded in
  `docs/design.md`: paths and an email rather than project content, and
  filtering the former risks breaking Claude Code.
- The sandbox now tells the session what it allows (issue #15).
  `AGENT_SANDBOX_BRIEFING` / `[briefing] mode`, **on by default**. Each launch
  writes a briefing from the policy actually in force -- egress mode and
  allowlist size, session `--allow` hosts, extra writable and read-only paths,
  which projects' memory is readable, `--ssh` hosts, seccomp state -- and binds
  it read-only at `/run/agent-sandbox/briefing.md`. The claude profile installs
  `SessionStart` and `SubagentStart` hooks that inject a compact summary, so it
  arrives on every launch, on `--continue`/`--resume` and again after
  compaction: what a session is told can never be older than its launch.
  It says both halves. A blocked action is deliberate, so retrying it or
  routing around it only spends the budget; and what is open was opened on
  purpose, so it should be used rather than worked around. It ends with the
  escalation recipe, because a sandboxed agent cannot widen its own access:
  state what you need, what for, and the exact `.agent-sandbox` lines, then ask
  the user to run `--trust`. Names and paths only, never the contents of
  anything shared. Turning it off grants and hides nothing; it only stops the
  sandbox describing itself. A user-supplied `--settings` is merged rather than
  clobbered -- specifically the last one, which is the value Claude Code would
  have honoured, so a wrapper that overrides an earlier `--settings` behaves as
  before. No setting of theirs is overridden, because the briefing's whole
  contribution is a list of two hook entries: only `hooks` is written, and only
  by appending, and an unrecognised `hooks` shape is refused rather than
  coerced. `disableAllHooks` is respected,
  with a note that the briefing will then not be injected.
- `.agent-sandbox` accepts a `[seccomp]` section with `mode = on|off`, so a
  project can ask for the syscall filter the way it already pins a network
  mode. An `AGENT_SANDBOX_SECCOMP` in your shell wins, as with `[net] mode`.
  Its own section rather than a key in a shared `[security]`/`[options]`
  group: the environment variable's name is the section (plus key) uppercased,
  and `[security] seccomp` would map to `AGENT_SANDBOX_SECURITY_SECCOMP`, which
  is not the variable. `mode` also leaves room for a `profile` key if a second
  filter ever ships. With the built-in default off a project can only turn the
  filter *on*, so this cannot weaken the sandbox today.
- Opt-in seccomp syscall filtering (issue #4): `AGENT_SANDBOX_SECCOMP=on`
  loads a default-deny filter into the sandbox, Docker's default profile
  (moby/profiles, Apache-2.0, vendored under `components/seccomp/`) compiled as
  for a container with no capabilities. Every syscall not allowlisted fails
  with EPERM; `unshare`/`setns`/`mount`/`bpf`/`ptrace`-with-caps stay denied,
  `clone` is allowed only without namespace flags and `clone3` returns ENOSYS,
  so the agent cannot make its own user namespace to regain capabilities.
  `install.sh` compiles the filter on the installing host with pyseccomp in the
  proxy's Python env, against that host's libseccomp; nothing binary ships.
  Verified: the real agent completes turns under it in proxy and strict.
  The knob takes `on`/`1` and `off`/`0`, and says nothing about which profile:
  the value is the state, so it still reads correctly if the filter ever becomes
  the default. An earlier iteration on `main` spelled the on value `default`,
  which is now refused with a message naming `on`/`off` rather than treated as
  an alias -- a stale `AGENT_SANDBOX_SECCOMP=default` in a shell profile must
  not quietly launch without the filter it was asking for.
- `tests/unit/docs.bats` checks the README's knobs table against the engine in
  both directions: every engine flag, every `AGENT_SANDBOX_*` the engine reads
  and every `.agent-sandbox` section and key is documented, and the table
  claims nothing the engine no longer has. Each extraction asserts it found a
  plausible number of items, so a rename or reformat that breaks it fails the
  test instead of silently checking nothing.

### Changed

- **The seccomp filter is on by default** (issue #4). It was opt-in on the
  understanding that it added depth to capability-dropping. A probe run showed
  otherwise: the AppArmor profile `install.sh` installs for bwrap is
  `flags=(unconfined)` with `userns,`, and AppArmor profiles are inherited by
  children -- so every process under bwrap is exempt from
  `kernel.apparmor_restrict_unprivileged_userns=1`, the restriction that would
  otherwise stop a sandboxed agent creating a user namespace and regaining
  capabilities in it. On an installed machine the filter is not depth, it is
  the only control. `tests/live/seccomp.bats` had asserted the behaviour all
  along ("without seccomp (control) ... a user namespace can be created");
  what was missing was the cause.
  If no filter is compiled for this architecture the engine warns at every
  launch and runs without it, rather than refusing a tool the user never asked
  to change -- `install.sh` only warns when it cannot build one. Asking for it
  explicitly (`AGENT_SANDBOX_SECCOMP=on`) still refuses in that situation,
  since what was requested cannot be delivered. `off` disables it.
- **Breaking:** memory scoping is now the default. Without any configuration,
  a session sees only the current project's directory under
  `~/.claude/projects/`; other projects' transcripts, todos and shell
  snapshots are hidden behind a tmpfs. Previously the default was `shared`
  (every project visible) and scoping had to be asked for with a
  `[share-memory]` section in an approved `.agent-sandbox`. The README claimed
  sessions are isolated from each other, which was true only once configured;
  it now holds out of the box. To go back to the old behaviour, set
  `memory_default = shared` in `~/.config/agent-sandbox/config` (global, so an
  agent inside the sandbox cannot set it), or list `all` under
  `[share-memory]` in the project's dot-file.
- **Breaking:** `AGENT_SANDBOX_PASSENV` is now `AGENT_SANDBOX_FORWARD`, with no
  alias. Every other setting's variable is its `.agent-sandbox` section (plus
  key) uppercased -- `[ro]`/`AGENT_SANDBOX_RO`, `[net] mode`/`AGENT_SANDBOX_NET`,
  `[conda] write`/`AGENT_SANDBOX_CONDA_WRITE` -- and this was the one exception,
  made obvious by the new knobs table putting both names side by side. Renamed
  rather than aliased because pre-1.0 is when it is free.
- README's "Knobs and flags" is now one table with a column per way to set a
  setting (command line, environment variable, `.agent-sandbox` entry) plus the
  default, instead of an environment-only table with the flags and the dot-file
  described in prose. Each column carries only the name; values, defaults and a
  link to the relevant document live in the last column. It also states how the
  three combine: hosts, paths, forwarded names and ports add up, while the
  network mode and the conda settings are taken over by the environment
  variable when set.
- README opens with a non-technical "Why" section: what the project is for,
  which two failures (an agent led astray, and an agent simply wrong) it puts a
  boundary around, why that boundary is enforced around the agent rather than by
  it (rules given to an agent drift and need repeating), and when running an
  agent sandboxed is worth the setup at all.
- README no longer claims "there is no seccomp filter"; syscall filtering is
  opt-in as of issue #4.
- `code.claude.com` (Claude Code's documentation) is in the starter allowlist:
  agents working on Claude Code configuration reach for it, and it was the most
  refused host in the author's `blocked.log`. It is a convenience host like
  `github.com`, not something an agent needs to run, so it is in the global
  starter list rather than the `claude` profile's required seeds.
- `docs/design.md` brought back in line with the code: guarantee rows for
  capability dropping and opt-in seccomp; residual risks split (capabilities,
  uid 0 in strict, seccomp/limits) and the uid-0 consequences documented;
  resolved items removed from "Open design questions" (syscall filtering, and
  per-session proxy identity, which shipped as issue #5).
- `install.sh` chooses the proxy runtime so it works from any shell state: an
  existing environment is reused only if `mitmdump --version` still succeeds
  and is otherwise recreated (it is installer-owned); a dedicated conda env is
  preferred whenever mamba/conda is available; a venv is built only from a
  regular-build `python3 >= 3.12` with `venv`/`ensurepip` (free-threaded
  builds cannot use mitmproxy's abi3 `aioquic` wheel), trying `/usr/bin/python3`
  before `PATH`'s and warning if the interpreter belongs to a conda env. This
  fixes a real outage-in-waiting: a venv built from a dev conda env's python
  stopped importing mitmproxy after that env switched interpreters, while the
  running service masked it until its next restart.
- Drop all capabilities in the sandbox (`bwrap --cap-drop ALL`). In
  `proxy`/`open`/`none` this is a no-op (bwrap is unprivileged), but in `strict`
  the agent ran inside pasta's root-owned user namespace and started as uid 0
  with the full capability set; it now starts with none, matching the other
  modes. Namespaced and host-harmless before, but an unnecessary surface.

### Fixed

- `docs/design.md` now states that `~/.claude` is writable and steers later
  sessions: `settings.json` must stay writable for `/model` and `/permissions`,
  and it can register arbitrary hook commands, so a compromised session can
  affect every later session and -- via the documented unsandboxed recovery
  path or `claude update` -- the host. No subset can be made read-only without
  breaking the feature, since `settings.json` is itself the channel. Found by
  the adversarial review (finding F2); documented rather than half-closed.
- The documentation said seccomp was opt-in / off by default; #28 had made it
  on by default. Swept every statement -- README, `docs/design.md` (including
  the residual-risk list, the trust surface, which had it flatly wrong), the
  engine `--help`, `components/seccomp/README.md`, and two `install.sh` messages
  the review missed -- to "on by default (`AGENT_SANDBOX_SECCOMP=off` disables
  it)". A `tests/unit/docs.bats` guard now pins the engine, its `--help` and the
  shipped docs to one another so the default cannot drift again silently. Found
  by the adversarial review (finding F3).
- The seccomp generator judged `minKernel`-gated profile rules against a
  hard-coded 5.15 floor instead of the host's kernel, so a rule gated above
  that was dropped even on a newer host. Harmless with the vendored profile
  (its only gate is 4.8) and the error direction was always deny, but latent: a
  future moby update adding a higher-gated allow rule would have silently left
  that syscall denied. `install.sh` now passes `uname -r`; an absent or
  unparseable kernel falls back to the floor, and an unparseable gate drops the
  rule, because the safe direction is deny and never allow. Found by the
  adversarial review (finding F4).
- `tests/unit/docs.bats` checked the whole table row for a `[section]`, so a
  markdown link in the last column could satisfy the search while the dot-file
  column said the setting did not exist. It now reads the dot-file column only,
  and derives the sections whose keys it checks instead of listing `conda net`,
  so a new key-taking section is not silently exempt. Latent until a section's
  name appeared in one of its own doc links.
- `platform.claude.com` is in the claude profile's seed allowlist. Without it
  `/login` failed with "OAuth error: proxy refused the connection": the OAuth
  flow reaches that host from inside the sandbox, and the only way to sign in
  was `AGENT_SANDBOX_NET=open`, which turns egress filtering off for the whole
  session -- a wide door for a narrow need. Found by reading
  `~/.config/agent-sandbox/blocked.log` after a failed sign-in. Existing
  installs pick it up by re-running `install.sh`, or by adding the line to
  `~/.config/agent-sandbox/allowlist.txt` (re-read per request, no restart).
- Memory scoping used the wrong project-state directory for any project path
  containing a character Claude Code rewrites. The profile mapped a path to a
  slug by replacing `/` only; Claude Code replaces every character outside
  `[A-Za-z0-9-]`, one for one. For a project like `~/work/site.com`, scoping put
  a tmpfs over `~/.claude/projects`, created and bound a directory that had
  never existed, and left the project's real memory and transcripts hidden, so
  notes did not persist and `--continue`/`--resume` found nothing -- silently.
  The scheme is undocumented, so it is now derived empirically by
  `probes/slug-probe.sh` and pinned by a unit test using a path with `.` and
  `+`; the previous tests shared the same wrong rule in their own helper and so
  passed, because bats temp paths happen to contain no dots.
- A `.agent-sandbox` `[conda] name = <env>` set `CONDA_PREFIX` and bound that
  env, but left PATH as the launching shell had it. So the sandbox got a
  contradiction (`CONDA_PREFIX` naming one env, PATH resolving another) and none
  of the pinned env's tools were found inside, defeating the documented
  "run in this conda env instead of whatever env is active in your shell".
  The env's `bin/` now takes the active env's place on PATH inside, as
  `conda activate` does, and is prepended when no env was active. The engine's
  own PATH is untouched, so it still finds bwrap, pasta and nft as before.
  Covered for all three starting points: no env active, a different env active,
  and conda's base active (the case that surfaced it).
- Strict-mode `--ssh` failed host-key verification. In strict the agent runs as
  uid 0 (pasta maps the one uid to root), so ssh resolves `~` through
  `getpwuid(0)` to root's home, not `$HOME`, and never saw the bound
  `~/.ssh/known_hosts`. The engine now also binds `known_hosts` and `config` at
  uid 0's home, so `--ssh` works in strict as in proxy. A live `--ssh` test
  covers it (the stubbed-toolchain unit test could not).
- Strict network mode (`AGENT_SANDBOX_NET=strict`) launched the agent with no
  proxy variables, so it resolved `api.anthropic.com` directly and failed with
  ENOTFOUND (strict has no DNS route by design). The strict wrapper set the
  proxy `--setenv` before the base `--clearenv`, which cleared them; the env is
  now set after `--clearenv`. Strict mode had never delivered a working proxy to
  the agent.
- `--allow` (and a `.agent-sandbox` `[allow]` line) no longer hangs the agent.
  The per-session proxy token went into the sandbox's proxy URL with an empty
  password (`TOKEN@host`), and Node's HTTP stack hangs on that, so the agent
  could not reach the API whenever a per-session allow host was set. The URL now
  carries a dummy password (`TOKEN:x@host`); the proxy addon reads the token
  from the username and ignores the password.

## 0.1.0 — 2026-09-09

First tagged version. Extracted from the author's private sandbox repository
(history preserved) and generalized.

- Engine + profiles: `claude.sh` became the provider-agnostic `agent-sandbox`
  engine with a `claude` profile; `--profile NAME` or inference from the symlink
  name. Knobs are `AGENT_SANDBOX_*`.
- `--allow HOST`: per-session egress hosts, honoured only while the session's
  owner process lives.
- Per-project `.agent-sandbox` file (trust-gated with `--trust`): `allow`
  hosts and `share-memory` for per-project memory scoping. Memory scoping hides
  `~/.claude/projects` and rebinds only the current project plus approved
  projects' memory; default stays `shared`, a global `memory_default = scoped`
  or a dot-file opts in. The trust store and global config live under
  `~/.config/agent-sandbox`, never bound into the sandbox.
- Egress proxy: blocked hosts are refused at CONNECT before any upstream
  connection; responses are streamed and HTTP/2 disabled in mitmproxy, taking
  throughput from ~1 MB/s to near-native; mitmproxy 12+ runs from a private
  environment (venv or conda) instead of the distro package.
- The proxy CA is trusted inside the sandbox only, bound over the system
  bundle; no system-wide trust and no sudo for it. Tools with private CA stores
  get the standard CA variables.
- Conda write mode bounded to the active env with a sandbox-owned package
  cache; every session gets an ephemeral `~/.cache`.
- Refusals extended: read-only binds into secret stores, and `/`, `$HOME` or a
  parent of `$HOME` as CWD or bind.
- Refusals extended again: more secret stores (`~/.azure`, `~/.config/gh`,
  `~/.local/share/keyrings`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`,
  `~/.pypirc`), the sandbox's own control plane (`~/.config/agent-sandbox`,
  `~/.mitmproxy`, `~/.local/share/agent-sandbox`, `~/.local/bin`,
  `~/.config/systemd`), and any directory that contains a protected path
  (`~/.config`, `~/.local`); one rule for CWD and for RO/RW binds.
- Fixed: the session liveness stamp recorded the wrong process's start time,
  so `--allow` never took effect and the SSH janitor could reap live sessions.
- Fixed: setting `RW` and `PASSENV` together aborted the launch (IFS leak).
- Installer split into `components/` + `install.sh.in`, bundled into a
  self-contained `install.sh`; per-profile symlinks and allowlist seeds;
  `--dry-run`; standalone `curl | bash` mode; migration from the pre-rename
  layout.
- `AGENT_SANDBOX_NET=strict` now works, via pasta (from the `passt` package)
  instead of the non-functional slirp4netns: pasta owns an isolated network
  namespace and forwards it in userspace, bwrap runs inside sharing it, and an
  nftables rule allows only the proxy on the gateway, so a tool that ignores
  `HTTPS_PROXY` has no route out (closes the raw-socket egress gap, issue #1).
  pasta's port forwarding is off both ways (its defaults would mirror every host
  port into the sandbox and publish sandbox listeners on the host).
  Needs `passt` and its AppArmor profile (added by `install.sh`) and nftables.
  In strict mode `--ssh HOST` works: the egress firewall is opened to the host's
  resolved IPv4 address(es) and its name is added to `/etc/hosts` (DNS is
  otherwise blocked); `--ssh-unrestricted` is refused, since the firewall must
  pin a named host. IPv6-only SSH hosts are not supported yet.
- Strict-mode port opt-ins: `--host-port PORT` (the sandbox may reach the
  host's 127.0.0.1:PORT) and `--agent-port PORT` (a port the agent listens on is
  published at the host's 127.0.0.1:PORT), also as `AGENT_SANDBOX_HOST_PORTS` /
  `AGENT_SANDBOX_AGENT_PORTS` and a trusted `.agent-sandbox` `[net]` section;
  TCP, 1024-65535, the sources form a union, `none` closes a direction, noted
  and ignored outside strict.
- The network mode can be set per project: a trusted `.agent-sandbox` `[net]`
  `mode = proxy|strict|open|none` line; an `AGENT_SANDBOX_NET` in the shell
  wins over it.
- `--allow` is now scoped to the session that granted it, not shared across
  concurrent sessions. The engine mints a per-session token, carries it in the
  sandbox's proxy URL (`http://<token>@127.0.0.1:8888`), and the addon grants
  the global allowlist plus only the matching live session's `--allow`. A
  concurrent session with a different token, or none, sees the global allowlist
  only (issue #5).
- A `.agent-sandbox` that was approved and then edited or deleted now refuses
  launches from that directory until `--trust` re-reviews it (or, with the file
  gone, forgets the approval). Ignoring it fell back to the defaults, which for
  memory scoping (`shared`) is wider than a scoped policy the agent could have
  removed.
- `--trust` shows the file through `cat -v` and refuses one containing control
  characters (at review and at launch), so a repo-shipped file cannot hide a
  line from the review with an escape sequence or a carriage return.
- `install.sh` is now a true install: it copies the engine and profiles under
  `~/.local/share/agent-sandbox` and points the launcher there, so the command
  no longer depends on the checkout (move or delete it and it keeps working)
  and a `git pull` takes effect on the next `install.sh`. `--dev` keeps the
  previous symlink-into-the-checkout for developing agent-sandbox; it also
  means an edit to the checked-out engine (including one a sandboxed agent
  makes to a checkout it has as CWD) is no longer a live host-code path under a
  normal install.
- Documentation: `docs/` (design and threat model, network, SSH, profiles,
  updating, troubleshooting, prior art), `AGENTS.md`, `scripts/check.sh`.
- Tests: bats suites under `tests/` (unit with a stub bwrap, integration with
  the real bwrap and a probe profile, opt-in live), run by `scripts/check.sh`;
  each guarantee in `docs/design.md` names the test that checks it. An opt-in
  end-to-end test installs for real into a throwaway HOME with a fake Claude
  binary and a `systemctl` shim, then runs the fake agent through the installed
  proxy.
- CI (`.github/workflows/ci.yml`): `scripts/check.sh` (lint, format, bundle
  sync, unit tests), and integration and end-to-end installer jobs on Ubuntu
  22.04, 24.04 and 26.04, with an allowed-to-fail real-user-systemd experiment.
