#!/usr/bin/env python3
"""Join a running keeper: run a command inside a role's launch as its equal.

    join.py [--seccomp FILE] [--env NAME=VALUE]... [--unset NAME]... PID -- CMD [ARG]...

PID is a host pid of a process inside the launch (the keeper's payload). The
command runs with that process's mounts, namespaces, working directory and
environment, its capability set (none), `no_new_privs`, and -- given --seccomp --
the same filter, which bwrap applied to it and which does not carry across a
join. `--env` and `--unset` change the environment it inherits; the engine uses
them for the variables that describe the joining terminal, never the sandbox.

WHY NOT nsenter. bwrap nests a second, capability-less user namespace when given
`--dev /dev`, so no process inside lives in the namespace that owns the mounts, and
in the strict network mode the network namespace is owned one level further out,
by pasta's. Rights over a namespace come from its OWNER, and entering a child user
namespace forfeits the parent's. So: resolve every identity first (/proc/self
stops resolving after the first setns), walk the user-namespace chain from the
outermost down, join each namespace right after entering its owner, and enter the
process's own user namespace last. nsenter cannot express that order. Measured
2026-09-27 in `none` and `strict` (probes/join-launch.py, #121).

THE PARENT STAYS ON THE HOST and waits, so the engine can account for the join and
return its exit status. It forwards the terminal's signals to the joined process
group: the child starts a session of its own, as bwrap's --new-session does, so it
has no controlling terminal and nothing the terminal sends reaches it otherwise.

Exit status: the command's, 128+N if it died of signal N, 127 if it could not be
executed, 125 if the join itself failed.
"""

import ctypes
import fcntl
import os
import signal
import sys

NS_GET_USERNS, NS_GET_PARENT = 0xB701, 0xB702
PR_SET_NO_NEW_PRIVS, PR_SET_SECCOMP, PR_CAPBSET_DROP = 38, 22, 24
SECCOMP_MODE_FILTER = 2
KINDS = ("ipc", "uts", "net", "pid", "mnt", "cgroup")

libc = ctypes.CDLL(None, use_errno=True)


def die(msg, code=125):
    sys.stderr.write(f"agent-sandbox: join: {msg}\n")
    sys.exit(code)


class Fprog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]


def parse(argv):
    seccomp, sets, unsets = None, {}, []
    i = 0
    while i < len(argv) and argv[i].startswith("--"):
        opt = argv[i]
        if opt == "--seccomp" and i + 1 < len(argv):
            seccomp = argv[i + 1]
        elif opt == "--env" and i + 1 < len(argv) and "=" in argv[i + 1]:
            k, v = argv[i + 1].split("=", 1)
            sets[k] = v
        elif opt == "--unset" and i + 1 < len(argv):
            unsets.append(argv[i + 1])
        else:
            die(f"bad option {opt!r}")
        i += 2
    if len(argv) < i + 3 or argv[i + 1] != "--":
        die("usage: join.py [--seccomp FILE] [--env K=V]... [--unset K]... PID -- CMD...")
    return seccomp, sets, unsets, argv[i], argv[i + 2 :]


def main(argv):
    seccomp, sets, unsets, pid, cmd = parse(argv)

    def ident(fd):
        return os.readlink(f"/proc/self/fd/{fd}")

    # Everything that has to be read on the HOST is read now: the target's view,
    # the filter file (the engine's directory is not visible inside), and every
    # namespace identity.
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
        with open(f"/proc/{pid}/environ", "rb") as fh:
            raw = fh.read()
        prog = None
        if seccomp:
            with open(seccomp, "rb") as fh:
                prog = fh.read()
        ns = {}
        for k in KINDS:
            try:
                ns[k] = os.open(f"/proc/{pid}/ns/{k}", os.O_RDONLY)
            except FileNotFoundError:
                pass
        owner = {k: fcntl.ioctl(fd, NS_GET_USERNS) for k, fd in ns.items()}
        inner = os.open(f"/proc/{pid}/ns/user", os.O_RDONLY)
        host_user = ident(os.open("/proc/self/ns/user", os.O_RDONLY))
    except OSError as exc:
        die(f"cannot read the launch's process {pid}: {exc}")
    env = {}
    for kv in raw.split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            env[os.fsdecode(k)] = os.fsdecode(v)
    for k in unsets:
        env.pop(k, None)
    env.update(sets)
    if prog is not None:
        if not prog or len(prog) % 8:
            die(f"{seccomp}: not a seccomp filter")
        buf = ctypes.create_string_buffer(prog, len(prog))
        fprog = Fprog(len(prog) // 8, ctypes.addressof(buf))

    # The user-namespace chain, innermost first, up to (not including) ours.
    chain = [inner]
    while True:
        try:
            parent = fcntl.ioctl(chain[-1], NS_GET_PARENT)
        except OSError:
            break
        if ident(parent) == host_user:
            break
        chain.append(parent)
    owner_id = {k: ident(fd) for k, fd in owner.items()}
    chain_id = [ident(fd) for fd in chain]
    if chain_id[-1] == host_user or ident(inner) == host_user:
        die(f"process {pid} is not inside a sandbox")
    for user_fd, user_id in reversed(list(zip(chain, chain_id))):  # outermost first
        if libc.setns(user_fd, 0) != 0:
            die(f"setns user {user_id}: {os.strerror(ctypes.get_errno())}")
        for k, fd in ns.items():
            if owner_id[k] == user_id and libc.setns(fd, 0) != 0:
                die(f"setns {k}: {os.strerror(ctypes.get_errno())}")

    # The pid namespace applies to children, hence the fork. A terminal signal that
    # arrives before the child exists is held and sent once it does; after that the
    # handler sends it straight to the child's group (waitpid is retried after a
    # handler runs, so a loop around it would never see the signal).
    child, pending = 0, []

    def forward(signum, _frame):
        if not child:
            pending.append(signum)
            return
        try:
            os.killpg(child, signum)
        except OSError:
            try:
                os.kill(child, signum)
            except OSError:
                pass

    sigs = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)
    for s in sigs:
        signal.signal(s, forward)
    pid_ = os.fork()
    if pid_ == 0:
        for s in sigs:
            signal.signal(s, signal.SIG_DFL)
        try:
            os.chdir(cwd)
            os.setsid()
            # The capability bounding set, as bwrap's --cap-drop ALL leaves it: empty.
            # Entering a user namespace grants every capability in it, and exec as a
            # non-root uid clears the effective set but not the bounding one.
            cap = 0
            while libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) == 0:
                cap += 1
            if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "no_new_privs")
            if prog is not None and libc.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ctypes.byref(fprog), 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "seccomp")
        except OSError as exc:
            sys.stderr.write(f"agent-sandbox: join: {exc}\n")
            os._exit(125)
        try:
            os.execvpe(cmd[0], cmd, env)
        except OSError as exc:
            sys.stderr.write(f"agent-sandbox: join: {cmd[0]}: {exc.strerror}\n")
            os._exit(127)
    child = pid_
    for s in pending:
        forward(s, None)
    try:
        _, st = os.waitpid(child, 0)
    except ChildProcessError:
        return 125
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    return os.waitstatus_to_exitcode(st)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
