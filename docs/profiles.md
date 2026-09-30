# Profiles: adding an agent

The engine is provider-agnostic. Everything specific to one agent lives in a
profile, `profiles/<name>.sh`, sourced by the engine on the host after it has
parsed its own flags and before the sandbox exists. The engine runs with
`set -euo pipefail`; profile code is subject to it.

The engine is asked for by name, and the agent is its command:
`asb [OPTIONS] CMD [AGENT OPTIONS]` (#151). The profile is CMD's basename
(`asb codex` → `profiles/codex.sh`), or `--profile NAME` when the binary is
called otherwise (`asb --profile claude /path/to/2.1.284`). The agent that runs
is CMD itself — looked up on PATH, or the path given — resolved through its
symlinks; the profile does not find it. Nothing is installed at the agent's own
name, so the agent's command stays the agent.

## The contract

Variables a profile declares (all optional unless marked):

| Variable | Meaning |
|---|---|
| `profile_command` | On-PATH name of the agent (default: the profile file's name): what the engine runs when no command is typed — a verb (`asb --profile NAME --status`) or `--exec`. |
| `profile_config_binds=(...)` | Host paths bound **read-write** into the sandbox: the agent's state and config. They must exist when the sandbox is built; create them in `profile_prepare()`. An entry is a path bound at itself, or `SRC<TAB>DEST` to bind `SRC` at `DEST` inside; a `DEST` under an earlier entry layers on it, so order the entries parent first. |
| `profile_env_pass=(...)` | Environment variable names forwarded into the sandbox **if set** in the caller's environment, on top of the engine's own list (locale, proxy, CA, CUDA). |
| `profile_env_set=(...)` | `NAME=VALUE` pairs always set inside. |
| `profile_env_refuse=(...)` | Names a user may not forward with `[forward]` or `AGENT_SANDBOX_FORWARD`: refused with a message. Names in `profile_env_set` are refused the same way, so a forward cannot override what the profile pins. |
| `profile_allowlist_seed` | Path of a file listing the hosts this agent must reach, in allowlist syntax. `install.sh` merges it into the global allowlist; the engine does not read it. |
| `profile_host_subcommands=(...)` | Agent subcommands the engine hands to `profile_handle_subcommand()` to run on the host, unsandboxed, instead of launching the sandbox (self-update, typically). |
| `profile_verbs=(...)` | Agent verbs that observe or manage a background service. The engine joins them into the role's running launch, where the service is, and never starts a launch for one: with none running, a verb in `profile_verbs_observe` answers that the role is not running (exit 0) and any other is refused. They get no briefing arguments. |
| `profile_verbs_observe=(...)` | The subset of `profile_verbs` that only ask questions. |
| `profile_daemon_argv=(...)` | Argv tokens, in order, that mark the agent's background daemon. A process inside the role's launch whose arguments contain them holds the launch as a join does, so the role does not end while it runs (#123). |

Functions a profile defines:

| Function | Meaning |
|---|---|
| `profile_prepare()` | Optional. Runs right before the sandbox is assembled; create state files here. Not run for host-side subcommands. |
| `profile_handle_subcommand()` | Required iff `profile_host_subcommands` is non-empty. Receives the agent's full argv (`$1` is the subcommand); its return code is the exit code. |
| `profile_memory_scope()` | Optional. Called with the resolved mode (`scoped`/`shared`) and the approved share paths. In `scoped` mode, hide the agent's per-project state and rebind the current project plus each share. Without it, a `scoped` setting is reported as ignored rather than silently doing nothing. |
| `profile_isolate()` | Optional. Declare which of the agent's cross-session state is replaced per launch, by filling `profile_isolate_spec` with `tmpfs<TAB>DIR` lines: empty inside, discarded at exit. (`copyout` and `append`, which merged a session's entries back at exit, are gone since #120: state that should outlive a launch is a channel, with a mode.) Pairs from a `[<profile>]` dot-file section arrive in `profile_dotfile` (below). |
| `profile_briefing_args()` | Optional. Called with the sandbox-side path of the briefing directory and the agent's argv when the briefing is on; append to `profile_briefing_argv` whatever makes the agent read it. Skipped when the briefing is off or could not be written. |
| `profile_route()` | Optional. Called with the agent's argv once the project's trusted `.agent-sandbox` is read, for a launch that is not a `--trust` review. Returns 0 to let the engine sandbox it, or runs the invocation itself and does not return (the claude profile: an `asb claude` typed inside a sandbox runs in it as it is). |
| `profile_before_join()` | Optional. Called with the agent's argv just before it is joined into the role's launch (not for `--exec`). The claude profile records workspace trust for a `--bg` there, which cannot answer the prompt. |

What the engine provides to a profile: `AGENT_SANDBOX_ENGINE` (real path of the
engine file), `AGENT_SANDBOX_PROFILE` (this profile's name),
`AGENT_SANDBOX_PROFILE_DIR`, and `_as_msg` for prefixed stderr messages.

### A dot-file section named after the profile

A project's `.agent-sandbox` may carry a section named after the **active**
profile — `[claude]` in a claude run. The engine does not interpret those
lines: it checks they are `key = value`, collects them, and hands them to the
profile in `profile_dotfile` (a `key=value` array) for the duration of
`profile_isolate()`. A section naming a different profile is skipped at a launch;
the dot-file's review reads every profile, and warns of a section that names none
and of a key a profile does not list in `profile_dotfile_keys`.

This exists because only a profile knows what its agent keeps where. List the
keys you read in `profile_dotfile_keys`, so the review can warn of any other — a
typo must not silently do nothing. The pairs reach you **only from an approved dot-file**, so
an unreviewed file grants nothing; the trust gate is the engine's, not yours.
`profiles/claude.sh` uses it for one key, `hide`
([config.md](config.md#the-file)).

A profile must **not** touch the engine's bwrap argument list. The declarations
above are the whole interface, so that the sandbox's isolation guarantees stay
reviewable in one place, the engine.

## Adding a profile

1. Create `profiles/<name>.sh` implementing the contract; `profiles/claude.sh`
   is the reference and has the contract in its header.
2. Add `profiles/<name>.allowlist` with the hosts the agent must reach.
3. Run `scripts/check.sh`, then `install.sh` (or `install.sh --dry-run` first):
   the installer reports the agent it finds on PATH and merges the seed hosts.
   `asb <name>` then runs it.
4. Add tests under `tests/` for the profile's hooks and any host-side subcommands.
5. Nothing in the engine should need to change. If it does, the contract is
   missing something; extend the contract (and this document) rather than
   special-casing a profile.

## The flagship: `claude`

`profiles/claude.sh` runs Claude Code — whatever `claude` is on your PATH, from
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
