#!/usr/bin/env bash
# tests/helpers/kcov-exec.sh LOG LIBS KCOV ARGS... -- run KCOV (scripts/coverage.sh's,
# through engine_cmd) with its own stdout on /dev/null and its stderr appended to LOG,
# the caller's two kept on fds 9 and 8 for the command KCOV traces. engine_cmd has KCOV
# start that command as `kcov-exec.sh --inner CMD...`, which puts the two back as its
# stdout and stderr and execs CMD: CMD is still KCOV's direct child (#462).
#
# LIBS, when not empty, is LD_LIBRARY_PATH for KCOV alone, so that a conda-built kcov
# finds its libraries; --inner gives CMD the caller's LD_LIBRARY_PATH back (or none).
# CMD must not get LIBS: the engine's own tools would load the conda environment's
# libraries over the system's -- the system curl, given conda's libcurl, prints "no
# version information available" into what the test reads (#469's CI run).
#
# Why: kcov v43, tracing a bash script,
# - relays the script's stdout through a pipe of its own, and reads that pipe only
#   between trace lines. One write larger than the pipe (64 KiB; 8 KiB for a user over
#   fs.pipe-user-pages-soft) blocks the script, and kcov with it, for good: --help and
#   --status hung so;
# - writes the continuation lines of a trace record that spans lines (a command whose
#   text holds a newline, `*[$'\t\n']*`) to its own stderr, which was the test's output.
# With kcov's own two elsewhere, neither reaches the test, and the engine writes to the
# test's descriptors directly.
if [[ "${1:-}" == --inner ]]; then
  shift
  case "${KCOV_EXEC_LD_LIBRARY_PATH-}" in
    -) unset LD_LIBRARY_PATH ;;
    =*) export LD_LIBRARY_PATH="${KCOV_EXEC_LD_LIBRARY_PATH#=}" ;;
  esac
  unset KCOV_EXEC_LD_LIBRARY_PATH
  exec 1>&9 2>&8 9>&- 8>&-
  exec "$@"
fi
log="$1" libs="$2"
shift 2
if [[ -n "$libs" ]]; then
  # the caller's, for --inner to put back: =VALUE, or - for none
  if [[ -v LD_LIBRARY_PATH ]]; then
    export KCOV_EXEC_LD_LIBRARY_PATH="=$LD_LIBRARY_PATH"
  else
    export KCOV_EXEC_LD_LIBRARY_PATH=-
  fi
  export LD_LIBRARY_PATH="$libs"
fi
exec 9>&1 8>&2 >/dev/null 2>>"$log"
exec "$@"
