#!/usr/bin/env bash
# A stand-in for the Claude Code binary for the end-to-end installer test,
# planted where the claude profile discovers it. Inside the sandbox it acts as
# a network probe; on the host it answers the update subcommands.
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
  --bg) # play the per-user daemon: spawn ONE pooled worker THROUGH the wrapper,
    # exactly as Claude Code does (<wrapper> <binary> --bg-spare <claim.sock>),
    # so wrapper mode is exercised end to end without the real binary.
    w="${CLAUDE_CODE_PROCESS_WRAPPER-}"
    if [ -n "$w" ]; then
      # Name the rendezvous socket the way Claude Code does -- under a per-instance
      # dir (/tmp/cc-daemon-<uid>/<inst>/spare/), never bare $TMPDIR. The wrapper
      # binds the socket's *directory* read-write, so a bare-$TMPDIR socket would
      # make it bind all of $TMPDIR; when $HOME lives under $TMPDIR (the e2e
      # throwaway home does), that collides with the read-only $HOME bind and
      # bwrap fails to remount. A deep per-instance dir mirrors the real layout.
      sockdir="${TMPDIR:-/tmp}/cc-daemon-$(id -u)/fake/spare"
      mkdir -p "$sockdir"
      spare=$($w claude --bg-spare "$sockdir/$$.claim.sock" 2>&1)
      printf 'backgrounded · f00dcafe\nspare: %s\n' "$spare"
    else
      printf 'backgrounded · f00dcafe (no wrapper set)\n'
    fi
    ;;
  --bg-spare) # a pooled worker: it runs the agent, so it must be sandboxed. The
    # engine sets AGENT_SANDBOX=1 inside every bwrap, so its presence == sandboxed.
    if [ -n "${AGENT_SANDBOX-}" ]; then
      echo "fake-claude: --bg-spare ran SANDBOXED as $(id -un) in $PWD"
    else
      echo "fake-claude: --bg-spare ran UNSANDBOXED as $(id -un) in $PWD"
    fi
    ;;
  --bg-pty-host) # a terminal front, not the agent loop: the wrapper passes it
    # through to the host unsandboxed (it spawns and wraps the spare itself).
    echo "fake-claude: --bg-pty-host ran as $(id -un) in $PWD"
    ;;
  daemon) # the supervisor: trusted infra, passed through to the host unsandboxed.
    echo "fake-claude: 'daemon ${2-}' ran as $(id -un) in $PWD"
    ;;
  *)
    echo "fake-claude: unknown arguments: $*" >&2
    exit 64
    ;;
esac
