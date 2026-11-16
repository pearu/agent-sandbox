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
  local -a _all=() _wrap=()
  # PINS_WRAP: a command the computation runs under (words, no quoting): a bwrap that
  # mounts something first, say
  [[ -z "${PINS_WRAP:-}" ]] || read -r -a _wrap <<<"$PINS_WRAP"
  # PINS_PRE: code run after the engine is sourced (a test's stand-in for a helper)
  # (HOME a test's own: the computation writes the launch's view under its trust store)
  mkdir -p "$BATS_TEST_TMPDIR/home"
  # shellcheck disable=SC2016 # the script's own expansions
  # (AGENT_SANDBOX cleared, as run_engine clears it: inside a role's sandbox the gate
  # would take this for a launch inside one, which asks nothing)
  mapfile -d '' _all < <(env -u AGENT_SANDBOX HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg" PINS_PRE="${PINS_PRE:-}" ${_wrap[@]+"${_wrap[@]}"} bash -c 'source "$1"; eval "$PINS_PRE"; shift; _preset="$1"; shift; IN=("$@")
    _as_ro_pins IN OUT PIN 2>"$BATS_TEST_TMPDIR/msg"; rc=$?
    printf "%s\0" "$rc" "${#OUT[@]}" "${OUT[@]}" ${PIN[@]+"${PIN[@]}"}' _ "$ENGINE" "$preset" "$@")
  RC="${_all[0]}"
  local n="${_all[1]}"
  OUT=("${_all[@]:2:n}")
  PIN=("${_all[@]:n+2}")
  MSG="$(cat "$BATS_TEST_TMPDIR/msg")"
  IN=("$@")
}

# need_bwrap -- skip where bwrap cannot run here (a nested mount needs it).
need_bwrap() {
  command -v bwrap >/dev/null || skip "bwrap not installed"
  bwrap --dev-bind / / true 2>/dev/null || skip "bwrap cannot run here"
}

# COUNT: PINS_PRE code that records each find, realpath, stat and readlink the computation
# runs, and each owner lookup (a subshell), one line per call in $BATS_TEST_TMPDIR/forks.
# shellcheck disable=SC2016 # code for the computation's shell to run
COUNT='for _c in find realpath stat readlink; do eval "$_c() { echo $_c >>\"\$BATS_TEST_TMPDIR/forks\"; command $_c \"\$@\"; }"; done
eval "$(declare -f _as_ro_pins_uid | sed "1s/_as_ro_pins_uid/_orig_uid/")"
_as_ro_pins_uid() { echo uid >>"$BATS_TEST_TMPDIR/forks"; _orig_uid "$@"; }'

# forks WHAT -- how many WHAT lines $BATS_TEST_TMPDIR/forks has (all: every line).
forks() {
  if [[ "$1" == all ]]; then
    cat "$BATS_TEST_TMPDIR/forks" 2>/dev/null | wc -l
  else
    grep -cx "$1" "$BATS_TEST_TMPDIR/forks" 2>/dev/null || true
  fi
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
  sed 's/^  _as_ro_pins _bwrap_opts _pinned_opts _pinned || return 1$/  _pinned_opts=("${_bwrap_opts[@]}") # no pins/' "$ENGINE" >"$d/agent-sandbox"
  chmod +x "$d/agent-sandbox"
  [ "$(grep -c '# no pins$' "$d/agent-sandbox")" -eq 1 ]
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
    printf '%s\n' "$output" | grep -qxF "agent-sandbox: pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): $want" \
      || {
        printf '%s\n' "$output" | grep -F 'pinned' >&2
        return 1
      }
  else
    [[ "$output" != *"pinned, on the way"* ]]
    run ! argv_has --bind "$PROJ/.asb" "$PROJ/.asb"
  fi
}

# cache_pins MODEL ROLE=PINS... -- with ~/.claude/cache/changelog.md in the home (the
# changelog channel's file), each ROLE's launch under the model's own preset pins exactly
# PINS (comma-separated, any order) and ~/.claude/cache. Without the file (NOCACHE=1) the
# same: the launch makes ~/.claude/cache where bwrap would make it for the channel's own
# store, and pins it at once; with HOME a symbolic link to the home (HLINK=1), the same.
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
      echo '~/.claude/cache'
    } | grep . | sort | paste -sd' ')"
    got="$(printf '%s\n' "$output" | sed -n "s/^agent-sandbox: pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): //p" | tr ',' '\n' | sed 's/^ *//' | sort | paste -sd' ')"
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

@test "a --remount-ro before the bind does not make it read-only: the read-write key's directory pinned, as any declared path's" {
  pins -- --bind "$P" "$P" --remount-ro "$P/a/b" --bind "$P/a/b" "$P/a/b"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/a" ]
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
  # $ST/x/b, not there yet, made where bwrap would make it (in the store) and pinned there
  [ "${PIN[*]}" = "$P/x $P/x/a/b" ]
  [ -d "$ST/x/b" ]
  [ -z "$MSG" ]
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

@test "a chain of three links resolves: the real path's directories and the source itself fixed where the project shows them" {
  mkdir -p "$P/ro" "$P/real/b"
  touch "$P/real/b/f.md"
  ln -s l2 "$P/ro/l1"
  ln -s l3 "$P/ro/l2"
  ln -s ../real "$P/ro/l3"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/l1/b/f.md" "$P/ro/l1/b/f.md"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/real $P/real/b $P/real/b/f.md" ]
}

# ---- symbolic links as the declarations they imply (#401) ----
# ln KEY MODE -- PINS_PRE for a launch in project $P whose connect path KEY has MODE
# (_as_connect_bind_all records it in _ln_mode); approve P CHAIN T KIND -- the record
# `asb --trust` writes for an implied declaration (P CHAIN T KIND MODE: the mode is part
# of what is approved), under the computation's HOME.
ln_mode() { PINS_PRE="_proj=$P; declare -A _ln_mode=([$1]=$2)"; }
approve() {
  local d="$BATS_TEST_TMPDIR/home/.config/agent-sandbox/trust"
  mkdir -p "$d"
  printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$d/$(printf '%s' "$P" | sha256sum | cut -d' ' -f1).links"
}
implied() { # MSG names the implied declaration KEY = MODE outside:T, refused without a terminal
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"connect: $1 is reached through a symbolic link"*"to $3, which is outside the role's view: it stands for '$1 = $2 outside:$3'"* ]]
  [[ "$MSG" == *"review it with: "*"--trust"* ]]
}

@test "links: a declared path through a link to a host object outside the view is the declaration it implies: refused without a terminal, launched once approved, the mount at the target's own path" {
  local e="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$e/b"
  touch "$e/b/f.md"
  ln -s "$e" "$P/lnk"
  ln_mode "$P/lnk/b/f.md" read-only
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  implied "$P/lnk/b/f.md" read-only "$e/b/f.md"
  [[ "$MSG" == *"($P/lnk -> $e)"* ]]
  approve "$P/lnk/b/f.md" "$P/lnk -> $e" "$e/b/f.md" file read-write # another mode: asked again
  ln_mode "$P/lnk/b/f.md" read-only
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  implied "$P/lnk/b/f.md" read-only "$e/b/f.md"
  approve "$P/lnk/b/f.md" "$P/lnk -> $e" "$e/b/f.md" file read-only
  ln_mode "$P/lnk/b/f.md" read-only
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  # bwrap cannot mount on the link: at its target; and from the target the check
  # resolved, not through the link (H)
  [[ " ${OUT[*]} " == *" --ro-bind $e/b/f.md $e/b/f.md "* ]]
  [[ " ${OUT[*]} " != *" $P/lnk/"* ]]
  # retargeted: changed since approved, asked again
  rm "$P/lnk"
  ln -s "$e/b" "$P/lnk"
  mkdir -p "$e/b/b"
  touch "$e/b/b/f.md"
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  implied "$P/lnk/b/f.md" read-only "$e/b/b/f.md"
}

@test "links: a target the view shows, read-only or read-write, implies nothing in any mode (A): the role keeps the access the target has" {
  local e="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$e"
  touch "$e/f.md"
  ln -s "$e/f.md" "$P/l.md"
  local m
  for m in read-write copy copy-on-write seed-only; do
    ln_mode "$P/l.md" "$m"
    pins -- --bind "$P" "$P" --ro-bind "$e" "$e" --bind "$P/l.md" "$P/l.md"
    [ "$RC" -eq 0 ]
    [[ " ${OUT[*]} " != *" --bind $e/f.md "* ]] # no read-write bind of the read-only target
  done
}

@test "links: a link to what the role already sees asks nothing (L4); a dangling one implies nothing" {
  ln -s a "$P/lnk"
  ln_mode "$P/lnk/b/f.md" read-only
  pins -- --bind "$P" "$P" --ro-bind "$P/lnk/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  ln -s nowhere "$P/dang"
  ln_mode "$P/dang/f" read-only
  pins -- --bind "$P" "$P" --ro-bind-try "$P/dang/f" "$P/dang/f"
  [ "$RC" -eq 0 ]
}

@test "links: a source through a link in a store-like directory (the middle of a chain too) is asked about; the role's own store, or own, is not" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/realdir" "$P/rw" "$P/real/b"
  touch "$h/realdir/x.md" "$P/real/b/f.md"
  ln -s realdir "$h/l"
  PINS_PRE="_proj=$P; declare -A _ln_mode=([$P/cfg/x.md]=read-only) _decl_src=([$P/cfg/x.md]=$h/l/x.md)" \
    pins -- --bind "$P" "$P" --ro-bind "$h/l/x.md" "$P/cfg/x.md"
  # shellcheck disable=SC2088 # the message's own ~
  implied "$P/cfg/x.md" read-only "~/store/realdir/x.md"
  # the middle of a chain, lnk -> rw/l2 -> ../real: the target is in the read-only project's view
  ln -s rw/l2 "$P/lnk"
  ln -s ../real "$P/rw/l2"
  PINS_PRE="_proj=$P; declare -A _ln_mode=([$P/x.md]=read-only) _decl_src=([$P/x.md]=$P/lnk/b/f.md)" pins -- --ro-bind "$P" "$P" --bind "$P/rw" "$P/rw" --ro-bind "$P/lnk/b/f.md" "$P/x.md"
  [ "$RC" -eq 0 ]
  # own: the role's own store goes where the link leads, nothing handed over
  ln_mode "$P/lnk/own" own
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/lnk/own"
  [ "$RC" -eq 0 ]
}

@test "links: a hide through a link is refused, the link named, a feature request invited; through a dangling link too (N)" {
  mkdir -p "$P/real/secret"
  ln -s real "$P/lnk"
  ln_mode "$P/lnk/secret" hide
  pins -- --bind "$P" "$P" --tmpfs "$P/lnk/secret"
  [ "$RC" -ne 0 ]
  [[ "$MSG" == *"$P/lnk/secret (a hidden path) is reached through the symbolic link"*"lnk -> real"*"not supported through a symbolic link"*"github.com/pearu/agent-sandbox/issues"* ]]
  ln -s nowhere "$P/dang"
  ln_mode "$P/dang/x" hide
  pins -- --bind "$P" "$P" --tmpfs "$P/dang/x"
  [ "$RC" -ne 0 ]
  [[ "$MSG" == *"not supported through a symbolic link"* ]]
}

@test "links: a declaration whose path is a link but whose source is elsewhere asks nothing (S2): the source goes at the target's path" {
  local e="$BATS_TEST_TMPDIR/ext"
  mkdir -p "$e"
  touch "$e/f.md"
  ln -s "$e/f.md" "$P/l.md"
  ln_mode "$P/l.md" read-only
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/l.md"
  [ "$RC" -eq 0 ]
  [[ " ${OUT[*]} " == *" --ro-bind $ST/f $e/f.md "* ]]
}

@test "links: a link at or above the home or the project is no declaration" {
  local real="$BATS_TEST_TMPDIR/realp"
  mkdir -p "$real/a"
  touch "$real/a/f.md"
  ln -s "$real" "$BATS_TEST_TMPDIR/lp"
  PINS_PRE="_proj=$BATS_TEST_TMPDIR/lp; declare -A _ln_mode=([$BATS_TEST_TMPDIR/lp/a/f.md]=read-only)" \
    pins -- --bind "$BATS_TEST_TMPDIR/lp" "$BATS_TEST_TMPDIR/lp" --ro-bind "$BATS_TEST_TMPDIR/lp/a/f.md" "$BATS_TEST_TMPDIR/lp/a/f.md"
  [ "$RC" -eq 0 ]
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

@test "R1: a read-write declaration's directories are fixed too: the path itself, or a host path elsewhere" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  pins -- --bind "$P" "$P" --bind "$P/a/r" "$P/a/r"
  [ "${PIN[*]}" = "$P/a" ]
  pins -- --bind "$P" "$P" --bind "$BATS_TEST_TMPDIR/elsewhere" "$P/a/b/c"
  same --bind "$P" "$P" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" --bind "$BATS_TEST_TMPDIR/elsewhere" "$P/a/b/c"
}

@test "R1, the key side: ./a/data/ in any mode, with its source elsewhere or not, pins ./a" {
  local big="$BATS_TEST_TMPDIR/home/big"
  mkdir -p "$big" "$P/a/data" "$ST/u" "$ST/w"
  pins -- --bind "$P" "$P" --bind "$big" "$P/a/data" # read-write outside:
  [ "${PIN[*]}" = "$P/a" ]
  pins -- --bind "$P" "$P" --ro-bind "$big" "$P/a/data" # read-only outside:
  [ "${PIN[*]}" = "$P/a" ]
  pins -- --bind "$P" "$P" --bind "$ST/x" "$P/a/data" # own, copy, seed-only: a store
  [ "${PIN[*]}" = "$P/a" ]
  pins -- --bind "$P" "$P" --overlay-src "$big" --overlay "$ST/u" "$ST/w" "$P/a/data" # copy-on-write
  [ "${PIN[*]}" = "$P/a" ]
  pins -- --bind "$P" "$P" --bind "$P/a/data" "$P/a/data" # read-write, the path itself
  [ "${PIN[*]}" = "$P/a" ]
}

@test "R1 and R2 (ey shape 2): valid, nothing refused; the read-write file's key directory, and the read-only key's, fixed" {
  local h="$BATS_TEST_TMPDIR/home"
  mkdir -p "$h/store/roles" "$P/cfg/sub"
  printf 'HOST\n' >"$h/store/roles/x.md"
  printf 'OTHER\n' >"$h/other.md"
  pins -- --bind "$h/store" "$h/store" --bind "$h/other.md" "$h/store/roles/x.md" --bind "$P" "$P" \
    --ro-bind "$h/store/roles/x.md" "$P/cfg/sub/x.md"
  [ "$RC" -eq 0 ]
  [ "$(printf '%s\n' "${PIN[@]}" | sort | paste -sd' ')" = "$(printf '%s\n' "$h/store/roles" "$P/cfg" "$P/cfg/sub" | sort | paste -sd' ')" ]
}

@test "R1 and R2, the source side: a source shown read-write at another path is valid and fixed there (itself and the directories above), never refused: a file, a directory, a part of one" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/sub/deep" "$P/cfg"
  touch "$h/sub/x.md"
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/sub/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  [ "$(printf '%s\n' "${PIN[@]}" | sort | paste -sd' ')" = "$(printf '%s\n' "$P/cfg" "$h/sub" "$h/sub/x.md" | sort | paste -sd' ')" ]
  pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$h/sub" "$P/cfg2" --bind "$h/sub/deep" "$P/alt"
  [ "$RC" -eq 0 ]
  [[ " ${PIN[*]} " == *" $h/sub "* ]] # the directory source itself, where ~/store shows it
  pins -- --bind "$P" "$P" --bind "$h/sub/x.md" "$P/alt.md" --ro-bind "$h/sub/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  [[ "$MSG" != *contradict* ]]
}

@test "R1, the source side, every mode with a host source: a directory or file source a read-write mount shows is self-bound there, the directories above it pinned" {
  local h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$h/real" "$P/x" "$ST/u" "$ST/w"
  touch "$h/x.md"
  local o
  for o in --bind --ro-bind; do
    pins -- --bind "$P" "$P" --bind "$h" "$h" "$o" "$h/real" "$P/x/d"
    [ "$RC" -eq 0 ]
    [[ " ${PIN[*]} " == *" $h/real "* ]]
    pins -- --bind "$P" "$P" --bind "$h" "$h" "$o" "$h/x.md" "$P/x/f.md"
    [ "$RC" -eq 0 ]
    [[ " ${PIN[*]} " == *" $h/x.md "* ]]
  done
  # copy-on-write: the overlay's lower
  pins -- --bind "$P" "$P" --bind "$h" "$h" --overlay-src "$h/real" --overlay "$ST/u" "$ST/w" "$P/x/d"
  [ "$RC" -eq 0 ]
  [[ " ${PIN[*]} " == *" $h/real "* ]]
  # copy and seed-only: a store, its declared source given (_decl_src)
  PINS_PRE="declare -A _decl_src=([$P/x/d]=$h/real)" pins -- --bind "$P" "$P" --bind "$h" "$h" --bind "$ST/x" "$P/x/d"
  [ "$RC" -eq 0 ]
  [[ " ${PIN[*]} " == *" $h/real "* ]]
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

@test "a directory on the way that the host does not have yet is made there first, where bwrap would make it, and pinned at this launch already" {
  pins -- --bind "$P" "$P" --ro-bind "$ST/f" "$P/nodir/sub/f.md" # an outside: source's shape
  same --bind "$P" "$P" --bind "$P/nodir" "$P/nodir" --bind "$P/nodir/sub" "$P/nodir/sub" --ro-bind "$ST/f" "$P/nodir/sub/f.md"
  [ -d "$P/nodir/sub" ]
  [ ! -e "$P/nodir/sub/f.md" ] # the bind's own mount point stays bwrap's to make
  [ -z "$MSG" ]
  # not under a read-only mount (bwrap could not make it there either)
  pins -- --ro-bind "$P" "$P" --ro-bind "$ST/f" "$P/nodir2/sub/f.md"
  same "${IN[@]}"
  [ ! -e "$P/nodir2" ]
}

@test "a join-scoped path declaration's source is a declared source: fixed where a read-write mount shows it; through a link, asked about only where it leads outside the view (copy, seed-only, copy-on-write)" {
  make_harness
  mkdir -p "$H/home/store/real"
  printf 'R\n' >"$H/home/store/real/r"
  local m
  for m in copy seed-only copy-on-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none -- asb --connect '~/store/ = read-write' --connect "./x/d/ = $m join-scoped outside:~/store/real/" claude --version
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2088 # the message's own ~
    [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): "*"~/store/real"* ]] || {
      echo "$m: $output" >&2
      return 1
    }
  done
  # a link to what the role sees already (~/store/realdir, read-write): ordinary content
  mv "$H/home/store/real" "$H/home/store/realdir"
  ln -s realdir "$H/home/store/real"
  for m in copy seed-only copy-on-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none -- asb --connect '~/store/ = read-write' --connect "./x/d/ = $m join-scoped outside:~/store/real/" claude --version
    [ "$status" -eq 0 ] || {
      echo "$m: $output" >&2
      return 1
    }
  done
  # a link to what it does not see: the implied declaration, refused without a terminal
  mkdir -p "$H/home/ext"
  rm "$H/home/store/real"
  ln -s ../ext "$H/home/store/real"
  for m in copy seed-only copy-on-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none -- asb --connect '~/store/ = read-write' --connect "./x/d/ = $m join-scoped outside:~/store/real/" claude --version
    [ "$status" -ne 0 ] || {
      echo "$m launched: $output" >&2
      return 1
    }
    [[ "$output" == *"to ~/ext, which is outside the role's view: it stands for '"*"/proj/x/d = $m outside:~/ext'"* ]]
  done
}

@test "the resolution follows links inside link targets, absolute targets and .., and is bounded" {
  mkdir -p "$P/ro/in" "$P/real/b"
  touch "$P/real/b/f.md"
  ln -s "$P/ro/in/up" "$P/ro/l1" # absolute
  ln -s ../../real "$P/ro/in/up" # relative, with ..
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/l1/b/f.md" "$P/ro/l1/b/f.md"
  [ "$RC" -eq 0 ]                                      # both links in the read-only mount: not replaceable
  [ "${PIN[*]}" = "$P/real $P/real/b $P/real/b/f.md" ] # the real path's directories and the source itself, in the read-write project
  ln -s loop2 "$P/ro/loop1"
  ln -s loop1 "$P/ro/loop2"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/ro/loop1/f" "$P/x/f"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"$P/ro/loop1/f does not resolve (40 symbolic links: a loop?), so it cannot be bound. Refusing to launch"* ]]
}

@test "a link the role cannot replace is not refused: in a read-only mount, the real path behind it, and the source itself, fixed where they show read-write" {
  mkdir -p "$P/ro"
  ln -s ../a "$P/ro/lnk"
  pins -- --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --ro-bind "$P/a/b/f.md" "$P/ro/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  same --bind "$P" "$P" --ro-bind "$P/ro" "$P/ro" --bind "$P/a" "$P/a" --bind "$P/a/b" "$P/a/b" \
    --bind "$P/a/b/f.md" "$P/a/b/f.md" --ro-bind "$P/a/b/f.md" "$P/ro/lnk/b/f.md"
}

@test "a link the role cannot replace is not refused: under copy-on-write; nor in a read-only project; nor under native" {
  mkdir -p "$P/c"
  ln -s ../a "$P/c/lnk"
  pins -- --bind "$P" "$P" --overlay-src "$P/c" --overlay /up /wk "$P/c" --ro-bind "$P/a/b/f.md" "$P/c/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  [ "${PIN[*]}" = "$P/a $P/a/b $P/a/b/f.md" ] # the real path's, and the source itself, in the read-write project
  ln -s a "$P/lnk"
  pins -- --ro-bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  same "${IN[@]}"
  pins native -- --bind "$P" "$P" --ro-bind "$P/a/b/f.md" "$P/lnk/b/f.md"
  [ "$RC" -eq 0 ]
  same "${IN[@]}"
}

@test "hard links: another name of a read-only file in a directory shown read-write is not a contradiction, and nothing searches for it" {
  local e="$BATS_TEST_TMPDIR/ext" h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$e" "$h" "$P/cfg"
  printf 'x\n' >"$e/x.md"
  ln "$e/x.md" "$h/alias.md"
  rm -f "$BATS_TEST_TMPDIR/forks"
  PINS_PRE="$COUNT" pins -- --bind "$P" "$P" --bind "$h" "$h" --ro-bind "$e/x.md" "$P/cfg/x.md"
  [ "$RC" -eq 0 ]
  [ "$(forks find)" -eq 0 ]
  [[ "$MSG" != *"hard link"* ]] # a directory would need a search: no warning
}

@test "final view and the end of the list: a read-only path at its own host path behind a link the role cannot replace, its real path shown by a LATER read-write mount: the pin goes after that mount, at the end" {
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

@test "mutants: a hidden read-only bind gets no pins" {
  pins -- --bind "$P" "$P" --ro-bind "$P/a/f.md" "$P/a/f.md" --bind "$P" "$P"
  same "${IN[@]}"
}

@test "hard links: another name of a read-only file shown through a read-write FILE mount launches with one warning naming both; a different file, or a covered mount, none" {
  local e="$BATS_TEST_TMPDIR/ext" h="$BATS_TEST_TMPDIR/home/store"
  mkdir -p "$e" "$h" "$P/cfg"
  printf 'x\n' >"$e/x.md"
  ln "$e/x.md" "$h/alias.md"
  printf 'o\n' >"$h/other.md"
  rm -f "$BATS_TEST_TMPDIR/forks"
  PINS_PRE="$COUNT" pins -- --bind "$P" "$P" --ro-bind "$e/x.md" "$P/cfg/x.md" --bind "$h/alias.md" "$P/alt.md"
  [ "$RC" -eq 0 ]
  [ "$(grep -c 'hard link' <<<"$MSG")" -eq 1 ]
  [[ "$MSG" == *"connect: warning: $e/x.md (read-only at $P/cfg/x.md) is another name (a hard link) of $h/alias.md, which this launch shows read-write at $P/alt.md: writing one changes the other"* ]]
  [ "$(forks find)" -eq 0 ]
  [ "$(forks stat)" -eq 1 ] # the computation's one stat, no other
  pins -- --bind "$P" "$P" --ro-bind "$e/x.md" "$P/cfg/x.md" --bind "$h/other.md" "$P/alt.md"
  [ "$RC" -eq 0 ]
  [[ "$MSG" != *"hard link"* ]]
  pins -- --bind "$P" "$P" --ro-bind "$e/x.md" "$P/cfg/x.md" --bind "$h/alias.md" "$P/alt.md" --ro-bind "$e/x.md" "$P/alt.md"
  [ "$RC" -eq 0 ]
  [[ "$MSG" != *"hard link"* ]]
}

@test "the shortcut past a source's chain: not through a link loop (the link test)" {
  # a loop: realpath -m gives the path back as it is, so only the link test sees it
  mkdir -p "$BATS_TEST_TMPDIR/lp"
  ln -s l2 "$BATS_TEST_TMPDIR/lp/l1"
  ln -s l1 "$BATS_TEST_TMPDIR/lp/l2"
  pins -- --bind "$P" "$P" --ro-bind "$BATS_TEST_TMPDIR/lp/l1/x" "$P/cfg/x"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"does not resolve (40 symbolic links: a loop?)"* ]]
}

@test "no find, no owner lookup: system binds, a read-only file in the project, and a read-only source shown read-write elsewhere" {
  mkdir -p "$P/cfg"
  PINS_PRE="$COUNT" pins -- --ro-bind /usr /usr --ro-bind /etc /etc --ro-bind-try /opt /opt --bind "$P" "$P" \
    --ro-bind "$P/a/f.md" "$P/a/f.md" --bind "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/alias" --ro-bind "$P/top.md" "$P/cfg/top.md" -- cmd
  [ "$RC" -eq 0 ]
  [ "$(forks find)" -eq 0 ]
  [ "$(forks uid)" -eq 0 ]
}

@test "launches through the engine: an outside: naming the declaration's own host path, directly or through a link, is a declaration at its own path: pinned as without outside:" {
  make_harness
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  mkdir -p "$proj/a/b"
  printf 'HOST\n' >"$proj/a/b/f.md"
  ln -s "$proj" "$H/home/wl"
  local src
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  for src in "$proj" "~/wl"; do
    run_engine AGENT_SANDBOX_NET=none -- asb --connect "./a/b/f.md = read-only outside:$src/a/b/f.md" claude --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./a, ./a/b"* ]] || {
      echo "read-only outside:$src: $output" >&2
      return 1
    }
    run_engine AGENT_SANDBOX_NET=none -- asb --connect "./a/b/ = copy outside:$src/a/b/" claude --version
    [ "$status" -eq 0 ] || {
      echo "$src: $output" >&2
      false
    }
    [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./a"* ]] || {
      echo "copy outside:$src: $output" >&2
      return 1
    }
  done
}

@test "R1 through the engine: a channel whose source the profile relocates is a declared source -- fixed where a read-write mount shows it; through a link outside the view, the implied declaration is refused without a terminal, in every mode" {
  make_harness
  mkdir -p "$H/profiles/relo"
  # (without the probe's `links = yes` for its channels: added below)
  grep -v '^profile_channel_links=' "$REPO_ROOT/tests/helpers/probe-profile.sh" >"$H/profiles/relo/profile.sh"
  # shellcheck disable=SC2016 # a line of the profile, for its own shell
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$H/profiles/relo/profile.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$H/bin/probe"
  chmod +x "$H/bin/probe"
  mkdir -p "$H/home/alt/extra" "$H/home/.probe/extra"
  local m
  for m in copy copy-on-write seed-only read-only read-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none AGENT_SANDBOX_PROFILE_DIR="$H/profiles" -- asb --profile relo \
      --connect '~/alt/ = read-write' --connect "extra = $m" --exec true
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2088 # the message's own ~
    [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): "*"~/alt/extra"* ]] || {
      echo "$m: $output" >&2
      return 1
    }
  done
  mkdir -p "$H/home/ext"
  rm -r "$H/home/alt/extra"
  ln -s ../ext "$H/home/alt/extra"
  for m in copy copy-on-write seed-only read-only read-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none AGENT_SANDBOX_PROFILE_DIR="$H/profiles" -- asb --profile relo \
      --connect '~/alt/ = read-write' --connect "extra = $m" --exec true
    [ "$status" -ne 0 ] || {
      echo "$m launched: $output" >&2
      return 1
    }
    # the probe profile's channel has no `links = yes`: through a link it is refused (C)
    [[ "$output" == *"(the extra channel) is reached through the symbolic link ~/alt/extra -> ../ext, and this location is not supported through a symbolic link"*"github.com/pearu/agent-sandbox/issues"* ]]
  done
  # with `links = yes` it is the implied declaration, refused without a terminal
  printf '%s\n' 'profile_channel_links=(extra)' >>"$H/profiles/relo/profile.sh"
  for m in copy read-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_engine AGENT_SANDBOX_NET=none AGENT_SANDBOX_PROFILE_DIR="$H/profiles" -- asb --profile relo \
      --connect '~/alt/ = read-write' --connect "extra = $m" --exec true
    [ "$status" -ne 0 ]
    [[ "$output" == *"to ~/ext, which is outside the role's view: it stands for '~/.probe/extra = $m outside:~/ext'"* ]]
  done
}

@test "R1 through the engine: a declared path's directory is fixed in every mode, its source elsewhere or not" {
  make_harness
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  mkdir -p "$proj/a/data" "$H/home/big"
  printf 'HOST\n' >"$proj/a/data/f"
  printf 'BIG\n' >"$H/home/big/f"
  local m
  for m in "read-only outside:~/big/" "read-write outside:~/big/" "copy outside:~/big/" "copy-on-write outside:~/big/" \
    "seed-only outside:~/big/" read-only read-write own copy; do
    run_engine AGENT_SANDBOX_NET=none -- asb --connect "./a/data/ = $m" claude --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./a"* ]] || {
      echo "$m: $output" >&2
      return 1
    }
  done
}

@test "round 7, B1: a plain launch's and the Supervisor's option lists: no find, a bounded number of processes" {
  model roles
  mkdir -p "$H/plain"
  RUN_CWD="$H/plain" run_engine AGENT_SANDBOX_NET=none -- asb claude --version
  [ "$status" -eq 0 ]
  local -a plain=("${ARGV[@]}")
  run_engine AGENT_SANDBOX_NET=none -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  local -a sup=("${ARGV[@]}")
  rm -f "$BATS_TEST_TMPDIR/forks"
  PINS_PRE="$COUNT" pins -- "${plain[@]}"
  [ "$RC" -eq 0 ]
  echo "plain: $(sort "$BATS_TEST_TMPDIR/forks" 2>/dev/null | uniq -c | paste -sd" ")" >&2
  [ "$(forks find)" -eq 0 ]
  [ "$(forks all)" -le 3 ]
  rm -f "$BATS_TEST_TMPDIR/forks"
  PINS_PRE="$COUNT" pins -- "${sup[@]}"
  [ "$RC" -eq 0 ]
  echo "supervisor: $(sort "$BATS_TEST_TMPDIR/forks" 2>/dev/null | uniq -c | paste -sd" ")" >&2
  [ "$(forks find)" -eq 0 ]
  [ "$(forks all)" -le 4 ]
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

@test "the pins read the engine's one bwrap table (_as_bwrap_options, checked against bwrap --help in tests/unit/init.bats): an option it lacks refuses, its qualify rows are the groups" {
  # an option taken out of the table: the pins cannot read the list, and refuse
  # shellcheck disable=SC2016 # code for the computation's shell
  PINS_PRE='_as_bwrap_table="$(grep -v "^--level-prefix " <<<"$_as_bwrap_table")"' \
    pins -- --bind "$P" "$P" --level-prefix --ro-bind "$P/a/b/f.md" "$P/a/b/f.md"
  [ "$RC" -eq 1 ]
  [[ "$MSG" == *"the pins cannot read the bwrap option '--level-prefix'"* ]]
  # the groups: what the table marks qualify, exactly
  local out
  out="$(bash -c 'source "$1"; declare -A n q; _as_bwrap_nargs n q; printf "%s\n" "${!q[@]}" | sort | paste -sd" "' _ "$ENGINE")"
  [ "$out" = "--overlay-src --perms --size" ]
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

@test "a launch through a link: to what the role sees, launched with the mount at the target; outside the view, refused once without a terminal, bwrap never run; approved by --trust, launched" {
  make_harness
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  mkdir -p "$proj/real/b" "$H/ext/b"
  touch "$proj/real/b/f.md" "$H/ext/b/f.md"
  ln -s real "$proj/lnk"
  run_engine AGENT_SANDBOX_NET=none -- asb --connect './lnk/b/f.md = read-only' claude --version
  [ "$status" -eq 0 ]
  # the target is in the role's view: ordinary content, no mount added for it (A)
  run argv_has --ro-bind "$proj/real/b/f.md" "$proj/real/b/f.md"
  [ "$status" -ne 0 ]
  rm "$proj/lnk"
  ln -s "$H/ext" "$proj/lnk"
  run_engine AGENT_SANDBOX_NET=none -- asb --connect './lnk/b/f.md = read-only' claude --version
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c "is reached through a symbolic link ($proj/lnk -> $H/ext)")" -eq 1 ]
  [ ! -s "$H/argv" ]
  run_engine AGENT_SANDBOX_NET=none -- asb --trust <<<$'y\ny' # one question per link
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'approve this link for')" -eq 2 ]
  [[ "$output" == *"/proj/lnk/b/f.md = read-only outside:"*"/ext/b/f.md"* ]]
  [[ "$output" == *"/proj/lnk = read-write outside:"*"/ext"* ]] # the link itself, in the project: the scan's
  run_engine AGENT_SANDBOX_NET=none -- asb --connect './lnk/b/f.md = read-only' claude --version
  [ "$status" -eq 0 ]
  argv_has --ro-bind "$(cd "$H/ext" && pwd -P)/b/f.md" "$(cd "$H/ext" && pwd -P)/b/f.md"
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
  [[ "$AOUT" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./a, ./a/b"* ]]
}

@test "the keeper's record of single-file mounts reads a pinned directory as read-write: the Supervisor's purpose file, on its real option list (#389)" {
  model roles
  run_engine AGENT_SANDBOX_NET=none -- asb --role supervisor claude --version
  [ "$status" -eq 0 ]
  argv_has --bind "$PROJ/.asb/roles" "$PROJ/.asb/roles" # the pin sits between
  local -a opts=()
  local w
  for w in "${ARGV[@]}"; do
    [[ "$w" == -- ]] && break
    opts+=("$w")
  done
  local rec
  rec="$(bash -c 'source "$1"; shift; _as_keeper_binds "$@" | tr "\0" "|"' _ "$ENGINE" "${opts[@]}")"
  [[ "$rec" == *"rw|ro|y|$PROJ/.asb/roles/supervisor.md|"* ]]
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
