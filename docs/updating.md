# Updating the agent

Inside the sandbox an agent cannot update itself: the egress allowlist blocks
its download host, its install directory is not bound, and for Claude Code
`DISABLE_AUTOUPDATER=1` is set so a session never tries on its own.

Profiles therefore list the subcommands that must run on the host. For the
`claude` profile:

```
claude update      # alias: upgrade
claude install [target]
```

The engine runs these with the newest installed binary directly on the host,
unsandboxed, with your full environment. The engine's `--ssh*` and `--allow`
flags are ignored for them, with a note.

The native updater installs the new release under
`~/.local/share/claude/versions/<version>`. The profile always runs the highest
version found there, so the update takes effect on the next launch. As of
Claude Code 2.1.263 the updater refuses to overwrite a launcher at
`~/.local/bin/claude` that is not its own `versions/` symlink (it logs
"Not replacing ..." and still reports success), so the engine stays on PATH.
Should an installer re-point the launcher anyway, the engine restores it right
after the subcommand finishes and says so.

Because the launcher is not installer-managed, Claude Code skips its automatic
cleanup of old versions (about 215 MB each). Prune by hand:

```
ls ~/.local/share/claude/versions/     # then remove the ones you don't need
```

Updating agent-sandbox itself: pull the repository and re-run `./install.sh`.
It is idempotent, keeps your allowlist edits, migrates older layouts, and
replaces the addon and unit with the current ones.
