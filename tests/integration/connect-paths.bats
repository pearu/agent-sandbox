#!/usr/bin/env bats
# Path declarations under the REAL bwrap. The unit suite pins the argv; this checks
# the argv means what it says once mounted: an `own` directory is the sandbox's and
# not the project's, it persists, and `read-only` cannot be written.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say scratch "$(cat scratch/f 2>/dev/null)"
say data "$(cat data/a 2>/dev/null)"
if [[ -n "${PROBE_WRITE:-}" ]]; then
  printf '%s\n' "$PROBE_WRITE" >scratch/f 2>/dev/null && say wrote_scratch yes
  printf 'x\n' >data/b 2>/dev/null && say wrote_data yes
fi
say finished yes
PROBE
  SB="$IHOME/.local/state/agent-sandbox/probe/$(printf '%s' "$(cd "$IWORK" && pwd -P)" | sed 's:[^A-Za-z0-9-]:-:g')/default"
  ENV=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state" AGENT_SANDBOX_FORWARD="PROBE_WRITE")
}

@test "own: the sandbox's directory, not the project's -- and it is there next launch" {
  mkdir -p "$IWORK/scratch"
  printf 'PROJECT\n' >"$IWORK/scratch/f"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=SANDBOX -- --connect './scratch/ = own' probe run
  [ "$status" -eq 0 ]
  [ "$(report finished)" = yes ]
  [ "$(report scratch)" = "" ] # the project's file is hidden
  [ "$(report wrote_scratch)" = yes ]
  [ "$(cat "$IWORK/scratch/f")" = PROJECT ] # and untouched
  local slug
  slug="$(cd "$IWORK" && pwd -P)/scratch"
  slug="${slug//\//_}"
  [ "$(cat "$SB/@paths/own/${slug#_}/f")" = SANDBOX ] # it went to the slot
  run_sandboxed "${ENV[@]}" -- --connect './scratch/ = own' probe run
  [ "$status" -eq 0 ]
  [ "$(report scratch)" = SANDBOX ] # the sandbox's own write persisted
}

@test "read-only: readable, and a write fails inside a project that is otherwise writable" {
  mkdir -p "$IWORK/data"
  printf 'DATA\n' >"$IWORK/data/a"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=x -- --connect './data = read-only' probe run
  [ "$status" -eq 0 ]
  [ "$(report data)" = DATA ]
  [ -z "$(report wrote_data)" ]
  [ ! -e "$IWORK/data/b" ]
  # the control: without the declaration, the same write lands
  run_sandboxed "${ENV[@]}" PROBE_WRITE=x -- probe run
  [ "$(report wrote_data)" = yes ]
}

@test "own with a trailing slash on a missing directory: the sandbox's, and an empty mount point outside" {
  run_sandboxed "${ENV[@]}" PROBE_WRITE=SANDBOX -- --connect './scratch/ = own' probe run
  [ "$status" -eq 0 ]
  [ "$(report wrote_scratch)" = yes ]
  # bwrap made the mount point on the host, and it is empty: the write went to the slot
  [ -d "$IWORK/scratch" ]
  [ -z "$(ls -A "$IWORK/scratch")" ]
}

@test "copy-on-write: the project's files read through, a write lands in the role's layer, the project is untouched" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11; this host: $(bwrap --version))"
  mkdir -p "$IWORK/data"
  printf 'DATA\n' >"$IWORK/data/a"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=x -- --connect './data/ = copy-on-write' probe run
  [ "$status" -eq 0 ]
  [ "$(report data)" = DATA ]      # read through from the project
  [ "$(report wrote_data)" = yes ] # writable inside
  [ ! -e "$IWORK/data/b" ]         # the write did not reach the project
  local slug
  slug="$(cd "$IWORK" && pwd -P)/data"
  slug="${slug//\//_}"
  [ -e "$SB/@paths/upper/${slug#_}/b" ] # it is in the role's upper layer
  printf 'LATER\n' >"$IWORK/data/a"     # a source edit reaches a file the sandbox has not written
  run_sandboxed "${ENV[@]}" -- --connect './data/ = copy-on-write' probe run
  [ "$(report data)" = LATER ]
  run_sandboxed "${ENV[@]}" -- --reset ./data/ probe
  [ "$status" -eq 0 ]
  [ ! -e "$SB/@paths/upper/${slug#_}" ] # and --reset takes the layer away
}

@test "project = read-only (#220): the tree cannot be written, a read-write path inside it can, and a missing own directory gets its mount point from the host" {
  mkdir -p "$IWORK/data"
  printf 'DATA\n' >"$IWORK/data/a"
  # The probe's report is in the project, which is read-only now: it goes to a file
  # outside, declared at the report's path -- a key the project does not have.
  : >"$I/rep"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=SANDBOX -- \
    --connect 'project = read-only' --connect "./report = read-write outside:$I/rep" \
    --connect './scratch/ = own' probe run
  [ "$status" -eq 0 ]
  grep -qx 'finished=yes' "$I/rep"
  grep -qx 'data=DATA' "$I/rep"
  run ! grep -q 'wrote_data' "$I/rep" # the read-only tree
  [ ! -e "$IWORK/data/b" ]
  grep -qx 'wrote_scratch=yes' "$I/rep" # own, inside the read-only tree
  [ -d "$IWORK/scratch" ]
  [ -z "$(ls -A "$IWORK/scratch")" ]
}

@test "project = copy-on-write: a role's writes stay in its layer, kept across its launches; the project and another role see none" {
  [[ "$(bwrap --help 2>&1)" == *"--overlay "* ]] || skip "this bubblewrap cannot mount an overlay"
  mkdir -p "$IWORK/data"
  printf 'DATA\n' >"$IWORK/data/a"
  : >"$I/rep"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=ROLE1 -- --role r1 \
    --connect 'project = copy-on-write' --connect "./report = read-write outside:$I/rep" probe run
  [ "$status" -eq 0 ]
  grep -qx 'data=DATA' "$I/rep"
  grep -qx 'wrote_data=yes' "$I/rep" # writable inside...
  [ ! -e "$IWORK/data/b" ]           # ...and the project untouched
  # the same role again: its layer is still there
  run_sandboxed "${ENV[@]}" -- --role r1 \
    --connect 'project = copy-on-write' --connect "./report = read-write outside:$I/rep" \
    --profile probe --exec bash -c 'cat data/b >/dev/null && echo seen >>report'
  grep -qx 'seen' "$I/rep"
  # another role: none of it
  : >"$I/rep"
  run_sandboxed "${ENV[@]}" -- --role r2 \
    --connect 'project = copy-on-write' --connect "./report = read-write outside:$I/rep" \
    --profile probe --exec bash -c 'test -e data/b && echo LEAK >>report; echo finished >>report'
  [ "$(cat "$I/rep")" = finished ]
}
