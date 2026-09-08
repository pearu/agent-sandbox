# AGENTS.md — rules for AI maintainers of agent-sandbox

This file is the canonical guide for any AI agent (Claude Code, Codex, Gemini,
...) working on this repository. `CLAUDE.md` just points here. Humans are
welcome to read it too; the human-facing docs live in `README.md` and `docs/`.

agent-sandbox runs an AI coding agent inside a bubblewrap sandbox with a
default-deny filesystem, an egress allowlist enforced by a host-side mitmproxy,
host-routed self-update, and an opt-in SSH broker whose keys never enter the
sandbox. It is a security tool. Treat every change to it as one.

## Layout and what is source of truth

| Path | Role |
|---|---|
| `agent-sandbox` | The engine (bash). Provider-agnostic: bwrap layout, network modes, CA handling, SSH broker + janitor, conda passthrough, launch. Security-sensitive. |
| `profiles/<name>.sh`, `profiles/<name>.allowlist` | One provider profile per agent. `profiles/claude.sh` is the flagship and documents the profile contract in its header. |
| `components/` | The files the installer places on a host: the mitmproxy allowlist addon, the starter allowlist, the systemd unit template, AppArmor profiles. **Source of truth.** |
| `install.sh.in` | The installer template, with `@@INCLUDE components/...@@` markers. **Source of truth.** |
| `install.sh` | **Generated** by `scripts/bundle.sh` from the two above. Never edit it by hand; edit the template or a component and rebundle. It is committed so `curl -fsSL .../install.sh | bash` works from one self-contained file. A normal run copies the engine + profiles under `~/.local/share/agent-sandbox/app` and points the launcher there (a true install, source-independent); `--dev` symlinks the launcher at the checkout for development. |
| `scripts/bundle.sh` | Regenerates `install.sh`. Idempotent. |
| `scripts/check.sh` | Every check CI's `check` job runs. Run it before committing. |
| `docs/config.md` | The per-project `.agent-sandbox` file (trust-gated), and per-project memory scoping. Trust store and global config under `~/.config/agent-sandbox`, never bound in. |
| `.github/workflows/ci.yml` | CI: `check` (scripts/check.sh), `integration` and `e2e` on Ubuntu 22.04, 24.04 and 26.04, and an allowed-to-fail `e2e-real-systemd` experiment. |
| `environment.yml` | The development tooling env (`agent-sandbox` mamba env): git-filter-repo, shellcheck, shfmt. Anything you install into that env for development goes in here, so the env can be recreated. |
| `docs/` | Design, threat model and residual risks (`docs/design.md`), network, SSH, profiles, prior art, troubleshooting. The trust surface for users. |
| `tests/` | bats suites, run with `tests/run.sh`: `unit/` (engine helpers, flags, the bwrap argv, the claude profile, the proxy addon with a stubbed mitmproxy, the installer's dry run), `integration/` (the real bwrap with a probe profile; `memory.bats` scopes per-project memory with the claude profile), `live/` (opt-in, real network and the host's proxy), `e2e/` (opt-in: `install.sh` for real against a throwaway HOME with a fake Claude binary and a `systemctl` shim, then the installed launcher through the installed proxy). Harness in `tests/helpers/`. |

## The engine is security-sensitive

Anything that changes what the sandbox can see or reach is a security change:
bwrap arguments and their order, binds and tmpfs mounts, the environment
allowlist, network modes and proxy settings, CA handling, the SSH broker and
janitor, session liveness stamps, the refusal rules for CWD and RO/RW paths.
For such a change:

1. **Add or extend a test** that fails without the change. Behaviour-identity
   matters: the bwrap argv the engine produces for a given input is the
   contract. A stub `bwrap` that dumps its argv is the standard harness.
2. **Update the residual-risk list** in `docs/design.md` if the change adds,
   removes or moves a risk. Say plainly what an adversary inside the sandbox
   can still do.
3. **Never weaken a default silently.** Read-only is the default for
   everything the agent did not explicitly get; new capabilities are opt-in
   flags or knobs, documented in the engine header and the docs.
4. **Verify claims empirically, in this repo's own tooling.** Do not assume a
   tool honours an environment variable or that a proxy option is safe: test it
   against a local mitmdump, a nested bwrap, or a stub. Several facts below were
   found only that way.
5. **Do not bypass the sandbox you are working in.** If you are running inside
   agent-sandbox, the egress allowlist is the user's control. Never reach a
   non-allowed host with `curl --noproxy`, raw sockets, or similar, even to
   "just check something". Ask for `--allow HOST` or ask the user to look.

## Validate before you commit

```
scripts/check.sh
```

runs: `bash -n` on every shell file; `shellcheck -x`; `shfmt -d .` (style comes
from `.editorconfig`: 2-space indent, indented `case` items, binary operators
at line start); `python3 -m py_compile components/*.py`; a bundle-sync check
(`install.sh` must equal what `scripts/bundle.sh` produces); and
`install.sh --dry-run` against a throwaway `HOME`. Fix formatting with
`shfmt -w .`, never by hand-aligning. `scripts/check.sh` runs the unit and
integration suites when `bats` is on PATH; `tests/run.sh unit|integration|live|all`
runs them directly, and `AGENT_SANDBOX_LIVE=1` enables the live tests.
`scripts/coverage.sh` reports line coverage: coverage.py for the addon (from
`environment.yml`) and kcov for the engine (a system package, `apt install
kcov` — not on conda-forge). The engine run needs bwrap/pasta for the
integration suites, so run it where those work.

### How the tests work

- **Unit suites never run bwrap.** `tests/helpers/common.bash` builds a fake
  HOME with a stub agent binary and a stub `bwrap` that dumps its argv to a
  file; `run_engine` launches the engine with a clean environment and loads that
  argv into `ARGV`, so tests assert on binds, order and `--setenv` pairs
  (`argv_has`, `setenv_value`, `argv_index`). Helper-level tests `source` the
  engine and call the `_as_*` functions directly.
- **Integration suites use the real bwrap** through a test profile whose
  "agent" is a probe script (`AGENT_SANDBOX_TEST_BIN`) that writes key=value
  lines to `$PWD/report` from inside the sandbox. They `skip` when unprivileged
  user namespaces are unavailable. SSH tests need a short session base because
  of the unix-socket path limit; `make_short_base` provides one.
- **The installer is tested for real, end to end** (`AGENT_SANDBOX_E2E=1`): a
  fake Claude binary (`tests/helpers/fake-claude.sh`) is planted where the
  profile discovers it, `systemctl --user` is a shim
  (`tests/helpers/systemctl-shim.sh`) that records calls and runs the unit's
  ExecStart itself, and the installed launcher then runs the fake agent through
  the installed proxy. The proxy-dependent tests need port 8888 free and skip
  otherwise, which is the case on a machine that already runs the proxy;
  `AGENT_SANDBOX_E2E_MITMDUMP=/path/to/mitmdump` skips the pip install.
- **The addon is tested without mitmproxy**: `tests/helpers/mitmproxy_stub.py`
  stands in for `mitmproxy.http`, and `addon_driver.py` runs one scenario.
- **A test must fail when the bug it guards is re-introduced.** Check that with
  a mutation: copy `agent-sandbox` into a directory that has a `profiles`
  symlink to the repo's, re-introduce the bug there, and run the guarding test
  with `AGENT_SANDBOX_TEST_ENGINE=/path/to/copy` (`AGENT_SANDBOX_TEST_ADDON` for
  the addon). Run the unmutated copy first: if that fails, the harness, not the
  test, is what you are measuring. The suites were checked this way against
  the start-time regression, the path guards, `--remount-ro`, `--clearenv`,
  the CA bind, conda write mode, sharing the network in `none` mode, exposing
  `~/.ssh`, and the addon's liveness, CONNECT and suffix logic.

## Conventions

- **Naming.** Anything generic says `agent` (`agent-sandbox`, `AGENT_SANDBOX_*`,
  `~/.config/agent-sandbox`, `agent-sandbox-mitmproxy.service`). Only genuinely
  Claude-specific things say `claude`: the `claude` profile and its files,
  `~/.claude`, `~/.claude.json`, `versions/`, `ANTHROPIC_*`, the `claude` command
  and symlink.
- **Shell.** bash 4.4+ (`local -n`, `${!var+x}`). `set -euo pipefail` inside the
  engine function. Helpers live at top level so tests can `source` the engine
  and call them. Messages go through `_as_msg`. Keep `IFS` changes inside a
  helper (`_as_split`); a `local IFS` in the main function leaks to everything
  after it.
- **Commits.** Imperative subject, a body that says why and what was verified,
  one logical change per commit. An AI-authored commit ends with
  `Co-Authored-By: <model name> <noreply@anthropic.com>` (or the equivalent for
  the agent in use). Keep commits local until the human has reviewed the
  messages; nothing is pushed without explicit approval.
- **Outward text.** Anything published under the human's name (issue and PR
  comments, PR bodies, review comments, commit messages that get pushed) is
  drafted, shown, and approved before it goes out. Such posts end with
  `_🤖 Drafted by Claude Code (an AI agent) and reviewed & approved by <human>._`
  (name the agent actually used). Never emit a bare `@username`; it notifies a
  real account and cannot be unsent. If a draft changes materially after
  approval, ask again.
- **Decisions belong to the human.** Present options with their trade-offs and
  measurements; do not proceed on a design-shaping choice without a call.
  Routine judgement calls are fine to make and state.

## Working from inside agent-sandbox

If you are an agent running inside this sandbox while maintaining it:

- `~/.config`, the host journal, `~/.mitmproxy`, and the session directory
  files other than the agent socket are **not visible**. The live addon,
  allowlist, `blocked.log` and per-session `allow.txt` are host-side; when you
  need them, write a small read-only script to a bound path (`~/.claude/` or
  the working directory) and ask the human to run it, then delete it.
- `/tmp` is a fresh tmpfs per session; scratch work does not survive a relaunch.
- Installing into the active conda env needs a launch with
  `AGENT_SANDBOX_CONDA_WRITE=1`; the base install stays read-only. Record
  what you installed in `environment.yml`.
- Nested bwrap works, so integration checks against the real engine are
  possible from inside.
- The sandbox trusts the proxy CA only through the bundle the engine binds at
  launch. Do not change the host's CA state mid-session; relaunch instead.
- When you have guessed wrong twice, stop guessing and get ground truth from
  the host.
- The engine and profiles you edit here are the checkout; a normal install
  runs a *copy* under `~/.local/share/agent-sandbox`, so your edits reach a
  real `claude` launch only after the human re-runs `install.sh`. Under
  `--dev` they are live at the next launch — do not rely on either; test with
  the bats suites, which run the checkout's engine directly.

## Decided; do not re-litigate (and the roadmap)

- **Multi-provider engine + profiles**; `claude` is the flagship profile.
  Roadmap profiles: `codex`, `gemini`, `ollama`/OpenAI-compatible, and a
  generic `command` profile for arbitrary workers.
- **Proxy runtime**: mitmproxy 12+ in a private environment under
  `~/.local/share/agent-sandbox`, venv + pip preferred, conda/mamba fallback.
  Distro packages are too old (Ubuntu 24.04 and 26.04 ship 8.1.1, whose leaf
  certificates lack an Authority Key Identifier and fail Python 3.13's strict
  verification).
- **Roadmap: standalone mitmproxy binary route.** `downloads.mitmproxy.org`
  serves `mitmproxy-<ver>-linux-<arch>.tar.gz` (~119 MB) but publishes no
  checksums or signatures, so a secure route must pin a SHA256 per version and
  architecture in this repo. Deliberately not implemented: narrow audience
  (no `python3-venv` and no conda), maintenance per release, not CI-testable.
  Handled at the documentation level instead: `docs/troubleshooting.md` tells a
  user on such a host how to get a Python venv or conda so the installer can
  build the proxy environment.
- **Roadmap: a no-systemd mode.** Claude Code runs under WSL and in
  devcontainers; WSL without systemd would need the proxy started another way,
  and containers additionally block bwrap's user namespaces under Docker's
  default seccomp profile. An installer flag is a few lines, but the lifecycle
  it implies (start at login, restart on failure, where the log goes) is not.
  Deliberately deferred; the end-to-end test uses a `systemctl` shim instead.
- **CA trust is sandbox-only**: the engine binds (system bundle + proxy CA)
  over `/etc/ssl/certs/ca-certificates.crt` inside the sandbox. No system-wide
  trust, no sudo for it. Kept over TLS passthrough (SNI-only allowlisting) after
  measuring both: interception keeps per-path logging and 403 bodies, and it
  is near-native speed with `http2=false` plus response streaming.
- **Proxy options that are unsafe here**: `stream_large_bodies` streams request
  bodies too, and then the allowlist hook runs after the upstream connect.
  Stream responses in `responseheaders`; refuse blocked hosts in `http_connect`.
- **bubblewrap stays a distro package.** Ubuntu 24.04+ needs root once for the
  bwrap AppArmor profile anyway; that and the package are the only sudo steps.
- **install.sh is a true install (copy), not an in-place symlink.** It copies
  the engine and profiles under `~/.local/share/agent-sandbox/app` and points
  the launcher there, so the installed command does not depend on the checkout
  (delete it and the command still works) and an edit to a checked-out engine
  or profile is inert until the next `install.sh`. `--dev` keeps the old
  symlink-into-the-checkout for people developing agent-sandbox; it warns that
  edits there — including any a sandboxed agent makes to a checkout it has as
  CWD — run on the host at the next launch. This is why a from-inside edit to
  the engine is not a live host-code path under a normal install.
- **No backwards-compatibility aliases** for renamed knobs; the project has no
  compatibility surface yet.
- **Strict network mode** is implemented with pasta: it owns an isolated netns,
  bwrap runs inside sharing it, and an nftables rule allows only the proxy on
  the gateway, closing the raw-socket loophole. Needs `passt` + its AppArmor
  profile; `--ssh` is unavailable there. A seccomp/firejail backend and the
  SNI/tls_passthrough evaluation are recorded as open design questions in
  `docs/design.md`.

## Pitfalls that already cost time

- `$BASHPID` inside `$(...)` is the substitution's subshell. Capture it in a
  variable first. Getting this wrong made every session look dead to the
  liveness checks.
- Claude Code's binary ignores `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE`; it
  reads `/etc/ssl/certs/ca-certificates.crt`. conda, mamba, pip and a conda
  git each have their own CA setting; the engine sets them all.
- mitmproxy buffers response bodies and its HTTP/2 path is pure Python; both
  are off by design here. Its log is block-buffered when redirected to a file:
  read it after the process exits, or set `PYTHONUNBUFFERED=1`.
- A bind mount over a file is hidden by any later bind of a parent directory;
  bind the parent first (the conda base install before the env inside it).
- `install.sh`'s smoke test must judge by status code: api.anthropic.com
  answers 404 for `/` and 401 without a key; both mean the proxy forwarded.
