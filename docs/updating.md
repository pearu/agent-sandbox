# Updating the agent

Inside the sandbox an agent cannot update itself: the egress allowlist blocks
its download host, its install directory is not bound, and for Claude Code
`DISABLE_AUTOUPDATER=1` is set so a session never tries on its own.

For an agent asb installs (#6) -- Claude Code -- `asb claude` runs asb's own install,
the version the profile pins, never the `claude` on your PATH. Install it once, and
again to move to another version:

```
asb --install claude            # the profile's pinned version
asb --install claude@2.1.330    # another; one the profile was not tested with is said untested
```

Each version is kept beside the others under
`~/.local/state/agent-sandbox/claude/install/`, and the last one installed is the one
launches run (`install/current`); a running role keeps the one it started with. A new
asb release may pin a newer version: run `asb --install claude` after updating asb.

**Upgrading from an asb before #6:** those ran whatever `claude` your PATH found. Now
`asb claude` refuses until you run `asb --install claude` once, and says so. Your own
Claude Code is not touched, and `claude` at your shell is still it, updated the way
its installer says (`claude update`). A binary of your own still runs in the sandbox
by its path: `asb --profile claude /path/to/claude`.

`asb claude update` is not special: it runs inside the sandbox like any other
command, where the download is blocked and the version's directory is read-only,
so it fails. Use `asb --install claude`.

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
