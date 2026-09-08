# SSH access: the destination-constrained broker

By default a session has **no** SSH credentials: nothing under `~/.ssh` is
bound and no agent socket is forwarded. It cannot push, cannot ssh anywhere,
and cannot post to a remote. That is the locked tier and needs no flag.

## Flags

Engine flags come before the agent's own arguments and are stripped before the
agent sees the command line.

| Flag | Meaning |
|---|---|
| `--ssh HOST` | Allow SSH to HOST. Repeatable. HOST is anything ssh accepts: a hostname, `user@host`, or an alias from `~/.ssh/config` (HostName, User, Port and IdentityFile are honoured; resolution is done on the host with `ssh -G`). |
| `--ssh-unrestricted` | Allow SSH anywhere the key is accepted. Mutually exclusive with `--ssh HOST`. The escape hatch. |
| `--ssh-key PATH` | Private key to use. Default: the first readable IdentityFile ssh itself would try for that host (config-aware; FIDO `*_sk` keys are skipped). |
| `--ssh-timeout LIFE` | Expire the loaded key after LIFE (seconds, or e.g. `30m`, `2h`). Off unless given. |

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

## Requirements and limits

- The host's key must already be in `~/.ssh/known_hosts` on the host: agent
  constraints are keyed by host key. If it is not, the engine refuses with a
  hint; connect once from a host shell (`ssh HOST`). This is deliberate: no
  trust-on-first-use is done for you.
- `~/.ssh/known_hosts` and `~/.ssh/config` are bound read-only into the sandbox
  (public data). Nothing else under `~/.ssh` is. `Include` files referenced
  from `config` are not bound; keep aliases in the main file.
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
