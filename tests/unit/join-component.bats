#!/usr/bin/env bats
# components/join.py, as a module: what the join returns for its command's end. The
# join runs under whatever python3 is first on PATH, so nothing here may need a newer
# Python than the oldest one it meets.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  JOIN="$REPO_ROOT/components/join.py"
}

@test "exit_status: the command's code, or 128 + its signal -- without os.waitstatus_to_exitcode (Python < 3.9)" {
  run python3 - "$JOIN" <<'PY'
import importlib.util, os, signal, sys
del os.waitstatus_to_exitcode  # as on Python 3.8 and older
spec = importlib.util.spec_from_file_location("join", sys.argv[1])
join = importlib.util.module_from_spec(spec)
spec.loader.exec_module(join)
for code in (0, 1, 3, 127):
    pid = os.fork()
    if pid == 0:
        os._exit(code)
    _, st = os.waitpid(pid, 0)
    assert join.exit_status(st) == code, (code, join.exit_status(st))
pid = os.fork()
if pid == 0:
    os.kill(os.getpid(), signal.SIGTERM)
    os._exit(0)
_, st = os.waitpid(pid, 0)
assert join.exit_status(st) == 128 + signal.SIGTERM, join.exit_status(st)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "join.py uses no os.waitstatus_to_exitcode, which Python 3.8 does not have" {
  run ! grep -n 'waitstatus_to_exitcode(' "$JOIN"
}
