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
your shell, and you.

**Out of scope**: kernel or bubblewrap escapes, a compromised host, side
channels, and resource exhaustion (there are no CPU, memory or disk limits).

## Guarantees, mechanisms, checks

Each row names the mechanism in the engine and how it is (or will be, in the
bats suite under `tests/`) checked. The standard harness is a stub `bwrap`
that records the argv it receives; the argv is the contract.

| Guarantee | Mechanism | Check |
|---|---|---|
| Default-deny filesystem. Only `/usr`, `/etc`, `/opt`, `/lib*`, `/bin`, `/sbin` are visible, read-only. `/tmp`, `/var/tmp`, `/run`, `/proc`, `/dev` are fresh. `$HOME` is a read-only tmpfs; only the profile's state paths, `$CWD`, the conda env, `~/.cache`, `~/.conda`, and paths you list are visible under it. | bwrap argument list built in the engine; `--remount-ro $HOME` last. | argv snapshots per configuration; A/B against the reference script. |
| Secret stores never enter. `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/{gcloud,sops}`, `~/.kube`, `~/.docker`, `~/.password-store` are refused as CWD and as `AGENT_SANDBOX_RO`/`_RW`. `/`, `$HOME` and any parent of `$HOME` are refused too. | `_as_check_paths`, CWD checks. | refusal cases: exit 1, bwrap never invoked. |
| Clean environment. Everything is cleared; only locale, colour hints, the profile's variables, proxy and CA variables, CUDA variables, and `AGENT_SANDBOX_PASSENV` names are forwarded. | `--clearenv` plus explicit `--setenv`. | argv snapshots. |
| Egress allowlist (default `proxy` mode). Every client that honours `HTTPS_PROXY` reaches the network only through the host proxy, which refuses non-allowed hosts at the CONNECT stage, before any upstream connection, and again per request inside an allowed tunnel. Refusals are logged. | `components/allowlist_addon.py`: `http_connect` and `request` hooks. | local mitmdump: blocked CONNECT returns 403 with zero upstream connects in the proxy log; blocked plain-HTTP returns the 403 body; allowed hosts pass. |
| Per-session `--allow` hosts lapse with the session. The engine writes them to the session dir; the addon honours them only while the process stamped in `owner.id` is alive, comparing PID and start time so a recycled PID never counts. | `_as_allow_setup`, `_owner_alive` in the addon. | alive: 200; owner killed: 403 at once; live PID with wrong start time: 403. |
| The proxy CA is trusted inside the sandbox only. The engine binds (system bundle + CA) over `/etc/ssl/certs/ca-certificates.crt` and points the CA variables of tools with private stores at it. The host trust store is never touched. | `_as_ca_bind`, `_as_ca_env`. | nested bwrap with a CA unknown to the host: inside verifies a leaf it signed, the host does not; Python 3.14 strict context succeeds. |
| SSH keys never enter. `--ssh HOST` starts a per-session ssh-agent on the host, loads the key with an OpenSSH destination constraint, binds only the socket (plus read-only `known_hosts` and `config`). The agent refuses to sign for any other host. Teardown kills the agent and removes the socket. | `_as_ssh_setup`, `_as_session_cleanup`. | generated host key: constrained key listed inside, private key path absent from argv, agent dead and dir gone after exit; unknown host refused before any session exists. |
| Concurrency-safe sessions. Each launch gets its own directory; the janitor reaps only directories whose owner (PID and start time) is gone and never touches unstamped or live ones. | `_as_session_begin`, `_as_session_sweep`. | dead reaped, live kept, unstamped kept, recycled-PID reaped. |
| Self-update runs on the host, never inside. The profile lists the subcommands; the engine runs them unsandboxed and restores the launcher symlink if an installer moves it. `DISABLE_AUTOUPDATER=1` inside. | `profile_host_subcommands`, `profile_handle_subcommand`. | stub binary: no bwrap call, exit code propagated, launcher restored. |
| Conda write mode is bounded. Only the active env becomes writable; the base install, other envs, conda itself, its shell hook and the host package cache stay read-only. Downloads go to a sandbox-owned cache. | conda block in the engine; `CONDA_PKGS_DIRS`. | nested real `mamba install` into an env: succeeds; base, other env and host cache not writable; package lands in the sandbox cache. |

## Residual risks

Stated plainly. These are what the adversary above can still do.

- **Raw-socket egress is unfiltered in `proxy` mode.** The sandbox shares the
  host network namespace. A tool that ignores `HTTPS_PROXY` (raw sockets, its
  own resolver) can reach anything the host can, including localhost services,
  databases and the LAN. The `strict` mode that closes this (slirp4netns) does
  not work on Ubuntu 24.04 yet. Consequence: the allowlist is a control on
  well-behaved clients, not a network boundary.
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
- **Strict network mode on Ubuntu 24.04+**: slirp4netns cannot enter bwrap's
  namespace unprivileged; pasta or rootlesskit may.
- **Per-session proxy identity**, such as a per-session proxy-auth token the
  addon maps to a session, so `--allow` stops being a union.
- **A standalone mitmproxy binary route** for hosts with neither
  `python3-venv` nor conda: `downloads.mitmproxy.org` serves a 119 MB tarball
  but publishes no checksums or signatures, so it needs a SHA256 pinned per
  version and architecture in this repository. Deliberately deferred.
