#!/usr/bin/env bats
# seed-only under the REAL bwrap. The unit suite pins the argv and the host-side store;
# only a real mount shows what the sandbox reads, and only bwrap creates the mount point
# on the host that the engine must clean up again.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say notes "$(cat "$HOME/.probe/NOTES.md" 2>/dev/null)"
say doc "$(cat "$HOME/.probe/docs/a.md" 2>/dev/null)"
[[ -n "${PROBE_WRITE:-}" ]] && printf '%s\n' "$PROBE_WRITE" >"$HOME/.probe/docs/a.md" && say wrote yes
say finished yes
PROBE
  ENV=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state" AGENT_SANDBOX_FORWARD="PROBE_WRITE"
    AGENT_SANDBOX_CONNECT='docs=seed-only native')
}

@test "seed-only: the sandbox reads the seed, keeps its own writes, and the source never changes" {
  printf 'SEED\n' >"$IHOME/.probe/docs/a.md"
  run_sandboxed "${ENV[@]}" PROBE_WRITE=SANDBOX -- probe run
  [ "$status" -eq 0 ]
  [ "$(report finished)" = yes ]
  [ "$(report doc)" = SEED ]
  [ "$(report wrote)" = yes ]
  [ "$(cat "$IHOME/.probe/docs/a.md")" = SEED ] # the source is untouched
  printf 'LATER\n' >"$IHOME/.probe/docs/a.md"   # and a later source change never arrives
  run_sandboxed "${ENV[@]}" -- probe run
  [ "$(report doc)" = SANDBOX ]
}

@test "seed-only over a file the source does not have leaves no mount point on the host" {
  rm -f "$IHOME/.probe/NOTES.md"
  run_sandboxed "${ENV[@]}" -- probe run
  [ "$status" -eq 0 ]
  [ "$(report finished)" = yes ]
  [ "$(report notes)" = "" ]
  [ ! -e "$IHOME/.probe/NOTES.md" ]
}
