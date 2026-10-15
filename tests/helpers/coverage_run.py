#!/usr/bin/env python3
"""Run a Python script under coverage.py, for scripts that leave the host's mounts.

    python3 coverage_run.py DATADIR RCFILE SCRIPT [ARG]...

scripts/coverage.sh sets AGENT_SANDBOX_TEST_PYTHON to this (with the python3 that has
coverage.py), so the engine's Python components are measured where they run. Each run
-- and each forked child that execs or _exits -- writes its data to DATADIR as
`.coverage.<pid>.<random>.dump` (CoverageData.dumps()); scripts/coverage.sh's merge
loads and combines them.

WHY NOT `coverage run -p`. components/join.py enters the sandbox's mount namespace
(setns) and stays there until it exits, so coverage.py's data file, a host path, does
not resolve when it is saved: the save fails, and `coverage run` then exits 1 instead of
the join's status (measured, tests/integration/keeper.bats). Here DATADIR is opened
BEFORE the script runs, and the data is written through that directory handle, which
keeps reaching the host's directory from any mount namespace -- as join.py itself moves
a join's stores out of staging. coverage.py's own `patch = execv` would save through
the path too, and it adds COVERAGE_PROCESS_CONFIG to the exec'd command's environment,
which is the sandbox's: so the exec and _exit hooks are this file's, and leave the
environment alone.
"""

import os
import runpy
import secrets
import sys

import coverage

# Imported now, on the host: dumps() imports them lazily, and after a join's setns the
# environment coverage.py comes from is not there to import them from (measured: the
# save failed with "No module named 'sqlite3.dump'").
import sqlite3.dump  # noqa: F401, E402
import zlib  # noqa: F401, E402


def main():
    datadir, rcfile, script = sys.argv[1:4]
    dfd = os.open(datadir, os.O_RDONLY | os.O_DIRECTORY)
    cov = coverage.Coverage(data_file=None, config_file=rcfile)
    saved = []

    def save():
        if saved and saved[-1] == os.getpid():
            return
        saved.append(os.getpid())
        try:
            cov.stop()
            data = cov.get_data()
            if not data.measured_files():  # a script outside the rcfile's source
                return
            blob = data.dumps()
            name = f".coverage.{os.getpid()}.{secrets.token_hex(8)}.dump"
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=dfd)
            with os.fdopen(fd, "wb") as fh:
                fh.write(blob)
        except Exception as exc:  # measuring must never change what the script does
            sys.stderr.write(f"coverage_run: not saved: {exc}\n")

    def hook(fn):
        def wrapped(*args, **kwargs):
            save()
            return fn(*args, **kwargs)

        return wrapped

    # os.execvpe and the rest of the exec family end in os.execv or os.execve.
    os.execv, os.execve, os._exit = hook(os.execv), hook(os.execve), hook(os._exit)
    sys.argv = sys.argv[3:]
    sys.path[0] = os.path.dirname(os.path.abspath(script))
    cov.start()
    try:
        runpy.run_path(script, run_name="__main__")
    finally:
        save()


if __name__ == "__main__":
    main()
