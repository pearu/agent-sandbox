# Troubleshooting

**`agent-sandbox: no profile selected`**
Run through a profile symlink (`claude`) or pass `--profile NAME`. The
message lists the profiles found.

**`<profile>: missing .../versions` or `no versions under ...`**
The agent is not installed where its profile expects. For `claude`:
`~/.local/share/claude/versions/`. Install the agent, then re-run
`install.sh`, which reports each profile's binary.

**`bwrap: setting up uid map: Permission denied` / `No permissions to create new namespace`**
Ubuntu 24.04+ restricts unprivileged user namespaces
(`kernel.apparmor_restrict_unprivileged_userns = 1`) and ships no AppArmor
profile for bwrap. `install.sh` installs one (this is the one step that needs
sudo). Verify with:

```
bwrap --ro-bind / / --unshare-user --unshare-pid -- /bin/true && echo OK
```

The coarser alternative is disabling the restriction system-wide:
`sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0`.

**`Can't bind mount ... on /newroot/usr/local`**
`/usr/local` is a symlink whose target is not exposed. The engine handles the
common case (a symlink off `/usr`, e.g. for CUDA). If you still hit it:
`AGENT_SANDBOX_RO=/path/to/real/local claude`.

**API or DNS errors such as `FailedToOpenSocket`**
Usually `/etc/resolv.conf` is a symlink into `/run` on systemd-resolved
systems. The engine binds the resolved target automatically; verify with
`readlink -f /etc/resolv.conf`.

**Every HTTPS request fails with certificate errors**
The proxy CA is not reaching the sandbox. The engine binds it over the system
bundle when `~/.mitmproxy/mitmproxy-ca-cert.pem` exists (or the file named by
`AGENT_SANDBOX_PROXY_CA`) and warns at launch if it does not; run `install.sh`
to (re)generate the CA. Tools with a private CA store (conda/mamba, pip, a
conda-provided git, node, npm, cargo) are covered by the CA variables the
engine sets (see [network.md](network.md)); a tool with yet another knob needs
it forwarded via `AGENT_SANDBOX_PASSENV`. If you changed the host's CA state
while a session was running, relaunch.

**`certificate verify failed: Missing Authority Key Identifier` (Python 3.13+)**
The proxy is an old mitmproxy (8.x) whose leaf certificates lack that
extension. Re-run `install.sh`; it installs mitmproxy 12 or newer.

**`CONNECT tunnel failed, response 403` / allowed hosts still 403**
The host is not in `~/.config/agent-sandbox/allowlist.txt` (bare hostnames;
leading `.` for subdomains) and not in this session's `--allow`. Check
`~/.config/agent-sandbox/blocked.log`, `systemctl --user status
agent-sandbox-mitmproxy`, and `journalctl --user -u agent-sandbox-mitmproxy -f`.
A `--allow` host that is refused means the addon does not see this session as
alive; relaunch, and if it persists report it: it is a bug.

**`strict mode needs pasta` / `needs nft` / `needs a default-route gateway`**
`AGENT_SANDBOX_NET=strict` needs the `passt` package (`sudo apt install passt`),
`nftables`, and a default route (pasta maps its gateway to the host proxy).
Install passt, then re-run `install.sh` so it adds pasta's AppArmor profile;
without that profile Ubuntu's userns restriction blocks pasta.

**A tool inside cannot find an API token (`AWS_*`, `GH_TOKEN`, ...)**
By design: only an explicit allowlist of variables is forwarded. Per session:
`AGENT_SANDBOX_PASSENV="GH_TOKEN" claude`.

**A tool inside cannot reach a file outside the project**
Expose it: `AGENT_SANDBOX_RO=/some/dir claude` (or `AGENT_SANDBOX_RW`).
Secret stores, `/`, `$HOME` and its parents are refused.

**`refusing to bind sensitive directory ... as CWD` / `refusing to bind '/' as CWD`**
You ran the agent from a secret store, from `/`, or from a parent of your
home. Run from a project directory.

**`mamba install` or `pip install` fails inside**
Launch with `AGENT_SANDBOX_CONDA_WRITE=1`; by default the active env is
read-only. The base install stays read-only either way.

**`no trusted host key for '<host>'` (with `--ssh`)**
The host is not in `~/.ssh/known_hosts` on the host side. Connect once from a
host shell (`ssh <host>`) to record it, then relaunch. Inside the sandbox
`known_hosts` is read-only, so unknown hosts cannot be added from there.

**`Permission denied (publickey)` to host B while running with `--ssh A`**
Working as designed: the agent only signs for hosts named in `--ssh`. Add
`--ssh B` (or `--ssh-unrestricted`).

**Commits inside fail with `Author identity unknown`**
`~/.gitconfig` is not bound in. Set a repo-local identity from a host shell;
the engine prints the exact commands at launch.
