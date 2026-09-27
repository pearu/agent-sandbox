#!/usr/bin/env python3
# join-launch.py PID CMD... -- run CMD inside the running launch that PID (a process
# inside it, host pid) belongs to, as that process's equal. The measurement behind
# #121 (one launch per role, every app joins it): with JOIN_SECCOMP_BPF set to the
# launch's filter file, the joined process matched the launch in mounts, environment,
# cwd, uid/gid, capabilities, NoNewPrivs and Seccomp, in net modes none and strict,
# and shared its own/copy stores (2026-09-27, kernel 6.8, bwrap 0.12, pasta).
#
#   JOIN_SECCOMP_BPF=~/.local/share/agent-sandbox/seccomp/x86_64.bpf \
#     python3 probes/join-launch.py <pid> /bin/sh -c 'cat /proc/self/status'
#
# A probe, not the engine: it trusts its caller and applies only what the launch
# applied. Requires the caller's uid to own the launch's user namespaces.
#
# Namespaces are owned by user namespaces, which nest: with pasta (strict mode)
# the net namespace belongs to pasta's, the mount namespace to bwrap's outer one,
# the process itself to bwrap's inner, capability-less one. Rights over a
# namespace come from its OWNER, and entering a child user namespace forfeits the
# parent's. So: walk the chain from the outermost user namespace down, joining
# each namespace right after entering its owner, and enter the process's own
# user namespace last. Then the launch's cwd and environment, and the two
# per-process settings namespaces do not carry: the seccomp filter and
# no_new_privs. nsenter cannot express the order.
import ctypes, fcntl, os, sys
pid, cmd = sys.argv[1], sys.argv[2:]
libc = ctypes.CDLL(None, use_errno=True)
NS_GET_USERNS, NS_GET_PARENT = 0xb701, 0xb702
def setns(fd, what):
    if libc.setns(fd, 0) != 0:
        sys.exit(f"setns {what}: {os.strerror(ctypes.get_errno())}")
def ident(fd): return os.readlink(f"/proc/self/fd/{fd}")

cwd = os.readlink(f"/proc/{pid}/cwd")
env = dict(kv.split(b"=", 1) for kv in open(f"/proc/{pid}/environ", "rb").read().split(b"\0") if b"=" in kv)
bpf = os.environ.get("JOIN_SECCOMP_BPF")             # read BEFORE joining: not visible inside
prog = open(bpf, "rb").read() if bpf else None
class Fprog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]
if prog:
    buf = ctypes.create_string_buffer(prog, len(prog))
    fp = Fprog(len(prog) // 8, ctypes.addressof(buf))

kinds = ("ipc", "uts", "net", "pid", "mnt")
ns = {k: os.open(f"/proc/{pid}/ns/{k}", os.O_RDONLY) for k in kinds}
owner = {k: fcntl.ioctl(ns[k], NS_GET_USERNS) for k in kinds}
inner = os.open(f"/proc/{pid}/ns/user", os.O_RDONLY)
host_user = ident(os.open("/proc/self/ns/user", os.O_RDONLY))
# the user-namespace chain, innermost first, up to (not including) ours
chain = [inner]
while True:
    try: parent = fcntl.ioctl(chain[-1], NS_GET_PARENT)
    except OSError: break
    if ident(parent) == host_user: break
    chain.append(parent)
# every identity is resolved NOW: /proc/self stops resolving once we join
owner_id = {k: ident(owner[k]) for k in kinds}
chain_id = [ident(fd) for fd in chain]
for user_fd, user_id in reversed(list(zip(chain, chain_id))):   # outermost first
    setns(user_fd, f"user ns {user_id}")
    for k in kinds:
        if owner_id[k] == user_id:
            setns(ns[k], k)
child = os.fork()                                      # the pid namespace applies to children
if child:
    _, st = os.waitpid(child, 0)
    sys.exit(os.waitstatus_to_exitcode(st))
os.chdir(cwd)
if prog:
    if libc.prctl(38, 1, 0, 0, 0) != 0: sys.exit("no_new_privs: " + os.strerror(ctypes.get_errno()))
    if libc.prctl(22, 2, ctypes.byref(fp), 0, 0) != 0: sys.exit("seccomp: " + os.strerror(ctypes.get_errno()))
os.execve(cmd[0], cmd, env)
