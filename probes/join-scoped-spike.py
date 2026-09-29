#!/usr/bin/env python3
# join-scoped-spike.py -- can a join have a store of its own (#147)?
#
# A joined process shares the keeper's mount namespace (#121), so a store of one
# join's own needs a mount namespace of the join's own. The idea measured here: the
# join child, after the setns chain and while it still holds capabilities in the
# inner user namespace, unshares a mount namespace, binds its store over the declared
# path, and only then drops the bounding set, sets no_new_privs and execs. Questions,
# each printed with its answer:
#
#   Q1  a bind straight from a HOST directory (an fd opened before joining, mounted
#       through /proc/self/fd) -- expected to fail: a bind's source has to be in the
#       caller's mount namespace, and the host's state directory is not
#   Q2  the staging route: the keeper binds the stores' parent at a hidden inside path;
#       the join binds its own subdirectory over the declared path, then covers the
#       staging path with an empty tmpfs -- do two joins each see only their own?
#   Q3  a join cannot see the staging path, or another join's store, afterwards
#   Q4  the keeper's own view of the declared path is unchanged, and so is the host's
#       view of the stores (each join's writes land in its own host directory)
#   Q5  a process the join starts sees the same (it inherits the namespace)
#   Q6  the join still ends up as the keeper's equal: CapBnd empty, NoNewPrivs 1, the
#       same uid/gid -- the mounts happen before any of that is dropped
#   Q7  a process joined the old way (no unshare) sees the staging path: the exposure
#       the tmpfs does not cover, and what every join must therefore do
#   Q8  can a join still reach another join's store through the keeper payload's view,
#       /proc/<payload>/root/run/joins/? Every join shares the keeper's pid namespace
#   Q9  the remedy for Q8, if it is needed: once a join has bound its store, the host
#       moves the store out of the staging directory. Does the join's bind survive the
#       move, and is the staging path then empty for anyone looking?
#
# Needs bubblewrap and unprivileged user namespaces. No Claude Code, no network.
#   python3 probes/join-scoped-spike.py
import ctypes, fcntl, os, subprocess, sys, tempfile, time

libc = ctypes.CDLL(None, use_errno=True)
NS_GET_USERNS, NS_GET_PARENT = 0xB701, 0xB702
CLONE_NEWNS = 0x00020000
MS_BIND, MS_REC, MS_PRIVATE = 4096, 16384, 1 << 18
PR_SET_NO_NEW_PRIVS, PR_CAPBSET_DROP = 38, 24
KINDS = ("ipc", "uts", "net", "pid", "mnt", "cgroup")


def err():
    return os.strerror(ctypes.get_errno())


def mount(src, dst, fstype, flags):
    r = libc.mount(src.encode() if src else None, dst.encode(), fstype.encode() if fstype else None, flags, None)
    return "ok" if r == 0 else f"failed: {err()}"


T = tempfile.mkdtemp(prefix="join-scoped-")
stage = f"{T}/stage"
for n in ("A", "B"):
    os.makedirs(f"{stage}/{n}")
os.makedirs(f"{T}/hostdir")
print(f"kernel {os.uname().release}; {subprocess.run(['bwrap', '--version'], capture_output=True, text=True).stdout.strip()}; dir {T}")

# The keeper: engine-shaped flags, the declared path an empty directory on a tmpfs, the
# stores' parent bound read-write at a hidden inside path.
args = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL",
        "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc", "--proc", "/proc", "--dev", "/dev"]
for d in ("/bin", "/lib", "/lib64", "/sbin"):
    if os.path.exists(d):
        args += ["--ro-bind", d, d]
args += ["--tmpfs", "/tmp", "--tmpfs", "/run", "--bind", stage, "/run/joins",
         "--tmpfs", "/work", "--dir", "/work/scratch", "--chdir", "/work", "--", "sleep", "300"]
keeper = subprocess.Popen(args, start_new_session=True)
target = None
for _ in range(200):
    c = keeper.pid
    while True:
        try:
            kids = open(f"/proc/{c}/task/{c}/children").read().split()
        except OSError:
            kids = []
        if not kids:
            break
        c = kids[0]
    try:
        if open(f"/proc/{c}/cmdline", "rb").read().split(b"\0")[0] == b"sleep":
            target = c
            break
    except OSError:
        pass
    time.sleep(0.02)
if not target:
    sys.exit("the keeper did not start")


def join(name, script, private=None, direct_fd_test=False):
    """Join the keeper as components/join.py does; with PRIVATE, first give the join a
    mount namespace of its own and bind /run/joins/PRIVATE over /work/scratch. Returns
    the script's stdout, plus a line per setup step."""
    sys.stdout.flush()  # or the forked children print the parent's buffer again
    r, w = os.pipe()
    pid = os.fork()
    if pid:
        os.close(w)
        out = os.read(r, 65536).decode()
        while True:
            chunk = os.read(r, 65536)
            if not chunk:
                break
            out += chunk.decode()
        os.waitpid(pid, 0)
        return out
    os.close(r)
    os.dup2(w, 1)
    os.dup2(w, 2)
    ident = lambda fd: os.readlink(f"/proc/self/fd/{fd}")
    hostfd = os.open(f"{T}/hostdir", os.O_RDONLY | os.O_DIRECTORY) if direct_fd_test else None
    ns = {k: os.open(f"/proc/{target}/ns/{k}", os.O_RDONLY) for k in KINDS if os.path.exists(f"/proc/{target}/ns/{k}")}
    owner = {k: ident(fcntl.ioctl(fd, NS_GET_USERNS)) for k, fd in ns.items()}
    chain = [os.open(f"/proc/{target}/ns/user", os.O_RDONLY)]
    host_user = ident(os.open("/proc/self/ns/user", os.O_RDONLY))
    while True:
        try:
            p = fcntl.ioctl(chain[-1], NS_GET_PARENT)
        except OSError:
            break
        if ident(p) == host_user:
            break
        chain.append(p)
    ids = [ident(fd) for fd in chain]
    for ufd, uid in reversed(list(zip(chain, ids))):
        libc.setns(ufd, 0)
        for k, fd in ns.items():
            if owner[k] == uid:
                libc.setns(fd, 0)
    child = os.fork()
    if child:
        _, st = os.waitpid(child, 0)
        os._exit(0)
    os.chdir("/work")
    if private or direct_fd_test:
        print(f"step unshare(CLONE_NEWNS): {'ok' if libc.unshare(CLONE_NEWNS) == 0 else 'failed: ' + err()}")
        print(f"step make / private: {mount(None, '/', None, MS_REC | MS_PRIVATE)}")
    if direct_fd_test:
        print(f"Q1 bind from a host fd: {mount(f'/proc/self/fd/{hostfd}', '/work/scratch', None, MS_BIND)}")
    if private:
        print(f"step bind the join's store: {mount(f'/run/joins/{private}', '/work/scratch', None, MS_BIND)}")
        print(f"step cover the staging path: {mount('tmpfs', '/run/joins', 'tmpfs', 0)}")
    cap = 0
    while libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) == 0:
        cap += 1
    libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
    sys.stdout.flush()
    os.execvp("sh", ["sh", "-c", script])


def status(pid_or_self):
    lines = open(f"/proc/{pid_or_self}/status").read().splitlines()
    return [l for l in lines if l.split(":")[0] in ("Uid", "Gid", "CapBnd", "CapEff", "NoNewPrivs")]


print()
print(join("q1", "true", direct_fd_test=True).strip())
a = join("A", "echo from-A >/work/scratch/a; echo \"Q2 A sees: $(ls /work/scratch | tr '\\n' ' ')\"; "
         "echo \"Q3 A sees the staging path: [$(ls /run/joins | tr '\\n' ' ')]\"; "
         "sh -c 'echo \"Q5 a child of A sees: $(ls /work/scratch | tr \"\\n\" \" \")\"'; "
         "grep -E '^(Uid|Gid|CapBnd|CapEff|NoNewPrivs):' /proc/self/status | sed 's/^/Q6 A /'", private="A")
print(a.strip())
b = join("B", "echo from-B >/work/scratch/b; echo \"Q2 B sees: $(ls /work/scratch | tr '\\n' ' ')\"", private="B")
print(b.strip())
print("Q6 keeper " + "\nQ6 keeper ".join(status(target)))
print(f"Q4 the keeper's /work/scratch: [{' '.join(sorted(os.listdir(f'/proc/{target}/root/work/scratch')))}]")
print(f"Q4 host store A: [{' '.join(sorted(os.listdir(f'{stage}/A')))}], B: [{' '.join(sorted(os.listdir(f'{stage}/B')))}]")
print(join("plain", "echo \"Q7 a plain join sees the staging path: [$(ls -R /run/joins | tr '\\n' ' ')]\"").strip())
# Q8: from a private join, look at the staging path through the keeper payload's root.
# Inside the pid namespace, bwrap's init is 1 and the payload is 2.
c = join("C", "echo \"Q8 through /proc/2/root, C sees: [$(ls -R /proc/2/root/run/joins 2>&1 | tr '\\n' ' ')]\"", private="A")
print(c.strip())
# Q9: move B's store out of the staging directory; B's bind must still reach it.
os.makedirs(f"{T}/moved", exist_ok=True)
os.rename(f"{stage}/B", f"{T}/moved/B")
d = join("D", "echo \"Q9 after the move, through /proc/2/root: [$(ls /proc/2/root/run/joins | tr '\\n' ' ')]\"", private="A")
print(d.strip())
# Q9b: a join whose store is moved away on the host WHILE it runs keeps writing to it.
import threading
os.makedirs(f"{stage}/F")
threading.Timer(0.5, lambda: os.rename(f"{stage}/F", f"{T}/moved/F")).start()
e = join("F", "echo one >/work/scratch/f; sleep 1; echo two >>/work/scratch/f; echo \"Q9b F, after its store was moved: $(cat /work/scratch/f | tr '\\n' ' ')\"", private="F")
print(e.strip())
print(f"Q9b the moved store on the host: [{open(f'{T}/moved/F/f').read().strip()}]; still in staging: {os.path.exists(f'{stage}/F')}")
print()
print("expected: Q1 fails (EINVAL) | Q2 A sees a, B sees b | Q3 empty | Q4 keeper empty, host A=[a] B=[b] |")
print("          Q5 a | Q6 A = keeper (CapBnd 0, NoNewPrivs 1) | Q7 the staging path shows both stores |")
print("          Q8 and Q9: measured, no expectation")
keeper.kill()
keeper.wait()
subprocess.run(["rm", "-rf", T])
