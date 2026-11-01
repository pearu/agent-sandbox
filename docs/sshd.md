# A sandboxed ssh login: the `sshd` profile

## What it is

`asb --profile sshd --role NAME`, run in a project directory, runs an OpenSSH server as
the role's agent, inside a `strict` sandbox whose policy is the project's
`.agent-sandbox` (#335). Another machine -- an agent's role, a script -- logs in with a
key the policy names. Every session (a command, `bash -s`, sftp, rsync, a pty, a job
detached with `setsid nohup`) runs inside that sandbox: the project directory is its
one writable place, the system is read-only, HOME is empty, egress goes only through
the sandbox's allowlist proxy, and only the GPU nodes the policy names are there. A
session cannot reach the host's loopback services or open a direct connection, cannot
forward a port, an agent, X11 or a socket, and cannot see the account's home, keys or
other users' homes.

It is not the system sshd and changes nothing of the host: no login shell, no
`ForceCommand`, no `Match` block, no root-owned policy, no PAM, no group or device
permission. It is an unprivileged sshd that the account runs in its own install, on a
port of its own, and it logs in only that account. The shape the issue first asked for
(a login shell and a root setup script) was dropped on 2026-10-31 for this one.

## The policy

The project's `.agent-sandbox`, reviewed and approved with `asb --trust` like any other.
An example, from the host it was built for:

```ini
[net]
mode = strict
agent-port = 0.0.0.0:2222
git = fetch

[allow]
github.com
.githubusercontent.com
conda.anaconda.org
pypi.org
files.pythonhosted.org
download.pytorch.org

[gpu]
devices = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1

[env]
TMPDIR = /home/tob/bench/tmp
CUDA_VISIBLE_DEVICES = 0

[sshd]
authorized-keys = /home/tob/.config/agent-sandbox/bench-keys
```

- `mode = strict` is required; a launch in any other mode refuses. Only there does the
  sandbox reach nothing but its proxy.
- `agent-port` is where sshd listens, exactly one token per launch (the flag
  `--agent-port` and `AGENT_SANDBOX_AGENT_PORTS` count too). A bare `2222` publishes it
  at the host's `127.0.0.1:2222`, for clients on the same host; `0.0.0.0:2222` at every
  IPv4 address of the host, reachable from the network, and an IPv4 literal at that one
  address. Nothing of agent-sandbox filters who connects to a published port: the
  host's firewall, or the cloud provider's, is the gate, and the keys file below is the
  login's.
- `git = fetch` lets git fetch over HTTPS and refuses a push
  ([network.md](network.md#no-git-transport-git--refuse-or-no-push-git--fetch)).
- `[allow]` is what sessions may reach through the proxy: here the Miniforge and conda
  channels, PyPI, the PyTorch wheel index and GitHub.
- `[gpu] devices` replaces the default node list: the driver's three shared nodes and
  the one card, `/dev/nvidia1`. Sessions see that card alone, as device 0
  ([design.md](design.md#the-hosts-gpus)).
- `[env] NAME = VALUE` is set in every session (under this profile a project's file
  may set a variable; under `claude` such a line is ignored). `TMPDIR` points into the
  project, the writable place. `CUDA_VISIBLE_DEVICES = 0` is optional: with one card
  bound it is device 0 anyway.
- `[sshd] authorized-keys` is the file of public keys that may log in, in
  `authorized_keys` form: an absolute path (or under `~`), outside the project, required.
  It is copied into the role's store at every launch; sshd reads the copy. The review
  says who may log in, and warns when the file is inside the project, which sessions
  can write.

`tob`, `/home/tob/bench` and `2222` are examples: nothing in the feature names an
account, a path or a port. The account is whoever launches, the role is `--role`, every
path and the port come from the policy. Sections take a role suffix as everywhere
([config.md](config.md#roles)), so two roles in one project can each have a port and a
card (`[net:a]`, `[gpu:a]`, ...).

## On a shared host

The owner has root; other people use the host. The login runs as a dedicated ordinary
account, so whatever escapes the sandbox lands there and not in the owner's.

1. Create the account: ordinary, no sudo, none of the owner's private keys or tokens,
   not in the `video`, `render` or `gpu` groups (the sandbox binds the GPU nodes itself; NVIDIA's are
   world-accessible, mode 0666, on the Ubuntu 24.04 host measured):

   ```sh
   sudo adduser --disabled-password --gecos '' tob
   ```

2. Log in as it: `sudo -u tob -i`, or `ssh tob@HOST` with a key of your own in its
   `~/.ssh/authorized_keys` (that key is for you, and that login, through the system
   sshd, is not sandboxed; the roles' key goes only in the policy's keys file).

3. As that account, clone agent-sandbox and run `install.sh`. It asks for sudo for one
   thing only: the AppArmor profiles for bwrap and pasta, when the kernel restricts
   unprivileged user namespaces and `/etc/apparmor.d/bwrap` or `/etc/apparmor.d/pasta`
   is missing. They are system-wide, so on a host where another account's install put
   them there, the step says `already present` and needs no root. Where they are
   missing, run `install.sh` once in an account with sudo (the owner's own) first.
   Missing packages are named with the `apt` line to give them (`bubblewrap`, `curl`;
   `passt` and `nftables` for `strict`; a `python3-venv` or a conda for the proxy's
   environment); the sshd binary is `openssh-server`'s. A bubblewrap below 0.12.0 is a
   warning, and its rebuild (`install.sh --rebuild-bwrap`) is the owner's, host-wide.
   An account that never logs in has no user manager: install.sh writes the proxy unit,
   says `note: this account has no user manager ...`, and goes on. That is fine here:
   the sshd profile runs a proxy of its own at every launch and needs no unit. The
   proxy's port is the account's own (8888, or the next free one when another
   account's proxy holds it; [network.md](network.md#its-port)).

4. Make the project directory (the scratch), the policy in it, and the keys file outside
   it:

   ```sh
   mkdir -p ~/bench/tmp && cd ~/bench
   $EDITOR .agent-sandbox                              # the policy above
   install -m 600 /dev/null ~/.config/agent-sandbox/bench-keys
   cat roles-key.pub >>~/.config/agent-sandbox/bench-keys
   asb --profile sshd --trust
   ```

   `~/.config/agent-sandbox` is never visible inside a sandbox, so no session can read
   or change the keys file there.

5. Launch it, in the background (it runs in the foreground until `--shutdown`), with the
   log outside the project:

   ```sh
   setsid nohup asb --profile sshd --role bench </dev/null >~/bench-sshd.log 2>&1 &
   asb --profile sshd --role bench --status
   asb --profile sshd --role bench --shutdown          # ends it and every job in it
   ```

   tmux does as well. The session directory and the proxy are the launch's own, not the
   user manager's, and logind leaves an account's processes running at its logout by
   default (`KillUserProcesses=no`); a launch outliving a real logout is not yet
   exercised.

This recipe as a whole, run as a dedicated account, is not yet exercised (it is the
live step after these docs). Its parts are measured: bwrap and pasta under the AppArmor
profiles for another ordinary account, and the profile itself, as the owner's
account, on an Ubuntu 24.04 host with two NVIDIA cards.

The host key is made at the first launch and kept:
`~/.local/state/agent-sandbox/sshd/<slug>/<role>/sshd/ssh_host_ed25519_key.pub`, where
`<slug>` is the project's path as `-home-tob-bench`. Give the clients its line as
`[HOST]:PORT ssh-ed25519 AAAA...` in their `known_hosts`, or compare the fingerprint
(`ssh-keygen -lf` that file) on their first connection.

What a running launch holds fixed: the keys file is copied at launch, so a key added or
removed takes effect at the next launch; a policy edit needs `asb --trust` again and a
relaunch (`--shutdown`, then launch).

## On a cloud instance

The same recipe, as a user of the instance; install the packages first, as root or with
sudo. On Verda (DataCrunch) the first login is root: create the user (`adduser`), log
in as it, and go on from step 3. That user has no sudo unless you give it one, and
install.sh's AppArmor step needs sudo once where the profiles are missing (step 3). On
Nebius the instance's user has sudo (as far as known) and runs the recipe as
themselves.

A port published at an address is reachable from wherever the address is, the internet
on a public instance: open it in the provider's firewall (security group) to the roles'
addresses only.

On an instance the boundary is the instance: an escape from the sandbox has the
launching user's rights, sudo included where the user has it, so whatever is on the
instance is in reach. A dedicated account without sudo narrows that as on a shared host.
Neither cloud has been exercised yet.

## The roles' side

The agents that log in are roles on another machine (or the same one). Their project's
`.agent-sandbox` names the login as an SSH host, and their account's `~/.ssh/config`
gives the alias its address, port, user and key ([ssh.md](ssh.md)):

```ini
[ssh]
tob-ex
```

```
Host tob-ex
  HostName ex.example.org
  Port 2222
  User tob
  IdentityFile ~/.ssh/tob_bench
```

`User` is the account that runs the sandbox: an sshd running as an account serves only
that account. The engine loads the key into the session's broker agent constrained to
that host and port, and refuses to start until the host key is in the roles'
`~/.ssh/known_hosts` under `[ex.example.org]:2222` (above). The roles' own allowlist
does not apply: SSH to a listed host is a direct connection, outside the proxy.

When the roles run on the same host as the sshd sandbox, its port is published at the
host's loopback (a bare `agent-port = 2222`), `HostName 127.0.0.1`, and a `strict` role
also needs the port opened toward the host:

```ini
[net]
mode = strict
host-port = 2222

[ssh]
tob-local
```

Measured on an Ubuntu 24.04 host (2026-11-01): with `host-port` the role's `ssh
tob-local` reached the sshd sandbox; without it, `Connection refused` (the engine's
pinhole for `127.0.0.1` opens the namespace's own loopback, where nothing listens).

The remote side of a script: sessions start in the account's HOME inside the sandbox,
which is an empty read-only directory. Use absolute paths into the project directory
(`ssh tob-ex 'cd /home/tob/bench && ./run.sh'`, `rsync ... tob-ex:/home/tob/bench/`),
and let `TMPDIR` from `[env]` take temporary files.

## What a session sees, and never sees

Measured inside a session on an Ubuntu 24.04 host (2026-11-01), with a policy of the
shape above:

- the project directory read-write at its own path; its `.agent-sandbox` read-only;
- the system (`/usr`, `/etc`, ...) read-only, `/sys` read-only, `/etc/group` the role's
  copy without the `tty` line;
- HOME (the account's home path) an empty read-only tmpfs, the working directory a
  session starts in; `~/.cache` and `~/.conda` writable tmpfs, fresh at each launch;
  under it, read-only, the tools environment on PATH and, when the launching shell had
  one active, its conda install and `.condarc`; `~/.cache/agent-sandbox/conda-pkgs`, the
  sandboxes' package cache, read-write; the role's sshd directory read-only;
- `/home` holding that tmpfs alone: the account's real home and other users' homes are
  not there, nor is `/root`;
- the environment: the launch's PATH, `HTTPS_PROXY` and the other proxy variables
  (`http://TOKEN:x@GATEWAY:PORT`, the session's proxy token), the CA variables
  (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `CURL_CA_BUNDLE`, ...), the conda
  variables, `AGENT_SANDBOX=1`, the policy's `[env]`, and what sshd sets per session;
- `nvidia-smi -L`: the one card bound, as GPU 0; `/dev` holding only the listed nodes;
- uid the account's; `ss -ltn` inside shows sshd alone, on `0.0.0.0:PORT`;
- `curl https://pypi.org/simple/` 200; `https://example.com/` refused by the proxy (403);
  a direct connection (`--noproxy`) times out; the host's `127.0.0.1:8888` refused.

Never in view: the account's `~/.ssh`, `~/.config` (the keys file, the trust store, the
allowlist), its tokens and credentials, other users' homes, the host's loopback
services, a route that bypasses the proxy. What a session can read and is worth knowing:
`/proc/driver/nvidia/gpus` still lists every card's bus (information, not access), and
the role's host key (see [design.md](design.md#residual-risks)).

## Operations

- **Logs.** sshd's log (`LogLevel VERBOSE`: each connection, key and session) goes to
  the launch's stderr: the file `nohup` writes to, or the tmux pane. The proxy's goes to
  the role's keeper log, `~/.local/state/agent-sandbox/sshd/<slug>/<role>/keeper.log`.
- **The proxy of its own.** Every launch starts one, a child of the role's keeper for
  the sandbox's lifetime, on the account's proxy port when nothing listens there, else
  on the next free port, said at launch (`sshd: proxy of its own at 127.0.0.1:8889 (the
  account's port, 8888, is in use)`). `--status` names it (`proxy: its own, at
  127.0.0.1:PORT`). One that does not come up refuses the launch, naming the keeper log.
- **`--status`** shows the keeper, the proxy and the sshd listener with any jobs;
  **`--shutdown`** ends the sandbox, every session and detached job in it, and the proxy.
- **One launch per role.** A second launch of a running role refuses: `role 'bench' is
  running already, its sshd with it, and a second sshd cannot listen on its port. End it
  first: asb --profile sshd --role bench --shutdown`.
- **Inside, sshd listens on `0.0.0.0`** whatever the token's address. A 2026 passt
  (git20260120, Ubuntu 26.04) delivers a connection from the host's loopback to the
  namespace's own address, not to its `127.0.0.1`, where a 2024 passt (git20240220,
  24.04) delivers it; the namespace is private, so only the published port is reachable
  from outside.

## Limits

- One port per role, one role per port.
- IPv4 only for the published address (a hostname, a CIDR and IPv6 are refused).
- No forwarding of any kind (`DisableForwarding yes`, `PermitTunnel no`), no user rc
  files or user environment, no password or keyboard-interactive login.
- Sessions run as the account's uid, so they share it with everything else the account
  runs: a dedicated account is what keeps them apart from yours.
- The keys file is read at launch; a change needs a relaunch.
- `asb --list` shows an sshd role with the claude-style resume line (`To resume:
  agent-sandbox --role ROLE sshd --continue`), which does not apply to it.
- A SIGKILL of the keeper's supervisor (the process `--status` names) orphans the
  launch: measured (2026-11-01), the sandbox and its sshd keep serving logins, sessions
  stay confined but the proxy, which also keeps running, refuses their requests (407:
  the session's owner is gone), and `--status` and `--shutdown` call the role not
  running.
  End it by hand: `kill -KILL` the innermost `bwrap` under the role's `pasta` (`pstree
  -p` of that pasta; it is the sandbox's pid 1), which takes sshd and its jobs along,
  and `kill` the `mitmdump` listening on the proxy port the launch named.
