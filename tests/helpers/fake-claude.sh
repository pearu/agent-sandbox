#!/usr/bin/env bash
# A stand-in for the Claude Code binary for the end-to-end installer test,
# planted where the claude profile discovers it. Inside the sandbox it acts as
# a network probe; on the host it answers the update subcommands.
# Root options come before a subcommand, as Claude Code's do (`claude --settings X
# mcp list`): the briefing's --settings is first on the line.
while [ "${1-}" = --settings ]; do shift 2; done
case ${1-} in
  --version) echo "9.9.9 (fake-claude)" ;;
  update | upgrade | install)
    echo "fake-claude: '$1' ran unsandboxed as $(id -un) in $PWD"
    ;;
  fetch) # fetch URL: the HTTP status through whatever proxy and CA the environment provides
    err="${TMPDIR:-/tmp}/fake-claude-fetch.$$"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$2" 2>"$err")
    rc=$?
    echo "code=$code rc=$rc err=$(tr '\n' ' ' <"$err")"
    rm -f "$err"
    ;;
  env)
    printf 'HTTPS_PROXY=%s\nSSL_CERT_FILE=%s\nHOME=%s\nPWD=%s\n' \
      "${HTTPS_PROXY-unset}" "${SSL_CERT_FILE-unset}" "$HOME" "$PWD"
    ;;
  --bg) # hand the task to the per-user daemon, as Claude Code does: start one if none
    # runs (detached, so it outlives this client), and say where this ran. Inside a
    # role's sandbox the daemon starts inside too, and holds the role's launch.
    [ -n "${AGENT_SANDBOX-}" ] && where=SANDBOXED || where=UNSANDBOXED
    pidf="${TMPDIR:-/tmp}/fake-claude-daemon.pid"
    if ! { [ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; }; then
      setsid "$0" daemon run </dev/null >/dev/null 2>&1 &
    fi
    printf 'backgrounded · f00dcafe (%s, wrapper=%s)\n' "$where" "${CLAUDE_CODE_PROCESS_WRAPPER-none}"
    ;;
  daemon)
    if [ "${2-}" = run ]; then # the supervisor: it stays, as the real one does when idle
      # Not `exec sleep`: this process's argv (`... daemon run`) is what marks it as
      # the daemon, and exec would replace it with sleep's.
      echo $$ >"${TMPDIR:-/tmp}/fake-claude-daemon.pid"
      sleep 600 &
      wait
      exit 0
    fi
    echo "fake-claude: 'daemon ${2-}' ran as $(id -un) in $PWD"
    ;;
  agents) # what the real one lists: sessions of the daemon it can reach
    pidf="${TMPDIR:-/tmp}/fake-claude-daemon.pid"
    if [ -r "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
      echo "agents: daemon running"
    else
      echo "agents: no daemon"
    fi
    ;;
  *)
    echo "fake-claude: unknown arguments: $*" >&2
    exit 64
    ;;
esac
