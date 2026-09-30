#!/usr/bin/env bats
# The keeper (#121), under the REAL bwrap: one launch per role, and every app joins it.
#
# The unit suite plays the keeper with a stub bwrap and a stub join, so it pins what
# the engine asks for; this proves that what it asks for is what happens -- that a
# second invocation of a running role is a process INSIDE the first one's launch, as
# its equal, and that the launch ends when the last of them does. The acceptance of
# #121 is the list of @tests below.
#
# A held join is an `--exec` that writes a marker in the project (bound read-write)
# and then waits for a release file there. Per-join behaviour is given on the
# command line, never in the environment: a join's environment is the KEEPER's,
# except the terminal's variables, which is one of the things tested here.
# shellcheck disable=SC2016 # the --exec scripts expand inside the sandbox, not here

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v python3 >/dev/null || skip "python3 not installed"
  command -v flock >/dev/null || skip "flock not installed (util-linux)"
  make_integration <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  SB="$IHOME/.local/state/agent-sandbox/probe/$(printf '%s' "$(cd "$IWORK" && pwd -P)" | sed 's:[^A-Za-z0-9-]:-:g')/default"
  printf 'YOURS\n' >"$IHOME/.probe/docs/a.md"
  BASE=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state")
  BGS=()
}

teardown() {
  local p f spid
  : >"$IWORK/release.all" 2>/dev/null
  for p in ${BGS[@]+"${BGS[@]}"}; do kill "$p" 2>/dev/null; done
  # Only keepers this test started, by the supervisor pid their record names.
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# hold NAME -- a command line that marks NAME as joined, then waits to be released.
hold() {
  printf 'touch %s.in; until [ -e release.%s ] || [ -e release.all ]; do sleep 0.05; done' "$1" "$1"
}

# bg_sandboxed NAME [VAR=value ...] -- engine args: start a launch in the background
# and return once NAME's command is inside (the marker exists). Sets BG_PID.
bg_sandboxed() {
  local name="$1" i
  shift
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  (cd "$IWORK" && exec env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE="${KEEPER_GRACE:-0}" \
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" "${envs[@]}" "$ENGINE" "$@") \
    </dev/null >"$I/$name.out" 2>&1 3>&- &
  BG_PID=$!
  BGS+=("$BG_PID")
  for ((i = 0; i < 300; i++)); do
    [[ -e "$IWORK/$name.in" ]] && return 0
    kill -0 "$BG_PID" 2>/dev/null || break
    sleep 0.05
  done
  echo "bg_sandboxed $name: did not join:" >&2
  cat "$I/$name.out" >&2
  return 1
}

release() { : >"$IWORK/release.$1"; }

keeper_payload() {
  local t
  read -r _ _ t _ <"$SB/keeper/id" && printf '%s' "$t"
}

wait_gone() { # wait_gone PID -- up to 10 s
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -d "/proc/$1" ]] || return 0
    sleep 0.05
  done
  return 1
}

@test "two launches of one role at once are ONE launch: one mount namespace, one overlay" {
  bg_sandboxed a "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- \
    --profile probe --exec sh -c "readlink /proc/self/ns/mnt >a.ns; awk -v m=\"\$HOME/.probe/docs\" '\$5 == m {print \$3}' /proc/self/mountinfo >a.dev; $(hold a)"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- \
    --profile probe --exec sh -c "readlink /proc/self/ns/mnt >b.ns; awk -v m=\"\$HOME/.probe/docs\" '\$5 == m {print \$3}' /proc/self/mountinfo >b.dev"
  [ "$status" -eq 0 ]
  [ -s "$IWORK/a.dev" ]
  [ "$(cat "$IWORK/a.ns")" = "$(cat "$IWORK/b.ns")" ]
  [ "$(cat "$IWORK/a.dev")" = "$(cat "$IWORK/b.dev")" ]
  # and the payload is inside that same namespace
  [ "$(readlink "/proc/$(keeper_payload)/ns/mnt")" = "$(cat "$IWORK/a.ns")" ]
  release a
}

@test "a joined app is the keeper's equal: mounts, uid/gid, capabilities, no_new_privs, seccomp" {
  # With the real filter, where it can be compiled here: a join has to apply it itself
  # (a seccomp filter does not carry across setns), and equal status lines prove it did.
  local sc="$I/seccomp" have_filter=0
  local -a base=("${BASE[@]}")
  mkdir -p "$sc"
  if python3 -c 'import pyseccomp' 2>/dev/null \
    && python3 "$REPO_ROOT/components/seccomp/gen-seccomp.py" "$REPO_ROOT/components/seccomp/moby-default.json" \
      "$(uname -m)" "$sc/$(uname -m).bpf" 2>/dev/null; then
    have_filter=1
    base+=(AGENT_SANDBOX_SECCOMP_DIR="$sc")
  fi
  bg_sandboxed a "${base[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t
  t="$(keeper_payload)"
  if ((have_filter)); then
    grep -q '^Seccomp:[[:space:]]*2$' "/proc/$t/status"
  fi
  run_sandboxed "${base[@]}" -- --profile probe --exec sh -c 'grep -E "^(Uid|Gid|Cap[A-Za-z]+|NoNewPrivs|Seccomp):" /proc/self/status >status.b; cat /proc/self/mountinfo >mounts.b; readlink /proc/self/ns/pid /proc/self/ns/net /proc/self/ns/uts /proc/self/ns/ipc /proc/self/ns/user >ns.b; unshare -U true 2>/dev/null && echo yes >unshare.b || echo no >unshare.b'
  [ "$status" -eq 0 ]
  diff <(grep -E "^(Uid|Gid|Cap[A-Za-z]+|NoNewPrivs|Seccomp):" "/proc/$t/status") "$IWORK/status.b"
  diff <(awk '{print $4, $5, $6, $9, $10}' "/proc/$t/mountinfo") <(awk '{print $4, $5, $6, $9, $10}' "$IWORK/mounts.b")
  diff <(readlink "/proc/$t/ns/pid" "/proc/$t/ns/net" "/proc/$t/ns/uts" "/proc/$t/ns/ipc" "/proc/$t/ns/user") "$IWORK/ns.b"
  # the filter is what refuses a new user namespace (see the engine's seccomp notes)
  if ((have_filter)); then
    [ "$(cat "$IWORK/unshare.b")" = no ]
  fi
  release a
}

@test "a join's environment is the keeper's, except the terminal it came from" {
  bg_sandboxed a "${BASE[@]}" AGENT_SANDBOX_FORWARD=MINE MINE=from-keeper -- --profile probe --exec sh -c "$(hold a)"
  local t
  t="$(keeper_payload)"
  run_sandboxed "${BASE[@]}" TERM=vt100 LANG=C MINE=from-join -- --profile probe --exec sh -c 'env -0 >env.b'
  [ "$status" -eq 0 ]
  # what describes the sandbox is the keeper's...
  grep -qz '^MINE=from-keeper$' "$IWORK/env.b"
  # ...what describes the terminal is this join's own: set, or unset when it is unset
  grep -qz '^TERM=vt100$' "$IWORK/env.b"
  grep -qz '^LANG=C$' "$IWORK/env.b"
  # and apart from the terminal's variables the two environments are the same
  local drop='^(TERM|LANG|LC_[A-Z]+|TZ|COLORTERM|NO_COLOR|FORCE_COLOR|SHLVL|PWD|_)='
  diff <(tr '\0' '\n' <"/proc/$t/environ" | grep -Ev "$drop" | sort) \
    <(tr '\0' '\n' <"$IWORK/env.b" | grep -Ev "$drop" | sort)
  release a
}

@test "what one join writes to an own store, another reads, and it is in the role's store" {
  bg_sandboxed a "${BASE[@]}" AGENT_SANDBOX_CONNECT='extra=own native' -- \
    --profile probe --exec sh -c "echo FROM-A >\"\$HOME/.probe/extra/x\"; $(hold a)"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='extra=own native' -- --profile probe --exec sh -c 'cat "$HOME/.probe/extra/x" >seen.b'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/seen.b")" = FROM-A ]
  [ ! -e "$IHOME/.probe/extra/x" ] # nothing reached the native source
  release a
}

@test "the keeper ends when its last join ends, and not while one is still joined" {
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t spid
  t="$(keeper_payload)"
  read -r spid _ <"$SB/keeper/id"
  run_sandboxed "${BASE[@]}" -- --profile probe --exec true
  [ "$status" -eq 0 ]
  sleep 0.3
  [ -d "/proc/$t" ] # a still joined: the keeper stays
  release a
  wait "$BG_PID"
  wait_gone "$t"
  wait_gone "$spid"
  [ ! -e "$SB/keeper" ]
}

@test "with a grace, commands run one after another share one keeper, which then ends on its own" {
  KEEPER_GRACE=2 bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t
  t="$(keeper_payload)"
  release a
  wait "$BG_PID"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_KEEPER_GRACE=2 -- --profile probe --exec true
  [ "$status" -eq 0 ]
  [ "$(keeper_payload)" = "$t" ] # joined the idle keeper within its grace
  wait_gone "$t"
}

@test "a join that arrives during the grace keeps the keeper: it is counted again before the end" {
  KEEPER_GRACE=1 bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t
  t="$(keeper_payload)"
  release a
  wait "$BG_PID" # the keeper is idle now, inside its grace
  KEEPER_GRACE=1 bg_sandboxed b "${BASE[@]}" -- --profile probe --exec sh -c "$(hold b)"
  [ "$(keeper_payload)" = "$t" ]
  sleep 2 # past the grace that began before b joined
  [ -d "/proc/$t" ]
  [ -e "$IWORK/b.in" ]
  release b
  wait "$BG_PID"
  wait_gone "$t"
}

@test "a join may repeat the running policy, not change it" {
  bg_sandboxed a "${BASE[@]}" -- --preset shared --profile probe --exec sh -c "$(hold a)"
  run_sandboxed "${BASE[@]}" -- --preset isolated --profile probe --exec true
  [ "$status" -eq 2 ]
  [[ "$output" == *"preset = shared"*"isolated"* ]]
  run_sandboxed "${BASE[@]}" -- --preset shared --profile probe --exec true
  [ "$status" -eq 0 ]
  run_sandboxed AGENT_SANDBOX_NET=proxy XDG_STATE_HOME="$IHOME/.local/state" -- --profile probe --exec true
  [ "$status" -eq 2 ]
  [[ "$output" == *"net = none"* ]]
  release a
}

@test "a changed dot-file is not seen by the running keeper, and is seen by the next" {
  trust_it() {
    mkdir -p "$IHOME/.config/agent-sandbox/trust"
    sha256sum -- "$IWORK/.agent-sandbox" | cut -d' ' -f1 \
      >"$IHOME/.config/agent-sandbox/trust/$(printf '%s' "$(cd "$IWORK" && pwd -P)" | sha256sum | cut -d' ' -f1)"
  }
  printf '[connect]\ndocs = read-only native\n' >"$IWORK/.agent-sandbox"
  trust_it
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  printf '[connect]\ndocs = own native\n' >"$IWORK/.agent-sandbox"
  trust_it
  run_sandboxed "${BASE[@]}" -- --profile probe --exec sh -c 'echo X >"$HOME/.probe/docs/new.md" 2>/dev/null && echo wrote >w.b || echo refused >w.b'
  [ "$status" -eq 0 ]
  [[ "$output" == *".agent-sandbox has changed"* ]]
  [ "$(cat "$IWORK/w.b")" = refused ] # still read-only: the keeper's policy
  release a
  wait "$BG_PID"
  run_sandboxed "${BASE[@]}" -- --profile probe --exec sh -c 'echo X >"$HOME/.probe/docs/new.md" 2>/dev/null && echo wrote >w.c || echo refused >w.c'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/w.c")" = wrote ] # the next keeper has the new policy
  [ ! -e "$IHOME/.probe/docs/new.md" ]
}

@test "Ctrl-C at one join ends that join's command, not the launch" {
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t
  t="$(keeper_payload)"
  (cd "$IWORK" && exec setsid env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE=0 AGENT_SANDBOX_PRESET=shared \
    "${BASE[@]}" "$ENGINE" --profile probe --exec sh -c 'touch b.in; exec sleep 60') \
    </dev/null >"$I/b.out" 2>&1 3>&- &
  local b=$! i rc=0
  BGS+=("$b")
  for ((i = 0; i < 200; i++)); do
    [[ -e "$IWORK/b.in" ]] && break
    sleep 0.05
  done
  sleep 0.2
  kill -INT -- "-$b" # the terminal's SIGINT goes to the foreground process group
  wait "$b" || rc=$?
  [ "$rc" -eq 130 ]
  [ -d "/proc/$t" ] # the launch, and a with it, are untouched
  release a
}

@test "net modes: a join shares the keeper's network namespace in proxy and in strict" {
  local mode
  for mode in proxy strict; do
    if [[ "$mode" == strict ]] && ! { command -v pasta && { command -v nft || [ -x /usr/sbin/nft ]; }; } >/dev/null 2>&1; then
      continue
    fi
    rm -f "$IWORK"/*.in "$IWORK"/release.*
    bg_sandboxed "a$mode" AGENT_SANDBOX_NET=$mode XDG_STATE_HOME="$IHOME/.local/state" -- --profile probe --exec sh -c "$(hold "a$mode")"
    local t
    t="$(keeper_payload)"
    run_sandboxed AGENT_SANDBOX_NET=$mode XDG_STATE_HOME="$IHOME/.local/state" -- \
      --profile probe --exec sh -c 'readlink /proc/self/ns/net >net.b; printf "%s" "$HTTPS_PROXY" >proxy.b'
    [ "$status" -eq 0 ]
    [ "$(readlink "/proc/$t/ns/net")" = "$(cat "$IWORK/net.b")" ]
    [[ "$(cat "$IWORK/proxy.b")" == http://*:8888 ]]
    release "a$mode"
    wait "$BG_PID"
    wait_gone "$t"
  done
}

@test "a write inside lands in the layer, never in the source" {
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --profile probe --exec sh -c 'echo MINE >"$HOME/.probe/docs/a.md"'
  [ "$status" -eq 0 ]
  [ "$(cat "$IHOME/.probe/docs/a.md")" = YOURS ]
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --profile probe --exec sh -c 'cat "$HOME/.probe/docs/a.md" >seen'
  [ "$(cat "$IWORK/seen")" = MINE ]
}

@test "--reset refuses while something is joined, and afterwards the source comes back" {
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --profile probe --exec sh -c 'echo MINE >"$HOME/.probe/docs/a.md"'
  bg_sandboxed a "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --profile probe --exec sh -c "$(hold a)"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --reset docs probe
  [ "$status" -ne 0 ]
  [[ "$output" == *"is running"* ]]
  release a
  wait "$BG_PID"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --reset docs probe
  [ "$status" -eq 0 ]
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_CONNECT='docs=copy-on-write native' -- --profile probe --exec sh -c 'cat "$HOME/.probe/docs/a.md" >seen'
  [ "$(cat "$IWORK/seen")" = YOURS ]
}

@test "nothing of a launch outlives it: no keeper process, no record, no session directory" {
  run_sandboxed "${BASE[@]}" -- --profile probe --exec true
  [ "$status" -eq 0 ]
  [ ! -e "$SB/keeper" ]
  [ -z "$(ls -A "$I/base" 2>/dev/null)" ]
  local c a0
  for c in /proc/[0-9]*/cmdline; do
    a0="$(tr '\0' '\n' <"$c" 2>/dev/null | head -1)"
    [[ "$a0" == agent-sandbox-keeper ]] || continue
    # a keeper of this test would bind this test's HOME
    if grep -qF "$IHOME" "${c%/cmdline}/environ" 2>/dev/null; then
      echo "left behind: ${c%/cmdline}" >&2
      return 1
    fi
  done
}

@test "a daemon started inside holds the keeper after its join has ended, and --shutdown ends both" {
  # The probe profile's daemon is any process with `daemon run` in its argv. Started
  # detached, it is reparented to the sandbox's pid 1 and outlives the join.
  #
  # THE LAUNCH RUNS IN THE BACKGROUND, and the daemon is ended from outside. Under
  # coverage the engine returns only when its keeper's supervisor exits -- kcov waits for
  # every traced descendant -- which is when the daemon dies; a launch in the
  # foreground would wait out the daemon, and find the keeper gone when it came back.
  # So the 300 s here is an upper bound this test never reaches, traced or not.
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c 'setsid python3 -c "import time; time.sleep(300)" daemon run </dev/null >/dev/null 2>&1 & touch a.in'
  local t i
  for ((i = 0; i < 100; i++)); do
    t="$(keeper_payload 2>/dev/null)" && [ -n "$t" ] && break
    sleep 0.05
  done
  [ -n "$t" ]
  sleep 1.5 # the join is long gone; with no grace an unheld keeper would be too
  [ -d "/proc/$t" ]
  run_sandboxed "${BASE[@]}" -- --shutdown probe
  [ "$status" -eq 0 ]
  [[ "$output" == *"ended, with everything that ran in it"* ]]
  wait_gone "$t"
  wait "$BG_PID"
  [ ! -e "$SB/keeper" ]
}

@test "once the daemon exits, the keeper ends on its own" {
  # In the background for the same reason as above: traced, the launch returns only
  # once the daemon has gone.
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c 'setsid python3 -c "import time; time.sleep(2)" daemon run </dev/null >/dev/null 2>&1 & touch a.in'
  local t i
  for ((i = 0; i < 100; i++)); do
    t="$(keeper_payload 2>/dev/null)" && [ -n "$t" ] && break
    sleep 0.05
  done
  [ -n "$t" ]
  sleep 1
  [ -d "/proc/$t" ] # held
  wait_gone "$t"    # the daemon is gone after 2 s, and the supervisor notices within 5
  wait "$BG_PID"
}

@test "--shutdown ends what is joined too" {
  bg_sandboxed a "${BASE[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local t rc=0
  t="$(keeper_payload)"
  run_sandboxed "${BASE[@]}" -- --shutdown probe
  [ "$status" -eq 0 ]
  wait "$BG_PID" || rc=$?
  [ "$rc" -ne 0 ] # the held command did not finish on its own: it was ended
  wait_gone "$t"
}

@test "run-scoped copy-on-write: a write lasts the run, a join sees it, the next run starts from the source" {
  local cow=(AGENT_SANDBOX_CONNECT='docs=copy-on-write native run-scoped')
  bg_sandboxed a "${BASE[@]}" "${cow[@]}" -- --profile probe --exec sh -c "echo MINE >\"\$HOME/.probe/docs/a.md\"; $(hold a)"
  run_sandboxed "${BASE[@]}" "${cow[@]}" -- --profile probe --exec sh -c 'cat "$HOME/.probe/docs/a.md" >seen.b'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/seen.b")" = MINE ]            # one run is one installation
  [ "$(cat "$IHOME/.probe/docs/a.md")" = YOURS ] # the source never saw it
  release a
  wait "$BG_PID"
  [ ! -e "$SB/@run" ] # gone with the run, overlay layers and all
  run_sandboxed "${BASE[@]}" "${cow[@]}" -- --profile probe --exec sh -c 'cat "$HOME/.probe/docs/a.md" >seen.c'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/seen.c")" = YOURS ] # the next run reads the source again
}

@test "join-scoped: two joins into one running role each have a scratch of their own (#147)" {
  mkdir -p "$IWORK/scratch"
  local js=(AGENT_SANDBOX_CONNECT='./scratch/=own join-scoped')
  bg_sandboxed a "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c "echo from-a >scratch/a; ls scratch >a.sees; $(hold a)"
  local t
  t="$(keeper_payload)"
  run_sandboxed "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c 'echo from-b >scratch/b; ls scratch >b.sees; ls -R /run/agent-sandbox-stage /proc/2/root/run/agent-sandbox-stage >b.stage 2>&1'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/a.sees")" = a ] # each sees its own, and only its own
  [ "$(cat "$IWORK/b.sees")" = b ]
  # B cannot reach A's store, not even through the keeper's view: both staging listings
  # hold nothing but their own headers
  [ "$(grep -c ':$' "$IWORK/b.stage")" -eq 2 ]
  run ! grep -q -v -e ':$' -e '^$' "$IWORK/b.stage"
  [ -z "$(ls -A "$IWORK/scratch")" ]              # the project's own directory is untouched
  [ -z "$(ls -A "/proc/$t/root$IWORK/scratch")" ] # and the keeper sees an empty mount point
  compgen -G "$SB/@join/j*/*scratch" >/dev/null   # A's store is out of staging, under @join
  [ -z "$(ls -A "$SB/@join-stage")" ]
  release a
  wait "$BG_PID"
  [ ! -e "$SB/@join" ] # gone with the join, and with the launch
}

@test "copy join-scoped: two joins each start from the source, write their own, and the source is untouched (#153)" {
  mkdir -p "$IWORK/data"
  printf 'SRC\n' >"$IWORK/data/f"
  local js=(AGENT_SANDBOX_CONNECT='./data/=copy join-scoped')
  bg_sandboxed a "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c "cat data/f >a.saw; echo from-a >data/f; $(hold a)"
  run_sandboxed "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c 'cat data/f >b.saw; echo from-b >data/f; cat data/f >b.after'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/a.saw")" = SRC ] # both seeded from the source,
  [ "$(cat "$IWORK/b.saw")" = SRC ] # B not seeing A's write
  [ "$(cat "$IWORK/b.after")" = from-b ]
  [ "$(cat "$IWORK/data/f")" = SRC ] # and the source never written
  release a
  wait "$BG_PID"
  [ ! -e "$SB/@join" ]
}

@test "join-scoped: the store of a join killed with -9 goes at the supervisor's next sweep" {
  mkdir -p "$IWORK/scratch"
  local js=(AGENT_SANDBOX_CONNECT='./scratch/=own join-scoped')
  bg_sandboxed a "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c "$(hold a)"
  local first=$BG_PID
  local before f
  before="$(printf '%s\n' "$SB"/keeper/joined/*)"
  bg_sandboxed b "${BASE[@]}" "${js[@]}" -- --profile probe --exec sh -c "echo x >scratch/x; $(hold b)"
  [ "$(compgen -G "$SB/@join/j*" | wc -l)" -eq 2 ]
  # b's join record names the engine process that holds the join (the launcher's own
  # shell is its parent): kill that one, so no exit step of it runs
  local rec=""
  for f in "$SB"/keeper/joined/*; do
    [[ $'\n'"$before"$'\n' == *$'\n'"$f"$'\n'* ]] || rec="${f##*/}"
  done
  [ -n "$rec" ]
  kill -KILL "$rec"
  local i n=2
  for ((i = 0; i < 160; i++)); do # the sweep runs at least every five seconds
    n="$(compgen -G "$SB/@join/j*" | wc -l)"
    ((n == 1)) && break
    sleep 0.05
  done
  [ "$n" -eq 1 ] # b's store is gone, a's is still there
  release a
  wait "$first"
}
