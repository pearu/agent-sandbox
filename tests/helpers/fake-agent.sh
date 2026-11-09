#!/usr/bin/env bash
# A stand-in for an agent's binary, the same for every profile: the shared tests plant it
# where that agent's installer puts its own (the profile's test adapter,
# profiles/<name>/test.bash, test_plant). Inside the sandbox it acts as a probe; on the
# host it answers the update subcommands. Its words are the tests' own, not any agent's.
#
# Planted, it is this file behind a header that tests/helpers/adapters.bash
# (fake_agent_file) writes from the profile and its adapter -- run as it is, the defaults
# below apply:
#   FAKE_AGENT          the profile's name, for its messages
#   FAKE_ROOT_OPTIONS   the agent's options that take one value and may come before a
#                       subcommand (claude: --settings, which the briefing puts first on
#                       the line); skipped in pairs before the words are read
#   FAKE_DAEMON         the argv that marks the agent's background daemon (the profile's
#                       [agent] daemon), which the keeper counts as holding a launch
#   FAKE_STATUS         the verb that lists the daemon's sessions (the profile's [agent]
#                       status)
#
# Words:
#   --version            a version line
#   update|upgrade|install
#                        where it ran (the profile routes nothing of these; a test asks)
#   fetch URL            the HTTP status through whatever proxy and CA the environment gives
#   env                  the proxy, CA, HOME and PWD it sees
#   args WORD...         each argument after `args` on a line of its own, `arg=WORD`
#   sh SCRIPT            runs SCRIPT with bash, inside: what an integration test asks
#   --bg ...             hands the task to the per-user daemon, starting one if none runs
#   FAKE_DAEMON...       the daemon itself: it stays, as the real one does when idle
#   FAKE_STATUS          whether the daemon it can reach is running
: "${FAKE_AGENT:=agent}"
[ -n "${FAKE_ROOT_OPTIONS+x}" ] || FAKE_ROOT_OPTIONS=()
# Neutral raw defaults, no agent's words: what runs the raw file (CI's e2e-real-systemd
# job, which only needs it found) never asks for a daemon.
[ -n "${FAKE_DAEMON+x}" ] || FAKE_DAEMON=(fake-agent-daemon run)
: "${FAKE_STATUS:=fake-agent-status}"
skipped=1
while [ "$skipped" = 1 ] && [ $# -ge 2 ]; do
  skipped=0
  for o in ${FAKE_ROOT_OPTIONS[@]+"${FAKE_ROOT_OPTIONS[@]}"}; do
    if [ "$1" = "$o" ]; then
      shift 2
      skipped=1
      break
    fi
  done
done
pidf="${TMPDIR:-/tmp}/fake-$FAKE_AGENT-daemon.pid"
if [ "$*" = "${FAKE_DAEMON[*]}" ]; then # the supervisor: it stays, as the real one does when idle
  # Not `exec sleep`: this process's argv is what marks it as the daemon, and exec would
  # replace it with sleep's.
  echo $$ >"$pidf"
  sleep 600 &
  wait
  exit 0
fi
case ${1-} in
  --version) echo "9.9.9 (fake-agent $FAKE_AGENT)" ;;
  update | upgrade | install)
    echo "fake-agent: '$1' ran unsandboxed as $(id -un) in $PWD"
    ;;
  fetch) # fetch URL: the HTTP status through whatever proxy and CA the environment provides
    err="${TMPDIR:-/tmp}/fake-agent-fetch.$$"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$2" 2>"$err")
    rc=$?
    echo "code=$code rc=$rc err=$(tr '\n' ' ' <"$err")"
    rm -f "$err"
    ;;
  env)
    printf 'HTTPS_PROXY=%s\nSSL_CERT_FILE=%s\nHOME=%s\nPWD=%s\n' \
      "${HTTPS_PROXY-unset}" "${SSL_CERT_FILE-unset}" "$HOME" "$PWD"
    ;;
  args)
    shift
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
    ;;
  sh) exec bash -c "$2" ;;
  --bg) # hand the task to the per-user daemon, as Claude Code does: start one if none
    # runs (detached, so it outlives this client), and say where this ran. Inside a
    # role's sandbox the daemon starts inside too, and holds the role's launch.
    [ -n "${AGENT_SANDBOX-}" ] && where=SANDBOXED || where=UNSANDBOXED
    if ! { [ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; }; then
      setsid "$0" "${FAKE_DAEMON[@]}" </dev/null >/dev/null 2>&1 &
    fi
    printf 'backgrounded · f00dcafe (%s, wrapper=%s)\n' "$where" "${CLAUDE_CODE_PROCESS_WRAPPER-none}"
    ;;
  "$FAKE_STATUS") # what the real one lists: sessions of the daemon it can reach
    if [ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
      echo "$FAKE_STATUS: daemon running"
    else
      echo "$FAKE_STATUS: no daemon"
    fi
    ;;
  *)
    echo "fake-agent: unknown arguments: $*" >&2
    exit 64
    ;;
esac
