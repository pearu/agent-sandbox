# Profiles: adding an agent

The engine is provider-agnostic. Everything specific to one agent lives in a
profile, a directory `profiles/<name>/`: a script, `profile.sh`, sourced by the
engine on the host after it has parsed its own flags and before the sandbox
exists, and the profile's own dot-file, `agent-sandbox`, read right after it (see
[The profile's dot-file](#the-profiles-dot-file)). The engine runs with
`set -euo pipefail`; profile code is subject to it.

The engine is asked for by name, and the agent is its command:
`asb [OPTIONS] CMD [AGENT OPTIONS]` (#151). The profile is CMD's basename
(`asb codex` → `profiles/codex/`), or `--profile NAME` when the binary is
called otherwise (`asb --profile claude /path/to/2.1.284`). The agent that runs
is CMD itself, resolved through its symlinks: the path given, or for a name, the
version asb installed when the profile has an [install recipe](#the-install-recipe)
(PATH is not read then), else the name looked up on PATH. The profile does not find
it. Nothing is installed at the agent's own name, so the agent's command stays the
agent.

## The contract

Variables a profile declares (all optional unless marked):

| Variable | Meaning |
|---|---|
| `profile_command` | The agent's command (default: the profile file's name): what the engine runs when no command is typed — a verb (`asb --profile NAME --status`) or `--exec` -- looked up on PATH, or for a profile with an [install recipe](#the-install-recipe) the name of the binary asb installs (a `file`). With no command and no `--profile`, a verb acts on the [default agent](#the-default-agent). |
| `profile_config_binds=(...)` | Host paths bound **read-write** into the sandbox, after the dot-file's `[agent] base`: the agent's state and config. They must exist when the sandbox is built; create them in `profile_prepare()`. An entry is a path bound at itself, or `SRC<TAB>DEST` to bind `SRC` at `DEST` inside; a `DEST` under an earlier entry layers on it, so order the entries parent first. |
| `profile_env_pass=(...)` | Environment variable names forwarded into the sandbox **if set** in the caller's environment, on top of the engine's own list (locale, proxy, CA, CUDA). The dot-file's `[env]` names add to it. |
| `profile_env_set=(...)` | `NAME=VALUE` pairs always set inside. The dot-file's `[env] NAME = VALUE` adds to it. |
| `profile_env_refuse=(...)` | Names a user may not forward with `[env]` or `AGENT_SANDBOX_FORWARD`: refused with a message. Names in `profile_env_set` are refused the same way, so a forward cannot override what the profile pins. |
| `profile_ro_binds=(...)` | Host paths bound **read-only** into the sandbox (#335), in the grammar of `profile_config_binds` (a path bound at itself, or `SRC<TAB>DEST`), applied right after them, so after the system's `/etc` and the blank `$HOME`: a `DEST` there lands over them. `SRC` must exist; create it in `profile_prepare()`. sshd: the role's sshd directory at itself, and its `/etc/group` without the `tty` line over `/etc/group`. |
| `profile_self_contained=1` | The profile needs nothing of the account but its install (#335). Every launch in the `proxy` or `strict` mode runs **a proxy of its own**, a child of the keeper's supervisor for the sandbox's lifetime: the installed mitmdump (`AGENT_SANDBOX_MITMDUMP`, else install.sh's `proxy-venv/` or `proxy-env/` under `~/.local/share/agent-sandbox`) with the installed addon and the unit's options, `--listen-host 127.0.0.1`, on the account's port (`~/.config/agent-sandbox/proxy-port`, `AGENT_SANDBOX_PROXY_PORT`) when nothing listens there, else on the next free port above it; that port is the proxy URL's and the strict chain's. The launch says `PROFILE: proxy of its own at 127.0.0.1:PORT` (and, on another port, why); the supervisor starts it before the sandbox, waits until it listens there (10 s at most), ends it when the keeper ends, and one that does not come up refuses the launch, naming the keeper's log, which has its output. And **the session directory lives in the role's store**, `<state>/<profile>/<slug>/<role>/sessions/`, not under `$XDG_RUNTIME_DIR`, which logind removes at the account's last logout (pam_systemd(8)); the proxy is told that base (`AGENT_SANDBOX_SESSION_BASE`), and an explicit `AGENT_SANDBOX_SESSION_BASE` still wins. A self-contained launch needs no user manager, linger or unit. |
| `profile_project_env_set=1` | A project's `[env] NAME = VALUE` (and `[env:<role>]`'s) is set inside (#335), after everything forwarded; without it such a line is the profile's alone and ignored in a project's file. A name the profile pins (`profile_env_set`) or refuses, or one the engine pins (`HOME`, `USER`, `AGENT_SANDBOX`), is said and not set; the network mode's proxy and CA variables come later and win. The review says what each line sets, for which roles, and under which profiles it is ignored. |
| `profile_by_name_only=1` | The profile is chosen by `--profile NAME` alone (#335): a verb or `--check` with no command never picks it, even with its command on PATH (see [the default agent](#the-default-agent)). sshd sets it. |
| `profile_verbs=(...)` | (Or `[agent] verbs` in the dot-file.) Agent verbs that observe or manage a background service. The engine joins them into the role's running launch, where the service is, and never starts a launch for one: with none running, a verb in `profile_verbs_observe` answers that the role is not running (exit 0) and any other is refused. They get no briefing arguments. |
| `profile_verbs_observe=(...)` | (Or `[agent] verbs-observe`.) The subset of `profile_verbs` that only ask questions. |
| `profile_daemon_argv=(...)` | (Or `[agent] daemon`.) Argv tokens, in order, that mark the agent's background daemon. A process inside the role's launch whose arguments contain them holds the launch as a join does, so the role does not end while it runs (#123). |
| `profile_serve_new=(...)`, `profile_serve_resume=(...)` | (Or `[agent] serve-new`, `serve-resume`.) The agent's arguments for one turn of `asb --role R --serve CMD` (#277): the session's first turn, and every later one; `{id}` is the session's id, and the prompt follows them. Without both, `--serve` refuses. claude: `-p --session-id {id} --permission-mode bypassPermissions` and `-p --resume {id} --permission-mode bypassPermissions`. |
| `profile_resume=(...)` | (Or `[agent] resume`.) The agent's arguments that resume its last session: what `asb --resume` puts after the agent's own arguments, and before a `[briefing] start` text (#355), so `asb --role R --resume claude --model x` runs `claude --model x --continue`. `--resume` is the engine's flag, translated here; after the command, `asb claude --resume ID` is Claude Code's own and the engine leaves it alone. Without it, `--resume` refuses, naming `[agent] resume`; it is refused with `--serve` (which resumes its own session by id), `--exec`, a verb and a review. `_as_profile_facts` emits it, `resume<TAB>NAME<TAB>WORD...`, for what reads a profile without loading it. claude: `--continue`. |
| `profile_clear="..."` | (Or `[agent] clear`.) What the host side of `asb --roles` types into a role's pane, then Enter, when the Supervisor writes the role's reset marker `.asb/coord/to/ROLE.reset` (#329): a fresh start of the session at its terminal. Per role: each role's keys are its agent's profile's (#355), so a round of mixed agents types each its own. Empty: that profile's roles are not watched, and `--roles` names them. `_as_profile_facts` emits it, `clear<TAB>NAME<TAB>KEYS`. claude: `/clear`. |
| `profile_account_paths=(...)` | (Or `[agent] account-paths`.) The agent's files under its base that are an account's, its login first (#355): see the dot-file table below. Without it the profile has no accounts, and `--account NAME` or `[agent] account = NAME` refuses the launch. claude: `.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner`. |
| `profile_login=(...)` | (Or `[agent] login`; `profile_login_set=1` says the key is there.) The agent's arguments that start its login (#355): what `asb --agent AGENT --account NAME --login` runs on the account's directory, after the agent's name. Possibly empty (`login =`): the agent with no arguments then. Without the key, `--login` refuses, naming `[agent] login`. `_as_profile_facts` emits it, `login<TAB>NAME[<TAB>WORD...]`. claude: `auth login` (Claude Code 2.1.319: `claude auth login`, a subscription login by default). |
| `profile_account_expiry=(FILE KEYPATH)` | (Or `[agent] account-expiry`.) Where the agent's login says when it ends (#355): FILE under the state directory (the base, or an account's directory) and the dot-separated JSON key path of a number of epoch milliseconds. `asb --list` and the briefing say a login due within 7 days or expired, and `--status` its date always, with what renews it (`asb --agent AGENT --account NAME --login` for an account; for the base the profile's `login-renew`, and none without it). The engine reads that one number and nothing else of the file, never through a symlink; a missing file, a missing key or a non-number is an unknown expiry, of which nothing is said. Without the key nothing is said either. `_as_profile_facts` emits it, `account-expiry<TAB>NAME<TAB>FILE<TAB>KEYPATH`. claude: `.credentials.json claudeAiOauth.refreshTokenExpiresAt` (measured, 2.1.319: milliseconds; the refresh token's own expiry, about a month after the login). |
| `profile_login_renew=TEXT` | (Or `[agent] login-renew`.) What renews the base's login (#355): said as `run TEXT` by `--list` when the login has expired (a due one carries no renewal there) and by `--status` when it is due within 7 days or has expired, the briefing as `the user renews it with TEXT`. An account's renewal is the engine's, `asb --agent AGENT --account NAME --login`. Without the key no renewal is named for the base: the clause ends at `expired` or the date. `_as_profile_facts` emits it, `login-renew<TAB>NAME<TAB>TEXT`. claude: `/login`, Claude Code's in-session command. |

Functions a profile defines:

| Function | Meaning |
|---|---|
| `profile_prepare()` | Optional. Runs right before the sandbox is assembled; create state files here. |
| `profile_slug()` | Optional. Called with a project directory; prints this agent's name for it in its own per-project state (claude: the directory under `~/.claude/projects/`). `{slug}` expands to it in the channel table, in a path declaration's key and in its `outside:` source (#176); without this hook a `{slug}` is refused. Any other `{name}` is refused too. |
| `profile_session_args()` | Optional. Called with the agent's argv for every launch and join that runs the agent as a session -- interactive or not, a resume, a turn of `--serve` or `--summarize`, `--login` -- **the briefing on or off**; never for `--exec` (the caller's own command) or a verb (no session). It appends to `profile_session_argv` what every such invocation must carry, and the engine puts those arguments **first**, before the briefing's and the agent's own. It reads `_preset` by dynamic scope: the preset of the sandbox the agent runs in (`native`, `isolated`, `inherit` or `shared`; for a join, the running keeper's), so an argument can depend on it. For what the sandbox's guarantees rest on, which a briefing switched off must not take away. |
| `profile_briefing_args()` | Optional. Called with the sandbox-side path of the briefing directory and the agent's argv when the briefing is on; append to `profile_briefing_argv` whatever makes the agent read it. The engine puts those arguments **before** the agent's own (a subcommand such as `claude mcp list` refuses an option of the agent's after it). To change the agent's own arguments -- claude drops the user's `--settings` once it has merged it into its own -- set `profile_agent_argv`, which starts as they were typed. Skipped when the briefing is off or could not be written. |
| `profile_start_args()` | Optional. Called with the text of the role's `[briefing] start` file and the agent's argv, at a launch that starts a session (not `--exec`, a verb, a turn of `--serve`, or with the briefing off); set `profile_start_argv` to the arguments that make the agent run that text as its first turn, which the engine puts **after** the agent's own. Leave it empty to decline -- for an invocation that is not an interactive session. claude: `-- TEXT`, Claude Code's positional prompt, which `--continue` and `--resume ID` take as the first turn of the resumed session; declined for `-p`, `--bg`, `--help`, `--version`, a `--` already there, and a first word that is not an option (a subcommand, or a prompt of the user's own). Without the hook, the text is read and not used. claude also makes the text a command, `/start`, wherever it gives the first turn: `.claude/commands/start.md` in the briefing directory, which `profile_briefing_args` adds with `--add-dir` (Claude Code reads an added directory's `.claude/commands/`; the role's own `~/.claude/commands/` is the `skills` channel, the user's under `inherit`), so a role cleared with `/clear` runs it again with `/start`. |
| `profile_check_notes()` | Optional. Prints lines `--check` shows for the role, after the engine's own, one per line; it reads the engine's locals by dynamic scope, `_watch_path` among them (the role's `[serve] watch`, empty without one and on a turn of `--serve`). claude: the watcher rule's line, for a role with a watch path. |
| `profile_telemetry_hosts()` | Optional. Prints, one per line, the hosts the agent reaches on its own rather than for a command (telemetry, metrics, error reports, feature flags), as the allowlist writes them: an exact hostname or a `.domain`. They are refused like any unlisted host; the engine writes them to the briefing directory's `telemetry-hosts`, so a profile's refusal hook can leave them out of what it reports, and `--check` counts them (#276). These are the agent's own hosts; the hosts of the tools the engine ships (gh's `cafe.github.com`) are the engine's table, added to the same file (#304). |
| `profile_route()` | Optional. Called with the agent's argv once the project's trusted `.agent-sandbox` is read, for a launch that is not a `--trust` review. Returns 0 to let the engine sandbox it, or runs the invocation itself and does not return. Inside a sandbox it is not reached: there the engine itself runs what an `asb` names as it is, with no second sandbox (#197). |
| `profile_before_join()` | Optional. Called with the agent's argv just before it is joined into the role's launch (not for `--exec`). The claude profile records workspace trust for a `--bg` there, which cannot answer the prompt. Failing refuses the join: the sshd profile refuses a second launch of a running role there, since a second sshd could not listen on its port. |
| `profile_account_switched()` | Optional. Called at a cold start (never a join) whose account is not the one the role's stores last ran on, after the channels' stores are ready (#355): the record `<sb>/account` the previous launch left, a missing one being the base, against the account in force (`--account`, `[agent] account`, the base). A launch's own `--exec` counts; an engine turn (`--serve`'s, `--summarize`'s) neither records nor compares. Failing refuses the launch. claude: sets `oauthAccount.profileFetchedAt` to 0 in the role's `.claude.json` store (`config` under `own`, `seed-only`, `copy` or `copy-on-write`; never the native file under `read-write` or `native`), so Claude Code refetches the account's profile at its first run and `/status` names the organisation of the account in force, not the last one's (it otherwise refetches only after 12-24 h). |
| `profile_trust_notes()` | Optional. Called at the dot-file's review with the project directory and the `KEY=VALUE` pairs of the project's section named after this profile (#335), in a subshell with only the profile sourced; prints one line per note, which the engine says as `.agent-sandbox: LINE`. sshd: who may log in (`[sshd] authorized-keys`), a relative path a launch refuses, and a keys file inside the project, which sessions can write. |
| `profiles/<name>/test.bash` | Not the engine's: the profile's **test adapter**, sourced only by the test suites (install.sh leaves it out of the install). With it, every shared test runs for the profile -- `tests/unit/profile-contract.bats`, `tests/integration/profile-contract.bats`, `tests/live/agent.bats` and the agent block of `tests/e2e/install.bats` -- once per adapter. It says what the profile does not: how the agent's installer lays the binary out (`test_plant`), the agent's options that come before a subcommand, the base's top-level layout for `--check`, a fake login of the agent's shape, and how to run one cheap real turn for the live suite. What the profile states (its base, hide list, resume, clear and login words, account paths) the tests read from `_as_profile_facts` and the dot-file. The contract is at the top of `profiles/claude/test.bash`. |

What the engine provides to a profile: `AGENT_SANDBOX_ENGINE` (real path of the
engine file), `AGENT_SANDBOX_PROFILE` (this profile's name),
`AGENT_SANDBOX_PROFILE_DIR`, `_as_msg` for prefixed stderr messages,
`profile_role_dir` in `profile_prepare()` (the role's store on the host, never bound
into a sandbox, #335), and, by dynamic scope there, the launch's resolved `_knob_net`
(the network mode), `_preset` in `profile_session_args()` (the sandbox's preset),
`_agent_ports` (the agent-port tokens, merged from every source and
normalized: `PORT`, or `ADDR:PORT` for an address other than `127.0.0.1`), `_role` and
`_df_profile_kv` (the approved dot-file's pairs of the profile's section), and, in
`profile_briefing_args()`, the array `_permission_rules`: the trusted dot-file's
`[permissions]` rules for this launch's role, each once, in the agent's own syntax, for
the profile to hand to the agent (claude: `permissions.allow` in its `--settings`). A
profile that reads none leaves them unapplied. Before them, claude's `--settings`
carries two rules of the engine's own at every briefed launch and join, so that Claude
Code does not ask "outside the working directories" for the engine's files:
`Read(//run/agent-sandbox/**)`, the briefing directory, and
`Edit(//run/agent-sandbox/summary/line)`, the session's summary line where the engine
bound it (`_summary_line`). A leading `//` is an absolute path in Claude Code's
`Read`/`Edit` rules (a single `/` is relative to the settings file), and an `Edit` rule
covers `Write`, whose own path rules never match
([permissions](https://code.claude.com/docs/en/permissions)). They are narrower than
`--add-dir`, which would allow edits anywhere in the directory, and the trust review and
`--check` do not list them: no dot-file line asks for them, and they reach nothing the
binds do not already give. A user's `--settings` rules come first, and their `deny` and
`ask` rules still win; a `permissions` of theirs that is not an object (or an `allow`
that is not an array) is kept as it is and no rule is added, which the launch says, the
hooks merged all the same.

### A dot-file section named after the profile

A project's `.agent-sandbox` may carry a section named after the **active** profile —
`[claude]` in a claude run. The engine checks its lines are `key = value` and reads
`hide` there: paths under the profile's base blanked every launch, on top of the
profile's own `[agent] hide` (relative paths only; `/` and `..` are ignored with a
note). The claude profile reads `state-background` itself, in `profile_briefing_args`,
from `_df_profile_kv`. A profile allows it by listing it in `profile_dotfile_keys`,
which is also how the review knows to warn of any other key — a typo must not silently
do nothing. A section naming a different profile is skipped at a launch; the dot-file's
review reads every profile, and warns of a section that names none. The pairs count
**only from an approved dot-file**, so an unreviewed file grants nothing; the trust gate
is the engine's, not the profile's. `profiles/claude/profile.sh` lists `hide` and
`state-background` ([config.md](config.md#the-file)).

**A profile may ship a helper beside its script** for what bash does badly, such as
parsing the agent's own file formats. The claude profile's is `profile.py`, a subcommand
each: the config file's seed view, the prompt history's, the `--bg` workspace trust, the
`--settings` merge. Scripts the agent runs inside the sandbox are copied beside the
briefing and named in the `--settings` from there: `refusal-hook.sh` (a refused host,
after a Bash call that failed), `state-hook.sh` (what the session is doing, from
`SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest`, `Notification`, and
`PostToolUse`/`PostToolUseFailure` for any tool, into the sandbox's `/tmp`: `working`,
`needs you`, and after a reply one of four -- `asks you` when the `Stop` input's
`last_assistant_message` (the transcript's tail without it) ends one of its last three
lines with `?` (blank lines, quotes -- `>`, `▎` -- and fenced code not counted),
`running` when a background command of the role's own is running; it wakes when that
ends (an entry of the `Stop` input's `background_tasks` whose command does not name
`inbox-wait`; without that field, a Bash tool wrapper, `bash -c ... eval`, other than
the watcher's among Claude Code's children), `waiting` when a process named `inbox-wait`
runs under Claude Code (`CLAUDE_PID`), `idle` otherwise, and the same watcher test at
`SessionStart`; with `[claude] state-background = on` also the terminal's background,
reset by a `SessionEnd` hook; no hook fires on an Esc interrupt, so the state stays
`working` until the next event; and, for a role whose `[serve:ROLE] watch` names its
inbox, the watcher rule: its `Stop` command carries `AGENT_SANDBOX_WATCH=PATH`, and a
turn that ends with no `inbox-wait` running under Claude Code is refused once -- the
hook prints `{"decision":"block","reason":...}`, the reason saying the watcher on PATH
is not running and to arm it in the background, and Claude Code goes on with that -- but
not when the input's `stop_hook_active` is true, so never twice in a row; not in a print
run, nor on a turn of `--serve`, whose loop is the watcher; `--check` says it for the
role; and, for every session where the engine bound the role's summary directory (the
briefing on, #314), the summary rule: the `Stop` command carries
`AGENT_SANDBOX_SUMMARY=/run/agent-sandbox/summary/line`, and a turn that ends with that
line missing or empty is refused once in the same way, the reason saying to write the
one-line summary there -- not with `stop_hook_active`, not in a print run, `--serve`'s
turns included; a `Stop` that fails both rules gets one refusal naming both; `--check`
says it) and `statusline.sh` (the `statusLine`: a bar of the state's colour with the
role and that state, padded to `COLUMNS` less 4, the most Claude Code shows of the line
without cutting it, `refreshInterval` 1, the role written into its command since neither
its stdin nor the sandbox's environment carries it; a `statusLine` in the user's
`--settings` wins) (#287), and, for a role with a `[briefing] start`, the `/start`
command (`.claude/commands/start.md`, the start text, the directory added with
`--add-dir`). The contract is still the bash hooks, and the policy stays in them: the
helper does one thing and exits nonzero when it cannot, and the hook decides what a
launch then does. `python3` is always there -- the engine refuses a launch without it,
since every command is joined by it -- so a hook needs no second, bash version of what
the helper does. The engine gives the hook its directory as `profile_home` (what
`{profile}` expands to), and the installer copies the profile's directory whole.

A profile must **not** touch the engine's bwrap argument list. The declarations
above are the whole interface, so that the sandbox's isolation guarantees stay
reviewable in one place, the engine.

## The profile's dot-file

`profiles/<name>/agent-sandbox` is in the grammar of a project's `.agent-sandbox`
([config.md](config.md)) and states what the profile can say as data (#181, plan
#173). The engine reads it after `profile.sh`, at every launch of the profile. It
ships with the engine, so it is not reviewed the way a project's file is. It stands
below a project's file: lists add up, and a project's value overrides a
single-valued one.

| Section, key | Sets |
|---|---|
| `[agent] verbs`, `verbs-observe`, `daemon`, `status`, `serve-new`, `serve-resume` | `profile_verbs`, `profile_verbs_observe`, `profile_daemon_argv`, `profile_status_argv`, `profile_serve_new`, `profile_serve_resume` (space-separated words) |
| `[agent] command` | `profile_command` |
| `[agent] clear` | `profile_clear`, the whole value |
| `[agent] resume` | `profile_resume` (space-separated words) |
| `[agent] login` | `profile_login` (space-separated words, possibly none) and `profile_login_set=1`: what `asb --login` runs on an account's directory (#355) |
| `[agent] login-renew` | `profile_login_renew` (the rest of the line, as written): what renews the base's login, said when it is due (#355); a value with a tab is said and ignored |
| `[agent] account-expiry` | `profile_account_expiry` (two words, FILE KEYPATH): where the login's expiry is written, in epoch milliseconds, for `--list`, `--status` and the briefing (#355); any other number of words is said and ignored |
| `[agent] install` | `profile_install`: how asb installs the agent (#6), the kind of file the profile's `resolve.sh` names -- `file` (one binary, nothing beside it) or `tar PATH` (a tarball, the binary at the relative `PATH` inside it: no part starting with `.` or `-`, so no leading `/` and no `..`); any other shape is said and ignored. `_as_profile_facts` emits it, `install<TAB>NAME<TAB>KIND[<TAB>PATH]`. See [The install recipe](#the-install-recipe). claude: `file` |
| `[agent] base` | the agent's state directory (`~/.claude`), bound **read-write** before anything else, so every channel and declaration layers on it; created when absent; checked as any read-write bind is (never `/`, `$HOME` or a parent of it, nothing protected), and resolved again at bind time (#175) |
| `[agent] base-env` | the variable the agent itself reads to move its state (claude: `CLAUDE_CONFIG_DIR`); set and non-empty in the launching shell, it wins over `base` (#190). `{base}` in the dot-file is the base so resolved |
| `[agent] hide` | `profile_hide`: paths under the agent's state directory blanked every launch: a tmpfs each, empty inside and gone at exit |
| `[agent] visible` | `profile_visible`: paths under the agent's state directory deliberately left native, with a reason beside them, so that `asb --check` does not list them as unclassified (#82) |
| `[agent] account-paths` | `profile_account_paths` (space-separated paths under the base, the login first): the agent's files that are an **account's** (#355). With an account in force (`--account NAME`, `[agent] account = NAME` in a project's file) the directory `~/.local/state/agent-sandbox/<profile>/accounts/NAME/` is bound at the base's inside path in place of the base, so these files are the account's and the base's are never in the sandbox (the base's other top-level entries are bound one by one, these never); `{base}`, the `base-env` variable and every channel store slot are unchanged. A profile without the key has no accounts: naming one refuses the launch. `asb --check` counts them as classified. `_as_profile_facts` emits it, `account-paths<TAB>NAME<TAB>PATH...`. claude: `.credentials.json .oauth_refresh.lock .oauth_refresh.lock.owner` (measured, 2.1.319: a refresh replaces the credentials file and rotates its refresh token, so an account's login has one live home and is bound as a directory, never copied; the refresh lock Claude Code takes lives beside it) |
| `[env]` | `NAME`: `profile_env_pass`; `NAME = VALUE`: `profile_env_set` (a leading `~` is `$HOME`, and `{base}` expands); `-NAME`: `profile_env_refuse` |
| `[allow]` | hosts opened for every launch of the profile, as its session allowlist beside `--allow`'s (proxy and strict) |
| `[channel:<name>]` | `profile_channels`, one section per channel and a path per line, a trailing `/` for a directory; a path's value sets `outside:SRC` (`profile_channel_sources`), `filter:FN` (`profile_channel_filters`) `vendor:PREFIX` (`profile_channel_vendor`) and `start:FILE` (`profile_channel_start`: the template a file store starts as with nothing to seed from). `{base}` and `{slug}` expand (#190). A `reach = HOW [-- note]` line (`profile_channel_reach`) says how what another session left there arrives in a session -- `context`, `searched`, `pointed` or `never`, the leak study's scale -- for `asb --check`; a channel without one is printed UNMEASURED, so write one only from a measurement. `create = yes` makes a connected channel's missing source directory on the host (mode 700) rather than an empty mount, so what the user writes there later reaches a running session (`profile_channel_create`); `login = FILE -- NOTE` names the file whose absence means the channel carries nothing yet, and the one sentence said at launch, by `--check` and in the briefing when it is missing (`profile_channel_login`); `env = NAME` sets NAME to the channel's path under every preset but native (`profile_channel_env`) |
| `[preset:<name>]` | `profile_channel_presets`: for `isolated`, `inherit` or `shared`, the channels whose rung is not the ladder's, in the `[connect]` grammar (`config = seed-only`) (#191) |

`[agent]` is the profile's own section. In a project's file the same section is
named after the profile (`[claude]`), and only the keys the profile lists in
`profile_dotfile_keys` are read there; the review warns of the rest, and of a
`[channel:<name>]`, which is a profile's. Other sections in a profile's dot-file are not
read yet: the launch says so.

## The install recipe

An agent asb installs itself (#6) is described by three things in its profile
directory. `asb --install` reads them (below), and a launch runs what it installed:
for such a profile, a name -- `asb claude`, `--agent R=claude`, `[agent] command =
claude` -- is the version `install/current` names, under every preset, `--preset
native` and `none` included, and the `claude` on your PATH is never read. A path is
still what it names (`asb --profile claude /path/to/claude`), the escape hatch for a
binary of your own. The binary is the profile's command in the version's directory
for a `file`, `PATH` in it for a `tar PATH`.

With none installed (no `install/current` at all) a launch at a terminal -- stdin and
stderr a terminal, on the host -- asks once, when its own checks have passed (the
dot-file reviewed and applied, its account resolved; a join into a running role asks
nothing), after running the profile's resolver for the pin (a network call, said
first), and on `y` installs it as `asb --install` does, then goes on with the launch:

```
agent-sandbox: claude is not installed for agent-sandbox; looking up claude 2.1.321, its pinned version...
agent-sandbox: install claude 2.1.321 (342 MB from downloads.claude.ai)? [y/N]
```

Any other answer, and any launch with no terminal (a script's `-p`, CI, a pane nobody
is at), refuses at once, never asking or blocking, naming the line that installs it:

```
agent-sandbox: claude is not installed for agent-sandbox: install it, asb --install claude
```

(exit 1). Only a launch asks: `--exec`, the agent's verbs, `--status`, `--shutdown`,
`--delete`, `--reset`, `--serve`, `--summarize` and `--roles`' check of every role
refuse with that line. `--check` never looks the agent up, so it neither asks nor
refuses for it. `--account NAME --login` installs the pin first, unasked (see
[Accounts](config.md#accounts)). A `current` that is there but broken is never mended
by the question: the same refusal, with what is wrong in parentheses, for a `current`
that is not a symlink, names a version that is not there, or a version's directory
without the binary.

**The version a launch runs** is said on its launch line: `agent: claude 2.1.321`
with `--verbose` when it is the pin, and always, whatever the verbosity, when it is
not -- after an `asb --install claude@V`, or once an `install.sh` run has brought a
new pin:

```
agent-sandbox: agent: claude, running 2.1.300, pinned 2.1.321 (asb --install claude moves to the pin)
agent-sandbox: agent: claude, running 9.9.9 (untested with asb), pinned 2.1.321 (asb --install claude moves to the pin)
```

A join says the running role's (`agent: claude 2.1.321, the running role's`). Each
launch records it in the role's store, `<store>/version` (`PROFILE<TAB>VERSION`, empty
for an agent named by path), and in its keeper's policy (`version`): `--status` says it
(`version: claude 2.1.321`, or `running V, pinned W`), and `--list` names it after the
profile (`claude 2.1.321, base`). The briefing does not. A name that is not the
profile's command (`asb --profile claude other`) is refused: PATH is not read for this
profile, so name another binary by its path.

The bind: the version's directory alone, read-only, at its own path
(`~/.local/state/agent-sandbox/claude/install/2.1.321/`), never the `install/` that
holds the other versions; outside `native` the directories above it are empty mount
points on the blank `$HOME`, so nothing else of the state directory, a control path,
is visible, and `current` is made beside it (bwrap's `--symlink`) so an `asb` run
inside finds the same binary. Under `native` the version's directory is bound
read-only too, over the read-write `$HOME`, so the agent cannot change itself under
any preset; the rest of the state directory is the host's there, as all of `$HOME`
is. A path keeps the single read-only file bind. A running role keeps the version it
started with: after an `asb --install` moves `current`, an idle keeper is replaced
and a busy one refuses a launch of the role by name, naming both binaries and both
versions (`running with agent = .../2.1.321/claude (claude 2.1.321), and this
launch's agent asks for '.../2.1.300/claude' (claude 2.1.300)`), as for any change of
the agent's binary.

| File | What it is |
|---|---|
| `agent-sandbox`, `[agent] install` | The kind of file the vendor ships: `file` or `tar PATH` (above). |
| `versions` | The versions the profile was tested with live, one per line: `VERSION`, or `VERSION pinned` for the one asb installs. `#` starts a comment; blank lines are skipped. A version is exact -- dot-separated numbers, then an optional `-`/`+` suffix (`2.1.321`, `2.2.0-rc.1`) -- never a range. A line of another shape and a version listed again are ignored; two pinned, or versions with none pinned, leaves no pin. These problems are said when `asb --install` reads the table; `_as_profile_facts` reads it silently, so a bad table never breaks a launch or `--check`. No checksums: they come from the vendor at install time. A version goes in when the live tests pass with it. `_as_profile_facts` emits `version<TAB>NAME<TAB>V` for each and `pin<TAB>NAME<TAB>V` for the pin. claude: `2.1.321 pinned` |
| `resolve.sh` | The resolver, vendor-specific, run on the host and reviewed as engine code: `resolve.sh VERSION PLATFORM [BASE]`. PLATFORM is the engine's `ARCH-LIBC`, `uname -m` then `gnu` or `musl` (`x86_64-gnu`, `aarch64-musl`); the script maps it to the vendor's names. BASE, for tests and mirrors, is read in place of the vendor's source: an `https://` or `file://` URL or an absolute directory. It prints one line, `URL<TAB>SHA256<TAB>SIZE` (SIZE in bytes, empty when the vendor states none), and exits 0; the engine downloads URL and keeps the file only if its SHA-256 is SHA256. Where the vendor signs what states the checksum, the script verifies that signature against a key pinned in the profile directory before it prints anything. A failure is one line on stderr and nothing on stdout: exit 2 for arguments it does not take, 1 for anything else. It fetches only metadata, never the agent, and runs nothing it fetched. |

claude's resolver reads `<BASE>/<VERSION>/manifest.json` (default BASE
`https://downloads.claude.ai/claude-code-releases`) and uses it only when
`manifest.json.sig` is a good signature by Anthropic's release key --
`release-key.asc`, as published at `https://downloads.claude.ai/keys/claude-code.asc`,
fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE` as the vendor's
setup docs print it -- and the manifest names VERSION itself. The binary is
`<BASE>/<VERSION>/<platform>/claude`, platform `linux-x64`, `linux-arm64` or a `-musl`
variant of either. It needs `curl` and `gpg` on PATH; gpg runs in a scratch home with
no agent, so your keyring is never read. The vendor signs manifests "from 2.1.89
onward" (its docs); a version without a signature is refused.

### The default agent

A role verb (`--status`, `--shutdown`, `--delete`, `--reset`, `--summarize`) with no
command, no `--profile` and no role agent acts on the default agent. The candidates are
the profiles asb can run, those not chosen by `--profile` alone
(`profile_by_name_only`): every profile with an install recipe, installed or not
(installable), and every other whose command is on PATH, looked up as a launch looks
it up. A profile whose `profile.sh` fails to load is never one, and the refusals name
it (`failed to load: NAME`).

- One candidate: that one.
- Several: the one set with `asb --set-default-agent AGENT`, kept in
  `~/.config/agent-sandbox/default-agent` (one line, the profile's name, beside
  `tools.txt`). With none set: `there are several agents asb can run (claude codex) and
  no default is set: set it, asb --set-default-agent AGENT, or name one, asb --status
  AGENT or --profile NAME`; with one set that is not a candidate, the refusal names it
  and the file.
- None: `none installed has an agent asb installs or its command on PATH (installed:
  NAMES): install the agent, or name its binary by path`.

`asb --set-default-agent AGENT`, alone on the line, on the host only, sets it; AGENT
must be a candidate (refused, exit 2, naming them, otherwise). `asb --set-default-agent`
prints the one set, or says that none is and what the default is then.

`--check` with no command checks every candidate, each under a heading of its name
(one: no heading), the default set or not; a profile named (CMD, `--profile`, the
role's agent) is checked whether its agent is installed or not.

### `asb --install AGENT[@VERSION] [--from FILE [--sha256 SUM]]`

The installer, alone on the line, on the host only (refused inside a sandbox on either
sign of one, the `AGENT_SANDBOX` marker or pid 1 being bubblewrap, as `--login` and
`--setup-remote` are). An explicit `--install` is your word: it asks nothing.

1. It reads the profile's `versions` table itself, saying what the table gets wrong.
   VERSION defaults to the pin. A version that is not exact (`1.2.3`, no range) is
   refused (exit 2); an exact one that is not a line of the table installs all the
   same, said first -- `claude 2.1.330 is not in profile 'claude''s versions table: it
   has not been tested with asb` -- and on the last line, `(untested with asb)`; its
   checksum is the vendor's, through the resolver, as for any version. A `--from FILE`
   that is not a readable file, and a `--sha256 SUM` that is not 64 lowercase hex
   digits, are refused here too.
2. A version already installed is not fetched again: it only becomes current (step 6);
   a `--from FILE` is then said to be unused, and with `--sha256 SUM` neither FILE nor
   SUM is used (FILE must still be a readable file, and SUM well formed).
3. It runs `resolve.sh VERSION PLATFORM` with PLATFORM this host's `ARCH-LIBC` (musl
   when `/lib/libc.musl-*` exists or `ldd` names musl, as the vendor's own script
   decides) and the tools env's `engine-bin/` first on PATH, where `install.sh` links
   conda-forge's `gpg` for it (no sandbox has that directory on its PATH).
4. It downloads URL with the host's `curl -fsSL --proto '=https,file'` (redirects to
   `https` only; the host's own proxy settings apply, never the sandbox's proxy), at
   most SIZE bytes when stated (4 GiB otherwise), then refuses the file unless its size
   is SIZE and its SHA-256 is SHA256. `--from FILE` takes FILE in place of the download,
   checked the same way: the resolver still runs, since the SHA-256 comes from it.
   `--from FILE --sha256 SUM` is the offline install: the resolver is not run, and FILE
   must have the SHA-256 SUM (no size check, since none is stated). `--sha256` without
   `--from` is refused.
5. It unpacks into a temporary directory beside the destination, `.VERSION.XXXXXX`: a
   `file` is the binary, named as the profile's command (claude: `claude`); a `tar
   PATH` is unpacked with `tar --no-same-owner --no-same-permissions`, refused before
   anything is written when a member is absolute or has a `..` part, or when tar cannot
   list the members (`--quoting-style=escape`: GNU tar), and after when
   anything in it is not a file, directory or symlink, a symlink resolves outside the
   tree (followed as the kernel follows it, not read as text), or PATH is not an
   executable file inside. Then one rename puts it at
   `~/.local/state/agent-sandbox/<profile>/install/<VERSION>/` (`$XDG_STATE_HOME` is
   honoured). Any failure removes the temporary directory: nothing is left, and the
   current version stays.
6. `install/current`, a symlink to `<VERSION>`, is pointed at it (replaced by a rename):
   the version launches will run. The last line names the version, its binary's path,
   and that it is now current.

Exit 0 when installed (or already there), 2 for a refusal, 1 for a failure (the
resolver's, the download's, a size, checksum or tarball check).
`AGENT_SANDBOX_INSTALL_BASE` is for tests: it is passed to the resolver as BASE, the
source read in place of the vendor's; the SHA-256 the resolver gives is enforced all the
same.

## Adding a profile

1. Create `profiles/<name>/profile.sh` implementing the contract;
   `profiles/claude/profile.sh` is the reference and has the contract in its header.
2. Add `profiles/<name>/agent-sandbox`: the hosts the agent must reach under
   `[allow]`, and what else it can state as data (below).
3. Run `scripts/check.sh`, then `install.sh` (or `install.sh --dry-run` first): the
   installer reports the agent it finds on PATH. `asb <name>` then runs it. For an agent
   asb installs, add its [install recipe](#the-install-recipe): `[agent] install`, a
   `versions` table with the live-tested version pinned, and a `resolve.sh` that checks
   the vendor's signature where there is one; `asb <name>` then runs
   `asb --install <name>`'s install, never one on PATH.
4. Add `profiles/<name>/test.bash`, the profile's test adapter (the contract is at the
   top of `profiles/claude/test.bash`): every shared test then runs for it. Its own
   tests, for what only this agent has, go under `tests/<layer>/profile-<name>/`. A new
   profile adds these two and changes no shared test.
5. Nothing in the engine should need to change. If it does, the contract is
   missing something; extend the contract (and this document) rather than
   special-casing a profile.

## The flagship: `claude`

`profiles/claude/profile.sh` runs Claude Code — asb's install of it,
`asb --install claude` (#6), never the `claude` on your PATH; a binary of your own runs
by its path, `asb --profile claude /path/to/claude` — binds `~/.claude` read-write and,
inside it at `~/.claude/.claude.json`, the project's own copy of `~/.claude.json`
(seeded and refreshed per launch, see [config.md](config.md)), with `CLAUDE_CONFIG_DIR`
pointing Claude Code there (it writes the file through a lock directory and a temp file
beside it, which the read-only `$HOME` refused; the writes were then silently lost),
forwards `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`, sets `DISABLE_AUTOUPDATER=1`,
refuses to forward `CLAUDE_CODE_PROJECT_DIR_NAME`, and routes `update`, `upgrade` and
`install` to the host (see [updating.md](updating.md)).

## `sshd`: a sandboxed ssh login

`profiles/sshd/` (#335) runs an OpenSSH server as the agent:
`asb --profile sshd --role NAME`, no command. Its `profile_command` is the path of
`sshd-agent.sh` beside it, which the engine binds read-only at itself, so it runs
whatever the account's PATH (sshd itself is in `/usr/sbin`, often off a user's PATH);
inside the sandbox it writes one `SetEnv` line -- every variable of its environment, the
launch's, but `HOME`, `USER`, `LOGNAME`, `SHELL`, `MAIL`, `TERM`, `PWD`, `OLDPWD`,
`SHLVL`, `_`, `SSH_*` and its own two -- into `/tmp`, before an `Include` of the
configuration `profile_prepare()` wrote on the host, and execs `sshd -D -e -f` it.
`profile_prepare()` refuses a launch that is not `strict`, that has not exactly one
agent port, or whose `[sshd] authorized-keys` is missing, relative or unreadable; it
keeps the role's host key (ed25519, made once), copies the keys file, writes
`/etc/group` without the `tty` line (a pty's `chown` to gid 5 fails in the user
namespace; without the group sshd uses the user's own) and the configuration: `Port`
from the agent-port token and `ListenAddress 0.0.0.0`, every address of the namespace
whatever the token's (a 2026 passt delivers a connection from the host's loopback to the
namespace's own address, not to its `127.0.0.1`, measured on Ubuntu 26.04; the namespace
is private, so only the published port is reachable), `HostKey`, `AuthorizedKeysFile`
(the copy), `PidFile none`, `UsePAM no`, `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitUserEnvironment no`, `PermitUserRC no`,
`DisableForwarding yes`, `PermitTunnel no`, `StrictModes no`, `Subsystem sftp` (the
host's sftp-server, else `internal-sftp`), `LogLevel VERBOSE`. sshd's log goes to the
launch's stderr; the proxy's to the keeper's log. It declares `profile_self_contained`,
`profile_project_env_set`, `profile_by_name_only`, `profile_ro_binds` and
`profile_trust_notes`, refuses a command or arguments in `profile_route()`, and a second
launch of a running role in `profile_before_join()`.

## Roadmap profiles

`codex`, `gemini`, an `ollama`/OpenAI-compatible profile, and a generic
`command` profile that sandboxes an arbitrary worker with a scoped allowlist,
for orchestrating many agents.
