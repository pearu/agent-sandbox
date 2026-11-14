#!/usr/bin/env bats
# The parents of read-only and own binds, pinned (_as_ro_pins): every directory above a
# read-only bind, or one that is the role's own (own, copy, copy-on-write, seed-only), that
# the role has read-write from the host is bound onto itself, so the role cannot rename or
# remove it and move what is bound beneath it away. The computation on fixed option lists (the
# cases of the measured prototype, readonly-spike's probes/readonly-pin-bwrap.py, and
# more), then the engine's launches: unchanged where nothing is pinned, and the shipped
# models' roles. The real mounts are tests/integration/ro-pins.bats'.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  P="$BATS_TEST_TMPDIR/p"
  # a store: under the state directory, $XDG_STATE_HOME/agent-sandbox (pins sets it)
  ST="$BATS_TEST_TMPDIR/xdg/agent-sandbox/st"
  mkdir -p "$P/sub" "$P/.asb/roles" "$P/.asb/coord/me" "$P/a/b/c" "$P/a/r" "$P/a/s" "$ST/x/d" \
    "$P/x/a/b" "$P/a/bc/d" "$P/a/cow" "$P/a/z" "$P/a/t"
  touch "$P/sub/f.md" "$P/.asb/roles/r.md" "$P/a/f.md" "$P/a/b/f.md" "$P/a/b/c/f.md" "$P/a/r/f.md" "$P/top.md" "$ST/f" \
    "$P/x/a/b/f.md" "$P/a/bc/d/f" "$P/a/z/f.md"
}

# a test that made a directory unwritable and failed before restoring it: bats can remove it
teardown() {
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# pins [native] -- OPTS -- OUT and PIN from _as_ro_pins over the words after --, the engine
# sourced in a subshell; MSG its messages, RC its status.
pins() {
  local preset=shared
  [[ "$1" == native ]] && preset=native && shift
  [[ "$1" == -- ]] && shift
  local -a _all=()
  # PINS_PRE: code run after the engine is sourced (a test's stand-in for a helper)
  mapfile -d '' _all < <(XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg" PINS_PRE="${PINS_PRE:-}" bash -c 'source "$1"; eval "$PINS_PRE"; shift; _preset="$1"; shift; IN=("$@")
    _as_ro_pins IN OUT PIN 2>"$BATS_TEST_TMPDIR/msg"; rc=$?
    printf "%s\0" "$rc" "${#OUT[@]}" "${OUT[@]}" ${PIN[@]+"${PIN[@]}"}' _ "$ENGINE" "$preset" "$@")
  RC="${_all[0]}"
  local n="${_all[1]}"
  OUT=("${_all[@]:2:n}")
  PIN=("${_all[@]:n+2}")
  MSG="$(cat "$BATS_TEST_TMPDIR/msg")"
  IN=("$@")
}

# same LIST... -- the computation did not refuse, and OUT is exactly the words given.
same() {
  [ "${RC:-0}" -eq 0 ] || {
    echo "refused (RC=$RC): $MSG" >&2
    return 1
  }
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
  sed 's/^  _as_ro_pins _bwrap_opts _pinned_opts _pinned || return 1$/  : no pins/' "$ENGINE" >"$d/agent-sandbox"
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
    printf '%s\n' "$output" | grep -qxF "agent-sandbox: pinned, above a read-only, hidden or own path (the role cannot rename or remove them): $want" \
      || {
        printf '%s\n' "$output" | grep -F 'pinned' >&2
        return 1
      }
  else
    [[ "$output" != *"pinned, above"* ]]
    run ! argv_has --bind "$PROJ/.asb" "$PROJ/.asb"
  fi
}

# cache_pins MODEL ROLE=PINS... -- with ~/.claude/cache/changelog.md in the home (the
# changelog channel's file), each ROLE's launch under the model's own preset pins exactly
# PINS (comma-separated, any order) and ~/.claude/cache. Without the file (NOCACHE=1)
# exactly PINS; with HOME a symbolic link to the home (HLINK=1), the same.
cache_pins() {
  model "$1"
  shift
  local -a envs=(AGENT_SANDBOX_NET=none)
  if [[ "${HLINK:-0}" == 1 ]]; then
    ln -s home "$H/hlink"
    envs+=(HOME="$H/hlink")
  fi
  if [[ "${NOCACHE:-0}" != 1 ]]; then
    mkdir -p "$H/home/.claude/cache"
    printf 'log\n' >"$H/home/.claude/cache/changelog.md"
  fi
  local rp role want got
  for rp in "$@"; do
    role="${rp%%=*}" want="${rp#*=}"
    TEST_PRESET='' run_engine "${envs[@]}" -- asb --role "$role" claude --version
    [ "$status" -eq 0 ] || {
      echo "$role: refused: $output" >&2
      return 1
    }
    # shellcheck disable=SC2088 # the message's own ~
    want="$({
      tr ',' '\n' <<<"$want"
      [[ "${NOCACHE:-0}" == 1 ]] || echo '~/.claude/cache'
    } | grep . | sort | paste -sd' ')"
    got="$(printf '%s\n' "$output" | sed -n "s/^agent-sandbox: pinned, above a read-only, hidden or own path (the role cannot rename or remove them): //p" | tr ',' '\n' | sed 's/^ *//' | sort | paste -sd' ')"
    [ "$got" = "$want" ] || {
      echo "$role: pinned [$got], expected [$want]" >&2
      return 1
    }
  done
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

@test "a read-write directory from the role's store counts: the pin's source is under the store, and the walk goes on above it" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/.asb/s" --ro-bind "$ST/f" "$P/.asb/s/d/f"
  same --bind "$P" "$P" --bind "$P/.asb" "$P/.asb" --bind "$ST/x" "$P/.asb/s" --bind "$ST/x/d" "$P/.asb/s/d" \
    --ro-bind "$ST/f" "$P/.asb/s/d/f"
  [ "${PIN[*]}" = "$P/.asb $P/.asb/s/d" ]
}

@test "B1: a read-write mount between the read-write root and the read-only bind does not stop the walk" {
  pins -- --bind "$P" "$P" --bind "$P/x/a" "$P/x/a" --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  same --bind "$P" "$P" --bind "$P/x" "$P/x" --bind "$P/x/a" "$P/x/a" --bind "$P/x/a/b" "$P/x/a/b" \
    --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  [ "${PIN[*]}" = "$P/x $P/x/a/b" ] # the mount point ./x/a is not pinned again
}

@test "B1: an own store between: ./x pinned above it" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/x/a" --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  [ "${PIN[*]}" = "$P/x" ] # $ST/x/b is not there: nothing to pin inside the store
  [ -z "$MSG" ]            # and not said: only a mount point bwrap makes in the store
}

@test "B1: a copy-on-write overlay between: nothing inside it, ./x above it" {
  pins -- --bind "$P" "$P" --overlay-src "$P/x/a" --overlay /up /wk "$P/x/a" --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  same --bind "$P" "$P" --bind "$P/x" "$P/x" --overlay-src "$P/x/a" --overlay /up /wk "$P/x/a" \
    --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  [ "${PIN[*]}" = "$P/x" ]
}

@test "B2: a pin never goes between --overlay-src and its --overlay" {
  pins -- --bind "$P" "$P" --overlay-src "$P/a/cow" --overlay /up /wk "$P/a/cow" --ro-bind "$P/a/z/f.md" "$P/a/z/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --overlay-src "$P/a/cow" --overlay /up /wk "$P/a/cow" \
    --bind "$P/a/z" "$P/a/z" --ro-bind "$P/a/z/f.md" "$P/a/z/f.md"
}

@test "B2: nor between --size or --perms and the option they qualify" {
  pins -- --bind "$P" "$P" --size 1000 --perms 0700 --tmpfs "$P/a/t" --ro-bind "$P/a/r/f.md" "$P/a/r/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --size 1000 --perms 0700 --tmpfs "$P/a/t" \
    --bind "$P/a/r" "$P/a/r" --ro-bind "$P/a/r/f.md" "$P/a/r/f.md"
}

@test "what shows at a path is the latest mount at or above it: a read-only mount over an earlier read-write one hides it" {
  pins -- --bind "$P/x" "$P/x" --ro-bind "$P" "$P" --ro-bind "$P/x/a/b/f.md" "$P/x/a/b/f.md"
  same "${IN[@]}"
  pins -- --bind "$P/x" "$P/x" --tmpfs "$P" --ro-bind "$ST/f" "$P/x/a/b/f.md"
  same "${IN[@]}"
}

@test "a read-only file two levels inside a read-only directory in a read-write root: nothing inside the read-only mount" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a" "$P/a" --ro-bind "$P/a/b/c/f.md" "$P/a/b/c/f.md"
  same "${IN[@]}"
}

@test "containment is by path components: a mount at ./a/b says nothing about ./a/bc" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/bc/d/f" "$P/a/bc/d/f"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --ro-bind "$P/a/b" "$P/a/b" --bind "$P/a/bc" "$P/a/bc" \
    --bind "$P/a/bc/d" "$P/a/bc/d" --ro-bind "$P/a/bc/d/f" "$P/a/bc/d/f"
}

@test "final view: a read-only bind a later mount above it hides gets nothing; the one after that mount does" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/f.md" "$P/a/f.md" --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  same --bind "$P" "$P" --ro-bind "$P/a/f.md" "$P/a/f.md" --bind "$P" "$P" \
    --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "final view: a read-write mount AFTER the read-only bind that shows its source is a contradiction; declared read-only at its own path too, it is pinned there, after that mount" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/sub"
  touch "$h/sub/x.md"
  pins -- --bind "$P" "$P" --ro-bind "$h/sub/x.md" "$P/x.md" --bind "$h" "$h"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it read-write at $h/sub/x.md: the two contradict"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$h/sub/x.md" "$P/x.md" --bind "$h" "$h" --ro-bind "$h/sub/x.md" "$h/sub/x.md"
  [ "$RC" -eq 0 ]
  # ~/store/sub: pinned once, after ~/store, before the read-only bind at its own path
  [ "${PIN[*]}" = "$h/sub" ]
  same --bind "$P" "$P" --ro-bind "$h/sub/x.md" "$P/x.md" --bind "$h" "$h" --bind "$h/sub" "$h/sub" \
    --ro-bind "$h/sub/x.md" "$h/sub/x.md"
}

@test "final view: a link whose directory a LATER read-write mount shows is replaceable (refused); a later read-only mount over it makes it safe" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/realdir" "$h/p/links"
  touch "$h/realdir/x.md"
  ln -s ../../realdir "$h/p/links/l"
  pins -- --bind "$P" "$P" --ro-bind "$h/p/links/l/x.md" "$P/x.md" --bind "$h" "$h"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $h/p/links/l, a symbolic link in a directory the role can write"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$h/p/links/l/x.md" "$P/x.md" --bind "$h" "$h" --ro-bind "$h/p/links" "$h/p/links" \
    --ro-bind "$h/realdir" "$h/realdir"
  [ "$RC" -eq 0 ]
}

@test "final view: a covered host object shown by a LATER read-write mount refuses; hidden by a later tmpfs it does not" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/real/b"
  touch "$h/real/b/f.md"
  ln -s real "$h/lnk"
  pins -- --bind "$h" "$h" --ro-bind "$ST/f" "$h/lnk/b/f.md" --bind "$h/real" "$h/real"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"goes through $h/lnk, a symbolic link in a directory the role can write, and covers $h/real/b/f.md, which the role sees"* ]]
  pins -- --bind "$h" "$h" --ro-bind "$ST/f" "$h/lnk/b/f.md" --tmpfs "$h/real"
  [ "$RC" -eq 0 ]
}

@test "the covered object must be seen: one that exists but no mount shows is not a refusal; one only a read-only mount shows is" {
  local o="$BATS_TEST_TMPDIR/out"
  mkdir -p "$o/b" "$P/ro/real/b"
  touch "$o/b/f.md" "$P/ro/real/b/f.md"
  ln -s "$o" "$P/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/lnk/b/f.md" # $o is not in the sandbox
  [ "$RC" -eq 0 ]
  ln -s ro/real "$P/lnk2"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$ST/f" "$P/lnk2/b/f.md" # seen, read-only
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"covers $P/ro/real/b/f.md, which the role sees"* ]]
}

@test "a chain of three links resolves; the walk stops beneath a destination link" {
  mkdir -p "$P/ro" "$P/real/b"
  touch "$P/real/b/f.md"
  ln -s l2 "$P/ro/l1"
  ln -s l3 "$P/ro/l2"
  ln -s ../real "$P/ro/l3"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/l1/b/f.md" "$P/ro/l1/b/f.md"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/real $P/real/b" ]
  ln -s a "$P/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/lnk/b/new.md" # nothing covered: not refused
  [ "$RC" -eq 0 ]
  [[ " ${PIN[*]} " != *" $P/lnk/b "* ]] # not through the link
}

@test "a link in a sticky directory, neither the directory nor the link the role's, is not replaceable; the role's own link there is" {
  local d="$BATS_TEST_TMPDIR/sticky"
  mkdir -p "$d" "$P/real/b"
  chmod 1777 "$d"
  touch "$P/real/b/f.md"
  ln -s "$P/real" "$d/l"
  # shellcheck disable=SC2016 # the stand-in's own expansions
  PINS_PRE='_as_ro_pins_uid() { printf 0; }' pins -- --bind "$d" "$d" --ro-bind "$d/l/b/f.md" "$P/x.md"
  [ "$RC" -eq 0 ]
  # shellcheck disable=SC2016 # the stand-in's own expansions
  PINS_PRE='_as_ro_pins_uid() { [[ "$1" == */l ]] && printf "%s" "$EUID" || printf 0; }' pins -- --bind "$d" "$d" --ro-bind "$d/l/b/f.md" "$P/x.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $d/l, a symbolic link in a directory the role can write"* ]]
}

@test "a directory remounted read-only later is not pinned (the remount would take the pin), and said" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/f.md" "$P/a/f.md" --remount-ro "$P/a"
  same "${IN[@]}"
  [[ "$MSG" == *"pins: $P/a is remounted read-only later in the list, so it is not pinned"* ]]
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

@test "read-write declarations get no pins for their own sake: the path itself, or a host path elsewhere" {
  pins -- --bind "$P" "$P" --bind "$P/a/r" "$P/a/r" --bind "$BATS_TEST_TMPDIR/elsewhere" "$P/a/b/c"
  same "${IN[@]}"
}

@test "a hide (a tmpfs) in a read-write host directory gets its parents pinned; one directly in the root none" {
  pins -- --bind "$P" "$P" --tmpfs "$P/a/b/c"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --tmpfs "$P/a/b/c"
  pins -- --bind "$P" "$P" --tmpfs "$P/a"
  same "${IN[@]}"
  pins -- --tmpfs /tmp --tmpfs "$P" --tmpfs "$P/a/b" # none under a tmpfs
  same "${IN[@]}"
}

@test "an own, copy or seed-only directory (a store's, at another path) gets its parents pinned" {
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/a/b/c"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --bind "$ST/x" "$P/a/b/c"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "an own or copy FILE (a store's) gets its parents pinned" {
  pins -- --bind "$P" "$P" --bind "$ST/f" "$P/x/a/f"
  same --bind "$P" "$P" --bind "$P/x" "$P/x" --bind "$P/x/a" "$P/x/a" --bind "$ST/f" "$P/x/a/f"
}

@test "a copy-on-write directory (an overlay) gets its parents pinned" {
  pins -- --bind "$P" "$P" --overlay-src "$P/x/a/b" --overlay /up /wk "$P/x/a/b"
  same --bind "$P" "$P" --bind "$P/x" "$P/x" --bind "$P/x/a" "$P/x/a" --overlay-src "$P/x/a/b" --overlay /up /wk "$P/x/a/b"
}

@test "the role's own binds: nothing under native, nothing where no read-write host mount shows above them" {
  pins native -- --bind "$P" "$P" --bind "$ST/x" "$P/a/b/c"
  same "${IN[@]}"
  pins -- --tmpfs "$P" --bind "$ST/x" "$P/a/b/c"
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

@test "a directory not there on the host is not pinned, and not said (only bwrap's mount-point stub is there): the launch does not fail on it" {
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/nodir/sub/f.md" # an outside: source's shape
  same "${IN[@]}"
  [ -z "$MSG" ]
}

@test "a read-only bind whose source goes through a link the role can replace (in a read-write host directory) is refused, naming the link and the resolved path" {
  ln -s a "$P/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 1 ]
  # not a declaration here (no recorded declared source): what a channel's user can do
  [[ "$MSG" == *"connect: $P/lnk/b/f.md: its source goes through $P/lnk, a symbolic link in a directory the role can write, so it is not bound read-only: the role could replace the link and have the next launch bind its own file. Make $P/lnk the directory it points to, or bind from the resolved path ($P/a/b/f.md; for a channel, its mode with outside:$P/a/b/f.md). Refusing to launch"* ]]
  ln -s ../a "$P/x/lnk2" # deeper: a link inside a plain directory of the project
  pins -- --bind "$P" "$P" --ro-bind "$P/x/lnk2/b/f.md" "$P/x/lnk2/b/f.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $P/x/lnk2,"* ]]
}

@test "B1: a replaceable link in the MIDDLE of the source's resolution is refused, naming that link" {
  # shape 1: a read-only project, ./rw/ read-write, lnk -> rw/l2 -> real
  mkdir -p "$P/rw" "$P/real/b"
  touch "$P/real/b/f.md"
  ln -s rw/l2 "$P/lnk"
  ln -s ../real "$P/rw/l2"
  pins -- --ro-bind "$P" "$P" --bind "$P/rw" "$P/rw" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $P/rw/l2, a symbolic link in a directory the role can write"* ]]
  [[ "$MSG" == *"bind from the resolved path ($P/real/b/f.md;"* ]]
  # shape 2: ~/store read-write, the source through ~/store/l -> realdir
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/realdir"
  touch "$h/realdir/x.md"
  ln -s realdir "$h/l"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/l/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $h/l, a symbolic link"* ]]
}

@test "the resolution follows links inside link targets, absolute targets and .., and is bounded" {
  mkdir -p "$P/ro/in" "$P/real/b"
  touch "$P/real/b/f.md"
  ln -s "$P/ro/in/up" "$P/ro/l1" # absolute
  ln -s ../../real "$P/ro/in/up" # relative, with ..
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/l1/b/f.md" "$P/ro/l1/b/f.md"
  [ "$RC" -eq 0 ]                       # both links in the read-only mount: not replaceable
  [ "${PIN[*]}" = "$P/real $P/real/b" ] # the real path's directories, in the read-write project
  ln -s loop2 "$P/ro/loop1"
  ln -s loop1 "$P/ro/loop2"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/loop1/f" "$P/x/f"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"$P/ro/loop1/f does not resolve (40 symbolic links: a loop?), so it cannot be bound. Refusing to launch"* ]]
}

@test "a replaceable link on the DESTINATION side, the source elsewhere: refused where it covers a host file the role sees, not where nothing is there" {
  ln -s a "$P/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/lnk/b/f.md" # covers ./a/b/f.md
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"connect: $P/lnk/b/f.md goes through $P/lnk, a symbolic link in a directory the role can write, and covers $P/a/b/f.md, which the role sees: the role could replace the link and have that uncovered at the next launch. Declare the path it resolves to instead: $P/a/b/f.md. Refusing to launch"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/lnk/b/new.md" # nothing there to cover
  [ "$RC" -eq 0 ]
  [ -z "$MSG" ]
}

@test "the source shows only where its host directory does: under a store's copy of the directory nothing is pinned for it, nor refused" {
  mkdir -p "$P/s/real/b" "$ST/x/real/b" # the store has its own copy of the directories
  touch "$P/s/real/b/f.md"
  ln -s real "$P/s/lnk"
  # ./s/ = copy: the store at ./s hides the host's ./s; the declaration's source is the host's
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/s" --ro-bind "$P/s/lnk/b/f.md" "$P/s/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  [ -z "${PIN[*]}" ]
  # as the engine binds it: the source resolved, ./s/real/b/f.md, which the store hides
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/s" --ro-bind "$P/s/real/b/f.md" "$P/s/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  [ -z "${PIN[*]}" ] # not the store's own ./s/real, ./s/real/b
}

@test "a read-write mount hidden by a later read-only one shows nothing: no pin for a source under it" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/roles" "$P/cfg"
  touch "$h/roles/x.md"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/cfg" ]
}

@test "a link the role cannot replace is not refused: in a read-only mount, the real path behind it pinned where it shows read-write" {
  mkdir -p "$P/ro"
  ln -s ../a "$P/ro/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/a/b/f.md" "$P/ro/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  # (where the bind lands through the link, on its source, nothing more is made read-only)
  same --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" \
    --ro-bind "$P/a/b/f.md" "$P/ro/lnk/b/f.md"
}

@test "a link the role cannot replace is not refused: under copy-on-write; nor in a read-only project; nor under native" {
  mkdir -p "$P/c"
  ln -s ../a "$P/c/lnk"
  pins -- --bind "$P" "$P" --overlay-src "$P/c" --overlay /up /wk "$P/c" --ro-bind "$P/a/b/f.md" "$P/c/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/a $P/a/b" ] # the real path's, in the read-write project
  ln -s a "$P/lnk"
  pins -- --ro-bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  same "${IN[@]}"
  pins native -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  same "${IN[@]}"
}

@test "the role's own path through a replaceable link: refused where it covers a host object the role sees; behind a link it cannot replace, the real path pinned" {
  ln -s a "$P/lnk"
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/lnk/b" # an own directory over ./a/b
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"connect: $P/lnk/b goes through $P/lnk, a symbolic link in a directory the role can write, and covers $P/a/b, which the role sees"* ]]
  pins -- --bind "$P" "$P" --bind "$ST/f" "$P/lnk/b/f.md" # an own file over ./a/b/f.md
  [ "$RC" -eq 1 ]
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/lnk/new" # nothing there to cover
  [ "$RC" -eq 0 ]
  mkdir -p "$P/ro"
  ln -s ../a "$P/ro/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --bind "$ST/f" "$P/ro/lnk/b/f.md"
  [ "$RC" -eq 0 ] # the link is in a read-only mount
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "a read-only bind's source is walked where a read-write host mount shows it, and a contradiction refused there; read-only or not shown, pinned only" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/roles" "$P/cfg/sub"
  touch "$h/roles/x.md"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/sub/x.md" --ro-bind "$h/roles/x.md" "$h/roles/x.md"
  [ "$RC" -eq 0 ] # declared read-only at its own path too: both kept
  [ "${PIN[*]}" = "$P/cfg $P/cfg/sub $h/roles" ]
  pins -- --bind "$P" "$P" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" # not shown read-write: nothing for it
  same --bind "$P" "$P" --bind "$P/cfg" "$P/cfg" --ro-bind "$h/roles/x.md" "$P/cfg/x.md"
}

@test "a contradiction refuses: the object bound read-only also shown read-write at another path (itself, a containing directory, at two paths, through a mount at another path)" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/roles" "$P/cfg"
  touch "$h/roles/x.md"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" # a containing directory
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"binds $h/roles/x.md read-only at $P/cfg/x.md, and $h shows it read-write at $h/roles/x.md: the two contradict, so the launch is refused. Make one of them read-only too -- declaring $h/roles/x.md read-only at its own path ($h/roles/x.md = read-only) keeps both -- or remove one."* ]]
  pins -- --bind "$P" "$P" --bind "$h/roles" "$P/mnt" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" # through a mount at another path
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it read-write at $P/mnt/x.md"* ]]
  pins -- --bind "$P" "$P" --bind "$h/roles" "$P/m1" --bind "$h/roles" "$P/m2" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" # at two paths
  [ "$RC" -eq 1 ]
  pins -- --bind "$P" "$P" --bind "$h/roles" "$P/m1" --ro-bind "$h/roles" "$P/cfg/roles" # the object itself, a directory
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it read-write at $P/m1"* ]]
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h" "$P/cfg" # a read-write declaration that is itself the source
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it read-write at $h: the two contradict, so the launch is refused. Make one of them read-only too or remove one."* ]]
}

@test "a contradiction refuses: a part of a read-only directory source shown read-write elsewhere" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/sub/deep" "$P/cfg"
  pins -- --bind "$P" "$P" --ro-bind "$h/sub" "$P/cfg" --bind "$h/sub/deep" "$P/alt"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"binds $h/sub read-only at $P/cfg, and $P/alt shows $h/sub/deep, inside it, read-write at $P/alt"* ]]
  # the same part at its own place inside the read-only tree: ordinary nesting
  pins -- --bind "$P" "$P" --ro-bind "$h/sub" "$P/cfg" --bind "$h/sub/deep" "$P/cfg/deep"
  [ "$RC" -eq 0 ]
}

@test "B1: a read-write FILE declaration of the same object, or of a file inside a read-only directory source, is a contradiction" {
  local e="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$e/d"
  touch "$e/x.md" "$e/d/x.md"
  pins -- --bind "$P" "$P" --ro-bind "$e/x.md" "$P/cfg/x.md" --bind "$e/x.md" "$P/alt.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"binds $e/x.md read-only at $P/cfg/x.md, and $P/alt.md shows it read-write at $P/alt.md"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$e/d" "$P/cfg" --bind "$e/d/x.md" "$P/alt.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows $e/d/x.md, inside it, read-write at $P/alt.md"* ]]
}

@test "B2: host paths compared resolved: a read-write mount given through a link shows the resolved source (contradiction, replaceable link, source pins)" {
  local real="$BATS_TEST_TMPDIR/home" hl="$BATS_TEST_TMPDIR/hlink"
  mkdir -p "$real/store/roles" "$real/store/realdir" "$P/cfg"
  touch "$real/store/roles/x.md" "$real/store/realdir/y.md"
  ln -s home "$hl"
  ln -s realdir "$real/store/l"
  pins -- --bind "$P" "$P" --bind "$hl" "$hl" --ro-bind "$real/store/roles/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it read-write at $hl/store/roles/x.md"* ]]
  pins -- --bind "$P" "$P" --bind "$hl" "$hl" --ro-bind "$real/store/l/y.md" "$P/cfg/y.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $real/store/l, a symbolic link in a directory the role can write"* ]]
  # an object the role cannot write: no contradiction, the directories above it pinned
  # where the linked mount shows them
  chmod 444 "$real/store/roles/x.md"
  PINS_PRE='_as_ro_pins_uid() { printf 0; }; _as_ro_pins_find_writable() { :; }' \
    pins -- --bind "$P" "$P" --bind "$hl" "$hl" --ro-bind "$real/store/roles/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  [[ " ${PIN[*]} " == *" $hl/store "* ]]
  [[ " ${PIN[*]} " == *" $hl/store/roles "* ]]
  chmod 644 "$real/store/roles/x.md"
}

@test "B3: a part already read-write at its own place, shown read-write at a second path too, is not a contradiction" {
  mkdir -p "$P/out" "$BATS_TEST_TMPDIR/home/out-alias"
  # project = read-only, ./out/ = read-write, ~/out-alias/ = read-write outside:./out/
  pins -- --ro-bind "$P" "$P" --bind "$P/out" "$P/out" --bind "$P/out" "$BATS_TEST_TMPDIR/home/out-alias"
  [ "$RC" -eq 0 ]
  local s="$BATS_TEST_TMPDIR/src/libfoo"
  mkdir -p "$s/build" "$P/ref" "$P/build"
  # ./ref/ = read-only outside:~/src/libfoo/, ./ref/build/ and ./build/ read-write outside:~/src/libfoo/build/
  pins -- --bind "$P" "$P" --ro-bind "$s" "$P/ref" --bind "$s/build" "$P/ref/build" --bind "$s/build" "$P/build"
  [ "$RC" -eq 0 ]
  # without the part read-write in place it is one
  pins -- --bind "$P" "$P" --ro-bind "$s" "$P/ref" --bind "$s/build" "$P/build"
  [ "$RC" -eq 1 ]
}

@test "B4: a directory the role neither owns nor can write, holding a file it can write, is writable to it: a contradiction" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/foreign" "$P/cfg"
  touch "$h/foreign/f"
  chmod 666 "$h/foreign/f"
  chmod 555 "$h/foreign"
  PINS_PRE='_as_ro_pins_uid() { printf 0; }' pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/foreign" "$P/cfg"
  [ "$RC" -eq 1 ]
  PINS_PRE='_as_ro_pins_uid() { printf 0; }; _as_ro_pins_find_writable() { :; }' \
    pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/foreign" "$P/cfg"
  [ "$RC" -eq 0 ] # nothing in it the role can write
  chmod 755 "$h/foreign"
}

@test "B5: another name of a read-only file (a hard link) in a directory shown read-write is a contradiction; a file with one link is not searched" {
  local e="$BATS_TEST_TMPDIR/ext" h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$e" "$h" "$P/cfg"
  printf 'x\n' >"$e/x.md"
  printf 'y\n' >"$e/y.md"
  ln "$e/x.md" "$h/alias.md"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$e/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"shows it, as $h/alias.md (another name of the same file), read-write at $h/alias.md"* ]]
  PINS_PRE='_as_ro_pins_samefile() { echo searched >&2; }' pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$e/y.md" "$P/cfg/y.md"
  [ "$RC" -eq 0 ]
  [[ "$MSG" != *searched* ]]
}

@test "mutants: a hidden read-only bind gets no pins; a hidden read-write part is no contradiction; the part's own could-write test counts" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/f.md" "$P/a/f.md" --bind "$P" "$P"
  same "${IN[@]}"
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/sub/deep" "$P/cfg" "$P/alt"
  pins -- --bind "$P" "$P" --ro-bind "$h/sub" "$P/cfg" --bind "$h/sub/deep" "$P/alt" --ro-bind "$ST/x" "$P/alt"
  [ "$RC" -eq 0 ] # the read-write view at ./alt is hidden by the later read-only bind
  # shellcheck disable=SC2016 # the stand-in's own expansions
  PINS_PRE='_as_ro_pins_writable() { [[ "$1" != */deep ]]; }' pins -- --bind "$P" "$P" --ro-bind "$h/sub" "$P/cfg" --bind "$h/sub/deep" "$P/alt"
  [ "$RC" -eq 0 ] # the part is not writable to the role
}

@test "mutants: a link in a directory the role owns but has made unwritable is replaceable (it can chmod it)" {
  local e="$BATS_TEST_TMPDIR/ext" # the target: not shown to the role, no contradiction
  mkdir -p "$P/own" "$e/b"
  touch "$e/b/f.md"
  ln -s "$e" "$P/own/l"
  chmod 555 "$P/own"
  pins -- --bind "$P" "$P" --ro-bind "$P/own/l/b/f.md" "$P/x.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"its source goes through $P/own/l, a symbolic link in a directory the role can write"* ]]
  chmod 755 "$P/own"
}

@test "final view and the end of the list: a pin above a link in a directory a LATER read-write mount shows goes after that mount, at the end" {
  local h="$BATS_TEST_TMPDIR/home/store" o="$BATS_TEST_TMPDIR/out"
  mkdir -p "$h/d" "$o"
  touch "$o/f.md"
  ln -s "$o" "$h/d/l"
  chmod 555 "$h/d"
  PINS_PRE='_as_ro_pins_uid() { printf 0; }' pins -- --bind "$P" "$P" --ro-bind "$h/d/l/f.md" "$P/x.md" --bind "$h" "$h" -- cmd
  [ "$RC" -eq 0 ]
  same --bind "$P" "$P" --ro-bind "$h/d/l/f.md" "$P/x.md" --bind "$h" "$h" --bind "$h/d" "$h/d" -- cmd
  chmod 755 "$h/d"
}

@test "not a contradiction: an object the role cannot write anyway (another user's, not writable)" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/roles" "$P/cfg"
  touch "$h/roles/x.md"
  chmod 444 "$h/roles/x.md"
  PINS_PRE='_as_ro_pins_uid() { printf 0; }' pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" # the role's own: it can chmod it
  [ "$RC" -eq 1 ]
  chmod 644 "$h/roles/x.md"
}

@test "not a contradiction: nesting at the same path, and a read-write view covered in the final view (read-only, hide, store, overlay)" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/sub" "$h/roles" "$P/cfg"
  touch "$h/sub/x.md" "$h/roles/x.md"
  pins -- --bind "$h" "$h" --ro-bind "$h/sub/x.md" "$h/sub/x.md" # ~/store rw, ~/store/sub/x.md read-only
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$h/sub" ]
  local cover
  for cover in "--ro-bind $h/roles/x.md $h/roles/x.md" "--tmpfs $h/roles" "--bind $ST/x $h/roles" \
    "--overlay-src $h/roles --overlay /up /wk $h/roles"; do
    # shellcheck disable=SC2086 # the cover's words
    pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/roles/x.md" "$P/cfg/x.md" $cover
    [ "$RC" -eq 0 ] || {
      echo "refused with $cover: $MSG" >&2
      return 1
    }
  done
}

@test "an option list the computation cannot read refuses: an unknown option, a word that is no option, missing arguments" {
  pins -- --bind "$P" "$P" --new-option x --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"the pins cannot read the bwrap option '--new-option' (at 3): this is a bug in agent-sandbox, and the launch is refused rather than run without them"* ]]
  pins -- --bind "$P" "$P" stray --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"cannot read the bwrap option 'stray' (at 3)"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md"
  [ "$RC" -eq 1 ]
  pins -- --bind "$P" "$P" --level-prefix --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "$RC" -eq 0 ] # takes no argument
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "the option table is bubblewrap's: every option of the installed bwrap's --help, with its number of arguments" {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  local -A want=() got=()
  local o rest line
  while IFS= read -r line; do
    [[ "$line" =~ ^\ \ \ \ (--[a-z0-9-]+)((\ [A-Z0-9_]+)*)(\ |$) ]] || continue
    o="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
    rest="${rest//[!\ ]/}"
    want[$o]=${#rest}
  done < <(bwrap --help 2>&1)
  [ "${#want[@]}" -gt 60 ]
  # shellcheck disable=SC1090
  source "$ENGINE"
  _as_bwrap_nargs got
  for o in "${!want[@]}"; do
    [ "${got[$o]-missing}" = "${want[$o]}" ] || {
      echo "$o: table ${got[$o]-missing}, bwrap ${want[$o]}" >&2
      return 1
    }
  done
  for o in "${!got[@]}"; do
    [ -n "${want[$o]+x}" ] || {
      echo "$o: in the table, not in bwrap --help" >&2
      return 1
    }
  done
}

@test "a destination that is not normalised is pinned once per directory: // and /./" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/a//b/f.md"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a//b/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
  pins -- --bind "$P/" "$P/" --ro-bind "$P/a/b/f.md" "$P/a/./b/f.md"
  same --bind "$P/" "$P/" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a/./b/f.md"
  [ "${PIN[*]}" = "$P/a $P/a/b" ]
}

@test "a pin is bound as the mount it lies in: under a --dev-bind it is a --dev-bind" {
  pins -- --dev-bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  same --dev-bind "$P" "$P" --dev-bind "$P/a" "$P/a" --dev-bind "$P/a/b" "$P/a/b" --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  pins -- --dev-bind "$P" "$P" --bind "$ST/x" "$P/a/s" --ro-bind "$ST/f" "$P/a/s/d/f"
  same --dev-bind "$P" "$P" --dev-bind "$P/a" "$P/a" --bind "$ST/x" "$P/a/s" --bind "$ST/x/d" "$P/a/s/d" \
    --ro-bind "$ST/f" "$P/a/s/d/f"
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
  both --connect './b/ = own' --connect './d/ = read-write' claude --version # own in the root: nothing above
  [ "$A" = "$B" ]
  TEST_PRESET='' both --preset native --connect './a/b/f.md = read-only' claude --version
  [ "$A" = "$B" ]
}

@test "a launch refuses a read-only declaration through a link the role can replace, saying it once, bwrap never run" {
  make_harness
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  mkdir -p "$proj/real/b"
  touch "$proj/real/b/f.md"
  ln -s real "$proj/lnk"
  run_engine AGENT_SANDBOX_NET=none -- asb --connect './lnk/b/f.md = read-only' claude --version
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c "its source goes through $proj/lnk, a symbolic link in a directory the role can write")" -eq 1 ]
  [[ "$output" == *"Declare the path it resolves to instead: $proj/real/b/f.md. Refusing to launch"* ]]
  [ ! -s "$H/argv" ]
  run_engine AGENT_SANDBOX_NET=none -- asb --connect './real/b/f.md = read-only' claude --version # the resolved path
  [ "$status" -eq 0 ]
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
  [[ "$AOUT" == *"pinned, above a read-only, hidden or own path (the role cannot rename or remove them): ./a, ./a/b"* ]]
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

@test "the github model: its setup role gets .asb and .asb/roles pinned; the copy-on-write roles and the default none" {
  model github
  pinned gh-setup .asb .asb/roles
  pinned gh-review-1
  pinned gh-triage-1
  pinned gh-fix-1
  pinned default
}

@test "the market model: its role gets .asb and .asb/roles pinned; the default none" {
  model market
  pinned market-1 .asb .asb/roles
  pinned default
}

@test "where ~/.claude/cache/changelog.md exists, every role of the roles model gets ~/.claude/cache pinned too (its changelog channel's store inside the read-write base)" {
  cache_pins roles supervisor=./.asb,./.asb/roles setup=./.asb,./.asb/roles implementer-1= reviewer-1= planner-1= gate=
}

@test "where ~/.claude/cache/changelog.md exists, the github roles get ~/.claude/cache pinned too" {
  cache_pins github gh-setup=./.asb,./.asb/roles gh-review-1= gh-triage-1= gh-fix-1= default=
}

@test "where ~/.claude/cache/changelog.md exists, the market role gets ~/.claude/cache pinned too" {
  cache_pins market market-1=./.asb,./.asb/roles default=
}

@test "the roles model under its own preset, without ~/.claude/cache/changelog.md: each role's pins exact, nothing refused" {
  NOCACHE=1 cache_pins roles supervisor=./.asb,./.asb/roles setup=./.asb,./.asb/roles implementer-1= reviewer-1= planner-1= gate=
}

@test "the roles model under its own preset, under a linked \$HOME (a symbolic link to the home), with the changelog: each role's pins exact, nothing refused" {
  HLINK=1 cache_pins roles supervisor=./.asb,./.asb/roles setup=./.asb,./.asb/roles implementer-1= reviewer-1= planner-1= gate=
}

@test "the roles model under its own preset, under a linked \$HOME, without the changelog: each role's pins exact, nothing refused" {
  HLINK=1 NOCACHE=1 cache_pins roles supervisor=./.asb,./.asb/roles setup=./.asb,./.asb/roles implementer-1= reviewer-1= planner-1= gate=
}

@test "the github model under its own preset, without ~/.claude/cache/changelog.md: each role's pins exact, nothing refused" {
  NOCACHE=1 cache_pins github gh-setup=./.asb,./.asb/roles gh-review-1= gh-triage-1= gh-fix-1= default=
}

@test "the github model under its own preset, under a linked \$HOME (a symbolic link to the home), with the changelog: each role's pins exact, nothing refused" {
  HLINK=1 cache_pins github gh-setup=./.asb,./.asb/roles gh-review-1= gh-triage-1= gh-fix-1= default=
}

@test "the github model under its own preset, under a linked \$HOME, without the changelog: each role's pins exact, nothing refused" {
  HLINK=1 NOCACHE=1 cache_pins github gh-setup=./.asb,./.asb/roles gh-review-1= gh-triage-1= gh-fix-1= default=
}

@test "the market model under its own preset, without ~/.claude/cache/changelog.md: each role's pins exact, nothing refused" {
  NOCACHE=1 cache_pins market market-1=./.asb,./.asb/roles default=
}

@test "the market model under its own preset, under a linked \$HOME (a symbolic link to the home), with the changelog: each role's pins exact, nothing refused" {
  HLINK=1 cache_pins market market-1=./.asb,./.asb/roles default=
}

@test "the market model under its own preset, under a linked \$HOME, without the changelog: each role's pins exact, nothing refused" {
  HLINK=1 NOCACHE=1 cache_pins market market-1=./.asb,./.asb/roles default=
}
