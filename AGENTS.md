# AGENTS.md — rules for AI maintainers of agent-sandbox

This file is the canonical guide for any AI agent (Claude Code, Codex, Gemini,
...) working on this repository. `CLAUDE.md` just points here. Humans are
welcome to read it too; the human-facing docs live in `README.md` and `docs/`.

agent-sandbox runs an AI coding agent inside a bubblewrap sandbox with a default-deny
filesystem, an egress allowlist enforced by a host-side mitmproxy, and an opt-in SSH
broker whose keys never enter the sandbox. It is a security tool. Treat every change to
it as one.

## Layout and what is source of truth

| Path | Role |
|---|---|
| `agent-sandbox` | The engine (bash). Provider-agnostic: bwrap layout, network modes, CA handling, SSH broker + janitor, conda passthrough, launch. Security-sensitive. |
| `profiles/<name>/profile.sh`, `profiles/<name>/agent-sandbox` | One provider profile per agent: its script and its own dot-file (#181). `profiles/claude/` is the flagship; `profile.sh` documents the profile contract in its header. |
| `components/` | The files the installer places on a host: the mitmproxy allowlist addon, the starter allowlist, the systemd unit template, AppArmor profiles. **Source of truth.** |
| `install.sh.in` | The installer template, with `@@INCLUDE components/...@@` markers. **Source of truth.** |
| `install.sh` | **Generated** by `scripts/bundle.sh` from the two above. Never edit it by hand; edit the template or a component and rebundle. It is committed so `curl -fsSL .../install.sh | bash` works from one self-contained file. A normal run copies the engine + profiles under `~/.local/share/agent-sandbox/app` and points the launcher there (a true install, source-independent); `--dev` symlinks the launcher at the checkout for development. |
| `scripts/bundle.sh` | Regenerates `install.sh`. Idempotent. |
| `scripts/check.sh` | Every check CI's `check` job runs. Run it before committing. |
| `docs/config.md` | The per-project `.agent-sandbox` file (trust-gated), and per-project memory scoping. Trust store and global config under `~/.config/agent-sandbox`, never bound in. |
| `.github/workflows/ci.yml` | CI: `check` (scripts/check.sh), `integration` and `e2e` on Ubuntu 22.04, 24.04 and 26.04, an allowed-to-fail `e2e-real-systemd` experiment, a `coverage` job (kcov + coverage.py -> Codecov badge), and `ci-ok`, the gate that needs every job that must pass: the ruleset on main requires it alone, so its name never changes and a new required job goes in its `needs`. |
| `environment.yml` | The development tooling env (`agent-sandbox` mamba env): git-filter-repo, shellcheck, shfmt. Anything you install into that env for development goes in here, so the env can be recreated. |
| `docs/` | Design, threat model and residual risks (`docs/design.md`), network, SSH, profiles, prior art, troubleshooting. The trust surface for users. |
| `tests/` | bats suites, run with `tests/run.sh`: `unit/` (engine helpers, flags, the bwrap argv, the proxy addon with a stubbed mitmproxy, the installer's dry run), `integration/` (the real bwrap with a probe profile), `live/` (opt-in, real network and the host's proxy), `e2e/` (opt-in: `install.sh` for real against a throwaway HOME with a fake agent per profile and a `systemctl` shim, then the installed launcher through the installed proxy). In each layer, `profile-contract.bats` runs for every profile with a test adapter (`profiles/<name>/test.bash`), and `profile-<name>/` holds that profile's own tests (the claude profile's under real bwrap: accounts, config file, isolation, memory). Harness in `tests/helpers/`. |

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
`environment.yml`) and kcov for the engine. kcov is not on conda-forge nor in
Ubuntu 24.04's repos — build it from source
(<https://github.com/SimonKagstrom/kcov>, see its `INSTALL.md`); `coverage.sh`
prints the build deps if it is missing. The engine run needs bwrap/pasta for
the integration suites, so run it where those work. The engine's Python components
(`join.py`, `connect-sync.py`) are measured in the same stages: the engine runs them
through `AGENT_SANDBOX_TEST_PYTHON` (`_as_python`; tests that run one directly use
`python_cmd`), which the stages set to `tests/helpers/coverage_run.py`; the data goes
to `engine-runs/<stage>/py/`, and `engine-merge` combines it into
`coverage-out/components-coverage.xml`. CI uploads the reports to Codecov, where
`codecov.yml` splits them per component (engine, proxy addon, Python components, claude
profile); every status is informational, and the README badge is the only overall
number.

### How the tests work

- **Unit suites never run bwrap.** `tests/helpers/common.bash` builds a fake
  HOME with a stub agent binary and a stub `bwrap` that dumps its argv to a
  file; `run_engine` launches the engine with a clean environment and loads that
  argv into `ARGV`, so tests assert on binds, order and `--setenv` pairs
  (`argv_has`, `setenv_value`, `argv_index`). Helper-level tests `source` the
  engine and call the `_as_*` functions directly.
- **Integration suites use the real bwrap** through a test profile whose "agent" is a
  probe script, the command `probe` on the harness's PATH (so a launch reads
  `-- [ENGINE FLAGS] probe [ARGS]`, as a user's `asb … claude` does), that writes
  key=value lines to `$PWD/report` from inside the sandbox. They `skip` when
  unprivileged user namespaces are unavailable. SSH tests need a short session base
  because of the unix-socket path limit; `make_short_base` provides one.
- **Two kinds of tests: shared and agent-only.** A test that is the same for every agent
  is written once and runs once per profile **test adapter**,
  `profiles/<name>/test.bash` (its contract is at the top of
  `profiles/claude/test.bash`): `tests/<layer>/profile-contract.bats` in unit and
  integration, `tests/live/agent.bats`, and the agent block of `tests/e2e/install.bats`
  register their tests per adapter with
  `bats_test_function --description "<agent>: ..."` (`tests/helpers/adapters.bash`). The
  adapter says only what the profile does not: where its binary is planted (asb's
  install of it for a profile with an install recipe, `install_fake_agent`; else its
  installer's layout), its options that come before a subcommand, its base's layout for
  `--check`, a fake login of its shape, and its live turn. What the profile states --
  base, hide list, resume, clear and login words, account paths -- the tests read the
  engine's way (`_as_profile_facts`, the dot-file; `profile_facts`, `profile_get`). The
  agent is the shared fake, `tests/helpers/fake-agent.sh`, whose words (`--version`,
  `fetch URL`, `env`, `args`, `sh`, `--bg`) are the tests' own. A test only one agent
  can have goes under `tests/<layer>/profile-<name>/`. **A new profile adds its adapter
  and its `profile-<name>/` directories, and changes no shared test**; if a shared test
  needs to change for it, the adapter contract is missing something -- extend it (and
  the claude adapter) instead. The unit suites' many `asb claude` launches are not
  agent-only tests: they test the engine with claude as the vehicle, and stay.
- **Inside a sandbox the suites run with host-only skips.** A role developing asb
  (the `github` model's gh-setup, gh-review and gh-fix) runs `tests/run.sh` inside
  its sandbox. A test of what only the host does -- `--login`, `--install`,
  `--set-default-agent`, `--setup-remote`, the dot-file gate against a faked marker,
  `probes/orphans.sh`, which inside would kill the role's own keeper -- calls
  `require_host REASON` (`tests/helpers/common.bash`), which skips it with "runs only
  on the host: REASON" when the engine's own test (`_as_maybe_inside`: the
  `AGENT_SANDBOX` marker or pid 1 being bubblewrap) says the suite is inside one; on the
  host it runs as ever. bats reports each skip (`ok N ... # skip REASON`, and the
  count in its summary), so the number skipped is visible. Use it only for behaviour
  that is the host's; a test that can run inside is adjusted instead. A change that
  touches a host-only path still needs a run on the host, or CI (which runs there).
- **The installer is tested for real, end to end** (`AGENT_SANDBOX_E2E=1`): every
  adapter plants the shared fake agent where a launch runs it from (claude: installed as
  `asb --install claude` installs it, #6) before `install.sh` runs, `systemctl --user`
  is a shim (`tests/helpers/systemctl-shim.sh`) that records calls and runs the unit's
  ExecStart itself, and the installed `asb CMD` then runs each fake agent through the
  installed proxy. The proxy-dependent tests use the port the throwaway install recorded
  (8888, or the next free one on a machine that already runs the proxy);
  `AGENT_SANDBOX_E2E_MITMDUMP=/path/to/mitmdump` skips building the proxy env.
- **The addon is tested without mitmproxy**: `tests/helpers/mitmproxy_stub.py`
  stands in for `mitmproxy.http`, and `addon_driver.py` runs one scenario.
- **Assert a negative with `run ! cmd`, never `! cmd`.** Bash suppresses `errexit` --
  and the `ERR` trap bats fails on -- for a negated command, so a test body of `! true`
  followed by anything else is reported `ok`: the line reads like a guarantee and
  enforces nothing. Fifty of them had accumulated here before anyone noticed, two
  asserting the opposite of what the engine does. `run !` (bats >= 1.5.0; the suites
  declare 1.11.0, for `bats_test_function`, in `tests/helpers/common.bash`) fails the
  test when the command succeeds. It replaces `$status` and `$output`, so check a
  message *before* the `run !` that follows it. `[ ! -s "$f" ]` is fine; there the
  negation is the test operator's own. ShellCheck reports the bad form as SC2314, and
  `scripts/check.sh` runs ShellCheck on the `.bats` files -- that is the actual guard;
  the rule here is so you know why it fires. SC2314 does not see a function registered
  with `bats_test_function` (the shared profile-contract, live and e2e agent tests) as a
  test, so `scripts/check.sh` also greps every `.bats` file for a line starting with
  `! `, which is the guard there.
- **GitHub's runners have conda on PATH.** A test that assumes no host conda must
  stub `conda` and `mamba` (exit 1, first on PATH) and clear `CONDA_*`/`MAMBA_*`
  from the environment it runs the engine or installer with. Under `env -i` on a
  dev box nothing is found, so such a test passes locally by accident.
- **A test must fail when the bug it guards is re-introduced.** Check that with
  a mutation: copy `agent-sandbox` into a directory that has a `profiles`
  symlink to the repo's and a copy (never a link) of its `models` and `components`
  (`init.bats` copies the engine's `models` and writes in the copy), re-introduce the
  bug there, and run the guarding test
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
  `~/.claude`, `~/.claude.json`, `versions/`, `ANTHROPIC_*`, the `claude`
  command. The engine's own commands are `agent-sandbox` and `asb` (#151);
  nothing of ours is ever installed at `claude`.
- **Shell.** bash 4.4+ (`local -n`, `${!var+x}`). `set -euo pipefail` inside the
  engine function. Helpers live at top level so tests can `source` the engine
  and call them. Messages go through `_as_msg`. Keep `IFS` changes inside a
  helper (`_as_split`); a `local IFS` in the main function leaks to everything
  after it.
- **Prose.** Markdown prose is wrapped at a comfortable width, about 80-90 columns;
  there is no hard limit and no check. An edit changes only the lines it touches and
  does not re-flow the paragraph, so the diff stays small; uneven line lengths that
  follow are expected. Line width is not a review finding unless it hurts reading (a
  prose line of several hundred columns, say) or a break changes how the text renders.
  A line `asb --init` reads by its prefix (`#@own `, `#@shared `) keeps the prefix at its
  start however it is wrapped, and a `#@ key = value` line stays one line.
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
  real `asb claude` launch only after the human re-runs `install.sh`. Under
  `--dev` they are live at the next launch — do not rely on either; test with
  the bats suites, which run the checkout's engine directly.

## Decided; do not re-litigate (and the roadmap)

- **Multi-provider engine + profiles**; `claude` is the flagship profile.
  Roadmap profiles: `codex`, `gemini`, `ollama`/OpenAI-compatible, and a
  generic `command` profile for arbitrary workers.
- **Proxy runtime**: mitmproxy 12+ in a private conda-forge environment under
  `~/.local/share/agent-sandbox`, built with install.sh's own pinned micromamba as the
  tools env is, never with the host's conda or python (#335); a working `proxy-venv` an
  earlier install made is still used. Distro packages are too old (Ubuntu 24.04 and
  26.04 ship 8.1.1, whose leaf certificates lack an Authority Key Identifier and fail
  Python 3.13's strict verification).
- **No standalone mitmproxy binary route.** `downloads.mitmproxy.org`
  serves `mitmproxy-<ver>-linux-<arch>.tar.gz` (~119 MB) but publishes no
  checksums or signatures, so a secure route must pin a SHA256 per version and
  architecture in this repo. Its audience was hosts with no `python3-venv` and
  no conda; install.sh's own micromamba builds the proxy env there (#335).
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
- **bubblewrap stays a distro package, from Ubuntu's own source.** Ubuntu 24.04+
  needs root once for the bwrap AppArmor profile anyway; that and the package
  are the only sudo steps. Where the distribution's binary lags -- 24.04 ships
  0.9.0, and its noble-security update dropped the fix for CVE-2026-87766 again
  -- the supported route is a no-change rebuild of Ubuntu's newer source
  package, never a third-party PPA; the recipe is in `docs/troubleshooting.md`,
  and `install.sh` warns below 0.12.0. The sandbox creates mount points inside
  the agent's writable state directory, which is the shape that CVE describes.
- **install.sh is a true install (copy), not an in-place symlink.** It copies
  the engine and profiles under `~/.local/share/agent-sandbox/app` and points
  `asb` there, so the installed command does not depend on the checkout
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
  profile; an `--ssh` host gets a pinhole there (direct, outside the proxy;
  `docs/ssh.md`). A seccomp/firejail backend and the SNI/tls_passthrough
  evaluation are recorded as open design questions in `docs/design.md`.

## Pitfalls that already cost time

- The `.bats` suites were not under ShellCheck for the project's first months,
  and 50 negative assertions that could not fail (`! cmd`, SC2314) accumulated
  where the one tool that knows about that bug was not looking. The general
  shape: a check that cannot go red is worse than no check, because it reports
  a guarantee nobody is keeping. When you add a linter, point it at everything;
  when you add an assertion, know what makes it fail.
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
