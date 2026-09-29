#!/usr/bin/env bats
# The keeper (#121, #129 step 9): one launch per role, and every app joins it. The stub
# bwrap plays the launch (it runs the keeper's payload on the host) and the stub join
# records what it was asked to run; tests/integration/keeper.bats does the same under
# the real bwrap and join.
#
# What is pinned here is the engine's side of the decisions of 2026-09-28 (#121):
#   - a join may REPEAT the running policy, not change it: only the knobs this
#     invocation set are compared; a bare join always joins
#   - a changed dot-file warns and joins
#   - a join's environment is the keeper's, except the terminal's variables
#   - per-launch state (the session directory, its briefing) is per keeper

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  SBOX="$H/home/.local/state/agent-sandbox/claude/${PROJ//[^A-Za-z0-9-]/-}/default"
  CFG="$H/home/.config/agent-sandbox"
  BIN="$H/home/.local/share/claude/versions/2.1.300/claude"
}

teardown() {
  rm -f "$H/hold" 2>/dev/null
  [[ -n "${BG_PID:-}" ]] && wait "$BG_PID" 2>/dev/null
  return 0
}

trust() {
  mkdir -p "$CFG/trust"
  sha256sum -- "$PROJ/.agent-sandbox" | cut -d' ' -f1 \
    >"$CFG/trust/$(printf '%s' "$PROJ" | sha256sum | cut -d' ' -f1)"
}

@test "a launch is a keeper: bwrap runs the marked payload, and the agent is joined into it" {
  run_engine -- claude -p hi
  [ "$status" -eq 0 ]
  local i
  i="$(argv_index --)"
  [ "${ARGV[*]:i+1}" = "bash -c unset PWD OLDPWD; exec -a \"\$0\" sleep infinity agent-sandbox-keeper" ]
  [ "${JOINV[0]}" = "$BIN" ]
  join_has -p hi
}

@test "the join names the payload by its host pid, applies no filter it was not given, and drops SHLVL" {
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  local pid
  pid="$(grep -B1 -m1 '^--$' "$H/join" | head -1)"
  [[ "$pid" =~ ^[0-9]+$ ]]
  run ! grep -qx -- --seccomp "$H/join" # the harness has no compiled filter
  grep -qx -- 'SHLVL' "$H/join"
}

@test "with a filter compiled, the join is given the same file bwrap is" {
  mkdir -p "$H/sc"
  printf '\0\0\0\0\0\0\0\0' >"$H/sc/$(uname -m).bpf"
  run_engine AGENT_SANDBOX_SECCOMP_DIR="$H/sc" -- claude --version
  [ "$status" -eq 0 ]
  argv_has --seccomp 10
  grep -A1 -x -- --seccomp "$H/join" | tail -1 | grep -qx "$H/sc/$(uname -m).bpf"
}

@test "the terminal's variables are the join's own: set where they are set, unset where not" {
  run_engine TERM=vt100 LC_ALL=C.UTF-8 -- claude --version
  [ "$status" -eq 0 ]
  grep -qx 'TERM=vt100' "$H/join"
  grep -qx 'LC_ALL=C.UTF-8' "$H/join"
  grep -qx 'LANG=C.UTF-8' "$H/join" # the harness sets LANG
  grep -A1 -x -- --unset "$H/join" | grep -qx COLORTERM
  # nothing else is passed in: everything else is the keeper's
  run ! grep -q '^HOME=' "$H/join"
  run ! grep -q '^PATH=' "$H/join"
}

@test "a second invocation joins the running keeper and builds nothing" {
  engine_bg -- claude --version
  run_engine -- claude -p again
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ]
  join_has "$BIN" -p again
  release_bg
  [ "$BG_STATUS" -eq 0 ]
}

@test "a bare join always joins, whatever the keeper was started with" {
  engine_bg -- claude --preset isolated --connect 'skills=read-only native' --allow pypi.org --version
  # TEST_PRESET empty: the harness otherwise sets AGENT_SANDBOX_PRESET, which is a knob set
  TEST_PRESET="" run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/join" ]
  release_bg
}

@test "a join that repeats the keeper's knobs joins" {
  engine_bg AGENT_SANDBOX_NET=none -- claude --preset isolated --connect 'skills=read-only native' --allow pypi.org --version
  run_engine AGENT_SANDBOX_NET=none -- claude --preset isolated --connect 'skills=read-only native' --allow pypi.org --version
  [ "$status" -eq 0 ]
  [ -s "$H/join" ]
  release_bg
}

@test "a join that changes a knob is refused, naming it, and joins nothing" {
  engine_bg -- claude --preset isolated --version
  local spec
  for spec in "--preset inherit" "--connect skills=own" "--overlay off"; do
    # shellcheck disable=SC2086 # the spec is flag and value
    run_engine -- claude $spec --version
    [ "$status" -eq 2 ]
    [[ "$output" == *"role 'default' is running"*"cannot change"* ]]
    [ ! -s "$H/join" ]
  done
  TEST_PRESET="" run_engine AGENT_SANDBOX_NET=none -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"net = proxy"*"AGENT_SANDBOX_NET asks for 'none'"* ]]
  TEST_PRESET="" run_engine AGENT_SANDBOX_SECCOMP=off -- claude --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"seccomp = on"* ]]
  release_bg
}

@test "an IDLE keeper whose policy differs is replaced, not refused: nothing is joined to keep it for" {
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 -- claude --preset isolated --version
  release_bg
  local spid
  read -r spid _ <"$SBOX/keeper/id" # still there, in its grace
  run_engine -- claude --preset inherit --version
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # a launch of its own
  [[ "$output" != *"cannot change"* ]]
  [ ! -d "/proc/$spid" ] # the idle one was ended
}

@test "an IDLE keeper started under a different dot-file is replaced too, without a warning" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 -- claude --version
  release_bg
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ]
  [[ "$output" != *"has changed"* ]]
}

@test "an IDLE keeper with the same policy is joined within its grace" {
  engine_bg AGENT_SANDBOX_KEEPER_GRACE=30 -- claude --version
  release_bg
  local spid
  read -r spid _ <"$SBOX/keeper/id"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [ ! -s "$H/argv" ] # joined, nothing built
  # End it as a reset would, rather than leave it waiting out its grace. (Killing the
  # supervisor would orphan the stub's payload: only the real bwrap dies with it.)
  : >"$SBOX/keeper/stop"
  kill -USR1 "$spid"
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -d "/proc/$spid" ]] || break
    sleep 0.05
  done
  [ ! -d "/proc/$spid" ]
}

@test "a listed grant the keeper does not have is refused; one it has joins" {
  engine_bg -- claude --allow pypi.org --allow .example.org --version
  run_engine -- claude --allow pypi.org --version
  [ "$status" -eq 0 ]
  run_engine -- claude --allow evil.example --version
  [ "$status" -eq 2 ]
  [[ "$output" == *"--allow evil.example is not part of its policy (allow: "*"pypi.org"* ]]
  release_bg
}

@test "the policy a join is checked against is the keeper's own record of it" {
  engine_bg -- claude --preset isolated --version
  grep -qx $'preset\tisolated\t--preset' "$SBOX/keeper/policy"
  grep -q $'^connect:skills\town\t' "$SBOX/keeper/policy"
  grep -qx -- '-' "$SBOX/keeper/dotfile" # no approved dot-file
  release_bg
  [ ! -e "$SBOX/keeper" ] # and it is gone with the keeper
}

@test "a changed dot-file warns and joins; the running keeper's policy stands" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- claude --version
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox"
  trust
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" == *".agent-sandbox has changed since this role's keeper started"* ]]
  [ -s "$H/join" ]
  release_bg
}

@test "a join named by --role reads the keeper's copy of the dot-file: an unapproved edit does not refuse it" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  cp "$PROJ/.agent-sandbox" "$H/approved"
  engine_bg -- claude --role r --version
  local rsb="${SBOX%/default}/r"
  cmp "$rsb/keeper/dotfile.copy" "$H/approved"
  printf '[connect]\nskills = own native\n[net]\nmode = none\n' >"$PROJ/.agent-sandbox" # not approved
  TEST_PRESET="" run_engine -- claude --role r --version
  [ "$status" -eq 0 ]
  [[ "$output" == *".agent-sandbox has changed since this role's keeper started"* ]]
  [[ "$output" != *"Refusing to launch"* ]]
  [ -s "$H/join" ]
  release_bg
}

@test "without --role, an unapproved edit still refuses a join: the role would come from that file" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- claude --version
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox"
  run_engine -- claude --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed since you approved it"* ]]
  [ ! -s "$H/join" ]
  release_bg
}

@test "once the keeper has ended, the unapproved edit refuses a launch named by --role too" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- claude --role r --version
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox"
  release_bg
  run_engine -- claude --role r --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed since you approved it"* ]]
  [ ! -s "$H/argv" ]
}

@test "a keeper started with no approved dot-file keeps no copy, and its joins read none" {
  engine_bg -- claude --role r --version
  [ ! -e "${SBOX%/default}/r/keeper/dotfile.copy" ]
  printf '[connect]\nskills = own native\n' >"$PROJ/.agent-sandbox" # present, never approved
  run_engine -- claude --role r --version
  [ "$status" -eq 0 ]
  [ -s "$H/join" ]
  release_bg
}

@test "an unchanged dot-file says nothing" {
  printf '[connect]\nskills = read-only native\n' >"$PROJ/.agent-sandbox"
  trust
  engine_bg -- claude --version
  run_engine -- claude --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"has changed"* ]]
  release_bg
}

@test "a join's own --settings get their own file beside the keeper's briefing, removed afterwards" {
  engine_bg -- claude --version
  local sess
  sess="$(cat "$SBOX/keeper/session")"
  [ -d "$sess/briefing" ]
  # A join stub that snapshots its own settings file while joined.
  cat >"$H/bin/join-stub.py" <<'STUB'
import glob, os, shutil, sys
with open(os.environ["JOIN_DUMP"], "w") as fh:
    for a in sys.argv[1:]:
        fh.write(a + "\n")
for f in glob.glob(os.environ["SESS"] + "/briefing/join.*/settings.json"):
    shutil.copy(f, os.environ["SNAP"])
STUB
  run_engine SESS="$sess" SNAP="$H/snap.json" -- claude --settings '{"x":1}' --version
  [ "$status" -eq 0 ]
  [[ "${JOINV[-1]}" == /run/agent-sandbox/join.*/settings.json ]]
  grep -q '"x": 1' "$H/snap.json"
  grep -q 'hook-SessionStart.json' "$H/snap.json"
  [ -z "$(find "$sess/briefing" -name 'join.*')" ]
  release_bg
}

@test "different roles are different keepers" {
  engine_bg -- claude --role one --version
  run_engine -- claude --role two --preset isolated --version
  [ "$status" -eq 0 ]
  [ -s "$H/argv" ] # a launch of its own, not a join refused for its preset
  release_bg
}

@test "the session directory is the keeper's: its owner is the supervisor, not the engine that made it" {
  engine_bg -- claude --version
  local sess pid spid
  sess="$(cat "$SBOX/keeper/session")"
  read -r pid _ <"$sess/owner.id"
  read -r spid _ <"$SBOX/keeper/id"
  [ "$pid" = "$spid" ]
  release_bg
  [ ! -e "$sess" ] # cleaned up when the keeper ended
}

@test "a launch that cannot start reports the launch's own status and leaves no record" {
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
  run_engine -- claude --version
  [ "$status" -eq 3 ]
  [[ "$output" == *"the sandbox did not start (exit 3)"* ]]
  [ ! -e "$SBOX/keeper" ]
  [[ "$output" != *"without the sandbox"* ]] # 3 is not bwrap missing
}

@test "the keeper lock is not left held: a second launch after a failed one starts" {
  cp "$H/bin/bwrap" "$H/bwrap.working"
  cat >"$H/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
  run_engine -- claude --version
  [ "$status" -eq 3 ]
  cp "$H/bwrap.working" "$H/bin/bwrap"
  run_engine -- claude --version
  [ "$status" -eq 0 ]
}
