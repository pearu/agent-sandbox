# Changelog

## Unreleased

Extracted from the author's private sandbox repository (history preserved) and
generalized.

- Engine + profiles: `claude.sh` became the provider-agnostic `agent-sandbox`
  engine with a `claude` profile; `--profile NAME` or inference from the symlink
  name. Knobs are `AGENT_SANDBOX_*`.
- `--allow HOST`: per-session egress hosts, honoured only while the session's
  owner process lives.
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
- Documentation: `docs/` (design and threat model, network, SSH, profiles,
  updating, troubleshooting, prior art), `AGENTS.md`, `scripts/check.sh`.
