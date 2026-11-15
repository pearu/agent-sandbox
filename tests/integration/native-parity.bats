#!/usr/bin/env bats
# `--preset native` against `--preset none`: the differential test.
#
# THIS IS THE ORACLE, not another feature test. Every other suite asserts what
# the sandbox SHOULD do; this one asserts that when it is told to isolate
# nothing, it distorts nothing -- run the same agent both ways and the two must
# agree. A difference here is a bug in agent-sandbox by definition, because the
# preset's whole claim is that there is nothing left to differ.
#
# It has already earned its keep. Written after `native` was implemented and
# believed finished, it found three divergences the by-hand check had not:
#   - --clearenv dropped every variable outside the allowlist, so an agent that
#     reads one of its own knobs behaved differently inside and said nothing;
#   - $HOME was still a tmpfs, so ~/.gitconfig, ~/.npmrc, ~/.ssh/config and
#     anything else no channel declares simply did not exist;
#   - /tmp and /var/tmp were private, so work left there was invisible.
# Each is the kind of thing that surfaces as "the agent behaves oddly in the
# sandbox" months later, with nothing to point at.
#
# The comparison is the WHOLE report, sorted, not a list of fields. A parity
# test that checks named properties only ever finds the differences someone
# already thought of.

# shellcheck disable=SC2016 # the --exec scripts expand inside the sandbox, not here

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
# Everything a sandbox could plausibly distort, in one report.
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
say cwd "$PWD"
say cwd-writable "$(touch "$PWD/.w" 2>/dev/null && echo yes || echo no)"; rm -f "$PWD/.w"
say home "$HOME"
say id "$(id -u):$(id -g):$(id -un)"
# the profile's declared channels, at `live` under both
say docs-a "$(cat "$HOME/.probe/docs/a.md" 2>&1)"
say notes "$(cat "$HOME/.probe/NOTES.md" 2>&1)"
say extra-e "$(cat "$HOME/.probe/extra/e.md" 2>&1)"
# and everything in $HOME that no channel declares
say home-entries "$(ls -A "$HOME" 2>&1 | grep -v '^\.cache$' | sort | tr '\n' ' ')"
say undeclared "$(cat "$HOME/.rc-ish" 2>&1)"
say undeclared-dir "$(cat "$HOME/tools/t.txt" 2>&1)"
say home-writable "$(touch "$HOME/.w" 2>/dev/null && echo yes || echo no)"; rm -f "$HOME/.w"
# the host's temp directories
say tmp-marker "$(cat "$TMP_MARKER" 2>&1)"
say tmp-writable "$(touch "$TMP_MARKER.w" 2>/dev/null && echo yes || echo no)"; rm -f "$TMP_MARKER.w"
# a write reaching the real file, which is what `live` means
printf 'WROTE\n' >"$HOME/.probe/docs/w.md" 2>/dev/null; say write-docs "$?"
# the environment the agent is handed. AGENT_SANDBOX is the marker saying a
# sandbox is present, which is TRUE under native and false under --preset
# none, so it is the one name excluded rather than asserted.
say env "$(env | sed 's/=.*//' | grep -vE '^(_|AGENT_SANDBOX)$' | sort | tr '\n' ' ')"
say path "$PATH"
PROBE
  printf 'YOURS\n' >"$IHOME/.probe/docs/a.md"
  printf 'NOTES\n' >"$IHOME/.probe/NOTES.md"
  printf 'EXTRA\n' >"$IHOME/.probe/extra/e.md"
  # Things in $HOME that NO channel declares -- the class the tmpfs hid.
  printf 'rc\n' >"$IHOME/.rc-ish"
  mkdir -p "$IHOME/tools" && printf 'tool\n' >"$IHOME/tools/t.txt"
  TMP_MARKER="$(mktemp "/tmp/as-native-parity.XXXXXX")"
  printf 'HOSTTMP\n' >"$TMP_MARKER"
  # A variable outside every allowlist: an agent's own knob, in other words.
  PAR=(AGENT_SANDBOX_NET=none AGENT_SANDBOX_SECCOMP=off
    TMP_MARKER="$TMP_MARKER" SOME_AGENT_KNOB=hello)
}

teardown() {
  [[ -n "${TMP_MARKER:-}" ]] && rm -f "$TMP_MARKER"
  return 0
}

# Run the probe one way and keep the report under its own name.
capture() { # capture NAME engine-args...
  local name="$1"
  shift
  rm -f "$IHOME/.probe/docs/w.md" # each run must start from the same source
  run_sandboxed "${PAR[@]}" -- "$@" probe run
  [ "$status" -eq 0 ] || {
    echo "$name launch failed ($status): $output"
    return 1
  }
  sort "$IWORK/report" >"$IWORK/$name"
}

@test "THE ORACLE: --preset native and --preset none agree on everything" {
  capture native --preset native
  capture none --preset none
  # diff, not [ = ], so a failure names the fields rather than dumping both.
  run diff -u "$IWORK/native" "$IWORK/none"
  [ "$status" -eq 0 ]
}

@test "and the comparison is worth something: the DEFAULT preset does differ" {
  # A parity test that passes because both sides are broken the same way, or
  # because the probe reads nothing that a sandbox touches, is worse than none.
  # The default preset isolates, so it MUST fail the same comparison -- if it
  # ever agrees, this file has stopped measuring anything.
  capture none --preset none
  TEST_PRESET="" capture isolated --preset inherit
  run diff -q "$IWORK/isolated" "$IWORK/none"
  [ "$status" -ne 0 ]
}

@test "native is refused from the environment, so only a flag can turn it on" {
  # The parity above is exactly what makes native dangerous to reach by accident:
  # it is state isolation off. Belongs here, next to what it protects.
  TEST_PRESET=native run_sandboxed "${PAR[@]}" -- probe run
  [ "$status" -ne 0 ]
  [[ "$output" == *"only accepted as the --preset flag"* ]]
}

@test "the oracle holds with copy and seed-only declared: under native they bind what --preset none shows" {
  capture native --preset native --connect 'docs = copy' --connect 'extra = seed-only'
  capture none --preset none
  run diff -u "$IWORK/native" "$IWORK/none"
  [ "$status" -eq 0 ]
}

@test "copy and seed-only under native, channel and path declaration, first launch and next: the role sees the source" {
  mkdir -p "$IWORK/d" "$IWORK/e"
  printf 'HOST\n' >"$IWORK/d/f"
  printf 'HOST\n' >"$IWORK/e/f"
  local i
  for i in 1 2; do
    rm -f "$IWORK/view"
    run_sandboxed "${PAR[@]}" -- --preset native --connect 'docs = copy' --connect 'extra = seed-only' \
      --connect './d/ = copy' --connect './e/ = seed-only' --profile probe --exec bash -c '
      echo "v=$(cat "$HOME/.probe/docs/a.md") $(cat "$HOME/.probe/extra/e.md") $(cat d/f) $(cat e/f)" >view'
    [ "$status" -eq 0 ]
    [ "$(cat "$IWORK/view")" = "v=YOURS EXTRA HOST HOST" ] || {
      echo "launch $i: $(cat "$IWORK/view")" >&2
      return 1
    }
  done
}

@test "copy-on-write under native, channel, directory and file (the copy fallback) declarations: the role sees the source" {
  mkdir -p "$IWORK/c"
  printf 'HOST\n' >"$IWORK/c/f"
  printf 'ONE\n' >"$IWORK/one.md"
  run_sandboxed "${PAR[@]}" -- --preset native --connect 'docs = copy-on-write' --connect './c/ = copy-on-write' \
    --connect './one.md = copy-on-write' --profile probe --exec bash -c '
    echo "v=$(cat "$HOME/.probe/docs/a.md") $(cat c/f) $(cat one.md)" >view'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/view")" = "v=YOURS HOST ONE" ]
}

@test "under native, copy reads its source as with no sandbox: a link inside it is copied as the content it names" {
  mkdir -p "$IWORK/src" "$IHOME/shared"
  printf 'SHARED\n' >"$IHOME/shared/f"
  ln -s "$IHOME/shared/f" "$IWORK/src/l"
  run_sandboxed "${PAR[@]}" -- --preset native --connect './src/ = copy' --profile probe --exec bash -c '
    echo "v=$([ -L src/l ] && echo link || echo file) $(cat src/l)" >view'
  [ "$status" -eq 0 ]
  [ "$(cat "$IWORK/view")" = "v=file SHARED" ]
}

@test "under native, a sandbox: source inside another role's store through that role's link launches, as with no sandbox" {
  mkdir -p "$IHOME/secret"
  printf 'S\n' >"$IHOME/secret/s"
  TEST_PRESET=isolated run_sandboxed "${PAR[@]}" -- --role b --profile probe --exec bash -c 'ln -s "$HOME/secret" "$HOME/.probe/docs/sub"'
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${PAR[@]}" -- --role a --preset native --connect '~/.probe/docs/sub/ = read-only sandbox:@b' --profile probe --exec true
  [ "$status" -eq 0 ]
  [[ "$output" != *"leaves the store"* ]]
}

@test "a read-only channel the profile creates, under native: missing, it is made as with no check, and bound" {
  printf '%s\n' 'profile_channel_create=(docs)' >>"$IPROFILES/probe/profile.sh"
  rm -rf "$IHOME/.probe/docs"
  run_sandboxed "${PAR[@]}" -- --preset native --connect 'docs = read-only' --profile probe --exec bash -c '
    echo "v=$([ -d "$HOME/.probe/docs" ] && echo dir)" >view'
  [ "$status" -eq 0 ]
  [ -d "$IHOME/.probe/docs" ]
  [ "$(cat "$IWORK/view")" = "v=dir" ]
}
