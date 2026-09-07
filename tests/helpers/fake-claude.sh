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
  *)
    echo "fake-claude: unknown arguments: $*" >&2
    exit 64
    ;;
esac
