#!/usr/bin/env bats
# The sshd profile end to end (#335): the REAL bwrap, pasta, nftables and OpenSSH. The
# engine of this checkout launches `asb --profile sshd` in a throwaway project on a free
# loopback port, with a throwaway key pair and a policy (strict, the port, an [env] set,
# the keys file outside the project), its proxy of its own a fake started through
# AGENT_SANDBOX_MITMDUMP -- an HTTP proxy that answers every request and logs it, which
# is all the sandbox's side needs. Then, through ssh from the host: a command, `bash -s`
# on stdin, sftp (a put and a get), rsync, a detached job that outlives its session, a
# pty session, a request that reaches the proxy and a direct connection that does not;
# and `asb --shutdown` ending all of it. Skips where sshd, ssh, ssh-keygen or pasta is
# absent, or pasta cannot make a namespace here.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  local t
  for t in /usr/sbin/sshd ssh ssh-keygen sftp pasta nft curl; do
    command -v "$t" >/dev/null || [[ -x "$t" ]] || skip "$t is not installed (openssh-server, openssh-client, passt, nftables, curl)"
  done
  if ! timeout -k 1 8 pasta --config-net --quiet -- true >/dev/null 2>&1 3>&-; then
    skip "pasta cannot create a namespace here (needs passt + its AppArmor profile, or the userns sysctl relaxed)"
  fi
  make_integration </dev/null
  PROJ="$(cd "$IWORK" && pwd -P)"
  mkdir -p "$PROJ/tmp" "$I/keys" "$IHOME/.config/agent-sandbox"
  : >"$IHOME/.config/agent-sandbox/allowlist_addon.py" # the engine checks it is installed
  make_fake_ca "$I/ca.pem"
  ssh-keygen -q -t ed25519 -N '' -C sshd-test -f "$I/keys/client" </dev/null
  cp "$I/keys/client.pub" "$I/keys/authorized"
  PORT="$(free_port)"
  PROXY_PORT="$(free_port)"
  # The fake proxy: answers every request 200 with a fixed body and logs its first line
  # beside itself; started by the engine with --listen-port, as mitmdump is.
  cat >"$I/fake-mitmdump" <<'S'
#!/usr/bin/env bash
d="${0%/*}"
port=""
while [ "$#" -gt 0 ]; do [ "$1" = --listen-port ] && port="$2"; shift; done
exec python3 -c '
import socketserver, sys
log = sys.argv[2]
class H(socketserver.StreamRequestHandler):
    def handle(self):
        first = self.rfile.readline().decode("latin-1").strip()
        auth = "no-auth"
        while True:
            l = self.rfile.readline()
            if not l or l in (b"\r\n", b"\n"):
                break
            if l.lower().startswith(b"proxy-authorization:"):
                auth = "auth"
        with open(log, "a") as fh:
            fh.write("%s %s\n" % (first, auth))
        body = b"fake-proxy-ok\n"
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$port" "$d/proxy.log"
S
  chmod +x "$I/fake-mitmdump"
  printf '[net]\nmode = strict\nagent-port = %s\n\n[env]\nTMPDIR = %s/tmp\n\n[sshd]\nauthorized-keys = %s\n' \
    "$PORT" "$PROJ" "$I/keys/authorized" >"$PROJ/.agent-sandbox"
  local tr="$IHOME/.config/agent-sandbox/trust"
  mkdir -p "$tr"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 >"$tr/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
  LAUNCH_PID=""
}

teardown() {
  if [[ -n "${LAUNCH_PID:-}" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    asb_sshd --shutdown >/dev/null 2>&1 || true
    kill "$LAUNCH_PID" 2>/dev/null || true
  fi
  return 0
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

listening() { (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# What the role's port says first: sshd's banner once it runs.
# shellcheck disable=SC2016 # the inner shell's $1
banner() { timeout 2 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" && head -c 4 <&3' _ "$PORT" 2>/dev/null; }

# asb_sshd ARGS... -- the engine as the profile's owner runs it, from the project.
asb_sshd() {
  engine_cmd
  (cd "$PROJ" && exec env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm LANG=C.UTF-8 \
    AGENT_SANDBOX_KEEPER_GRACE=0 AGENT_SANDBOX_SECCOMP_DIR="$I/no-seccomp" AGENT_SANDBOX_PROXY_CA="$I/ca.pem" \
    AGENT_SANDBOX_MITMDUMP="$I/fake-mitmdump" AGENT_SANDBOX_PROXY_PORT="$PROXY_PORT" \
    "${ENGINE_CMD[@]}" --profile sshd "$@")
}

# s ARGS... -- ssh into the role as this account, with the throwaway key only. Its
# stderr goes to $I/ssh.err: the account's home in /etc/passwd is not this test's HOME,
# so sshd says it cannot chdir there (a real launch's HOME is the account's).
SSH_OPTS=()
s() {
  ssh "${SSH_OPTS[@]}" -p "$PORT" "$(id -un)@127.0.0.1" "$@" 2>>"$I/ssh.err"
}

@test "sshd: a command, bash -s, sftp, rsync, a detached job, a pty, egress only through the proxy; --shutdown ends it all" {
  SSH_OPTS=(-F /dev/null -i "$I/keys/client" -o IdentitiesOnly=yes -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
  asb_sshd </dev/null >"$I/launch.out" 2>&1 3>&- &
  LAUNCH_PID=$!
  local i
  # pasta accepts on the host at once; sshd inside answers with its banner once it runs
  for ((i = 0; i < 150; i++)); do
    [[ "$(banner)" == SSH-* ]] && break
    kill -0 "$LAUNCH_PID" 2>/dev/null || break
    sleep 0.1
  done
  echo "launch: $(cat "$I/launch.out")"
  [[ "$(banner)" == SSH-* ]]
  grep -q "sshd: proxy of its own at 127.0.0.1:$PROXY_PORT" "$I/launch.out"

  # a command
  run s 'echo hello; id -u'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = hello ]
  [ "${lines[1]}" = "$(id -u)" ]

  # bash -s, the script on stdin
  # shellcheck disable=SC2016 # the remote shell's arithmetic
  run s bash -s <<<'echo "from stdin $((6 * 7))"'
  [ "$status" -eq 0 ]
  [ "$output" = "from stdin 42" ]

  # the session has what the launch has: the proxy with its token, the CA variables,
  # the policy's [env] set
  run s env
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^HTTPS_PROXY=http://[0-9a-f]{32}:x@[0-9.]+:'"$PROXY_PORT"'$'
  printf '%s\n' "$output" | grep -qx 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
  printf '%s\n' "$output" | grep -qx "TMPDIR=$PROJ/tmp"
  printf '%s\n' "$output" | grep -qx 'AGENT_SANDBOX=1'

  # sftp: a put and a get
  printf 'up\n' >"$I/up.txt"
  printf 'down\n' >"$PROJ/srv.txt"
  run sftp "${SSH_OPTS[@]}" -P "$PORT" -b - "$(id -un)@127.0.0.1" <<EOF
put $I/up.txt $PROJ/up.txt
get $PROJ/srv.txt $I/down.txt
EOF
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/up.txt")" = up ]
  [ "$(cat "$I/down.txt")" = down ]

  # rsync over the same ssh
  if command -v rsync >/dev/null; then
    mkdir -p "$I/rs/sub"
    printf 'r\n' >"$I/rs/sub/f"
    run rsync -a -e "ssh ${SSH_OPTS[*]} -p $PORT" "$I/rs/" "$(id -un)@127.0.0.1:$PROJ/rs/"
    [ "$status" -eq 0 ]
    [ "$(cat "$PROJ/rs/sub/f")" = r ]
  else
    echo "# rsync is not installed: its step skipped" >&3
  fi

  # a detached job outlives its session: it keeps writing after the session ended
  run s "setsid nohup bash -c 'while :; do date +%s%N >$PROJ/beat; sleep 0.2; done' >/dev/null 2>&1 </dev/null & echo started"
  [ "$status" -eq 0 ]
  [ "$output" = started ]
  sleep 1
  local b1 b2
  b1="$(cat "$PROJ/beat")"
  sleep 1
  b2="$(cat "$PROJ/beat")"
  [ "$b1" != "$b2" ]

  # a pty session
  run s -tt tty </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | tr -d '\r' | grep -qE '^/dev/pts/[0-9]+$'

  # egress: a request reaches the proxy, with the session's token; a direct one does not
  run s 'curl -sS -m 10 http://sshd-test.invalid/marker'
  [ "$status" -eq 0 ]
  [ "$output" = fake-proxy-ok ]
  grep -q '^GET http://sshd-test.invalid/marker HTTP/1.1 auth$' "$I/proxy.log"
  run s 'curl -sS -m 3 --noproxy "*" -o /dev/null http://1.1.1.1/; echo "rc=$?"'
  [[ "$output" == *"rc="* && "$output" != *"rc=0"* ]]

  # --shutdown: the launch returns, nothing listens on either port, the job is gone
  run asb_sshd --shutdown
  [ "$status" -eq 0 ]
  for ((i = 0; i < 100; i++)); do
    kill -0 "$LAUNCH_PID" 2>/dev/null || break
    sleep 0.1
  done
  run ! kill -0 "$LAUNCH_PID"
  LAUNCH_PID=""
  run ! listening "$PORT"
  run ! listening "$PROXY_PORT"
  b1="$(cat "$PROJ/beat")"
  sleep 1
  [ "$(cat "$PROJ/beat")" = "$b1" ]
}
