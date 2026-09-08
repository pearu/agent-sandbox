# Changelog

## Unreleased

Extracted from the author's private sandbox repository (history preserved) and
generalized.

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
  Needs `passt` and its AppArmor profile (added by `install.sh`) and nftables;
  `--ssh` is unavailable in this mode.
- Documentation: `docs/` (design and threat model, network, SSH, profiles,
  updating, troubleshooting, prior art), `AGENTS.md`, `scripts/check.sh`.
- Tests: bats suites under `tests/` (unit with a stub bwrap, integration with
  the real bwrap and a probe profile, opt-in live), run by `scripts/check.sh`;
  each guarantee in `docs/design.md` names the test that checks it. An opt-in
  end-to-end test installs for real into a throwaway HOME with a fake Claude
  binary and a `systemctl` shim, then runs the fake agent through the installed
- CI (`.github/workflows/ci.yml`): `scripts/check.sh` (lint, format, bundle
  sync, unit tests), and integration and end-to-end installer jobs on Ubuntu
  22.04 and 24.04, with an allowed-to-fail real-user-systemd experiment.
  proxy.
