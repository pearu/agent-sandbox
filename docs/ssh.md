# SSH access: the destination-constrained broker

By default a session has **no** SSH credentials: nothing under `~/.ssh` is
bound and no agent socket is forwarded. It cannot push, cannot ssh anywhere,
and cannot post to a remote. That is the locked tier and needs no flag.

## Flags

Engine flags come before the agent's own arguments and are stripped before the
agent sees the command line.

| Flag | Meaning |
|---|---|
| `--ssh HOST` | Allow SSH to HOST. Repeatable; adds to the project file's `[ssh]` hosts (below). HOST is anything ssh accepts: a hostname, `user@host`, or an alias from `~/.ssh/config` (HostName, User, Port and IdentityFile are honoured; resolution is done on the host with `ssh -G`). |
| `--ssh-unrestricted` | Allow SSH anywhere the key is accepted. Mutually exclusive with `--ssh HOST`. The escape hatch. |
| `--ssh-key PATH` | Private key to use. Default: the first readable IdentityFile ssh itself would try for that host (config-aware; FIDO `*_sk` keys are skipped). |
| `--ssh-timeout LIFE` | Expire the loaded key after LIFE (seconds, or e.g. `30m`, `2h`). Off unless given. |

## In the project's file: `[ssh]`

A host a project's sessions always need goes in its `.agent-sandbox`, one per line,
in the forms `--ssh HOST` takes, and per role with a suffix
([config.md](config.md)):

```ini
[ssh:gh-fix-*]
github.com                # the fixers' ghstack pushes through an SSH origin; no other role gets SSH
```

`asb --apply '[ssh:gh-fix-*]' github.com` adds the line and runs the review. Like
every section it counts only once approved, and the review says it is a widening: the
role signs in as you at that host. At a launch the section's hosts for the role and
the launch's `--ssh` hosts are one list, through everything below: the destination
constraint, the `known_hosts` check, strict mode's pinholes. `--ssh-unrestricted`,
`--ssh-key` and `--ssh-timeout` stay on the command line -- a project's file never
picks your key or lifts the constraint; given at a launch, they apply to the file's
hosts too, and with `--ssh-unrestricted` the file's hosts are within the unconstrained
key (the launch says so). The hosts stand alone (#293): `[net] git` and `retrieve-only`
govern git over HTTPS, not SSH, so a role under `git = fetch` or `refuse` gets the
file's hosts and its `--ssh` hosts like any other, and a push over SSH to a remote on
one of them is possible where the account allows it. `asb --check --role R` lists a
role's hosts with the section each came from and says that; the review and the
session's briefing name them and say it too.

## How it works

The engine starts a fresh `ssh-agent` for this session only, loads the key into
it, binds just that agent's unix socket into the sandbox and exports
`SSH_AUTH_SOCK`. ssh and git inside ask the host agent to sign; the private key
is never visible inside. When the session ends the agent is killed and its
socket removed. An agent orphaned by an uncatchable kill (SIGKILL of the engine)
is reaped by the next launch's janitor, which skips sessions that are still
running, so this is safe with any number of concurrent sessions. Session state
lives under `$XDG_RUNTIME_DIR/agent-sandbox.<uid>/` (falling back to `/tmp`).

**Per-host enforcement.** With `--ssh HOST` the key is loaded with an OpenSSH
destination constraint (`ssh-add -h`, OpenSSH 8.9 or newer). The agent then
refuses to sign for any other host; for a non-permitted host the key is not
even offered. This matters because SSH is a raw socket and, in `proxy` mode,
shares the host network namespace, so the egress allowlist cannot see or filter
it. The constraint is the control.

In the `strict` network mode the sandbox has its own network namespace whose
firewall drops everything but the proxy, so `--ssh HOST` additionally opens a
pinhole: the host is resolved to its IPv4 address(es) on the host side, an
nftables rule permits TCP to each on the SSH port, and the name is written into
the sandbox's `/etc/hosts` (DNS is blocked there). All IPs returned are pinned,
so a round-robin rotation within the session still connects. `--ssh-unrestricted`
is refused in strict mode — there is no named host to pin — and IPv6-only hosts
are not supported yet. The destination constraint still applies, so the firewall
hole and the key are limited to the same named hosts.

**User pinning.** The constraint carries a user only when you asked for one:
you wrote `user@host`, or `~/.ssh/config` sets `User` for that alias. So
`--ssh github.com` permits any user (`git@` included); `--ssh git@github.com`
permits only `git@`. Non-22 ports are handled (`[host]:port`, as `known_hosts`
stores them).

## What the key may do on a host

The sandbox decides where ssh can go, not what it does there. One connection carries
a shell, a `git push`, a port forward or a file copy alike, and the sandbox cannot
split a shell from a push on it: the session is encrypted end to end, and ssh knows
nothing about git. So `[net] git` and `retrieve-only`, which the proxy applies to
HTTPS, do not reach into SSH, and git over SSH reaches exactly the hosts the role may
sign in to.

What the key may do on a host is the remote's rule. On a server you run, the
`authorized_keys` line for the key says it: a forced command (`command="..."`, e.g.
one that serves only `git-upload-pack`), `restrict` (no pty, no forwarding), `from=`.
On a hosting service it is the account's: a deploy key or a machine account without
push rights where the role must not push. An ssh config inside the sandbox is advisory
-- the agent can pass `-F /dev/null` or its own options -- and the limit is the
broker's host constraint and the server's host key check, both on the host.

## Requirements and limits

- The host's key must already be in `~/.ssh/known_hosts` on the host: agent
  constraints are keyed by host key. If it is not, the engine refuses with a
  hint; connect once from a host shell (`ssh HOST`). This is deliberate: no
  trust-on-first-use is done for you.
- `~/.ssh/known_hosts` and `~/.ssh/config` are bound read-only into the sandbox
  (public data). Nothing else under `~/.ssh` is, except the public half, `KEY.pub`, of
  each key the broker loads, so a config with `IdentitiesOnly yes` still selects the
  agent's key. Without a `KEY.pub` beside the key, drop `IdentitiesOnly` for that host
  (the engine says so with `--verbose`). `Include` files referenced from `config` are
  not bound; keep aliases in the main file.
- The system config's includes, `/etc/ssh/ssh_config.d/*`, are bound as copies owned
  by you, made at each launch: the originals are root's, which the sandbox's user
  namespace does not map, and OpenSSH refuses an included file owned by neither root
  nor you (10.2 on Ubuntu 26.04, whose systemd puts `20-systemd-ssh-proxy.conf` there:
  every ssh exited 255 with "Bad owner or permissions"). An edit on the host reaches
  the next launch.
- An encrypted key prompts for its passphrase once, on the host tty, at launch.
  A non-tty launch cannot prompt.
- Constraints are host-level, not operation-level: within a permitted host the
  tunnel is opaque, so a force-push cannot be blocked.
- `--ssh-unrestricted` loads the key with no constraint: a compromised session
  can authenticate as you to any host that trusts the key for as long as the
  session lives. Mitigate with `--ssh-timeout`.

## Git identity

`~/.gitconfig` is not bound into the sandbox, so a global git identity is
invisible inside and commits fail with "Author identity unknown". The engine
prints a hint at launch when the repository has no local identity. Set one
from a host shell:

```
git -C /path/to/repo config user.name  "$(git config --global user.name)"
git -C /path/to/repo config user.email "$(git config --global user.email)"
```
