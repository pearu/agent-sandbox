# Profiles: adding an agent

The engine is provider-agnostic. Everything specific to one agent lives in a
profile, `profiles/<name>.sh`, sourced by the engine on the host after it has
parsed its own flags and before the sandbox exists. The engine runs with
`set -euo pipefail`; profile code is subject to it.

A profile is selected with `--profile NAME`, or inferred from `argv[0]` when
the engine is invoked through a symlink named after it. `install.sh` creates
`~/.local/bin/<profile_command>` for every profile it finds, so each agent keeps
its usual command name.

## The contract

Variables a profile declares (all optional unless marked):

| Variable | Meaning |
|---|---|
| `profile_command` | On-PATH name of the agent (default: the profile file's name). The installer symlinks `~/.local/bin/<profile_command>` at the engine. |
| `profile_config_binds=(...)` | Host paths bound **read-write** into the sandbox: the agent's state and config. They must exist when the sandbox is built; create them in `profile_prepare()`. |
| `profile_env_pass=(...)` | Environment variable names forwarded into the sandbox **if set** in the caller's environment, on top of the engine's own list (locale, proxy, CA, CUDA). |
| `profile_env_set=(...)` | `NAME=VALUE` pairs always set inside. |
| `profile_allowlist_seed` | Path of a file listing the hosts this agent must reach, in allowlist syntax. `install.sh` merges it into the global allowlist; the engine does not read it. |
| `profile_host_subcommands=(...)` | Agent subcommands the engine hands to `profile_handle_subcommand()` to run on the host, unsandboxed, instead of launching the sandbox (self-update, typically). |

Functions a profile defines:

| Function | Meaning |
|---|---|
| `profile_bin_discover()` | **Required.** Locate the agent executable: set `profile_bin` (path) and `profile_version` (for messages). On failure print why with `_as_msg` and return non-zero. |
| `profile_prepare()` | Optional. Runs right before the sandbox is assembled; create state files here. Not run for host-side subcommands. |
| `profile_handle_subcommand()` | Required iff `profile_host_subcommands` is non-empty. Receives the agent's full argv (`$1` is the subcommand); its return code is the exit code. |

What the engine provides to a profile: `AGENT_SANDBOX_ENGINE` (real path of the
engine file), `AGENT_SANDBOX_PROFILE` (this profile's name),
`AGENT_SANDBOX_PROFILE_DIR`, and `_as_msg` for prefixed stderr messages.

A profile must **not** touch the engine's bwrap argument list. The declarations
above are the whole interface, so that the sandbox's isolation guarantees stay
reviewable in one place, the engine.

## Adding a profile

1. Create `profiles/<name>.sh` implementing the contract; `profiles/claude.sh`
   is the reference and has the contract in its header.
2. Add `profiles/<name>.allowlist` with the hosts the agent must reach.
3. Run `scripts/check.sh`, then `install.sh` (or `install.sh --dry-run` first):
   the installer reports the agent binary via your `profile_bin_discover`,
   merges the seed hosts, and creates the symlink.
4. Add tests under `tests/` for discovery and for any host-side subcommands.
5. Nothing in the engine should need to change. If it does, the contract is
   missing something; extend the contract (and this document) rather than
   special-casing a profile.

## The flagship: `claude`

`profiles/claude.sh` runs Claude Code: it finds the newest install under
`~/.local/share/claude/versions/` (a single executable named after the version,
or a directory containing `claude`), binds `~/.claude` and `~/.claude.json`
read-write, forwards `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`, sets
`DISABLE_AUTOUPDATER=1`, and routes `update`, `upgrade` and `install` to the
host (see [updating.md](updating.md)).

## Roadmap profiles

`codex`, `gemini`, an `ollama`/OpenAI-compatible profile, and a generic
`command` profile that sandboxes an arbitrary worker with a scoped allowlist,
for orchestrating many agents.
