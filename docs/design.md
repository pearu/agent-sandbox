# Design and threat model

agent-sandbox runs an AI coding agent inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox with a default-deny filesystem, an egress allowlist enforced by a
host-side proxy, host-routed self-update, and an opt-in SSH broker whose keys
never enter the sandbox. This document is the trust surface: what is
guaranteed, by which mechanism, how it is checked, and, just as plainly, what
is not guaranteed.

## Architecture

```
 host                                             sandbox (bwrap, user namespace)
 ─────────────────────────────────────────────    ───────────────────────────────
 agent-sandbox (engine, bash)  ──── exec/launch ─▶  the agent binary (read-only)
   ├─ profiles/<name>.sh  (sourced)                 /usr /etc /opt /lib* /bin  ro
   ├─ session dir: owner.id, agent.sock,            /tmp /var/tmp /run /proc /dev fresh
   │   agent.pid, allow.txt                         $HOME  tmpfs, read-only
   ├─ ca-bundle.crt = system bundle + proxy CA        ├─ profile state (rw)
   └─ ssh-agent (per session, constrained key)        ├─ $CWD (rw)
                                                      ├─ $CONDA_PREFIX (ro / rw)
 agent-sandbox-mitmproxy.service (systemd --user)     ├─ ~/.cache, ~/.conda (tmpfs)
   mitmdump ≥ 12 on 127.0.0.1:8888                    └─ agent.sock (with --ssh)
   ├─ components/allowlist_addon.py                 /etc/ssl/certs/ca-certificates.crt
   ├─ ~/.config/agent-sandbox/allowlist.txt           = ca-bundle.crt (bind)
   └─ ~/.config/agent-sandbox/blocked.log            env: cleared + explicit allowlist
                                                    HTTPS_PROXY=http://127.0.0.1:8888
```

- **Engine** (`agent-sandbox`): provider-agnostic bash. It parses its own flags,
  selects a profile, asks the profile where the agent binary is, routes
  host-side subcommands (such as `claude update`), assembles the bwrap
  invocation, sets up per-session state (SSH agent, `--allow` file, CA bundle)
  and launches. Everything the agent can see or reach is decided here.
- **Profile** (`profiles/<name>.sh`): what is specific to one agent, behind a
  small contract (see [profiles.md](profiles.md)). The `claude` profile is the
  flagship.
- **Egress proxy**: a mitmproxy 12+ instance run as a systemd user service from
  a private environment under `~/.local/share/agent-sandbox`, loading the
  allowlist addon. It terminates TLS with its own CA. See [network.md](network.md).
- **Session state**: `$XDG_RUNTIME_DIR/agent-sandbox.<uid>/session.XXXXXX/`
  holds the liveness stamp (`owner.id`: the engine's PID and start time), the
  SSH agent socket and PID, and the `--allow` hosts. `ca-bundle.crt` at the base
  is shared by sessions. A janitor reaps orphans at every launch.
- **Installer** (`install.sh`, generated from `install.sh.in` and `components/`):
  host setup, per profile. See the repository `README.md`.

Launch order matters for the guarantees below: the base conda install is bound
before the env inside it, the CA bundle after `/etc`, `--remount-ro $HOME` after
every bind under `$HOME`, and the SSH socket and `--allow` file exist before
bwrap starts.

## Threat model

**Adversary**: the agent process and anything it runs inside the sandbox,
assumed compromised: by prompt injection through the content it reads, by a
malicious dependency it installs, or by a bug. It runs arbitrary code as your
uid inside the sandbox. Its goals: read secrets, exfiltrate data, persist on
the host, reach internal services, act as you (push code, ssh, call APIs).

**Trusted**: the kernel, bubblewrap and user namespaces, the engine (it runs on
the host, before the sandbox exists), the proxy process and its addon, systemd,
your shell, and you. In the strict network mode, also `pasta` (it owns the
sandbox's network namespace) and `nftables` (the in-namespace firewall).

**Out of scope**: kernel or bubblewrap escapes, a compromised host, side
channels, and resource exhaustion (there are no CPU, memory or disk limits).

## Guarantees, mechanisms, checks

Each row names the mechanism in the engine and how it is (or will be, in the
bats suite under `tests/`) checked. The standard harness is a stub `bwrap`
that records the argv it receives; the argv is the contract.

| Guarantee | Mechanism | Check |
|---|---|---|
| Default-deny filesystem. Only `/usr`, `/etc`, `/opt`, `/lib*`, `/bin`, `/sbin` are visible, read-only. `/tmp`, `/var/tmp`, `/run`, `/proc`, `/dev` are fresh. `$HOME` is a read-only tmpfs; only the profile's state paths, `$CWD`, the conda env, `~/.cache`, `~/.conda`, and paths you list are visible under it. | bwrap argument list built in the engine; `--remount-ro $HOME` last. | `tests/unit/argv.bats` (argv per configuration), `tests/integration/sandbox.bats` (HOME read-only, secrets invisible, host `/tmp` invisible, system read-only). A/B argv identity against the reference script was checked once at extraction. |
| Secret stores and the sandbox's own control plane never enter. Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.password-store`, `~/.config/{gcloud,sops,gh}`, `~/.local/share/keyrings`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`) and the control plane (`~/.config/agent-sandbox`: trust store, allowlist, addon; `~/.mitmproxy`: the CA key; `~/.local/share/agent-sandbox`: the proxy runtime; `~/.local/bin`: the launcher; `~/.config/systemd`: user units) are refused as CWD and as `AGENT_SANDBOX_RO`/`_RW`, read-only included, and so is any directory that contains one (`~/.config`, `~/.local`). `/`, `$HOME` and any parent of `$HOME` are refused too. The list is a blocklist and cannot be complete; a path not on it that you bind is yours to judge. | `_as_secret_paths`, `_as_control_paths`, `_as_path_protected` (one rule for binds and CWD), `_as_check_paths`. | `tests/unit/helpers.bats` (`_as_check_paths`: each kind, containing directories, siblings pass), `tests/unit/argv.bats` (CWD and bind refusals: exit 1, bwrap never invoked). |
| Clean environment. Everything is cleared; only locale, colour hints, the profile's variables, proxy and CA variables, CUDA variables, and `AGENT_SANDBOX_PASSENV` names are forwarded. | `--clearenv` plus explicit `--setenv`. | `tests/unit/argv.bats` (environment allowlist, PASSENV), `tests/integration/sandbox.bats` (a host variable is unset inside). |
| Egress allowlist (default `proxy` mode). Every client that honours `HTTPS_PROXY` reaches the network only through the host proxy, which refuses non-allowed hosts at the CONNECT stage, before any upstream connection, and again per request inside an allowed tunnel. Refusals are logged. | `components/allowlist_addon.py`: `http_connect` and `request` hooks. | `tests/unit/addon.bats` (CONNECT and request refusals, logging, streaming, with a stubbed mitmproxy); `tests/live/proxy.bats` against the host's real proxy (opt-in). Zero upstream connects on a blocked CONNECT was verified once with a local mitmdump log. |
| Strict network mode (opt-in, `AGENT_SANDBOX_NET=strict`). The sandbox gets its own network namespace, owned by `pasta` and forwarded in userspace; an nftables rule inside allows only the proxy on the gateway, and pasta's port forwarding is off both ways, so a tool ignoring `HTTPS_PROXY`, host loopback services and the LAN are all unreachable — only the proxy is. The agent is root only in bwrap's child user namespace, which has no authority over the netns pasta's parent namespace owns, so it cannot alter the firewall. `--host-port`/`--agent-port` open named TCP ports. | `_as_launch_pasta` (pasta + the nft ruleset), the `strict` arm of the engine, the userns nesting. | `tests/unit/strict.bats` (the pasta/nft argv: netns, `policy drop`, only the gateway proxy, port forwarding off, ports opened on request), `tests/integration/strict.bats` (real pasta+bwrap+nft: proxy reachable at the gateway only, raw egress, host loopback and publishing a sandbox listener all blocked, ports opened on request). `install.sh` re-checks the contract on the host. |
| Per-session `--allow` hosts lapse with the session. The engine writes them to the session dir; the addon honours them only while the process stamped in `owner.id` is alive, comparing PID and start time so a recycled PID never counts. | `_as_allow_setup`, `_owner_alive` in the addon. | `tests/unit/addon.bats` (alive honoured; dead, recycled-PID and unstamped sessions ignored), `tests/unit/helpers.bats` (the stamp is the launcher's own PID and start time), `tests/unit/argv.bats` (file written, removed at exit). Verified live once: alive 200, owner killed 403. |
| The proxy CA is trusted inside the sandbox only. The engine binds (system bundle + CA) over `/etc/ssl/certs/ca-certificates.crt` and points the CA variables of tools with private stores at it. The host trust store is never touched. | `_as_ca_bind`, `_as_ca_env`. | `tests/unit/helpers.bats` (`_as_ca_bind`, `_as_ca_env`), `tests/integration/sandbox.bats` (bundle inside is the system bundle plus the given CA; plain system bundle with a warning when the CA is missing). Python 3.14 strict verification through the live proxy was checked once by hand. |
| SSH keys never enter. `--ssh HOST` starts a per-session ssh-agent on the host, loads the key with an OpenSSH destination constraint, binds only the socket (plus read-only `known_hosts` and `config`). The agent refuses to sign for any other host. Teardown kills the agent and removes the socket. | `_as_ssh_setup`, `_as_session_cleanup`. | `tests/integration/ssh.bats` (generated host key: constrained key listed inside, `~/.ssh` and the private key invisible, known_hosts read-only, agent dead and dir gone after exit; unknown host refused before any session exists). |
| Concurrency-safe sessions. Each launch gets its own directory; the janitor reaps only directories whose owner (PID and start time) is gone and never touches unstamped or live ones. | `_as_session_begin`, `_as_session_sweep`. | `tests/unit/helpers.bats` (`_as_session_sweep`), `tests/integration/ssh.bats` (janitor at launch; `--ssh` and `--allow` share one dir). |
| Self-update runs on the host, never inside. The profile lists the subcommands; the engine runs them unsandboxed and restores the launcher symlink if an installer moves it. `DISABLE_AUTOUPDATER=1` inside. | `profile_host_subcommands`, `profile_handle_subcommand`. | `tests/unit/profile-claude.bats` (no bwrap call, exit code propagated, flags ignored with a note, launcher restored). |
| Per-project policy is trust-gated. A project's `.agent-sandbox` (allow hosts, memory scoping, paths, environment, conda, network) is honored only after `--trust` records its SHA-256. A file with no approval on record is ignored with a note. Once approved, an edit by anyone, the agent included, or the file's removal refuses launches from that directory until `--trust` re-reviews it (or forgets the approval), because ignoring would fall back to the defaults, and for memory scoping the default is wider than a scoped policy. So the agent can neither grant itself anything nor quietly regain the defaults. The review shows the file escaped (`cat -v`) and a file containing control characters is refused at review and at launch, so no line can be hidden from the reviewer. The trust store and global config live under `~/.config/agent-sandbox`, which is never bound into the sandbox. | `_as_dotfile_trusted`, `_as_trust_record`, `_as_dotfile_parse`, `_as_dotfile_clean`, `_as_trust_review`, the trust-record check at launch. | `tests/unit/dotfile.bats` (unapproved ignored with a pointer to `--trust`; an edit and a deletion refuse to launch, bwrap never invoked, until `--trust` re-approves or forgets; an approved file adds allow hosts; `--trust` records the hash and offers to git-ignore; a file with an ESC sequence or a carriage return is refused at review and at launch, UTF-8 is shown escaped and accepted). |
| Memory is scoped per project on request. In `scoped` mode `~/.claude/projects` is hidden and only the current project (read-write) and each approved project's `memory/` (read-only) are rebound, so a session cannot read other projects' notes or transcripts. The default is `shared` (unchanged on upgrade); a global setting or a trusted dot-file selects `scoped`. | `profile_memory_scope` in the claude profile; `profile_tmpfs`/`_rw_binds`/`_ro_binds` applied by the engine after the state binds. | `tests/unit/dotfile.bats` (argv: tmpfs hide then current read-write then shared read-only, in that order), `tests/integration/memory.bats` (real bwrap: other project invisible, shared `memory/` read-only, current writable). |
| Conda write mode is bounded. Only the active env becomes writable; the base install, other envs, conda itself, its shell hook and the host package cache stay read-only. Downloads go to a sandbox-owned cache. | conda block in the engine; `CONDA_PKGS_DIRS`. | `tests/unit/argv.bats` (bind order and modes), `tests/integration/conda.bats` (fake layout: env writable only in write mode; base, other env and host cache never; sandbox cache first). A real nested `mamba install` was checked once at extraction. |

## Residual risks

Stated plainly. These are what the adversary above can still do.

- **Raw-socket egress is unfiltered in `proxy` mode.** The sandbox shares the
  host network namespace. A tool that ignores `HTTPS_PROXY` (raw sockets, its
  own resolver) can reach anything the host can, including localhost services,
  databases and the LAN. `AGENT_SANDBOX_NET=strict` closes this (pasta owns an
  isolated netns; an nftables rule allows only the proxy; pasta's port
  forwarding is off both ways, so host loopback services are not mirrored in
  and sandbox listeners are not published on the host, except the TCP ports
  you open with `--host-port`/`--agent-port`; a host port is a raw path to that
  service, and if the service forwards traffic, egress control ends there), at
  the cost of a `passt` dependency and losing `--ssh`. In the default `proxy` mode the
  allowlist is a control on well-behaved clients, not a network boundary; the
  user chooses the mode and its residual risk.
- **`--allow` is a union across live sessions.** The proxy cannot attribute a
  request to a session, so while any session allows a host, every concurrent
  session can reach it.
- **The agent's own credentials are inside.** `~/.claude` holds Claude's
  OAuth or API tokens and is read-write; any allowed host, api.anthropic.com
  first among them, is an exfiltration channel for anything the agent can read.
  The sandbox cannot prevent this.
- **`$CWD` is read-write**, including `.git`, `.env` and anything else in the
  project. Files the host later executes (git hooks, project scripts) are a
  persistence path from inside the sandbox to the host.
- **`$CONDA_PREFIX` is readable**, including secrets in
  `etc/conda/activate.d/*.sh`. With `AGENT_SANDBOX_CONDA_WRITE=1` the agent can
  put anything into that env, and you run it on the host the next time you
  activate it; the sandbox-owned package cache can be poisoned for future
  sandbox sessions.
- **The path refusals are a blocklist.** Secret stores and the sandbox's
  control plane are refused by name (the guarantees table has the list), and
  so is a directory containing one. A credential inside a directory you
  choose to bind is exposed with it: `~/.cargo/credentials.toml` under
  `~/.cargo`, the Hugging Face token under `~/.cache/huggingface`, a `.env` in
  `$CWD`. Nothing under `$HOME` is visible unless something binds it, so every
  such exposure is an explicit act of yours; the list catches the well-known
  mistakes in those acts, not all of them. Bind the narrowest path that works.
- **Memory scoping covers `~/.claude/projects` only.** In `scoped` mode other
  state under `~/.claude` (global command history, session metadata) stays
  visible; scoping isolates per-project memory and transcripts, not the whole
  identity. And a `.agent-sandbox` grants exactly what you approved: `--trust`
  shows the file before recording it, so review is where the security sits.
- **No seccomp, no capability dropping, no resource limits.** The isolation is
  bubblewrap's namespaces alone.
- **SSH constraints are host-level, not operation-level.** Within a permitted
  host the tunnel is opaque: a force-push cannot be blocked. `--ssh-unrestricted`
  lets the session authenticate as you to any host that trusts the key, for as
  long as it lives (`--ssh-timeout` bounds that).
- **An orphaned ssh-agent is reaped, not prevented.** If the engine is
  SIGKILLed, its agent lives until the next launch's janitor finds it dead.
- **Host-side subcommands run unsandboxed.** `claude update` runs the native
  binary on the host with your full environment.
- **The proxy is a host process that sees all traffic.** Its CA's private key
  lives in `~/.mitmproxy` on the host (not visible inside). Compromise of the
  proxy or that key is compromise of every sandbox's TLS.
- **The engine trusts the host's `/etc` and `/usr`.** A compromised host is out
  of scope.

## Open design questions

- **Running without a user systemd** (WSL with systemd disabled, containers).
  The installer and the unit assume `systemctl --user`. A no-systemd mode needs
  a story for starting the proxy at login, restarting it on failure and
  logging, not only a flag; and under Docker's default seccomp profile bwrap's
  user namespaces are blocked anyway. Deferred.

Recorded so they are not re-derived from scratch; each has measurements or
reasons attached in the repository history.

- **SNI/TLS-passthrough allowlisting.** Enforce the allowlist on the CONNECT
  host and relay TLS untouched (as
  [FoamoftheSea/claude-code-sandbox](prior-art.md) does with Squid). Measured:
  71 MB/s versus 50 to 74 MB/s for interception with `http2=false` and response
  streaming; it would remove the CA entirely. Rejected for now because
  interception keeps per-path logging and 403 bodies, and because a non-HTTP
  protocol could then be tunnelled to an allowed host's port 443. Revisit if
  the CA proves a burden.
- **A seccomp or firejail backend** for syscall filtering. Nothing here filters
  syscalls today.
- **Strict network mode** is implemented with pasta (it owns the netns; bwrap
  runs inside sharing it; an nftables rule allows only the proxy). slirp4netns
  could not, because it cannot enter bwrap's unprivileged netns from outside.
- **Per-session proxy identity**, such as a per-session proxy-auth token the
  addon maps to a session, so `--allow` stops being a union.
- **A standalone mitmproxy binary route** for hosts with neither
  `python3-venv` nor conda: `downloads.mitmproxy.org` serves a 119 MB tarball
  but publishes no checksums or signatures, so it needs a SHA256 pinned per
  version and architecture in this repository. Deliberately deferred.
