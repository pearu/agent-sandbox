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

**`mitmproxy needs python3 >= 3.12 with venv ... or conda/mamba on PATH` (install.sh)**
The installer builds the proxy in a private environment and needs one of two
runtimes on the host. Provide either:

- **A Python venv** — `python3 >= 3.12` with the `venv` and `ensurepip`
  modules. On Debian/Ubuntu: `sudo apt install python3-venv` (it pulls
  `ensurepip`); if your system `python3` is older than 3.12, install a newer
  one (e.g. from `deadsnakes`) or use conda below. Verify:
  `python3 -c 'import sys, venv, ensurepip; print(sys.version)'`.
- **conda or mamba** — install Miniforge/Miniconda so `mamba` or `conda` is on
  `PATH`; the installer creates a dedicated env from `conda-forge` and does not
  touch your base env.

Then re-run `./install.sh`. Everything lands under
`~/.local/share/agent-sandbox`, so nothing system-wide changes and it is
removed by deleting that directory. (There is no bundled mitmproxy binary: the
upstream tarball publishes no checksums, so a supply-chain-safe route would
have to pin a hash per release — see `AGENTS.md`.)

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

**`.agent-sandbox has changed since you approved it ... Refusing to launch`**
The project's `.agent-sandbox` no longer matches the content you approved:
you edited it, or the agent did. Run `claude --trust` from the project
directory; it shows the current content, and approving it records the new
hash. Do not approve a change you did not make without reading it.

**`.agent-sandbox contains control characters ... refusing it`**
The file holds a byte other than tab, newline, printable ASCII or UTF-8 text:
an escape sequence, a carriage return (a Windows editor), a NUL. Such bytes
could hide a line from the `--trust` review, so the file is refused until
they are gone; `cat -v .agent-sandbox` shows each as `^X`.

**`this project's approved .agent-sandbox is missing ... Refusing to launch`**
A `.agent-sandbox` you approved is gone. Launching anyway would replace its
policy with the defaults, which for memory scoping is wider. Restore the file,
or run `claude --trust` from the project directory: with the file missing it
offers to forget the approval.

**`claude: command not found` (or it runs an old version) after moving or pulling the repo**
A normal install copies the engine and profiles under
`~/.local/share/agent-sandbox` and the launcher points there, so moving the
clone is fine but a `git pull` takes effect only after you re-run
`./install.sh` (it re-copies). If you used `./install.sh --dev`, the launcher
points at the checkout instead: moving or deleting it breaks the command
(`~/.local/bin/<agent>` becomes a dangling symlink) — re-run `./install.sh`
from the new location.

**A tool inside cannot find an API token (`AWS_*`, `GH_TOKEN`, ...)**
By design: only an explicit allowlist of variables is forwarded. Per session:
`AGENT_SANDBOX_PASSENV="GH_TOKEN" claude`.

**A tool inside cannot reach a file outside the project**
Expose it: `AGENT_SANDBOX_RO=/some/dir claude` (or `AGENT_SANDBOX_RW`).
Secret stores, the sandbox's own configuration (`~/.config/agent-sandbox`,
`~/.mitmproxy`, `~/.local/share/agent-sandbox`, `~/.local/bin`,
`~/.config/systemd`), any directory containing one of those (`~/.config`,
`~/.local`), `/`, `$HOME` and its parents are refused; bind a specific
subdirectory instead. The full list is in `docs/design.md`.

**`refusing to bind '...' as CWD: it is|is inside|contains the secret store ...` / `... the sandbox's own control plane ...` / `refusing to bind '/' as CWD`**
You ran the agent from a secret store, from the sandbox's own configuration,
from a directory containing one of them, from `/`, or from a parent of your
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
