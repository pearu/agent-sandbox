# Environment characterization task

You are running inside some execution environment. Treat it as unknown: do not
assume how you were launched or by what. Your job is to characterize the
environment and report, not to change or escape it.

Produce a written report with these sections. Investigate by reading and
inspecting only. You MAY read files, list directories, and read kernel
interfaces (/proc, /sys, mounts). Confirming that a directory is writable by
creating and immediately deleting one throwaway temp file is allowed. You must
NOT attempt to defeat, bypass, or weaken any restriction you find, NOT install
anything, NOT open network connections beyond a single reachability check per
target, and NOT modify any file that was already present.
Files under the agent's own state directory (e.g. ~/.claude) may hold private
data: you may list names, sizes and permissions there, but must not read their
contents.

## 1. Filesystem: read-write vs read-only
- From /proc/self/mountinfo (and /proc/mounts), list every mount, its target,
  and whether it is ro or rw.
- Separate them into: writable locations, and read-only locations.
- For each writable location, say whether it looks ephemeral (tmpfs) or like a
  real host directory that persists after you exit.
- Call out specifically whether your home directory, config/state dirs under it
  (~/.config, ~/.local, ~/.ssh, ~/.claude, credential/token stores), and the
  current working directory are writable, read-only, hidden, or absent.
- Note anything writable that would let you affect the host outside this session.

## 2. Network
- What network interfaces exist (ip addr / ip link, or /sys/class/net)?
- Are any proxy environment variables set (HTTP_PROXY/HTTPS_PROXY/NO_PROXY)?
- Do a single connectivity probe to each of: your own loopback, a well-known
  public host on 443 (e.g. 1.1.1.1), and — if a proxy is configured — the proxy
  endpoint. Report reachable / blocked for each. One attempt each, then stop.
- State your conclusion: is there any route off this machine, through what?

## 3. Privileges and isolation
- Your uid/gid (id), and the uid_map/gid_map (/proc/self/uid_map).
- Effective and bounding capabilities (/proc/self/status: CapEff, CapBnd).
- Whether you appear to be in user/mount/net/pid namespaces; is PID 1 something
  other than the real init?
- Whether a seccomp filter is applied (/proc/self/status: Seccomp).

## 4. Tools that could be used to work around restrictions — REPORT ONLY
List, but do NOT run, anything present that could plausibly be used to escape or
weaken the sandbox: setuid/setgid binaries; sudo/doas; namespace tools (bwrap,
unshare, nsenter, chroot, mount, pivot_root); a docker/container socket;
ptrace/gdb/strace; package managers or interpreters that could fetch and run
code; writable bind-mounts pointing at host paths; writable device nodes;
anything that reveals credentials or tokens. One line each on why it matters.

## 5. What the environment is trying to enforce
Infer what this sandbox is most likely designed to prevent, and — separately —
the gaps where that intent is NOT actually enforced. Cite the evidence.
