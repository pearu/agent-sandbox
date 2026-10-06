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
is CMD itself — looked up on PATH, or the path given — resolved through its
symlinks; the profile does not find it. Nothing is installed at the agent's own
name, so the agent's command stays the agent.

## The contract

Variables a profile declares (all optional unless marked):

| Variable | Meaning |
|---|---|
| `profile_command` | On-PATH name of the agent (default: the profile file's name): what the engine runs when no command is typed — a verb (`asb --profile NAME --status`) or `--exec`. |
| `profile_config_binds=(...)` | Host paths bound **read-write** into the sandbox, after the dot-file's `[agent] base`: the agent's state and config. They must exist when the sandbox is built; create them in `profile_prepare()`. An entry is a path bound at itself, or `SRC<TAB>DEST` to bind `SRC` at `DEST` inside; a `DEST` under an earlier entry layers on it, so order the entries parent first. |
| `profile_env_pass=(...)` | Environment variable names forwarded into the sandbox **if set** in the caller's environment, on top of the engine's own list (locale, proxy, CA, CUDA). The dot-file's `[env]` names add to it. |
| `profile_env_set=(...)` | `NAME=VALUE` pairs always set inside. The dot-file's `[env] NAME = VALUE` adds to it. |
| `profile_env_refuse=(...)` | Names a user may not forward with `[env]` or `AGENT_SANDBOX_FORWARD`: refused with a message. Names in `profile_env_set` are refused the same way, so a forward cannot override what the profile pins. |
| `profile_verbs=(...)` | (Or `[agent] verbs` in the dot-file.) Agent verbs that observe or manage a background service. The engine joins them into the role's running launch, where the service is, and never starts a launch for one: with none running, a verb in `profile_verbs_observe` answers that the role is not running (exit 0) and any other is refused. They get no briefing arguments. |
| `profile_verbs_observe=(...)` | (Or `[agent] verbs-observe`.) The subset of `profile_verbs` that only ask questions. |
| `profile_daemon_argv=(...)` | (Or `[agent] daemon`.) Argv tokens, in order, that mark the agent's background daemon. A process inside the role's launch whose arguments contain them holds the launch as a join does, so the role does not end while it runs (#123). |

Functions a profile defines:

| Function | Meaning |
|---|---|
| `profile_prepare()` | Optional. Runs right before the sandbox is assembled; create state files here. |
| `profile_slug()` | Optional. Called with a project directory; prints this agent's name for it in its own per-project state (claude: the directory under `~/.claude/projects/`). `{slug}` expands to it in the channel table, in a path declaration's key and in its `outside:` source (#176); without this hook a `{slug}` is refused. Any other `{name}` is refused too. |
| `profile_briefing_args()` | Optional. Called with the sandbox-side path of the briefing directory and the agent's argv when the briefing is on; append to `profile_briefing_argv` whatever makes the agent read it. The engine puts those arguments **before** the agent's own (a subcommand such as `claude mcp list` refuses an option of the agent's after it). To change the agent's own arguments -- claude drops the user's `--settings` once it has merged it into its own -- set `profile_agent_argv`, which starts as they were typed. Skipped when the briefing is off or could not be written. |
| `profile_route()` | Optional. Called with the agent's argv once the project's trusted `.agent-sandbox` is read, for a launch that is not a `--trust` review. Returns 0 to let the engine sandbox it, or runs the invocation itself and does not return. Inside a sandbox it is not reached: there the engine itself runs what an `asb` names as it is, with no second sandbox (#197). |
| `profile_before_join()` | Optional. Called with the agent's argv just before it is joined into the role's launch (not for `--exec`). The claude profile records workspace trust for a `--bg` there, which cannot answer the prompt. |

What the engine provides to a profile: `AGENT_SANDBOX_ENGINE` (real path of the
engine file), `AGENT_SANDBOX_PROFILE` (this profile's name),
`AGENT_SANDBOX_PROFILE_DIR`, and `_as_msg` for prefixed stderr messages.

### A dot-file section named after the profile

A project's `.agent-sandbox` may carry a section named after the **active**
profile — `[claude]` in a claude run. The engine checks its lines are `key = value`
and reads the one key a project may set there today, `hide`: paths under the
profile's base blanked every launch, on top of the profile's own `[agent] hide`
(relative paths only; `/` and `..` are ignored with a note). A profile allows it by
listing it in `profile_dotfile_keys`, which is also how the review knows to warn of
any other key — a typo must not silently do nothing. A section naming a different
profile is skipped at a launch; the dot-file's review reads every profile, and warns
of a section that names none. The pairs count **only from an approved dot-file**, so
an unreviewed file grants nothing; the trust gate is the engine's, not the profile's.
`profiles/claude/profile.sh` lists `hide` ([config.md](config.md#the-file)).

**A profile may ship a helper beside its script** for what bash does badly, such as
parsing the agent's own file formats. The claude profile's is `profile.py`, a
subcommand each: the config file's seed view, the prompt history's, the `--bg`
workspace trust, the `--settings` merge. The contract is still the bash hooks, and the
policy stays in them: the helper does one thing and exits nonzero when it cannot, and
the hook decides what a launch then does. `python3` is always there -- the engine
refuses a launch without it, since every command is joined by it -- so a hook needs no
second, bash version of what the helper does. The engine
gives the hook its directory as `profile_home` (what `{profile}` expands to), and the
installer copies the profile's directory whole.

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
| `[agent] verbs`, `verbs-observe`, `daemon`, `status` | `profile_verbs`, `profile_verbs_observe`, `profile_daemon_argv`, `profile_status_argv` (space-separated words) |
| `[agent] command` | `profile_command` |
| `[agent] base` | the agent's state directory (`~/.claude`), bound **read-write** before anything else, so every channel and declaration layers on it; created when absent; checked as any read-write bind is (never `/`, `$HOME` or a parent of it, nothing protected), and resolved again at bind time (#175) |
| `[agent] base-env` | the variable the agent itself reads to move its state (claude: `CLAUDE_CONFIG_DIR`); set and non-empty in the launching shell, it wins over `base` (#190). `{base}` in the dot-file is the base so resolved |
| `[agent] hide` | `profile_hide`: paths under the agent's state directory blanked every launch: a tmpfs each, empty inside and gone at exit |
| `[agent] visible` | `profile_visible`: paths under the agent's state directory deliberately left native, with a reason beside them, so that `asb --check` does not list them as unclassified (#82) |
| `[env]` | `NAME`: `profile_env_pass`; `NAME = VALUE`: `profile_env_set` (a leading `~` is `$HOME`, and `{base}` expands); `-NAME`: `profile_env_refuse` |
| `[allow]` | hosts opened for every launch of the profile, as its session allowlist beside `--allow`'s (proxy and strict) |
| `[channel:<name>]` | `profile_channels`, one section per channel and a path per line, a trailing `/` for a directory; a path's value sets `outside:SRC` (`profile_channel_sources`), `filter:FN` (`profile_channel_filters`) `vendor:PREFIX` (`profile_channel_vendor`) and `start:FILE` (`profile_channel_start`: the template a file store starts as with nothing to seed from). `{base}` and `{slug}` expand (#190). A `reach = HOW [-- note]` line (`profile_channel_reach`) says how what another session left there arrives in a session -- `context`, `searched`, `pointed` or `never`, the leak study's scale -- for `asb --check`; a channel without one is printed UNMEASURED, so write one only from a measurement. `create = yes` makes a connected channel's missing source directory on the host (mode 700) rather than an empty mount, so what the user writes there later reaches a running session (`profile_channel_create`); `login = FILE -- NOTE` names the file whose absence means the channel carries nothing yet, and the one sentence said at launch, by `--check` and in the briefing when it is missing (`profile_channel_login`); `env = NAME` sets NAME to the channel's path under every preset but native (`profile_channel_env`) |
| `[preset:<name>]` | `profile_channel_presets`: for `isolated`, `inherit` or `shared`, the channels whose rung is not the ladder's, in the `[connect]` grammar (`config = seed-only`) (#191) |

`[agent]` is the profile's own section. In a project's file the same section is
named after the profile (`[claude]`), and only the keys the profile lists in
`profile_dotfile_keys` are read there; the review warns of the rest, and of a
`[channel:<name>]`, which is a profile's. Other sections in a profile's dot-file are not
read yet: the launch says so.

## Adding a profile

1. Create `profiles/<name>/profile.sh` implementing the contract;
   `profiles/claude/profile.sh` is the reference and has the contract in its header.
2. Add `profiles/<name>/agent-sandbox`: the hosts the agent must reach under
   `[allow]`, and what else it can state as data (below).
3. Run `scripts/check.sh`, then `install.sh` (or `install.sh --dry-run` first):
   the installer reports the agent it finds on PATH.
   `asb <name>` then runs it.
4. Add tests under `tests/` for the profile's hooks.
5. Nothing in the engine should need to change. If it does, the contract is
   missing something; extend the contract (and this document) rather than
   special-casing a profile.

## The flagship: `claude`

`profiles/claude/profile.sh` runs Claude Code — whatever `claude` is on your PATH, from
the native installer or a package — binds `~/.claude` read-write and, inside
it at `~/.claude/.claude.json`, the project's own copy of `~/.claude.json`
(seeded and refreshed per launch, see [config.md](config.md)), with
`CLAUDE_CONFIG_DIR` pointing Claude Code there (it writes the file through a
lock directory and a temp file beside it, which the read-only `$HOME` refused;
the writes were then silently lost), forwards `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`, sets
`DISABLE_AUTOUPDATER=1`, refuses to forward `CLAUDE_CODE_PROJECT_DIR_NAME`, and
routes `update`, `upgrade` and `install` to the host (see
[updating.md](updating.md)).

## Roadmap profiles

`codex`, `gemini`, an `ollama`/OpenAI-compatible profile, and a generic
`command` profile that sandboxes an arbitrary worker with a scoped allowlist,
for orchestrating many agents.
