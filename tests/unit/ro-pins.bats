#!/usr/bin/env bats
# The read-only binds' parents, pinned (_as_ro_pins): every directory between a
# read-write root and a read-only bind is bound onto itself, so the role cannot rename or
# remove it and move the read-only path away. The computation on fixed option lists (the
# cases of the measured prototype, readonly-spike's probes/readonly-pin-bwrap.py, and
# more), then the engine's launches: unchanged where nothing is pinned, and the shipped
# models' roles. The real mounts are tests/integration/ro-pins.bats'.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  P="$BATS_TEST_TMPDIR/p"
  ST="$BATS_TEST_TMPDIR/state"
  mkdir -p "$P/sub" "$P/.asb/roles" "$P/.asb/coord/me" "$P/a/b/c" "$P/a/r" "$P/a/s" "$ST/x/d"
  touch "$P/sub/f.md" "$P/.asb/roles/r.md" "$P/a/f.md" "$P/a/b/f.md" "$P/a/b/c/f.md" "$P/a/r/f.md" "$P/top.md" "$ST/f"
}

# pins [native] -- OPTS -- OUT and PIN from _as_ro_pins over the words after --, the engine
# sourced in a subshell; MSG its messages.
pins() {
  local preset=shared
  [[ "$1" == native ]] && preset=native && shift
  [[ "$1" == -- ]] && shift
  local -a _all=()
  mapfile -d '' _all < <(bash -c 'source "$1"; shift; _preset="$1"; shift; IN=("$@")
    _as_ro_pins IN OUT PIN 2>"$BATS_TEST_TMPDIR/msg"
    printf "%s\0" "${#OUT[@]}" "${OUT[@]}" ${PIN[@]+"${PIN[@]}"}' _ "$ENGINE" "$preset" "$@")
  local n="${_all[0]}"
  OUT=("${_all[@]:1:n}")
  PIN=("${_all[@]:n+1}")
  MSG="$(cat "$BATS_TEST_TMPDIR/msg")"
  IN=("$@")
}

# same LIST... -- OUT is exactly the words given.
same() {
  local want got
  want="$(printf '%s\0' "$@" | od -c)"
  got="$(printf '%s\0' "${OUT[@]}" | od -c)"
  [ "$got" = "$want" ] || {
    diff <(printf '%s\n' "$@") <(printf '%s\n' "${OUT[@]}") >&2
    return 1
  }
}

# ref_engine -- REF: a copy of the engine without the pin step, beside copies of what it
# reads next to itself.
ref_engine() {
  local d="$BATS_TEST_TMPDIR/ref"
  mkdir -p "$d"
  cp -r "$(dirname "$ENGINE")/profiles" "$(dirname "$ENGINE")/components" "$(dirname "$ENGINE")/models" "$d/"
  cp "$(dirname "$ENGINE")/VERSION" "$d/" 2>/dev/null || true
  sed 's/^  _as_ro_pins _bwrap_opts _pinned_opts _pinned$/  : no pins/' "$ENGINE" >"$d/agent-sandbox"
  chmod +x "$d/agent-sandbox"
  [ "$(grep -c '^  : no pins$' "$d/agent-sandbox")" -eq 1 ]
  REF="$d/agent-sandbox"
}

# both ARGS... -- launch ARGS with the engine and with REF; A and B the two argv, with the
# session directory's random name made one.
both() {
  run_engine AGENT_SANDBOX_NET=none -- asb "$@"
  [ "$status" -eq 0 ]
  A="$(printf '%s\n' "${ARGV[@]}" | sed 's|/session\.[^/]*|/session.X|g')"
  AOUT="$output"
  run_engine AGENT_SANDBOX_NET=none -- "$REF" "$@"
  [ "$status" -eq 0 ]
  B="$(printf '%s\n' "${ARGV[@]}" | sed 's|/session\.[^/]*|/session.X|g')"
}

# model NAME -- `asb --init NAME` in a fresh git project, approved as `--trust` records it.
model() {
  make_harness
  PROJ="$(cd "$H/proj" && pwd -P)"
  git -C "$PROJ" init -q
  git -C "$PROJ" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init
  engine_cmd
  run bash -c 'cd "$1" && env -i HOME="$2" PATH="$3" "${@:5}" --init "$4" 2>&1 </dev/null' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "$1" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" "${@:4}" --trust 2>&1' _ "$PROJ" "$H/home" "$H/bin:/usr/bin:/bin" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
}

# pinned ROLE [DIR...] -- ROLE's launch pins exactly DIRs (relative to the project).
pinned() {
  local role="$1" d want=""
  shift
  run_engine AGENT_SANDBOX_NET=none -- asb --role "$role" claude --version
  [ "$status" -eq 0 ]
  for d in "$@"; do
    argv_has --bind "$PROJ/$d" "$PROJ/$d"
    want+="${want:+, }./$d"
  done
  if (($#)); then
    printf '%s\n' "$output" | grep -qxF "agent-sandbox: read-only parents pinned (the role cannot rename or remove them): $want" \
      || {
        printf '%s\n' "$output" | grep -F 'pinned' >&2
        return 1
      }
  else
    [[ "$output" != *"read-only parents pinned"* ]]
    run ! argv_has --bind "$PROJ/.asb" "$PROJ/.asb"
  fi
}

@test "a file in a read-write project, one level down: its directory pinned, before it" {
  pins -- --bind "$P" "$P" --ro-bind "$P/sub/f.md" "$P/sub/f.md" -- cmd
  same --bind "$P" "$P" --bind "$P/sub" "$P/sub" --ro-bind "$P/sub/f.md" "$P/sub/f.md" -- cmd
  [ "${PIN[*]}" = "$P/sub" ]
}

@test "a read-only project root: nothing pinned, the list unchanged" {
  pins -- --ro-bind "$P" "$P" --ro-bind "$P/.asb/roles/r.md" "$P/.asb/roles/r.md"
  same "${IN[@]}"
  [ "${#PIN[@]}" -eq 0 ]
}

@test "a read-only directory with a read-write one inside, then a file: each parent pinned before what lies beneath it" {
  pins -- --bind "$P" "$P" --ro-bind "$P/.asb/coord" "$P/.asb/coord" --bind "$P/.asb/coord/me" "$P/.asb/coord/me" \
    --ro-bind "$P/.asb/roles/r.md" "$P/.asb/roles/r.md"
  same --bind "$P" "$P" --bind "$P/.asb" "$P/.asb" --ro-bind "$P/.asb/coord" "$P/.asb/coord" \
    --bind "$P/.asb/coord/me" "$P/.asb/coord/me" --bind "$P/.asb/roles" "$P/.asb/roles" \
    --ro-bind "$P/.asb/roles/r.md" "$P/.asb/roles/r.md"
  [ "${PIN[*]}" = "$P/.asb $P/.asb/roles" ]
}

@test "a read-write bind made read-only by a later --remount-ro is read-only: its parent pinned" {
  pins -- --bind "$P" "$P" --bind "$P/a/b" "$P/a/b" --remount-ro "$P/a/b"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --remount-ro "$P/a/b"
  [ "${PIN[*]}" = "$P/a" ]
}

@test "a --remount-ro before the bind does not make it read-only" {
  pins -- --bind "$P" "$P" --remount-ro "$P/a/b" --bind "$P/a/b" "$P/a/b"
  same "${IN[@]}"
}

@test "a copy-on-write project (an overlay) is not read-write from the host: nothing pinned" {
  pins -- --overlay-src "$P" --overlay /up /wk "$P" --ro-bind "$P/.asb/roles/r.md" "$P/.asb/roles/r.md"
  same "${IN[@]}"
  [ "${#PIN[@]}" -eq 0 ]
}

@test "a read-write directory from the role's store counts: the pin's source is under the store" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/.asb/s" --ro-bind "$ST/f" "$P/.asb/s/d/f"
  same --bind "$P" "$P" --bind "$ST/x" "$P/.asb/s" --bind "$ST/x/d" "$P/.asb/s/d" --ro-bind "$ST/f" "$P/.asb/s/d/f"
  [ "${PIN[*]}" = "$P/.asb/s/d" ]
}

@test "nested read-only binds: the parents of the outer one pinned, nothing inside the read-only mount" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b/c" "$P/a/b/c" --ro-bind "$P/a/b/c/f.md" "$P/a/b/c/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/c" "$P/a/b/c" \
    --ro-bind "$P/a/b/c/f.md" "$P/a/b/c/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "a read-only directory bind: the directories above it pinned, never the bind itself" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b" "$P/a/b"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --ro-bind "$P/a/b" "$P/a/b"
  [ "${PIN[*]}" = "$P/a" ]
}

@test "a directory that is already a mount point is not pinned again" {
  pins -- --bind "$P" "$P" --bind "$P/a" "$P/a" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "${PIN[*]}" = "$P/a/b" ]
}

@test "two read-only files sharing parents: each directory pinned once, before the first that needs it" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md" --ro-bind "$P/a/b/c/f.md" "$P/a/b/c/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md" \
    --bind "$P/a/b/c" "$P/a/b/c" --ro-bind "$P/a/b/c/f.md" "$P/a/b/c/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b $P/a/b/c" ]
}

@test "a pin goes before a bind beneath it made earlier than the read-only bind" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/a/s" --ro-bind "$P/a/r/f.md" "$P/a/r/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$ST/x" "$P/a/s" --bind "$P/a/r" "$P/a/r" \
    --ro-bind "$P/a/r/f.md" "$P/a/r/f.md"
}

@test "a read-only file directly in the read-write root: nothing pinned" {
  pins -- --bind "$P" "$P" --ro-bind "$P/top.md" "$P/top.md"
  same "${IN[@]}"
  [ "${#PIN[@]}" -eq 0 ]
}

@test "own and read-write binds get no pins for their own sake" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/a/b/c" --bind "$P/a/r" "$P/a/r" --tmpfs "$P/a/s"
  same "${IN[@]}"
}

@test "a -try bind whose source is missing makes no mount: no pins for it" {
  pins -- --bind "$P" "$P" --ro-bind-try "$P/a/b/gone.md" "$P/a/b/gone.md"
  same "${IN[@]}"
  pins -- --bind "$P" "$P" --ro-bind-try "$P/a/b/f.md" "$P/a/b/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "system binds with no read-write mount above them: nothing pinned" {
  pins -- --ro-bind /usr /usr --ro-bind-try /etc /etc --tmpfs "$P" --ro-bind "$ST/f" "$P/a/b/f"
  same "${IN[@]}"
}

@test "under --preset native nothing is pinned" {
  pins native -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  same "${IN[@]}"
  [ "${#PIN[@]}" -eq 0 ]
}

@test "a directory not there on the host is not pinned, and said: the launch does not fail on it" {
  pins -- --bind "$P" "$P" --ro-bind "$P/top.md" "$P/nodir/f.md"
  same "${IN[@]}"
  [[ "$MSG" == *"read-only pins: $P/nodir is not a directory on the host ($P/nodir), so it is not pinned: the role can rename it"* ]]
}

@test "a symbolic link in the chain is not pinned, and said; the real directories still are" {
  ln -s a "$P/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  same --bind "$P" "$P" --bind "$P/lnk/b" "$P/lnk/b" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  [[ "$MSG" == *"read-only pins: $P/lnk is a symbolic link on the host ($P/lnk), so it is not pinned"* ]]
}

@test "an option the computation does not know leaves the list unchanged, and is said" {
  pins -- --bind "$P" "$P" --new-option x --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  same "${IN[@]}"
  [[ "$MSG" == *"bwrap option '--new-option' unknown to the read-only pins: none made this launch"* ]]
}

@test "odd characters in a path: a space, a newline and a glob character pass through intact" {
  local d="$P/odd dir"$'\n'"[x]*"
  mkdir -p "$d/in"
  touch "$d/in/f"
  pins -- --bind "$P" "$P" --ro-bind "$d/in/f" "$d/in/f"
  same --bind "$P" "$P" --bind "$d" "$d" --bind "$d/in" "$d/in" --ro-bind "$d/in/f" "$d/in/f"
}

# ---- the engine's launches (stub bwrap) ----

@test "where nothing is pinned the bwrap arguments are byte-identical to the engine's without the step" {
  make_harness
  ref_engine
  mkdir -p "$H/proj/a/b" "$H/proj/d"
  touch "$H/proj/a/b/f.md" "$H/proj/top.md"
  both claude --version # a plain launch: the project read-write, nothing read-only in it
  [ -n "$A" ]
  [ "$A" = "$B" ]
  both --connect './top.md = read-only' claude --version # a file in the root
  [ "$A" = "$B" ]
  both --connect 'project = read-only' --connect './a/b/f.md = read-only' --connect './d/ = read-write' claude --version
  [ "$A" = "$B" ]
  both --connect 'project = copy-on-write' --connect './a/b/f.md = read-only' claude --version
  [ "$A" = "$B" ]
  both --connect './a/b/ = own' --connect './d/ = read-write' claude --version
  [ "$A" = "$B" ]
  TEST_PRESET='' both --preset native --connect './a/b/f.md = read-only' claude --version
  [ "$A" = "$B" ]
}

@test "a read-only file two levels down in a read-write project: exactly the two pins added, before it" {
  make_harness
  ref_engine
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  mkdir -p "$proj/a/b"
  touch "$proj/a/b/f.md"
  both --connect './a/b/f.md = read-only' claude --version
  [ "$A" != "$B" ]
  local i
  i="$(printf '%s\n' "$A" | grep -nx -- "$proj/a/b/f.md" | head -1 | cut -d: -f1)"
  [ "$(printf '%s\n' "$A" | sed -n "$((i - 7)),$((i - 1))p" | paste -sd' ')" = "--bind $proj/a $proj/a --bind $proj/a/b $proj/a/b --ro-bind" ]
  # without the six words, the reference
  [ "$(printf '%s\n' "$A" | sed "$((i - 7)),$((i - 2))d")" = "$B" ]
  [[ "$AOUT" == *"read-only parents pinned (the role cannot rename or remove them): ./a, ./a/b"* ]]
}

@test "the roles model: the Supervisor and the setup role get .asb and .asb/roles pinned; the read-only-project roles none" {
  model roles
  pinned supervisor .asb .asb/roles
  local i j
  i="$(argv_index "$PROJ/.asb")"
  j="$(argv_index "$PROJ/.asb/coord")"
  ((i < j)) # .asb before every bind beneath it
  pinned setup .asb .asb/roles
  pinned implementer-1
  pinned reviewer-1
  pinned planner-1
  pinned gate
}

@test "the github model: its setup role gets .asb and .asb/roles pinned; the copy-on-write roles none" {
  model github
  pinned gh-setup .asb .asb/roles
  pinned gh-review-1
  pinned gh-triage-1
  pinned gh-fix-1
}
