#!/usr/bin/env bats
# A joined command and the terminal (components/join.py). Where the kernel blocks
# TIOCSTI (/proc/sys/dev/tty/legacy_tiocsti is 0), the command stays in the terminal's
# session: a resize reaches it as SIGWINCH, an interactive shell has job control, and
# one Ctrl-C is one SIGINT. Measured 2026-09-30: with the join's setsid() the command
# had no controlling terminal and never saw a resize. Driven on a pty, under the real bwrap.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  [[ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2>/dev/null)" == 0 ]] \
    || skip "this kernel lets unprivileged processes use TIOCSTI, so a join keeps its own session (#165)"
  make_integration <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
}

# on_pty PYTHON-BODY -- run the engine's --exec on a pty; the body drives it. It gets
# `fd`, `pid`, `read_until(marker)` and `out()` in scope, and prints what it measured.
on_pty() {
  cat >"$I/drive.py" <<EOF
import os, pty, select, signal, struct, sys, termios, fcntl, time
env = {"HOME": "$IHOME", "PATH": "$I/bin:/usr/bin:/bin", "USER": os.environ.get("USER", "u"),
       "TERM": "xterm", "AGENT_SANDBOX_PROFILE_DIR": "$IPROFILES", "AGENT_SANDBOX_NET": "none",
       "AGENT_SANDBOX_SESSION_BASE": "$I/base", "AGENT_SANDBOX_KEEPER_GRACE": "0",
       "AGENT_SANDBOX_PRESET": "shared"}
argv = ["$ENGINE", "--profile", "probe", "--exec"] + sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.chdir("$IWORK")
    os.execve(argv[0], argv, env)
buf = b""
def read_until(marker, limit=30):
    global buf
    t0 = time.time()
    while marker.encode() not in buf and time.time() - t0 < limit:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                c = os.read(fd, 4096)
            except OSError:
                return False
            if not c:
                return False
            buf += c
    return marker.encode() in buf
def out():
    return buf.decode(errors="replace")
$(cat)
os.waitpid(pid, 0)
EOF
  run timeout 90 python3 "$I/drive.py" "$@"
}

@test "a resize of the terminal reaches the joined command as SIGWINCH" {
  on_pty sh -c "trap 'echo GOT-WINCH' WINCH; echo READY; i=0; while [ \$i -lt 40 ]; do sleep 0.1; i=\$((i+1)); done; echo END" <<'PY'
read_until("READY")
time.sleep(0.3)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
read_until("END")
print("winch" if "GOT-WINCH" in out() else "no-winch")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *winch* && "$output" != *no-winch* ]]
}

@test "an interactive shell under --exec has job control" {
  on_pty env "PS1=PROMPT$ " bash --norc --noprofile -i <<'PY'
for line in ("sleep 2 &\n", "jobs\n", "exit\n"):
    read_until("PROMPT$ ")
    os.write(fd, line.encode())
    time.sleep(0.2)
read_until("NEVER", limit=5)
print("no-job-control" if ("no job control" in out() or "cannot set terminal process group" in out()) else "job-control")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *job-control* && "$output" != *no-job-control* ]]
}

@test "one Ctrl-C at the terminal is one SIGINT to the joined command" {
  on_pty sh -c "n=0; trap 'n=\$((n+1))' INT; echo READY; i=0; while [ \$i -lt 30 ]; do sleep 0.1; i=\$((i+1)); done; echo END-\$n" <<'PY'
read_until("READY")
time.sleep(0.3)
os.write(fd, b"\x03")
read_until("END-")
import re
m = re.search(r"END-(\d+)", out())  # the terminal echoes ^C right before it
print("sigints=" + (m.group(1) if m else "none"))
PY
  [ "$status" -eq 0 ]
  [ "$output" = sigints=1 ]
}
