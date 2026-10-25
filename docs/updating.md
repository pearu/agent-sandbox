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

`asb claude update` is not special: it runs inside the sandbox like any other
command, where the download is blocked and the versions directory is not bound,
so it fails. Type `claude update` at your shell.

Updating agent-sandbox itself: pull the repository and re-run `./install.sh`.
It is idempotent, keeps your allowlist edits, and
replaces the addon, the unit, and the installed copy of the engine and
profiles with the current ones. A plain `git pull` alone does not take effect:
the command runs from the copy under `~/.local/share/agent-sandbox`, not from
the checkout, so the re-run is what promotes your pull. (If you installed with
`--dev`, `asb` points at the checkout and a pull is live immediately.)

The same re-run updates the tools environment sandboxes find on PATH (`gh` by
default): `./install.sh` rebuilds it from conda-forge every time, so its packages are
the newest conda-forge has. A change to the list in `~/.config/agent-sandbox/tools.txt`
takes effect at that run too. A failed rebuild (no network, a spec conda-forge cannot
solve) warns and leaves the previous environment in place; the log of the failed run is
`~/.local/share/agent-sandbox/tools/<slot>.log`.
