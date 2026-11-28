#!/usr/bin/env bats
# The restart marker (#416), end to end: a real tmux, the real bwrap, a role's policy
# changed and approved while it runs. `asb --roles a` opens the role's pane and the
# host side beside it; once .agent-sandbox gains a [connect] line and is approved, an
# empty .asb/coord/to/a.restart ends the role and relaunches it in its pane, resumed,
# and the relaunched launch sees the path the change declared. The unit suite
# (tests/unit/roles-tmux.bats) pins the steps with a stub tmux; this proves a respawn
# after the shutdown takes the new policy (a respawn alone joins the old keeper, 2026-10-30).
# Each launch of the probe appends a line to $IWORK/launches -- its arguments and
# whether the declared path is there -- then holds until released. Another session
# joined into the role's launch holds its keeper, as one of yours may: the restart's
# shutdown ends it too, where a respawn alone would join the keeper it holds.
# shellcheck disable=SC2016 # the probe's lines expand inside the sandbox, not here

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v tmux >/dev/null || skip "tmux not installed"
  command -v setsid >/dev/null || skip "setsid not installed"
  make_integration <<'PROBE'
#!/usr/bin/env bash
seen=no
# the login it runs on (#482): the base's, or an account's, bound where the base is
{ cat "$HOME/.probe-base/.login" 2>/dev/null || echo none; } >>logins
[[ -e "${SHARED:?}/flag" ]] && seen=yes
printf 'args=%s seen=%s\n' "$*" "$seen" >>launches
date +%s.%N >>started
until [ -e release ]; do sleep 0.1; done
PROBE
  # the probe's profile, saying how it resumes a session
  printf '\nprofile_resume=(--resumed)\n' >>"$IPROFILES/probe/profile.sh"
  SHARED="$I/shared"
  mkdir -p "$SHARED" "$IWORK/.asb/coord/to"
  : >"$SHARED/flag"
  # the probe reads SHARED from its environment: a launch passes [env] through
  WD="$(cd "$IWORK" && pwd -P)"
  REC="$IHOME/.config/agent-sandbox/trust/$(printf '%s' "$WD" | sha256sum | cut -d' ' -f1)"
  export TMUX_TMPDIR="$I/tmux"
  mkdir -p "$TMUX_TMPDIR"
}

teardown() {
  : >"$IWORK/release" 2>/dev/null
  TMUX_TMPDIR="$I/tmux" tmux kill-server 2>/dev/null
  local f spid
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# approve LINE... -- .agent-sandbox is these lines, approved as --trust records it (no
# purpose file: the digest is the file's own)
approve() {
  printf '%s\n' "$@" >"$IWORK/.agent-sandbox"
  mkdir -p "${REC%/*}"
  sha256sum "$IWORK/.agent-sandbox" | cut -d' ' -f1 >"$REC"
  cp "$IWORK/.agent-sandbox" "$REC.approved"
}

# asb ARGS... -- the engine, from the project, with the harness's clean environment (and
# the tmux socket's directory, which the panes' launches inherit from the tmux server).
# A keeper's grace of 10 s: a launch that ends leaves its keeper running a while, as the
# default 2 s does, so a respawn alone would join it under the old policy, and only the
# restart's shutdown ends it.
asb() {
  engine_cmd
  (cd "$IWORK" && env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" \
    AGENT_SANDBOX_KEEPER_GRACE=10 AGENT_SANDBOX_PRESET=shared TMUX_TMPDIR="$TMUX_TMPDIR" \
    SHARED="$SHARED" SHELL=/bin/sh "${ENGINE_CMD[@]}" "$@") </dev/null 3>&-
}

# lines N -- wait (up to 30 s) until the probe has run N times
lines() {
  local i
  for ((i = 0; i < 300; i++)); do
    [[ -e "$IWORK/launches" ]] && (($(wc -l <"$IWORK/launches") >= $1)) && return 0
    sleep 0.1
  done
  echo "the probe ran $(wc -l <"$IWORK/launches" 2>/dev/null || echo 0) times, not $1" >&2
  return 1
}

@test "a restart marker relaunches a role of asb --roles under the policy approved since it started, resumed, and goes (#416)" {
  # kcov reads its trace pipe until every process holding it has ended, and the tmux server
  # and the __roles-resets watcher that `asb --roles` leaves running hold it: under kcov
  # `asb --roles` returns only once they end, which this test waits for it to do first
  [[ -z "${AGENT_SANDBOX_KCOV:-}" ]] || skip "under kcov, asb --roles returns only once the tmux server and the watcher it starts have ended: they hold kcov's trace pipe (#469)"
  approve '[agent]' 'command = probe' '[env]' 'SHARED'
  run asb --roles a
  [ "$status" -eq 0 ]
  [[ "$output" == *"the host takes restarts"* ]]
  lines 1
  [ "$(sed -n 1p "$IWORK/launches")" = "args= seen=no" ]
  # another session joined into the role's launch, as a terminal of yours may be: a
  # respawn alone would join the keeper it holds, under the old policy
  asb --role a --profile probe --exec sh -c 'touch other.in; until [ -e release ]; do sleep 0.1; done' \
    >"$I/other.out" 2>&1 &
  local other=$! i
  for ((i = 0; i < 300; i++)); do
    [[ -e "$IWORK/other.in" ]] && break
    sleep 0.1
  done
  [ -e "$IWORK/other.in" ]
  # the change, approved: the shared directory, read-only
  approve '[agent]' 'command = probe' '[env]' 'SHARED' '[connect]' "$SHARED/ = read-only"
  local t0 t1
  t0=$EPOCHREALTIME
  : >"$IWORK/.asb/coord/to/a.restart"
  for ((i = 0; i < 600; i++)); do
    [[ -e "$IWORK/.asb/coord/to/a.restart" ]] || break
    sleep 0.1
  done
  t1=$EPOCHREALTIME
  [ ! -e "$IWORK/.asb/coord/to/a.restart" ] || {
    echo "marker: $(cat "$IWORK/.asb/coord/to/a.restart")" >&2
    return 1
  }
  echo "# restart: $(echo "$t1 - $t0" | bc) s from marker to gone" >&3
  lines 2
  [ "$(sed -n 2p "$IWORK/launches")" = "args=--resumed seen=yes" ]
  # when the relaunched agent started, from the marker's going: a reset taken at the
  # watcher's next look (a second after) types into an agent that has started by then
  echo "# relaunch: the agent started $(echo "$(sed -n 2p "$IWORK/started") - $t1" | bc) s after the marker went" >&3
  # the shutdown ended everything joined, the other session too
  for ((i = 0; i < 100; i++)); do
    kill -0 "$other" 2>/dev/null || break
    sleep 0.1
  done
  run kill -0 "$other"
  [ "$status" -ne 0 ]
}

@test "a restart marker account=NAME moves a role of asb --roles to the account NAME that [agent] accounts lists: relaunched in its pane, resumed, its account's directory where the base is; a later empty marker keeps it there (#482)" {
  [[ -z "${AGENT_SANDBOX_KCOV:-}" ]] || skip "under kcov, asb --roles returns only once the tmux server and the watcher it starts have ended: they hold kcov's trace pipe (#469)"
  # the probe's accounts: ~/.probe-base is its base, .login its login
  printf '[agent]\nbase = ~/.probe-base\naccount-paths = .login\n' >>"$IPROFILES/probe/agent-sandbox"
  local acct="$IHOME/.local/state/agent-sandbox/probe/accounts/work" i
  mkdir -p "$IHOME/.probe-base" "$acct"
  echo base >"$IHOME/.probe-base/.login"
  echo work >"$acct/.login"
  approve '[agent]' 'command = probe' 'accounts = work' '[env]' 'SHARED'
  run asb --roles a
  [ "$status" -eq 0 ]
  lines 1
  [ "$(sed -n 1p "$IWORK/logins")" = base ]
  printf 'account=%s\n' work >"$IWORK/.asb/coord/to/a.restart.new"
  mv -T "$IWORK/.asb/coord/to/a.restart.new" "$IWORK/.asb/coord/to/a.restart"
  for ((i = 0; i < 600; i++)); do
    [[ -e "$IWORK/.asb/coord/to/a.restart" ]] || break
    sleep 0.1
  done
  [ ! -e "$IWORK/.asb/coord/to/a.restart" ] || {
    echo "marker: $(cat "$IWORK/.asb/coord/to/a.restart")" >&2
    return 1
  }
  lines 2
  [ "$(sed -n 2p "$IWORK/launches")" = "args=--resumed seen=no" ]
  [ "$(sed -n 2p "$IWORK/logins")" = work ]
  local log
  log="$IHOME/.local/state/agent-sandbox/.roles-resets/$(state_slug "$WD").log"
  grep -qF "role 'a': a restart marker -- ended it, relaunched it in pane " "$log"
  grep -qF " on the account 'work', its keeper is live, and removed the marker" "$log"
  # an empty marker: still on work
  : >"$IWORK/.asb/coord/to/a.restart"
  for ((i = 0; i < 600; i++)); do
    [[ -e "$IWORK/.asb/coord/to/a.restart" ]] || break
    sleep 0.1
  done
  [ ! -e "$IWORK/.asb/coord/to/a.restart" ]
  lines 3
  [ "$(sed -n 3p "$IWORK/logins")" = work ]
  [ "$(grep -c " on the account 'work', its keeper is live" "$log")" -eq 2 ]
}
