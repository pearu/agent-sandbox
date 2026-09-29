# Updating the agent

Inside the sandbox an agent cannot update itself: the egress allowlist blocks
its download host, its install directory is not bound, and for Claude Code
`DISABLE_AUTOUPDATER=1` is set so a session never tries on its own.

Update it outside the sandbox, the way its own installer tells you to. For
Claude Code that is simply

```
claude update      # alias: upgrade
```

— `claude` is Claude Code itself, not agent-sandbox (#151), so this is its own
updater, run as it would be without agent-sandbox installed. `asb claude` then
runs whatever `claude` is next time.

For convenience the profile also lists these subcommands as host-side, so that
`asb claude update` (and `upgrade`, `install [target]`) does the same thing: the
engine runs the agent directly on the host, unsandboxed, with your full
environment, instead of starting a sandbox that could not do it. The engine's
`--ssh*` and `--allow` flags are ignored for them, with a note.

Updating agent-sandbox itself: pull the repository and re-run `./install.sh`.
It is idempotent, keeps your allowlist edits, migrates older layouts, and
replaces the addon, the unit, and the installed copy of the engine and
profiles with the current ones. A plain `git pull` alone does not take effect:
the command runs from the copy under `~/.local/share/agent-sandbox`, not from
the checkout, so the re-run is what promotes your pull. (If you installed with
`--dev`, `asb` points at the checkout and a pull is live immediately.)
