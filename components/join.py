#!/usr/bin/env python3
"""Join a running keeper: run a command inside a role's launch as its equal.

    join.py [--seccomp FILE] [--env NAME=VALUE]... [--unset NAME]...
            [--private STAGE_HOST STAGE_INSIDE DEST_HOST ID [--private-path NAME PATH]...
             [--private-overlay NAME LOWER PATH]...]
            PID -- CMD [ARG]...

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
return its exit status.

THE TERMINAL. Where the kernel still lets an unprivileged process push keystrokes into
its terminal (TIOCSTI, CVE-2017-5226; /proc/sys/dev/tty/legacy_tiocsti is 1), the child
starts a session of its own, as bwrap's --new-session does: it has no controlling
terminal, and the parent forwards the terminal's signals to it. The price is no job
control and no SIGWINCH (measured, 2026-09-30: a joined shell never saw a resize). Where
the kernel blocks TIOCSTI (legacy_tiocsti is 0), there is nothing for that to protect,
so the child stays in the terminal's session and foreground group: Ctrl-C, Ctrl-Z and
resizes come from the terminal itself, as for any command. Then the parent forwards
only SIGTERM and SIGHUP, which may be sent to it alone: a Ctrl-C forwarded on top of the
terminal's own would arrive twice, and twice is how Claude Code is told to exit. A pty
per join would give both, everywhere (#165).

A JOIN'S OWN STORES (`join-scoped`, #147). With --private, the join gets a mount
namespace of its own: the child unshares one while it still holds capabilities in the
inner user namespace, binds STAGE_INSIDE/ID/NAME over each PATH, and covers STAGE_INSIDE
with an empty tmpfs; then the parent moves STAGE_HOST/ID to DEST_HOST/ID, out of the
staging directory the keeper binds, and only then does the command start. The move is
what keeps other joins out: every join shares the keeper's pid namespace, and through
/proc/<keeper payload>/root the staging directory is visible to all of them, whatever one
join covers in its own view. A bind survives its source directory being moved (measured,
probes/join-scoped-spike.py). The stores stay private for the life of the join: mounting
is denied to it afterwards by the dropped capabilities and the seccomp filter.

With --private-overlay NAME LOWER PATH (`copy-on-write join-scoped`, #153) the child
mounts an overlay at PATH instead of a bind: LOWER is the source, which the launch binds
read-only for the joins, and STAGE_INSIDE/ID/NAME/{upper,work} are this join's own. The
directory holding the lowers is covered with an empty tmpfs too, so the command reaches
the source only through its overlay. Measured on 6.8 with bubblewrap 0.12: the child
may mount it, holding the capabilities of the inner user namespace; a write lands in
the upper, the source is untouched, and the overlay survives the upper's directory being
moved out of staging.

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
CLONE_NEWNS, MS_BIND, MS_REC, MS_PRIVATE = 0x00020000, 4096, 16384, 1 << 18
SECCOMP_MODE_FILTER = 2
KINDS = ("ipc", "uts", "net", "pid", "mnt", "cgroup")

libc = ctypes.CDLL(None, use_errno=True)


def die(msg, code=125):
    sys.stderr.write(f"agent-sandbox: join: {msg}\n")
    sys.exit(code)


class Fprog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]


def parse(argv):
    seccomp, sets, unsets, private, ppaths, povs = None, {}, [], None, [], []
    arity = {"--seccomp": 1, "--env": 1, "--unset": 1, "--private": 4, "--private-path": 2,
             "--private-overlay": 3}
    i = 0
    while i < len(argv) and argv[i].startswith("--"):
        opt = argv[i]
        n = arity.get(opt)
        if n is None or i + n >= len(argv):
            die(f"bad option {opt!r}")
        val = argv[i + 1 : i + 1 + n]
        if opt == "--seccomp":
            seccomp = val[0]
        elif opt == "--env":
            if "=" not in val[0]:
                die(f"bad --env {val[0]!r}")
            k, v = val[0].split("=", 1)
            sets[k] = v
        elif opt == "--unset":
            unsets.append(val[0])
        elif opt == "--private":
            private = val
        elif opt == "--private-overlay":
            povs.append(val)
        else:
            ppaths.append(val)
        i += 1 + n
    if (ppaths or povs) and not private:
        die("--private-path and --private-overlay need --private")
    if len(argv) < i + 3 or argv[i + 1] != "--":
        die("usage: join.py [--seccomp FILE] [--env K=V]... [--unset K]... [--private ...] PID -- CMD...")
    return seccomp, sets, unsets, private, ppaths, povs, argv[i], argv[i + 2 :]


def mount(src, dst, fstype, flags):
    if libc.mount(src.encode() if src else None, dst.encode(), fstype.encode() if fstype else None, flags, None) != 0:
        raise OSError(ctypes.get_errno(), f"mount {src or fstype} on {dst}")


def main(argv):
    seccomp, sets, unsets, private, ppaths, povs, pid, cmd = parse(argv)

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
        # The staging and destination directories on the HOST, for the move out of
        # staging: opened now, they are reachable by handle once this process has joined.
        if private:
            stage_fd = os.open(private[0], os.O_RDONLY | os.O_DIRECTORY)
            dest_fd = os.open(private[2], os.O_RDONLY | os.O_DIRECTORY)
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

    # With TIOCSTI blocked, the joined command keeps the terminal (see the docstring).
    keep_terminal = tiocsti_blocked()

    # The pid namespace applies to children, hence the fork. A terminal signal that
    # arrives before the child exists is held and sent once it does; after that the
    # handler sends it straight to the child's group (waitpid is retried after a
    # handler runs, so a loop around it would never see the signal).
    child, pending = 0, []

    def forward(signum, _frame):
        if keep_terminal and signum in (signal.SIGINT, signal.SIGQUIT):
            return  # the terminal gave it to the child already
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
    if private:
        ready_r, ready_w = os.pipe()
        ack_r, ack_w = os.pipe()
    pid_ = os.fork()
    if pid_ == 0:
        for s in sigs:
            signal.signal(s, signal.SIG_DFL)
        # Python ignores SIGPIPE and SIGXFSZ at startup, and an ignored signal survives
        # exec: without this every joined command would start with both ignored, and
        # `yes | head` inside would print "Broken pipe" errors instead of stopping.
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
        try:
            if private:
                # A mount namespace of the join's own, made while the capabilities to do
                # it are still held; / private, so nothing propagates back to the keeper.
                os.close(ready_r)
                os.close(ack_w)
                if libc.unshare(CLONE_NEWNS) != 0:
                    raise OSError(ctypes.get_errno(), "unshare a mount namespace")
                mount(None, "/", None, MS_REC | MS_PRIVATE)
                stage_in, jid = private[1], private[3]
                for name, path in ppaths:
                    mount(f"{stage_in}/{jid}/{name}", path, None, MS_BIND)
                # copy-on-write for one join (#153): an overlay whose lower is the source,
                # bound read-only by the launch, and whose upper is this join's own.
                # Measured: the child may mount one, holding the capabilities of the
                # keeper's user namespace; a write lands in the upper, the source untouched.
                lowers = set()
                for name, lower, path in povs:
                    opts = f"lowerdir={lower},upperdir={stage_in}/{jid}/{name}/upper,workdir={stage_in}/{jid}/{name}/work"
                    if libc.mount(b"overlay", path.encode(), b"overlay", 0, opts.encode()) != 0:
                        raise OSError(ctypes.get_errno(), f"overlay on {path}")
                    lowers.add(os.path.dirname(lower))
                mount("tmpfs", stage_in, "tmpfs", 0)
                for d in lowers:  # the sources stay reachable only through the overlays
                    mount("tmpfs", d, "tmpfs", 0)
                os.write(ready_w, b"1")  # bound: the host may move the stores away now
                if os.read(ack_r, 1) != b"1":  # and the command starts only once it has
                    raise OSError(0, "the stores were not moved out of staging")
            os.chdir(cwd)
            if not keep_terminal:
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
    if private:
        os.close(ready_w)
        os.close(ack_r)
        ok = b"0"
        if os.read(ready_r, 1) == b"1":
            try:
                os.rename(private[3], private[3], src_dir_fd=stage_fd, dst_dir_fd=dest_fd)
                ok = b"1"
            except OSError as exc:
                sys.stderr.write(f"agent-sandbox: join: moving the join's stores out of staging: {exc.strerror}\n")
        try:
            os.write(ack_w, ok)
        except BrokenPipeError:  # the child failed before it asked, and said why
            pass
        os.close(ack_w)
    for s in pending:
        forward(s, None)
    try:
        _, st = os.waitpid(child, 0)
    except ChildProcessError:
        return 125
    return exit_status(st)


def tiocsti_blocked():
    """Does the kernel refuse TIOCSTI to unprivileged processes? legacy_tiocsti exists
    since Linux 6.2 and reads 0 where it does; absent or unreadable is taken as no."""
    try:
        with open("/proc/sys/dev/tty/legacy_tiocsti") as fh:
            return fh.read().strip() == "0"
    except OSError:
        return False


def exit_status(st):
    """The shell's exit status for a waitpid() status: the code, or 128 + the signal.
    Spelled with the W* macros rather than os.waitstatus_to_exitcode, which needs Python
    3.9: the join runs under whatever python3 is first on PATH, an old conda env's
    included (measured: an AttributeError there, after the command had already run)."""
    if os.WIFSIGNALED(st):
        return 128 + os.WTERMSIG(st)
    if os.WIFEXITED(st):
        return os.WEXITSTATUS(st)
    return 125


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
