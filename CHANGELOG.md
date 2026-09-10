# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com); the project
uses [Semantic Versioning](https://semver.org). Pre-1.0, minor versions may
break compatibility.

## Unreleased

### Added

- `.agent-sandbox` accepts a `[seccomp]` section with `mode = on|off`, so a
  project can ask for the syscall filter the way it already pins a network
  mode. An `AGENT_SANDBOX_SECCOMP` in your shell wins, as with `[net] mode`.
  Its own section rather than a key in a shared `[security]`/`[options]`
  group: the environment variable's name is the section (plus key) uppercased,
  and `[security] seccomp` would map to `AGENT_SANDBOX_SECURITY_SECCOMP`, which
  is not the variable. `mode` also leaves room for a `profile` key if a second
  filter ever ships. With the built-in default off a project can only turn the
  filter *on*, so this cannot weaken the sandbox today.
- Opt-in seccomp syscall filtering (issue #4): `AGENT_SANDBOX_SECCOMP=on`
  loads a default-deny filter into the sandbox, Docker's default profile
  (moby/profiles, Apache-2.0, vendored under `components/seccomp/`) compiled as
  for a container with no capabilities. Every syscall not allowlisted fails
  with EPERM; `unshare`/`setns`/`mount`/`bpf`/`ptrace`-with-caps stay denied,
  `clone` is allowed only without namespace flags and `clone3` returns ENOSYS,
  so the agent cannot make its own user namespace to regain capabilities.
  `install.sh` compiles the filter on the installing host with pyseccomp in the
  proxy's Python env, against that host's libseccomp; nothing binary ships.
  Verified: the real agent completes turns under it in proxy and strict.
  The knob takes `on`/`1` and `off`/`0`, and says nothing about which profile:
  the value is the state, so it still reads correctly if the filter ever becomes
  the default. An earlier iteration on `main` spelled the on value `default`,
  which is now refused with a message naming `on`/`off` rather than treated as
  an alias -- a stale `AGENT_SANDBOX_SECCOMP=default` in a shell profile must
  not quietly launch without the filter it was asking for.
- `tests/unit/docs.bats` checks the README's knobs table against the engine in
  both directions: every engine flag, every `AGENT_SANDBOX_*` the engine reads
  and every `.agent-sandbox` section and key is documented, and the table
  claims nothing the engine no longer has. Each extraction asserts it found a
  plausible number of items, so a rename or reformat that breaks it fails the
  test instead of silently checking nothing.

### Changed

- **Breaking:** memory scoping is now the default. Without any configuration,
  a session sees only the current project's directory under
  `~/.claude/projects/`; other projects' transcripts, todos and shell
  snapshots are hidden behind a tmpfs. Previously the default was `shared`
  (every project visible) and scoping had to be asked for with a
  `[share-memory]` section in an approved `.agent-sandbox`. The README claimed
  sessions are isolated from each other, which was true only once configured;
  it now holds out of the box. To go back to the old behaviour, set
  `memory_default = shared` in `~/.config/agent-sandbox/config` (global, so an
  agent inside the sandbox cannot set it), or list `all` under
  `[share-memory]` in the project's dot-file.
- **Breaking:** `AGENT_SANDBOX_PASSENV` is now `AGENT_SANDBOX_FORWARD`, with no
  alias. Every other setting's variable is its `.agent-sandbox` section (plus
  key) uppercased -- `[ro]`/`AGENT_SANDBOX_RO`, `[net] mode`/`AGENT_SANDBOX_NET`,
  `[conda] write`/`AGENT_SANDBOX_CONDA_WRITE` -- and this was the one exception,
  made obvious by the new knobs table putting both names side by side. Renamed
  rather than aliased because pre-1.0 is when it is free.
- README's "Knobs and flags" is now one table with a column per way to set a
  setting (command line, environment variable, `.agent-sandbox` entry) plus the
  default, instead of an environment-only table with the flags and the dot-file
  described in prose. Each column carries only the name; values, defaults and a
  link to the relevant document live in the last column. It also states how the
  three combine: hosts, paths, forwarded names and ports add up, while the
  network mode and the conda settings are taken over by the environment
  variable when set.
- README opens with a non-technical "Why" section: what the project is for,
  which two failures (an agent led astray, and an agent simply wrong) it puts a
  boundary around, why that boundary is enforced around the agent rather than by
  it (rules given to an agent drift and need repeating), and when running an
  agent sandboxed is worth the setup at all.
- README no longer claims "there is no seccomp filter"; syscall filtering is
  opt-in as of issue #4.
- `code.claude.com` (Claude Code's documentation) is in the starter allowlist:
  agents working on Claude Code configuration reach for it, and it was the most
  refused host in the author's `blocked.log`. It is a convenience host like
  `github.com`, not something an agent needs to run, so it is in the global
  starter list rather than the `claude` profile's required seeds.
- `docs/design.md` brought back in line with the code: guarantee rows for
  capability dropping and opt-in seccomp; residual risks split (capabilities,
  uid 0 in strict, seccomp/limits) and the uid-0 consequences documented;
  resolved items removed from "Open design questions" (syscall filtering, and
  per-session proxy identity, which shipped as issue #5).
- `install.sh` chooses the proxy runtime so it works from any shell state: an
  existing environment is reused only if `mitmdump --version` still succeeds
  and is otherwise recreated (it is installer-owned); a dedicated conda env is
  preferred whenever mamba/conda is available; a venv is built only from a
  regular-build `python3 >= 3.12` with `venv`/`ensurepip` (free-threaded
  builds cannot use mitmproxy's abi3 `aioquic` wheel), trying `/usr/bin/python3`
  before `PATH`'s and warning if the interpreter belongs to a conda env. This
  fixes a real outage-in-waiting: a venv built from a dev conda env's python
  stopped importing mitmproxy after that env switched interpreters, while the
  running service masked it until its next restart.
- Drop all capabilities in the sandbox (`bwrap --cap-drop ALL`). In
  `proxy`/`open`/`none` this is a no-op (bwrap is unprivileged), but in `strict`
  the agent ran inside pasta's root-owned user namespace and started as uid 0
  with the full capability set; it now starts with none, matching the other
  modes. Namespaced and host-harmless before, but an unnecessary surface.

### Fixed

- `tests/unit/docs.bats` checked the whole table row for a `[section]`, so a
  markdown link in the last column could satisfy the search while the dot-file
  column said the setting did not exist. It now reads the dot-file column only,
  and derives the sections whose keys it checks instead of listing `conda net`,
  so a new key-taking section is not silently exempt. Latent until a section's
  name appeared in one of its own doc links.
- `platform.claude.com` is in the claude profile's seed allowlist. Without it
  `/login` failed with "OAuth error: proxy refused the connection": the OAuth
  flow reaches that host from inside the sandbox, and the only way to sign in
  was `AGENT_SANDBOX_NET=open`, which turns egress filtering off for the whole
  session -- a wide door for a narrow need. Found by reading
  `~/.config/agent-sandbox/blocked.log` after a failed sign-in. Existing
  installs pick it up by re-running `install.sh`, or by adding the line to
  `~/.config/agent-sandbox/allowlist.txt` (re-read per request, no restart).
- Memory scoping used the wrong project-state directory for any project path
  containing a character Claude Code rewrites. The profile mapped a path to a
  slug by replacing `/` only; Claude Code replaces every character outside
  `[A-Za-z0-9-]`, one for one. For a project like `~/work/site.com`, scoping put
  a tmpfs over `~/.claude/projects`, created and bound a directory that had
  never existed, and left the project's real memory and transcripts hidden, so
  notes did not persist and `--continue`/`--resume` found nothing -- silently.
  The scheme is undocumented, so it is now derived empirically by
  `probes/slug-probe.sh` and pinned by a unit test using a path with `.` and
  `+`; the previous tests shared the same wrong rule in their own helper and so
  passed, because bats temp paths happen to contain no dots.
- A `.agent-sandbox` `[conda] name = <env>` set `CONDA_PREFIX` and bound that
  env, but left PATH as the launching shell had it. So the sandbox got a
  contradiction (`CONDA_PREFIX` naming one env, PATH resolving another) and none
  of the pinned env's tools were found inside, defeating the documented
  "run in this conda env instead of whatever env is active in your shell".
  The env's `bin/` now takes the active env's place on PATH inside, as
  `conda activate` does, and is prepended when no env was active. The engine's
  own PATH is untouched, so it still finds bwrap, pasta and nft as before.
  Covered for all three starting points: no env active, a different env active,
  and conda's base active (the case that surfaced it).
- Strict-mode `--ssh` failed host-key verification. In strict the agent runs as
  uid 0 (pasta maps the one uid to root), so ssh resolves `~` through
  `getpwuid(0)` to root's home, not `$HOME`, and never saw the bound
  `~/.ssh/known_hosts`. The engine now also binds `known_hosts` and `config` at
  uid 0's home, so `--ssh` works in strict as in proxy. A live `--ssh` test
  covers it (the stubbed-toolchain unit test could not).
- Strict network mode (`AGENT_SANDBOX_NET=strict`) launched the agent with no
  proxy variables, so it resolved `api.anthropic.com` directly and failed with
  ENOTFOUND (strict has no DNS route by design). The strict wrapper set the
  proxy `--setenv` before the base `--clearenv`, which cleared them; the env is
  now set after `--clearenv`. Strict mode had never delivered a working proxy to
  the agent.
- `--allow` (and a `.agent-sandbox` `[allow]` line) no longer hangs the agent.
  The per-session proxy token went into the sandbox's proxy URL with an empty
  password (`TOKEN@host`), and Node's HTTP stack hangs on that, so the agent
  could not reach the API whenever a per-session allow host was set. The URL now
  carries a dummy password (`TOKEN:x@host`); the proxy addon reads the token
  from the username and ignores the password.

## 0.1.0 — 2026-09-09

First tagged version. Extracted from the author's private sandbox repository
(history preserved) and generalized.

- Engine + profiles: `claude.sh` became the provider-agnostic `agent-sandbox`
  engine with a `claude` profile; `--profile NAME` or inference from the symlink
  name. Knobs are `AGENT_SANDBOX_*`.
- `--allow HOST`: per-session egress hosts, honoured only while the session's
  owner process lives.
- Per-project `.agent-sandbox` file (trust-gated with `--trust`): `allow`
  hosts and `share-memory` for per-project memory scoping. Memory scoping hides
  `~/.claude/projects` and rebinds only the current project plus approved
  projects' memory; default stays `shared`, a global `memory_default = scoped`
  or a dot-file opts in. The trust store and global config live under
  `~/.config/agent-sandbox`, never bound into the sandbox.
- Egress proxy: blocked hosts are refused at CONNECT before any upstream
  connection; responses are streamed and HTTP/2 disabled in mitmproxy, taking
  throughput from ~1 MB/s to near-native; mitmproxy 12+ runs from a private
  environment (venv or conda) instead of the distro package.
- The proxy CA is trusted inside the sandbox only, bound over the system
  bundle; no system-wide trust and no sudo for it. Tools with private CA stores
  get the standard CA variables.
- Conda write mode bounded to the active env with a sandbox-owned package
  cache; every session gets an ephemeral `~/.cache`.
- Refusals extended: read-only binds into secret stores, and `/`, `$HOME` or a
  parent of `$HOME` as CWD or bind.
- Refusals extended again: more secret stores (`~/.azure`, `~/.config/gh`,
  `~/.local/share/keyrings`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`,
  `~/.pypirc`), the sandbox's own control plane (`~/.config/agent-sandbox`,
  `~/.mitmproxy`, `~/.local/share/agent-sandbox`, `~/.local/bin`,
  `~/.config/systemd`), and any directory that contains a protected path
  (`~/.config`, `~/.local`); one rule for CWD and for RO/RW binds.
- Fixed: the session liveness stamp recorded the wrong process's start time,
  so `--allow` never took effect and the SSH janitor could reap live sessions.
- Fixed: setting `RW` and `PASSENV` together aborted the launch (IFS leak).
- Installer split into `components/` + `install.sh.in`, bundled into a
  self-contained `install.sh`; per-profile symlinks and allowlist seeds;
  `--dry-run`; standalone `curl | bash` mode; migration from the pre-rename
  layout.
- `AGENT_SANDBOX_NET=strict` now works, via pasta (from the `passt` package)
  instead of the non-functional slirp4netns: pasta owns an isolated network
  namespace and forwards it in userspace, bwrap runs inside sharing it, and an
  nftables rule allows only the proxy on the gateway, so a tool that ignores
  `HTTPS_PROXY` has no route out (closes the raw-socket egress gap, issue #1).
  pasta's port forwarding is off both ways (its defaults would mirror every host
  port into the sandbox and publish sandbox listeners on the host).
  Needs `passt` and its AppArmor profile (added by `install.sh`) and nftables.
  In strict mode `--ssh HOST` works: the egress firewall is opened to the host's
  resolved IPv4 address(es) and its name is added to `/etc/hosts` (DNS is
  otherwise blocked); `--ssh-unrestricted` is refused, since the firewall must
  pin a named host. IPv6-only SSH hosts are not supported yet.
- Strict-mode port opt-ins: `--host-port PORT` (the sandbox may reach the
  host's 127.0.0.1:PORT) and `--agent-port PORT` (a port the agent listens on is
  published at the host's 127.0.0.1:PORT), also as `AGENT_SANDBOX_HOST_PORTS` /
  `AGENT_SANDBOX_AGENT_PORTS` and a trusted `.agent-sandbox` `[net]` section;
  TCP, 1024-65535, the sources form a union, `none` closes a direction, noted
  and ignored outside strict.
- The network mode can be set per project: a trusted `.agent-sandbox` `[net]`
  `mode = proxy|strict|open|none` line; an `AGENT_SANDBOX_NET` in the shell
  wins over it.
- `--allow` is now scoped to the session that granted it, not shared across
  concurrent sessions. The engine mints a per-session token, carries it in the
  sandbox's proxy URL (`http://<token>@127.0.0.1:8888`), and the addon grants
  the global allowlist plus only the matching live session's `--allow`. A
  concurrent session with a different token, or none, sees the global allowlist
  only (issue #5).
- A `.agent-sandbox` that was approved and then edited or deleted now refuses
  launches from that directory until `--trust` re-reviews it (or, with the file
  gone, forgets the approval). Ignoring it fell back to the defaults, which for
  memory scoping (`shared`) is wider than a scoped policy the agent could have
  removed.
- `--trust` shows the file through `cat -v` and refuses one containing control
  characters (at review and at launch), so a repo-shipped file cannot hide a
  line from the review with an escape sequence or a carriage return.
- `install.sh` is now a true install: it copies the engine and profiles under
  `~/.local/share/agent-sandbox` and points the launcher there, so the command
  no longer depends on the checkout (move or delete it and it keeps working)
  and a `git pull` takes effect on the next `install.sh`. `--dev` keeps the
  previous symlink-into-the-checkout for developing agent-sandbox; it also
  means an edit to the checked-out engine (including one a sandboxed agent
  makes to a checkout it has as CWD) is no longer a live host-code path under a
  normal install.
- Documentation: `docs/` (design and threat model, network, SSH, profiles,
  updating, troubleshooting, prior art), `AGENTS.md`, `scripts/check.sh`.
- Tests: bats suites under `tests/` (unit with a stub bwrap, integration with
  the real bwrap and a probe profile, opt-in live), run by `scripts/check.sh`;
  each guarantee in `docs/design.md` names the test that checks it. An opt-in
  end-to-end test installs for real into a throwaway HOME with a fake Claude
  binary and a `systemctl` shim, then runs the fake agent through the installed
  proxy.
- CI (`.github/workflows/ci.yml`): `scripts/check.sh` (lint, format, bundle
  sync, unit tests), and integration and end-to-end installer jobs on Ubuntu
  22.04, 24.04 and 26.04, with an allowed-to-fail real-user-systemd experiment.
