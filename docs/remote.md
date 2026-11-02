# A sandboxed login on another host: `asb --setup-remote`

## What it makes

A login on another host, as an account there, that your roles reach as an SSH host
(#344). It is the [`sshd` profile](sshd.md) run by that account in its own install: every
session (a command, a shell, sftp, scp, rsync) runs inside a `strict` sandbox whose one
writable place is a project directory there, the scratch, with egress only through
that account's allowlist proxy and only the GPUs the section names. Here it is an alias
of your `~/.ssh/config`, `ssh ALIAS`, with a key of its own.

One command, run by you on this host in the roles' project, does it all from one
section of the project's `.agent-sandbox`:

```sh
asb --setup-remote ALIAS                                     # an existing [remote:ALIAS]
asb --setup-remote [ACCOUNT@]HOST[:SSHPORT] [--port [ADDR:]PORT]   # writes one first
asb --setup-remote ALIAS --status                            # is the login running there?
asb --setup-remote ALIAS --shutdown                          # end it; ALIAS alone starts it again
```

It runs on the host only: inside a sandbox it refuses, since it holds your ssh access.
A role proposes the line; you run it. It never runs sudo.

## The section

```ini
[remote:tob-ex]
host = ex                   # how you reach the host with ssh: a name, user@host, or an alias of ~/.ssh/config; :SSHPORT when its sshd is not on 22
account = tob               # the account that runs the login there (default: your ssh user there)
port = 0.0.0.0:2222         # where the login listens there: PORT, ADDR:PORT, or 0.0.0.0:PORT
scratch = ~/tob-ex          # the project directory there (default: ~/ALIAS, '~' the account's home)
gpu = /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia1   # default: all; none: no GPU
allow = pypi.org download.pytorch.org   # hosts its proxy lets through, beyond the account's allowlist (lines add up)
env = TMPDIR=/home/tob/tob-ex/tmp       # set inside (lines add up)
```

`host` and `port` are required. A `TMPDIR` in an `env` line that is under the scratch
(`~` the account's home) is made there, as the account, before the launch; another
`env` value, or a `TMPDIR` outside the scratch, is set as written and nothing is made.
`ALIAS` must be a role name (a letter or digit, then
letters, digits, `.`, `_`, `-`) and not `host` itself, since `Host ALIAS` in your
`~/.ssh/config` would shadow it. The review (`asb --trust`) says each line and what it
means; every key is in [config.md](config.md) under `[remote:<alias>]`.

`asb --setup-remote tob@ex --port 0.0.0.0:2222`, with no `[remote:tob-ex]` in the file,
appends one through `--apply`'s review (the lines, the diff, `[y/N]`): `host = ex`,
`account = tob`, `port =` the `--port` value (default `2222`), `scratch = ~/tob-ex`; no
`gpu`, `allow` or `env` line. Declined, the file is put back as it was and nothing is
done. Without `ACCOUNT@` the account is your ssh login name for HOST. When the file has
that section already and it says otherwise than the command line, the command refuses
rather than choosing.

## Before the first run

- `ssh HOST true` works from this account with no question: your key there and the
  host's key in your `~/.ssh/known_hosts` (`ssh HOST` once, by hand). The preflight runs
  with `BatchMode`.
- When `account` is not your ssh user there, `ssh -l ACCOUNT HOST true` works the same
  way: your public key in that account's `~/.ssh/authorized_keys`. The admin's script
  below puts it there for an account it creates; for one that exists, its owner or an
  admin adds it.
- This project's `.agent-sandbox` is approved (`asb --trust`), with the section in it.
- The command runs from a git checkout of agent-sandbox (the engine's own, or the one
  `install.sh` ran from): it installs asb there from that checkout's HEAD.

An account with no sudo at all is enough when the host has the packages (`bubblewrap`
0.12 or newer, `passt`, `nftables`, `openssh-server`) and bwrap's and pasta's user
namespaces work there; the preflight measures both. It needs no git there, and curl
only when your install has no micromamba to carry.

## When root is needed there

The preflight (one read-only ssh session as you) reports the distribution, the
packages, user namespaces as measured, the AppArmor profiles, sudo (reported, never
used), the account, the GPUs and the egress to conda-forge and GitHub. Where something
needs root -- a package, install.sh's AppArmor profiles where the kernel restricts user
namespaces, the bubblewrap rebuild on Ubuntu below 0.12.0, an account that does not
exist -- it writes the admin's script to `.asb/remote/ALIAS/admin.sh`, copies it to
`~/asb-admin-ALIAS.sh` in your home on the host, prints the one line that runs it, and
exits 1:

```sh
ssh -t HOST sudo bash asb-admin-ALIAS.sh                   # you have sudo there
ssh -t HOST bash asb-admin-ALIAS.sh                        # you are root there
ssh root@HOST bash -s < .asb/remote/ALIAS/admin.sh         # the host's admin, when you have no sudo
```

(`-p SSHPORT` in each when `host` names one.) Read the script first: it does only what
was measured missing, each step explained. Then run `asb --setup-remote ALIAS` again.

## What a run does

After a ready preflight, as the account (`ssh -l ACCOUNT HOST`, `BatchMode`):

1. Makes the roles' key `~/.ssh/asb-ALIAS` here, once (ed25519, no passphrase).
2. Carries the checkout (`git archive` of HEAD) and your micromamba into the account's
   `~/.local/share/agent-sandbox` and runs `install.sh` there, when the account's
   install is missing or of another commit. Uncommitted changes are not carried.
3. Writes the login's policy into `SCRATCH/.agent-sandbox`, generated from the section:
   `strict`, the port, `[allow]`, `[gpu]`, `[env]`, the keys file
   `~/.config/agent-sandbox/asb-ALIAS-keys` there (outside the scratch, holding the
   key's public half), and `[sshd] home = project`. It approves it there (you approved
   the section here) and launches the login in the background as the role `ALIAS`.
4. Here: the login's host key into `~/.ssh/known_hosts`, and the alias in a marked block
   of `~/.ssh/config` (below).
5. Checks through the alias, one line each, a failure being the exit status: the login
   is the account inside the sandbox; for the section's first allowed host (else the
   first host of the account's `allowlist.txt`) the proxy opens the tunnel and the host
   answers, whatever its status (download.pytorch.org answers 403 at `/`, and passes);
   `https://example.com/` is refused by the proxy at CONNECT; a direct connection around
   the proxy fails; `nvidia-smi` lists exactly the cards of the section's
   `/dev/nvidiaN` nodes.
6. Ends with `set up: ssh ALIAS` and the `asb --apply` lines a role still needs (below).

## Again: the update, and after a reboot

Run it again after any change; it is the update. A section edit is done with `--apply`
(or by hand and `--trust`), then the run:

```sh
asb --apply '[remote:ALIAS]' 'allow = download.pytorch.org'
asb --setup-remote ALIAS
```

The run says the policy lines that changed, then shuts the login down and relaunches
it. A new commit in the checkout is carried and installed, and the login relaunched.
Nothing changed and the login running: `up to date`. A reboot of the host ends the
login; `asb --setup-remote ALIAS` launches it again (no crontab entry is made). A reboot
of this machine needs nothing: the alias and key are files.

## Asking after it, and ending it

```sh
asb --setup-remote ALIAS --status
asb --setup-remote ALIAS --shutdown
```

Each is one ssh session as the account (`ssh [-p SSHPORT] -l ACCOUNT HOST`, `BatchMode`,
never sudo) that runs the account's own `~/.local/bin/asb --profile sshd --role ALIAS
--status` (or `--shutdown`) in the scratch there; its answer is said line by line, and
its exit status is the command's. No preflight, nothing carried, no policy written,
nothing here changed. ALIAS is a `[remote:ALIAS]` section of the file; a destination is
refused with these flags. `--shutdown` removes nothing, there or here: it ends the
login and every session in it, and `asb --setup-remote ALIAS` starts it again (the run
says `the login is not running (a reboot of HOST?): launching it`). An account with no
`~/.local/bin/asb`, or no scratch, is said as not set up, exit 1. Measured on ey
(2026-11-02):

```
$ asb --setup-remote tob-ey-addr --shutdown
agent-sandbox: remote tob-ey-addr: --shutdown, over ssh as tob to ey (ssh -l tob ey; BatchMode; never sudo): asb --profile sshd --role tob-ey-addr --shutdown in ~/tob-ey-addr there
agent-sandbox: remote tob-ey-addr:   agent-sandbox: role 'tob-ey-addr': ended, with everything that ran in it
agent-sandbox: remote tob-ey-addr: the login is not running there now; nothing was removed, there or here: to start it again, agent-sandbox --setup-remote tob-ey-addr
$ asb --setup-remote tob-ey-addr --status
agent-sandbox: remote tob-ey-addr: --status, over ssh as tob to ey (ssh -l tob ey; BatchMode; never sudo): asb --profile sshd --role tob-ey-addr --status in ~/tob-ey-addr there
agent-sandbox: remote tob-ey-addr:   role 'tob-ey-addr' of /home/tob/tob-ey-addr: not running; its stores (232K) are at /home/tob/.local/state/agent-sandbox/sshd/-home-tob-tob-ey-addr/tob-ey-addr
```

## How roles reach it

A role names the login in the project and is (re)launched:

```sh
asb --apply '[ssh:ROLE]' ALIAS
```

The role's SSH broker then holds `~/.ssh/asb-ALIAS`, constrained to the alias's host and
port, and a `strict` role gets a pinhole to it, outside the proxy ([ssh.md](ssh.md)).

A role that is running sees your `~/.ssh/config` and `~/.ssh/known_hosts` through
read-only binds of those files as they were at its launch, file by file. `--setup-remote`
writes both in place, and a running role sees that (measured: the alias block and the
host key line written into bound files show inside). A file written as a new one
since -- by an editor, `sed -i`, or `ssh-keygen -R`, which leaves `known_hosts.old` --
or one that did not exist at the launch is not seen: the role keeps the old one, and
gets `REMOTE HOST IDENTIFICATION HAS CHANGED` for a login whose key changed, or no
alias. Relaunch such a role after `--setup-remote` (its broker, key and pinhole are
also made at launch).
What else it needs depends on where the login listens and where the role runs:

| `port` | the alias block, the host another machine | roles on another host | roles on the login's host |
|---|---|---|---|
| `0.0.0.0:PORT` | `HostName` the host's name, `Port PORT` | yes, by the host's address | yes, through `127.0.0.1` and `[net:ROLE] host-port = PORT` |
| `ADDR:PORT` | `HostName ADDR` | yes, where ADDR is reachable from that host | no (not measured; below) |
| `PORT` | `HostName 127.0.0.1`, `ProxyJump HOST` | no, from a `strict` role (measured; below) | yes, through `127.0.0.1` and `[net:ROLE] host-port = PORT` |

- **By address, from another host.** Measured 2026-11-02: a `strict` role on ex
  (Ubuntu 24.04) with `[ssh:probe] tob-ey-ex`, the login on ey at `0.0.0.0:2224`, ran
  `ssh tob-ey-ex 'hostname; id -un; pwd'` and got `ey`, `tob`, `/home/tob/tob-ey-ex`.
  The same for a login at one address of ey, `port = 192.168.1.110:2225`: from your
  shell and from a `strict` role on ex, `ey`, `tob`, `/home/tob/tob-ey-addr`. A port at
  an address is reachable from wherever that address is: that host's firewall, or the
  cloud provider's, is the gate.
- **A bare port, from another host.** The alias's `ProxyJump HOST` is your own ssh to
  the host's system sshd, with your key. Measured 2026-11-02, a `strict` role on ex
  with `[ssh:probe] tob-qgpu3` (the login on qgpu3's `127.0.0.1:2222`, the jump
  `qgpu3`, an alias for `app.cozer.ee:2223`), where your own `ssh tob-qgpu3` works:

  ```
  agent-sandbox: strict --ssh: 127.0.0.1 reachable at 127.0.0.1 on port 2222 (direct, outside the proxy)
  ssh: Could not resolve hostname app.cozer.ee: Name or service not known
  Connection closed by UNKNOWN port 65535
  ```

  Each of the jump's three needs fails inside: the jump host's name does not resolve
  (`getent hosts app.cozer.ee` exits 2), its sshd by address gets no banner within
  10 s (the pinhole is for the alias's `HostName` and `Port`, `127.0.0.1:2222`, not the
  jump), and the broker holds only `~/.ssh/asb-tob-qgpu3`, not your key for the jump
  host. For roles on another host, use `0.0.0.0:PORT` or `ADDR:PORT`.
- **On the login's own host.** A `strict` sandbox there has the host's own addresses
  (measured: inside one, `ip -4 -br addr` shows the host's LAN address, on Ubuntu 24.04
  and 26.04), so a role dialing the host's address reaches its own namespace: `ssh:
  connect to host 192.168.1.110 port 2222: Connection refused`, measured on ey
  (2026-11-02). It reaches the login only at `127.0.0.1`, through the port opened toward
  the host: `[net:ROLE] host-port = PORT` (measured working with an alias `HostName
  127.0.0.1`). So when the host is this machine, the block is `HostName 127.0.0.1`, the
  login's port, no `ProxyJump`, for a bare port and `0.0.0.0` alike, and the run ends
  with both lines:

  ```sh
  asb --apply '[ssh:ROLE]' ALIAS
  asb --apply '[net:ROLE]' 'host-port = PORT'
  ```

  each only when no line gives it already. "This machine" is the preflight's
  `/etc/machine-id` and boot id both equal to this machine's. A login at one other
  address only (`ADDR:PORT`) keeps `HostName ADDR`, and the run says the roles here do
  not reach it: nothing listens at `127.0.0.1:PORT`, and ADDR inside their sandbox is
  their own (inferred from the measurement above, not measured for a specific address).

A role's sessions on the login start in the scratch, which is also their HOME
(`[sshd] home = project`): `ssh ALIAS ./run.sh`, `rsync -a out/ ALIAS:results/`.

## For a Supervisor proposing the commands

The owner runs every line below on the host, in the roles' project; a role runs none.
A login on another host, roles on this one:

```sh
asb --setup-remote tob@ex --port 0.0.0.0:2222     # appends [remote:tob-ex], asks [y/N], then sets up
# exit 1 with "needs root once": run the one line it prints, then:
asb --setup-remote tob-ex
asb --apply '[remote:tob-ex]' 'allow = pypi.org download.pytorch.org'   # optional, then:
asb --setup-remote tob-ex
asb --apply '[ssh:implementer-1]' tob-ex           # then relaunch implementer-1
```

A login on this same host: the same, and the `--apply '[net:ROLE]' 'host-port = PORT'`
line the run prints. After a reboot of the login's host: `asb --setup-remote tob-ex`.
Before proposing, check what the run said last: a failed check's line names what failed.

## The files it touches

Here:

- `~/.ssh/config`: one marked block per alias, between `# >>> agent-sandbox remote
  ALIAS (#344) >>>` and `# <<< agent-sandbox remote ALIAS <<<`, appended the first time
  and rewritten in place after; nothing outside the markers changes. Before the first
  block ever written into the file, a copy goes to `~/.ssh/config.before-agent-sandbox`
  (once). A `Host` or `Match` block of yours above it that sets one of its options first
  is said, and the run fails.
- `~/.ssh/known_hosts`: one line, `[HOSTNAME]:PORT ssh-ed25519 ... agent-sandbox remote
  ALIAS (#344)`, replaced on every run.
- `~/.ssh/asb-ALIAS`, `~/.ssh/asb-ALIAS.pub`: the roles' key.
- The project: the `[remote:ALIAS]` section, and `.asb/remote/ALIAS/admin.sh` when root
  was needed.

There, as the account: `~/.local/share/agent-sandbox/src` (the carried checkout) and the
install `install.sh` makes (`~/.local/bin/asb`, `~/.local/share/agent-sandbox`,
`~/.config/agent-sandbox`), `~/asb-install-ALIAS.log`; the scratch and its
`.agent-sandbox`; `~/.config/agent-sandbox/asb-ALIAS-keys`; the login's store
`~/.local/state/agent-sandbox/sshd/<slug>/ALIAS` (its host key); `~/asb-ALIAS-sshd.log`
and `~/asb-ALIAS-trust.log`. In your own home there, `~/asb-admin-ALIAS.sh` when root was
needed.

The install is the account's, shared by every login it runs: carrying a new commit for
one alias re-installs asb for all of them, and another login picks it up at its next
relaunch.

## The same host as a stand-in

`asb --setup-remote ACCOUNT@HOST` with HOST this machine runs the whole path: the
preflight, the admin's script, the account's install, the policy, the launch, the
checks, the update. What differs from another host: the alias is `127.0.0.1` with the
login's port, so the network path by address and the host's firewall are not
exercised; roles reach it only with `[net:ROLE] host-port`; the host key is filed as
`[127.0.0.1]:PORT`, a name any loopback login on that port shares. The account's
install is the same one any other login of that account runs (above).

## Retiring a login

End the login first:

```sh
asb --setup-remote ALIAS --shutdown
```

Then, here, remove the marked block from `~/.ssh/config`, the marked line from
`~/.ssh/known_hosts`, `~/.ssh/asb-ALIAS` and `~/.ssh/asb-ALIAS.pub`, the
`[remote:ALIAS]` section and the `[ssh]` lines naming ALIAS (then `asb --trust`). Until
the section is gone, `asb --setup-remote ALIAS` would set it up again. There, the
scratch, the keys file and the login's store stay until the account removes them; the
account itself and its install are its owner's or the admin's to remove.
