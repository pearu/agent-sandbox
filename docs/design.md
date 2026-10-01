# Design and threat model

agent-sandbox runs an AI coding agent inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox with a default-deny filesystem, an egress allowlist enforced by a
host-side proxy, and an opt-in SSH broker whose keys
never enter the sandbox. This document is the trust surface: what is
guaranteed, by which mechanism, how it is checked, and, just as plainly, what
is not guaranteed.

## Architecture

```
 host                                             sandbox (bwrap, user namespace)
 ─────────────────────────────────────────────    ───────────────────────────────
 agent-sandbox (engine, bash)  ──── exec/launch ─▶  the agent binary (read-only)
   ├─ profiles/<name>/    (sourced)                 /usr /etc /opt /lib* /bin  ro
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

- **Engine** (`agent-sandbox`, alias `asb`): provider-agnostic bash, invoked by
  name -- `asb [OPTIONS] CMD [AGENT OPTIONS]` (#151). It parses its own flags,
  takes the agent from CMD (a name on PATH, or a path, resolved), selects the
  profile CMD's basename names, assembles the bwrap
  invocation, sets up per-session state (SSH agent, `--allow` file, CA bundle)
  and launches. Everything the agent can see or reach is decided here.
- **Profile** (`profiles/<name>/`: `profile.sh` and its dot-file): what is specific to one agent, behind a
  small contract (see [profiles.md](profiles.md)). The `claude` profile is the
  flagship.
- **Egress proxy**: a mitmproxy 12+ instance run as a systemd user service from
  a private environment under `~/.local/share/agent-sandbox`, loading the
  allowlist addon. It terminates TLS with its own CA. See [network.md](network.md).
- **Keeper** (#121): one launch per role. The first invocation of a role starts
  bwrap with a payload that only holds the sandbox's namespaces, and every app, the
  first included, is joined into it by `components/join.py` (`setns`, then the same
  capability set, `no_new_privs` and seccomp filter). A second invocation of a
  running role builds nothing: it joins. The launch's host side is a supervisor, a
  background copy of the engine, which ends the keeper once nothing is joined (after
  a two-second grace) and then does what a launch's exit did. See
  [connections.md](connections.md#the-keeper-one-running-instance-per-role-121).
- **Session state**: `$XDG_RUNTIME_DIR/agent-sandbox.<uid>/session.XXXXXX/`
  holds the liveness stamp (`owner.id`: the keeper's supervisor's PID and start
  time), the SSH agent socket and PID, the `--allow` hosts and the briefing. One
  per keeper. `ca-bundle.crt` at the base is shared by sessions. A janitor reaps
  orphans at every launch.
- **Installer** (`install.sh`, generated from `install.sh.in` and `components/`):
  host setup, per profile. See the repository `README.md`.

Launch order matters for the guarantees below: the base conda install is bound
before the env inside it, the CA bundle after `/etc`, `--remount-ro $HOME` after
every bind under `$HOME`, and the SSH socket and `--allow` file exist before
bwrap starts.

### Background sessions (#123)

A background session (`asb claude --bg`) hands its task to a per-user daemon that
pre-warms a pool of worker processes and dispatches the task to one. The engine does
not launch those workers, so it does not wrap them: it runs `claude --bg` *inside the
role's launch*, as a join like any other, and the daemon, its spares and its pty
hosts start there (measured on 2.1.283, `probes/claude-bg-in-launch-probe.sh`). They
are in the role's namespaces by construction, each role gets its own daemon, and
nothing of it is left once the role's launch ends.

- **The daemon holds the launch.** A keeper ends when nothing is joined; `claude
  --bg` returns as soon as the daemon has the task, so the keeper also counts a
  daemon among its processes (the profile names it: `profile_daemon_argv`, `daemon
  run` for Claude Code). The daemon does not exit when idle (measured), so a role
  that has one ends by `asb --role x --shutdown claude`.
- **The management verbs join** (`daemon`, `agents`, `attach`, `logs`, `stop`, `rm`):
  they run inside the role's launch, where its daemon is, and never start one. With
  no launch running, `agents` and `logs` answer that the role is not running and exit
  0; the others refuse. A verb needs the project's `.agent-sandbox` only to find the
  role: when an unapproved edit keeps the file from being read and exactly one role
  of the project is running, that one is meant.
- **Workspace trust.** A `--bg` worker cannot answer Claude Code's trust prompt, so
  the engine records the project as trusted in the role's own config file when it is
  not there already, and says so; the user running `asb claude --bg` in the folder is
  the consent the prompt would ask for. Never in the native file.
- **What went.** The wrapper machinery that sandboxed each worker from a daemon on
  the host: `--wrap`, `CLAUDE_CODE_PROCESS_WRAPPER`, the per-`--bg` project record,
  the pool reap and the daemon restart, and the `sandbox` scope that made it opt-in
  (`--sandbox`, `AGENT_SANDBOX_CLAUDE_SANDBOX`, `[claude] sandbox`, each refused by
  name). A session runs without a sandbox only by `--preset none`, typed per launch.

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
| Secret stores and the sandbox's own control plane never enter. Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.password-store`, `~/.config/{gcloud,sops,gh}`, `~/.local/share/keyrings`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`) and the control plane (`~/.config/agent-sandbox`: trust store, allowlist, addon; `~/.mitmproxy`: the CA key; `~/.local/share/agent-sandbox`: the proxy runtime; `~/.local/state/agent-sandbox`: per-project state such as each project's copy of the agent's config file; `~/.local/bin`: the launcher; `~/.config/systemd`: user units) are refused as CWD and as a path declaration, read-only included, and so is any directory that contains one (`~/.config`, `~/.local`). The one exception is `~/.local/bin` declared read-only: its harm is a write (re-pointing a launcher), and read-only it puts your commands on the sandbox's PATH. `/`, `$HOME` and any parent of `$HOME` are refused too. The list is a blocklist and cannot be complete; a path not on it that you bind is yours to judge. | `_as_secret_paths`, `_as_control_paths`, `_as_path_protected` (one rule for binds and CWD), `_as_check_paths`. | `tests/unit/helpers.bats` (`_as_check_paths`: each kind, containing directories, siblings pass), `tests/unit/argv.bats` (CWD and bind refusals: exit 1, bwrap never invoked). |
| Clean environment. Everything is cleared; only locale, colour hints, the profile's variables, proxy and CA variables, CUDA variables, and `AGENT_SANDBOX_FORWARD` names are forwarded. bwrap itself, pid 1 inside and readable there, runs with no environment, and its options are not on its command line. | `--clearenv` plus explicit `--setenv`; bwrap is executed with an empty environment and `--args` from a file in the session directory, removed once opened (`_as_launch`, `_as_keeper_exec`, the strict wrapper, which also reads the proxy token from there rather than from pasta's command line). | `tests/unit/argv.bats` (environment allowlist, FORWARD, bwrap given nothing), `tests/unit/strict.bats` (the same through pasta), `tests/integration/sandbox.bats` (a host variable is unset inside, and pid 1's environment is empty). |
| Egress allowlist (default `proxy` mode). Every client that honours `HTTPS_PROXY` reaches the network only through the host proxy, which refuses non-allowed hosts at the CONNECT stage, before any upstream connection, and again per request inside an allowed tunnel. The decision is made on the destination the proxy actually dials -- the request-line authority, not a client-supplied `Host` header -- and any destination that resolves to a non-public address (loopback, private LAN, link-local/cloud-metadata) is refused before the socket opens, whatever its name, so the proxy cannot be turned into a path to host-local services. Refusals are logged. | `components/allowlist_addon.py`: `http_connect` and `request` gate `request.host`; `server_connect` refuses non-public resolved destinations (`_forbidden_destination`, `_addr_is_public`). | `tests/unit/addon.bats` (CONNECT and request refusals with a stubbed mitmproxy; the request-line-vs-Host-header gate; the resolved-destination gate for literals and for a name that resolves to a private address); `tests/e2e/install.bats` (a spoofed `Host` and an allowlisted loopback literal both refused against the real installed proxy, the loopback listener never hit). Zero upstream connects on a blocked CONNECT was verified once with a local mitmdump log. |
| Strict network mode (opt-in, `AGENT_SANDBOX_NET=strict`). The sandbox gets its own network namespace, owned by `pasta` and forwarded in userspace; an nftables rule inside allows only the proxy on the gateway, and pasta's port forwarding is off both ways, so a tool ignoring `HTTPS_PROXY`, host loopback services and the LAN are all unreachable — only the proxy is. The agent is root only in bwrap's child user namespace, which has no authority over the netns pasta's parent namespace owns, so it cannot alter the firewall. `--host-port`/`--agent-port` open named TCP ports, and `--ssh HOST` opens a firewall pinhole to that host's resolved IPv4 (with an `/etc/hosts` entry so its name resolves without DNS; `--ssh-unrestricted` is refused, as the firewall must pin a named host). | `_as_launch_pasta` (pasta + the nft ruleset), `_as_strict_ssh_rules`, the `strict` arm of the engine, the userns nesting. | `tests/unit/strict.bats` (the pasta/nft argv: netns, `policy drop`, only the gateway proxy, port forwarding off, ports opened on request), `tests/integration/strict.bats` (real pasta+bwrap+nft: proxy reachable at the gateway only, raw egress, host loopback and publishing a sandbox listener all blocked, ports opened on request). `install.sh` re-checks the contract on the host. |
| Per-session `--allow` hosts are scoped to their session and lapse with it. The engine writes them to the session dir with a per-session token, carried in the sandbox's proxy URL; the addon applies them only for a request bearing that token, and only while the process stamped in `owner.id` is alive (PID and start time, so a recycled PID never counts). Another session's `--allow` is not reachable. | `_as_allow_setup` (token + hosts), `_session_allow`/`_token_from`/`_owner_alive` in the addon. | `tests/unit/addon.bats` (a host is reachable only with its session's token and while the owner is alive; dead, recycled-PID, unstamped and cross-session all denied; the CONNECT token carries into the tunnel's inner requests), `tests/unit/argv.bats` (the token is minted, stored 0600, and set as the proxy URL's userinfo). Verified live once: alive 200, owner killed 403. |
| The proxy CA is trusted inside the sandbox only. The engine binds (system bundle + CA) over `/etc/ssl/certs/ca-certificates.crt` and points the CA variables of tools with private stores at it. The host trust store is never touched. | `_as_ca_bind`, `_as_ca_env`. | `tests/unit/helpers.bats` (`_as_ca_bind`, `_as_ca_env`), `tests/integration/sandbox.bats` (bundle inside is the system bundle plus the given CA; plain system bundle with a warning when the CA is missing). Python 3.14 strict verification through the live proxy was checked once by hand. |
| SSH keys never enter. `--ssh HOST` starts a per-session ssh-agent on the host, loads the key with an OpenSSH destination constraint, binds only the socket (and the public `known_hosts`/`config`, also at uid 0's home, since in `strict` ssh resolves `~` to root's) (plus read-only `known_hosts` and `config`). The agent refuses to sign for any other host. Teardown kills the agent and removes the socket. | `_as_ssh_setup`, `_as_session_cleanup`. | `tests/integration/ssh.bats` (generated host key: constrained key listed inside, `~/.ssh` and the private key invisible, known_hosts read-only, agent dead and dir gone after exit; unknown host refused before any session exists). |
| Concurrency-safe sessions. Each keeper gets its own directory; the janitor reaps only directories whose owner (PID and start time) is gone and never touches unstamped or live ones. | `_as_session_begin`, `_as_session_sweep`; the keeper's supervisor restamps the directory as its own. | `tests/unit/helpers.bats` (`_as_session_sweep`), `tests/unit/keeper.bats` (the supervisor owns it, and it goes with the keeper), `tests/integration/ssh.bats` (janitor at launch; `--ssh` and `--allow` share one dir). |
| One launch per role. Two invocations of one role at once are one sandbox: the second is a process joined into the first one's launch, in the same mount namespace, so there is never a second set of mounts -- in particular never two overlays over one upper layer, which overlayfs calls undefined. A joined process is the launch's equal in mounts, uid and gid, capabilities, `no_new_privs` and seccomp; its environment is the launch's but for the terminal's variables. Policy is fixed when the launch starts: a join that sets a knob to a value other than the running one is refused, naming it, while anything is joined; an idle launch in its grace is replaced instead. A join parses the keeper's copy of the approved dot-file, so an unapproved edit to the live file refuses it only when the role has to be read from that file. The launch ends once nothing is joined, never while a join is in progress. | `_as_keeper_*` in the engine (the lock, the record, the supervisor, `_as_keeper_admit` for the policy), `components/join.py` (the `setns` chain, the bounding set, `no_new_privs`, the filter). | `tests/unit/keeper.bats` (a second invocation builds nothing and joins; the policy rule per knob; the dot-file warning; the terminal's variables; a failed start), `tests/integration/keeper.bats` (real bwrap: one mount namespace and one superblock for two sessions; the joined process's status lines and mounts equal the launch's, with the real filter; the environment split; stores shared; the keeper outliving any one join and ending after the last; a join during the grace; Ctrl-C; `proxy` and `strict`). Mutation-checked: the policy check, the terminal variables, the recount, the join's filter and the join count. |
| Self-update runs on the host, never inside. `claude update` typed at your shell is Claude Code's own, since nothing shadows `claude` (#151); `asb claude update` runs inside like any command, where the download is blocked and the versions directory is not bound. `DISABLE_AUTOUPDATER=1` inside. | `profile_env_set`. | `tests/unit/profile-claude.bats` (`asb claude update` is joined like any command). |
| Per-project policy is trust-gated. A project's `.agent-sandbox` (allow hosts, memory scoping, paths, environment, conda, network) is honored only once approved, its SHA-256 and its content recorded. The review is part of the launch (#143): with a terminal, a new, changed or missing file is shown -- a changed one as a diff from the approved content -- and asked about, yes approving and launching, no launching nothing; without a terminal the launch refuses, and `--trust` is the same review without a launch. A new file refuses too, rather than being ignored. The file is read-only inside the sandbox (a built-in path declaration; `copy` may be declared, `read-write` is refused; not under `native`), so the agent is never its author. Inside a sandbox -- pid 1 is bubblewrap, not merely the marker set -- there is no gate: a nested sandbox only narrows. Refusing rather than ignoring matters because ignoring would fall back to the defaults, and a default can be wider than the policy you approved (a project pinning `[net] mode = strict` would drop to the default `proxy`). So the agent can neither grant itself anything nor quietly regain the defaults. The review shows the file escaped (`cat -v`) and a file containing control characters is refused at review and at launch, so no line can be hidden from the reviewer. The trust store and global config live under `~/.config/agent-sandbox`, which is never bound into the sandbox. | `_as_dotfile_trusted`, `_as_inside_sandbox`, `_as_trust_record`, `_as_trust_prompt`, `_as_dotfile_parse`, `_as_dotfile_clean`, `_as_trust_review`, the review and the trust-record check at launch, the built-in `./.agent-sandbox` declaration. | `tests/unit/dotfile-review.bats` (at a terminal: new shown whole, changed as a diff, missing offers to forget; no records and launches nothing; a join is asked and joins under the keeper's policy; `AGENT_SANDBOX=1` on the host keeps the gate; read-only bind, `copy`, `read-write` refused, not under `native`), `tests/integration/dotfile.bats` (unwritable inside under the real bwrap; `copy` writable and the project's file untouched; the engine inside knows it and needs no approval), `tests/unit/dotfile.bats` (unapproved refused with a pointer to `--trust`; an edit and a deletion refuse to launch, bwrap never invoked, until `--trust` re-approves or forgets; an approved file adds allow hosts; `--trust` records the hash and offers to git-ignore; a file with an ESC sequence or a carriage return is refused at review and at launch, UTF-8 is shown escaped and accepted). |
| Memory is scoped per project by default. Two channels cover `~/.claude/projects` (#196): `projects`, every project's state, is the role's own store under every preset but `native`, so a session cannot read other projects' notes or transcripts; `memory`, this project's `projects/<slug>/memory/`, is the role's own under `isolated` and `inherit` and the native memory under `shared` and `native`. Channel paths and declarations are bound by depth, outer first, so `projects`, this project's conversations (`transcripts`) and its memory nest, each at its own mode. "The current project" is the session's directory: the engine binds that directory and not its parents, so a session below a repository root has no `.git` in view and Claude Code keys its memory to the directory, not the repository -- subdirectories of one repository are separate projects inside the sandbox, though they share one memory natively. `[share-memory]` is sugar: a path P is the declaration `{base}/projects/{slug:P}/memory/ = read-only sandbox:P` -- P's default role's store, from its record of its last launch, or P's native memory if it never ran sandboxed (#200), a wildcard is expanded at launch to the matching projects whose memory resolves, `all` is `projects = read-write`; a share naming the current project is dropped. | `_as_connect_bind_all` (one pass by depth: channels, declarations, the per-session scratch), `_as_share_memory_sugar`, `_as_sandbox_store` and the per-launch record (`sandbox:`), `{slug:PATH}` in `_as_slug_expand`; the `projects` and `memory` channels and their `[preset:...]` rungs in `profiles/claude/agent-sandbox`. | `tests/unit/transcripts.bats` (memory inside the transcripts store inside the projects store, by depth; the native memory bound back under `shared`; `copy-on-write`), `tests/unit/dotfile.bats` (a share read-only, a wildcard, the current project dropped, `all`, the slug scheme), `tests/unit/connect.bats` (declarations nested by depth; a channel inside a declaration keeps its mode), `tests/unit/sandbox-source.bats` (the record, a store by mode, no record as native, the refusals, shares and wildcards through `sandbox:`), `tests/integration/memory.bats` (real bwrap: other project invisible, shared `memory/` read-only, current writable; under `inherit` the native memory out of view and a write kept in the role; a reviewer reading its implementer's memory read-only). |
| Conda write mode is bounded. Only the active env becomes writable; the base install, other envs, conda itself, its shell hook and the host package cache stay read-only. Downloads go to a sandbox-owned cache. | conda block in the engine; `CONDA_PKGS_DIRS`. | `tests/unit/argv.bats` (bind order and modes), `tests/integration/conda.bats` (fake layout: env writable only in write mode; base, other env and host cache never; sandbox cache first). A real nested `mamba install` was checked once at extraction. |
| All capabilities are dropped. The agent's effective and bounding capability sets are empty in every network mode, so a setuid binary or a capability-checking syscall gains it nothing. Needed most in `strict`, where bwrap runs inside pasta's root-owned user namespace and would otherwise start the agent as uid 0 with the full set. | `--cap-drop ALL` in the base bwrap arguments. | `tests/unit/argv.bats` (the flag is in the argv for every mode). Confirmed on a host that a root-in-userns bwrap goes from `CapEff: 000001ffffffffff` to `0000000000000000` with it. |
| Cross-session state is isolated, unconditionally. The `projects` channel covers `~/.claude/projects` and leaves the rest of the state directory readable, and most of it is keyed by session rather than by project. The per-launch parts are replaced by a tmpfs at every launch: `session-env`, `sessions`, `jobs`, `shell-snapshots`, `debug`, `paste-cache`, `backups` (config snapshots that kept purged projects, #75), `feedback-bundles` (unsent bug reports, #80), and `daemon`, the background supervisor's control key and its roster of other sessions, a channel between sessions rather than this session's state. The rest are channels since #120, each the role's own under every preset but `native`: `transcripts` -- this project's conversations under `projects/<slug>/`, `file-history` (verbatim file contents -- 40M across twelve sessions and thirty projects on one developer machine), `plans`, `history.jsonl` (every prompt typed anywhere) -- and `logs`, what the user's own hooks write (`responses.log`, `alerts.log`). Nothing is merged back into the native state when a launch ends. A role starts with none of the native history; `transcripts = seed-only` seeds it once, the prompt history filtered to this project's records by the JSON `project` field, so another project's records cannot pass. The project's memory, inside `projects/<slug>/`, is the `memory` channel, bound on top of the role's store by depth. What is left visible in `~/.claude` is visible on purpose (`gh` and `ide` exist to let Claude Code work from inside a sandbox), and `[claude] hide` is there for a user who disagrees about a particular path. The list is ours to maintain and will lag what upstream adds -- `ide` appeared after this isolation was built. | `_as_hide_spec` and `_as_connect_bind_all` in the engine (the tmpfs mechanism); `[agent] hide` in the claude profile's dot-file (which paths); the `transcripts` and `logs` channels in `profile_channels`, `_claude_history_view` for the seed filter. | `tests/unit/isolation.bats` (tmpfs for the per-launch parts, the role's stores for the rest, a canary from another session absent, nothing merged back), `tests/unit/transcripts.bats` (every preset, the seed filter, memory inside, two roles), `tests/integration/isolation.bats` (real bwrap: a canary in another session's `file-history` and `plans` unreadable from inside, the session's writes persisting to the next launch in the role and never reaching the host). |
| The config file `.claude.json` is the `config` channel (#119): one file following its mode. The native file holds the account, the user-level `mcpServers`, app state, and one entry per project (trust, allowed tools, project MCP servers, the last opening prompt). Under `inherit` and `shared` the role gets its **own copy**, `seed-only`: seeded once with every top-level key and only this project's entry, kept under `~/.local/state/agent-sandbox/claude/<slug>/<role>/config/` (a control path, never bound in), and after that Claude Code's alone -- the engine never reads or writes anything inside it again, `mcpServers` included. `own` (under `isolated`) starts from `{}`; Claude Code runs on it beside the credentials file and rebuilds the account block itself (measured, 2.1.283). `read-only`/`read-write` bind the native file whole, valid but not advocated; `native` binds and relocates nothing. The file is bound **inside** the state directory at `~/.claude/.claude.json`, with `CLAUDE_CONFIG_DIR` pointing Claude Code there, because Claude Code writes it through a lock directory and a temp file created beside it, and beside the read-only `$HOME` those failed silently: before this, every write a sandboxed session made to it was lost while the session reported success. The rename onto the bind mount fails and Claude Code rewrites the file in place; that write is not atomic. `user-mcp` is removed and refused, naming `config = own` (#132). `telemetry/` stays a deliberate cap: no project paths were found in it. | the engine's channel hooks (`profile_channel_sources`, `profile_channel_filters`, `profile_channel_start`, `profile_channel_presets`), filled from `profiles/claude/agent-sandbox` (the `config` channel's section and `start:` template, the `[preset:...]` rungs, the `[env]` pins); `profiles/claude/profile.sh` (`_claude_config_filter`, `_claude_config_prepare`: the base's own config file when `CLAUDE_CONFIG_DIR` is set, and `native`); the engine's `_as_state_dir` is in `_as_control_paths`, and the engine removes the empty mount-point file bwrap leaves on the host. | `tests/unit/config-channel.bats` (every mode, the filter, the presets, the migration, reset, a missing python3 and a failing view, the `user-mcp` refusal, the native `mcp` routing), `tests/unit/argv.bats` (the bind and the variable), `tests/unit/helpers.bats` (the state dir is refused), `tests/integration/config-file.bats` (inside: the role's filtered seed, the write lands in the store and the native file is byte-identical; at `read-write` it lands in the native file). |
| The sandbox tells the agent what it allows. Each launch writes a briefing from the resolved policy -- egress mode and allowlist size, session `--allow` hosts, extra writable and read-only paths, which projects' memory is readable, `--ssh` hosts, seccomp state -- bound read-only at `/run/agent-sandbox/`, plus the recipe for asking the user to open something. Names and paths only, never the contents of anything shared. On by default: the sessions that most need it are the ones nobody configured. | `_as_briefing_write` in the engine composes it; `profile_briefing_args` in the claude profile delivers it as `SessionStart`/`SubagentStart` hooks via `--settings`. Hooks rather than `--append-system-prompt`, which switches system-prompt snapshotting off; with snapshotting on a recorded prompt is reused until compaction, so a resumed session would keep describing a policy the user had since changed. A hook is re-run every launch, resume and compaction instead. Claude Code honours only the last `--settings`, so a user-supplied one is merged (`profiles/claude/profile.py`) and ours goes last; if the merge is refused the user's is kept and the loss is announced. | `tests/unit/briefing.bats` (binds and flag present and read-only, both hook payloads, the policy actually stated, the canary never read out of a shared project, `off` suppresses everything, dot-file and knob precedence, an unknown value refused, a user `--settings` merged both spellings, and the merge-failure fallback keeping the user's file). |
| Syscall filtering. With the filter on (the default) every syscall not on an allowlist fails with `EPERM`: `unshare`, `setns`, `mount`, `pivot_root`, `chroot`, `bpf` and the capability-gated `ptrace` family stay denied, `clone` is allowed only without namespace flags and `clone3` returns `ENOSYS`, so the agent cannot create a user namespace to regain capabilities. On by default (issue #4). It is not merely defence in depth on a machine where `install.sh` ran: the AppArmor profile it installs for bwrap is `flags=(unconfined)` with `userns,`, and an AppArmor profile is inherited by children -- so every process under bwrap is exempt from `kernel.apparmor_restrict_unprivileged_userns=1`, the very restriction that would otherwise stop a sandboxed agent creating a user namespace. With the filter off, nothing else does. Found by a probe run, 2026-09-11; the behaviour was already asserted by `tests/live/seccomp.bats` ("without seccomp (control) ... a user namespace can be created") but its cause was not written down. If no filter is compiled for the architecture the engine warns each launch and runs without it, rather than refusing a tool the user never asked to change. | Docker's default seccomp profile (vendored, Apache-2.0) compiled *as for a container with no capabilities* by `components/seccomp/gen-seccomp.py`; `install.sh` builds it per machine against that host's libseccomp; the engine passes `--seccomp` with the blob on fd 10 (opened by `_as_launch`, or by the strict wrapper inside pasta). | `tests/unit/seccomp.bats` (flag and fd only when enabled, per-arch, refusals), `tests/unit/strict.bats` (the wrapper opens the fd), `tests/live/seccomp.bats` (filter active inside; creating a user namespace refused, versus a control launch), `tests/live/agent.bats` (the real agent completes a turn under it, in proxy and strict). |

### Running something other than the agent: `--exec`

`--exec CMD [ARGS...]` runs CMD in place of the agent, in the sandbox the profile
would have built for it. It is a deliberately small mechanism -- every launch is a
keeper that the command is joined into, and `--exec` substitutes only the command
joined -- which is what makes it **a simple but reliable way to run a command in an
environment identical to a sandboxed agent session**. Identical is meant
literally: the same binds, environment, PATH, network mode and allowlist,
seccomp filter, state isolation and per-project `.agent-sandbox` policy, because
they are computed by the same code before the command is chosen. A shell there is
the agent's sandbox with a different entrypoint, which is why it needs no
profile-composition machinery. Beside a running agent of the same role it is not
even a copy: it is a process in that agent's own sandbox. That makes it the tool of choice for inspecting or
reproducing what a session sees, and for hosting agent sessions inside one
sandbox: the agent binary stays bound read-only, so an agent started from within
runs natively there.

Two dispatches are bypassed under `--exec`, because each interprets the first
argument: the management verbs (`agents`, `daemon`), and `profile_briefing_args`, whose `--settings` flags would corrupt an
arbitrary command line. `briefing.md` is still bound read-only.

**Scope note.** A project's `.agent-sandbox`, once approved, grants its policy to
whatever `--exec` runs there, not only to an agent session. This is not an
escalation -- the user already has full access to their own host, and types the
command themselves -- but the trust review's scope is properly read as "this
policy, for what I run in this project", not "this policy, for the agent".

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
  the cost of a `passt` dependency. In the default `proxy` mode the
  allowlist is a control on well-behaved clients, not a network boundary; the
  user chooses the mode and its residual risk.
- **DNS rebinding with a zero-TTL name can still race the destination check.**
  The proxy refuses to dial a destination that resolves to a non-public address,
  but for a domain name it resolves once to decide and mitmproxy resolves again
  to connect. An attacker who both gets a name onto the allowlist and controls
  its DNS to return a public address on the first lookup and a private one on
  the second could slip a single connection through between the two. The static
  cases -- an allowlisted name that simply resolves to loopback/private (`localhost`,
  an `/etc/hosts` entry, a stable record) -- are closed deterministically; only
  the time-of-check/time-of-use race on an attacker-controlled zero-TTL record
  remains, and it still requires the name to be on the allowlist. `strict` mode
  narrows it further (the netns has no route but the proxy).
- **`--allow` is scoped per session.** The engine mints a per-session token,
  carries it in the sandbox's proxy URL, and the addon grants the global
  allowlist plus only the matching live session's `--allow`, so one session's
  `--allow` hosts are not reachable from another (issue #5). The token is
  visible inside its own sandbox but grants only that session's own `--allow`,
  and another session's token (random, mode 0600, never bound in) cannot be
  forged. A client that drops the proxy's `Proxy-Authorization` gets the global
  allowlist only — fail-closed for `--allow`, never wider.
- **The agent's own credentials are inside, and so is anything else kept
  there.** `~/.claude` holds Claude's OAuth or API tokens and is read-write;
  the agent authenticates with them, so they cannot be hidden. Any allowed
  host, api.anthropic.com first among them, is an exfiltration channel for
  anything the agent can read. The sandbox cannot prevent this. Beyond the
  tokens the directory is a catch-all: Claude Code keeps its own state there,
  and so does anything you put there. On a machine where `~/.config/gh` is
  refused, a GitHub config under `~/.claude` is the obvious workaround — and it
  means the agent can read that token, which is a second way to grant GitHub
  access besides `[env] GH_TOKEN`, deliberate rather than a leak.
  `[claude] hide` blanks named subpaths for the cases where you want one gone,
  at the cost of whatever feature used it.
- **What a session writes in `~/.claude` can steer later sessions -- how far
  depends on the preset.** `settings.json` has to stay writable -- `/model` and
  `/permissions` write it, and so does the agent when the user asks it to change
  a setting -- and that file can register arbitrary hook commands.
  - Under **`inherit`** (the default) and **`isolated`** the declared channels are
    the role's own: `settings.json` and `CLAUDE.md` are its `copy` stores (`own`
    under `isolated`), `skills/`, `agents/`, `workflows/` and `plugins/` its
    overlays, the config file its `seed-only` copy. A hook a session registers,
    or an edit to the global `CLAUDE.md`, stays with that role (measured, #142).
  - Under **`shared`** and **`native`** those are your native files, so the same
    write runs in every later session of every project that shares them, and on
    the host the next time you run `claude` itself.
  - Under **every** preset, what no channel declares is the native directory,
    bound read-write: the scripts your hooks run (a `response-hook.py` wired to
    `Stop`, say), the rest of `cache/`, `telemetry/`, `usage-data/`,
    `stats-cache.json`, and whatever else you keep there. A session
    that rewrites a hook script runs code in every later native `claude` session
    -- which, with nothing shadowing `claude` (#151), is every one you start without
    `asb` -- and in every role whose settings register it. Where such files should
    belong is open (#142); `[claude] hide` blanks a path you would rather keep out.
  Isolation here covers reading -- another project's transcripts are hidden --
  and, at the default preset, writing to the declared channels; not writing to
  the rest of the shared directory. Stated plainly rather than half-closed.
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
- **Project state is keyed by a lossy slug.** Claude Code names a project's
  state directory after its path with every character outside `[A-Za-z0-9-]`
  turned into `-`, so two projects whose paths differ only in a converted
  character (`~/x.y` and `~/x-y`) share one directory, and scoping cannot
  separate them. The scheme is Claude Code's, undocumented, and pinned by
  `probes/slug-probe.sh` plus a unit test; a release that moved it would break
  scoping, which is why the test exists.
- **The `projects` channel covers `~/.claude/projects` only.** It isolates
  per-project memory and transcripts; the rest of `~/.claude` is the other channels'
  and the per-session scratch's, and what none of them names stays visible. And a `.agent-sandbox` grants exactly what you approved: `--trust`
  shows the file before recording it, so review is where the security sits.
- **All capabilities are dropped** (`--cap-drop ALL`), in every network mode.
  In `proxy`/`open`/`none` bwrap is unprivileged and the agent has none anyway;
  in `strict`, where bwrap runs inside pasta's root-owned user namespace, the
  drop is what keeps the agent from starting with the full capability set. A
  determined agent can still make its own user namespace and hold namespaced
  capabilities inside it (in any mode, via `unshare -U -r`), but they are
  confined there and grant nothing over the host; the seccomp filter, on by
  default, refuses that too.
- **In `strict` the agent runs as uid 0.** pasta maps your single uid to root in
  its user namespace, and bwrap's child namespace inherits that, so `id -u` is 0
  inside. It is root only there, with no capabilities, and files it writes land
  as you on the host, so it grants nothing extra. It does change behaviour:
  tools that refuse to run as root behave differently, and anything resolving
  `~` through the passwd database sees root's home instead of `$HOME` (which is
  why `--ssh` binds `known_hosts` and `config` at both).
- **Seccomp can be disabled, and there are no resource limits.** The
  default-deny syscall filter is on by default, but `AGENT_SANDBOX_SECCOMP=off`
  turns it off, and a host with no filter compiled for its architecture runs
  without one (with a warning). Without the filter nothing narrows the syscall
  surface, so a kernel bug reachable from an unprivileged process is reachable
  from the sandbox. There are no CPU, memory or disk limits in any
  configuration.
- **SSH constraints are host-level, not operation-level.** Within a permitted
  host the tunnel is opaque: a force-push cannot be blocked. `--ssh-unrestricted`
  lets the session authenticate as you to any host that trusts the key, for as
  long as it lives (`--ssh-timeout` bounds that).
- **An orphaned ssh-agent is reaped, not prevented.** If the engine is
  SIGKILLed, its agent lives until the next launch's janitor finds it dead.
- **Host-side subcommands run unsandboxed.** `asb claude update` runs the agent
  on the host with your full environment, as `claude update` does.
- **The proxy is a host process that sees all traffic.** Its CA's private key
  lives in `~/.mitmproxy` on the host (not visible inside). Compromise of the
  proxy or that key is compromise of every sandbox's TLS.
- **The engine trusts the host's `/etc` and `/usr`.** A compromised host is out
  of scope.

## Open design questions

Recorded so they are not re-derived from scratch; each has measurements or
reasons attached in the repository history.

- **Running without a user systemd** (WSL with systemd disabled, containers).
  The installer and the unit assume `systemctl --user`. A no-systemd mode needs
  a story for starting the proxy at login, restarting it on failure and
  logging, not only a flag; and under Docker's default seccomp profile bwrap's
  user namespaces are blocked anyway. Deferred.


- **SNI/TLS-passthrough allowlisting.** Enforce the allowlist on the CONNECT
  host and relay TLS untouched (as
  [FoamoftheSea/claude-code-sandbox](prior-art.md) does with Squid). Measured:
  71 MB/s versus 50 to 74 MB/s for interception with `http2=false` and response
  streaming; it would remove the CA entirely. Rejected for now because
  interception keeps per-path logging and 403 bodies, and because a non-HTTP
  protocol could then be tunnelled to an allowed host's port 443. Revisit if
  the CA proves a burden.
- **Strict network mode** (decided, shipped) is implemented with pasta (it owns the netns; bwrap
  runs inside sharing it; an nftables rule allows only the proxy). slirp4netns
  could not, because it cannot enter bwrap's unprivileged netns from outside.
- **A standalone mitmproxy binary route** for hosts with neither
  `python3-venv` nor conda: `downloads.mitmproxy.org` serves a 119 MB tarball
  but publishes no checksums or signatures, so it needs a SHA256 pinned per
  version and architecture in this repository. Deliberately deferred.
- **What passes between sandboxes** (issues #90, #55). The per-path
  dispositions above default an unclassified path to *shared*, and the leak
  study found six such paths. [connections.md](connections.md) proposes the
  replacement: a sandbox is an installation keyed by project and role, and
  what it shares is a set of explicit connections, each on a
  `own < seed-only < copy < copy-on-write < read-only < read-write` scale, with identity and the project
  directory the only mandatory ones. Proposed, not implemented; the config
  file's per-project copy (0.2.1) is its first channel.
