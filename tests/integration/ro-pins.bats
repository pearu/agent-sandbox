#!/usr/bin/env bats
# The read-only binds' parents, pinned, under the REAL bwrap: each directory between a
# read-write root and a read-only bind is a mount point of its own, so the role cannot
# rename or remove it and so cannot move the read-only path away -- on the host too -- or
# put a file of its own at that path for the next launch. tests/unit/ro-pins.bats pins the
# argv; this checks what it means once mounted.

# shellcheck disable=SC2016 # the --exec scripts expand inside the sandbox, not here

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v python3 >/dev/null || skip "python3 not installed"
  make_integration <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  BASE=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state")
  W="$(cd "$IWORK" && pwd -P)"
  mkdir -p "$W/a/b"
  printf 'HOST\n' >"$W/a/b/f.md"
  printf 'other\n' >"$W/a/b/other"
  # ops.py KEY:OP:ARG... -- each syscall the role makes, its result (ok, or the errno's
  # name) appended to the report as KEY=RESULT.
  cat >"$W/ops.py" <<'PY'
import errno, os, sys
def write(p, t):
    with open(p, "w") as f:
        f.write(t)
OPS = {"rename": os.rename, "rmdir": os.rmdir, "link": os.link, "unlink": os.unlink, "write": write,
       "mkdir": os.mkdir}
with open("report", "a") as r:
    for spec in sys.argv[1:]:
        key, op, *a = spec.split(":")
        try:
            OPS[op](*a)
            res = "ok"
        except OSError as e:
            res = errno.errorcode[e.errno]
        r.write("%s=%s\n" % (key, res))
PY
  RO=(--connect './a/b/f.md = read-only')
  BGS=()
}

teardown() {
  local p f spid
  : >"$IWORK/release.all" 2>/dev/null
  for p in ${BGS[@]+"${BGS[@]}"}; do kill "$p" 2>/dev/null; done
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# ref_engine -- REF: a copy of the engine without the pin step, beside a copy of its
# components (join.py).
ref_engine() {
  local d="$BATS_TEST_TMPDIR/ref"
  mkdir -p "$d"
  cp -r "$(dirname "$ENGINE")/components" "$d/"
  sed 's/^  _as_ro_pins _bwrap_opts _pinned_opts _pinned || return 1$/  : no pins/' "$ENGINE" >"$d/agent-sandbox"
  chmod +x "$d/agent-sandbox"
  [ "$(grep -c '^  : no pins$' "$d/agent-sandbox")" -eq 1 ]
  REF="$d/agent-sandbox"
}

# roles_project -- `asb --init roles` in the project, approved, with a `gh` channel in the
# probe profile, as the model connects it.
roles_project() {
  sed 's|^  "extra\tdir:$HOME/.probe/extra"$|&\n  "gh\tdir:$HOME/.config/gh"|' \
    "$REPO_ROOT/tests/helpers/probe-profile.sh" >"$IPROFILES/probe/profile.sh"
  grep -q '"gh' "$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/.config/gh"
  rm -rf "$W/a" "$W/ops.py"
  git -C "$W" init -q
  git -C "$W" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init
  run_sandboxed "${BASE[@]}" -- --init roles
  [ "$status" -eq 0 ]
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PROFILE_DIR="$4" "${@:5}" --trust --profile probe 2>&1' \
    _ "$W" "$IHOME" "$I/bin:/usr/bin:/bin" "$IPROFILES" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
}

# b1 MODE -- ./x/a/ declared MODE between the read-write project and ./x/a/b/f.md read-only:
# the role's `mv x` is refused, the host unchanged, the next launch reads the host's file.
b1() {
  mkdir -p "$W/x/a/b"
  printf 'HOST\n' >"$W/x/a/b/f.md"
  local -a decl=(--connect "./x/a/ = $1" --connect './x/a/b/f.md = read-only')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    python3 ops.py mv_x:rename:x:x.moved
    mkdir -p x/a/b 2>/dev/null; echo ROLE >x/a/b/f.md 2>/dev/null; true'
  [ "$status" -eq 0 ]
  [ "$(report mv_x)" = EBUSY ]
  [ ! -e "$W/x.moved" ]
  [ "$(cat "$W/x/a/b/f.md")" = HOST ]
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo "seen=$(cat x/a/b/f.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

# own_case MODE file|dir -- ./x/a/f (or ./x/a/d/) declared MODE, nothing read-only beneath
# ./x: the role's renames of x and x/a are refused, the host's original keeps its inode and
# text, and the next launch shows the role no host original at x.moved.
own_case() {
  local f decl ino
  if [[ "$2" == file ]]; then
    mkdir -p "$W/x/a"
    f=x/a/f decl="./x/a/f = $1"
  else
    mkdir -p "$W/x/a/d"
    f=x/a/d/g decl="./x/a/d/ = $1"
  fi
  printf 'HOST\n' >"$W/$f"
  ino="$(stat -c %i "$W/$f")"
  run_sandboxed "${BASE[@]}" -- --connect "$decl" --profile probe --exec bash -c '
    python3 ops.py mv_x:rename:x:x.moved mv_a:rename:x/a:x/a.moved
    echo ROLE >'"$f"' 2>/dev/null; true'
  [ "$status" -eq 0 ]
  [ "$(report mv_x)" = EBUSY ]
  [ "$(report mv_a)" = EBUSY ]
  [ ! -e "$W/x.moved" ]
  [ "$(cat "$W/$f")" = HOST ]
  [ "$(stat -c %i "$W/$f")" = "$ino" ]
  run_sandboxed "${BASE[@]}" -- --connect "$decl" --profile probe --exec bash -c '
    echo "moved=$([ -e x.moved ] && echo yes || echo no)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report moved)" = no ]
  [ "$(cat "$W/$f")" = HOST ]
}

# behind_link DECL... -- ro/lnk or c/lnk -> ../real, real/f.md HOST in the read-write project:
# the launch is not refused, the role's rename of real is EBUSY, the next launch reads HOST.
behind_link() {
  run_sandboxed "${BASE[@]}" -- "$@" --profile probe --exec bash -c '
    python3 ops.py mv:rename:real:real.moved
    mkdir -p real 2>/dev/null; echo ROLE >real/f.md 2>/dev/null; true'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
  [ "$(cat "$W/real/f.md")" = HOST ]
  [ ! -e "$W/real.moved" ]
}

# part_in_place MODE -- ./ref/ read-only from ~/src/libfoo/, ./ref/build/ MODE in place, and
# ./build/ read-write from ~/src/libfoo/build/: it launches; what the role writes in
# ref/build stays its own, what it writes in build reaches the host.
part_in_place() {
  mkdir -p "$IHOME/src/libfoo/build" "$W/ref"
  printf 'SRC\n' >"$IHOME/src/libfoo/a.c"
  printf 'OBJ\n' >"$IHOME/src/libfoo/build/o"
  local m="$1"
  [[ "$m" == own ]] || m="$m outside:~/src/libfoo/build/"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './ref/ = read-only outside:~/src/libfoo/' --connect "./ref/build/ = $m" \
    --connect './build/ = read-write outside:~/src/libfoo/build/' --profile probe --exec \
    python3 ops.py src:write:ref/a.c:R mine:write:ref/build/mine:M host:write:build/host:H
  [ "$status" -eq 0 ]
  [ "$(report src)" = EROFS ]
  [ "$(report mine)" = ok ]
  [ "$(report host)" = ok ]
  [ ! -e "$IHOME/src/libfoo/build/mine" ]
  [ -e "$IHOME/src/libfoo/build/host" ]
  [ "$(cat "$IHOME/src/libfoo/build/o")" = OBJ ]
  # the mirror: in place, not read-write elsewhere
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './ref/ = read-only outside:~/src/libfoo/' --connect "./ref/build/ = $m" \
    --profile probe --exec true
  [ "$status" -eq 0 ]
}

@test "the role's rename and removal of each pinned directory are refused (EBUSY), and the host is unchanged" {
  run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec python3 ops.py \
    mv_a:rename:a:a.moved mv_b:rename:a/b:a/b.moved rmdir_a:rmdir:a rmdir_b:rmdir:a/b
  [ "$status" -eq 0 ]
  [ "$(report mv_a)" = EBUSY ]
  [ "$(report mv_b)" = EBUSY ]
  [ "$(report rmdir_a)" = EBUSY ]
  [ "$(report rmdir_b)" = EBUSY ]
  [ "$(cat "$W/a/b/f.md")" = HOST ]
  [ ! -e "$W/a.moved" ]
  [ ! -e "$W/a/b.moved" ]
}

@test "the control: without the pins, the same rename moves the directory on the host" {
  ref_engine
  ENGINE="$REF" run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec python3 ops.py mv_a:rename:a:a.moved
  [ "$status" -eq 0 ]
  [ "$(report mv_a)" = ok ]
  [ -f "$W/a.moved/b/f.md" ]
}

@test "B1: a read-write declaration between the project and the read-only file does not stop the pins" {
  b1 read-write
}

@test "B1: an own declaration between" {
  b1 own
}

@test "B1: a copy declaration between" {
  b1 copy
}

@test "B1: a copy-on-write declaration between" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  b1 copy-on-write
}

@test "the role's own: an own file's parents are pinned, the host's original stays out of reach" {
  own_case own file
}

@test "the role's own: an own directory" {
  own_case own dir
}

@test "the role's own: a copy file" {
  own_case copy file
}

@test "the role's own: a copy directory" {
  own_case copy dir
}

@test "the role's own: a copy-on-write file (a copy)" {
  own_case copy-on-write file
}

@test "the role's own: a copy-on-write directory (an overlay)" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  own_case copy-on-write dir
}

@test "the role's own: a seed-only file" {
  own_case seed-only file
}

@test "the role's own: a seed-only directory" {
  own_case seed-only dir
}

@test "a read-only declaration through a link the role can replace is refused before anything runs; the resolved path launches" {
  mkdir -p "$W/x/real"
  printf 'HOST\n' >"$W/x/real/f.md"
  ln -s real "$W/x/lnk"
  run_sandboxed "${BASE[@]}" -- --connect './x/lnk/f.md = read-only' --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $W/x/lnk, a symbolic link in a directory the role can write"* ]]
  [[ "$output" == *"Declare the path it resolves to instead: $W/x/real/f.md. Refusing to launch"* ]]
  [ -z "$(report ran)" ]
  run_sandboxed "${BASE[@]}" -- --connect './x/real/f.md = read-only' --profile probe --exec python3 ops.py mv:rename:x/real:x/real.moved
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
}

@test "a link in a read-only directory, its target read-write: not refused, the real path pinned" {
  mkdir -p "$W/ro" "$W/real"
  printf 'HOST\n' >"$W/real/f.md"
  ln -s ../real "$W/ro/lnk"
  behind_link --connect './ro/ = read-only' --connect './ro/lnk/f.md = read-only'
  run_sandboxed "${BASE[@]}" -- --connect './ro/ = read-only' --connect './ro/lnk/f.md = read-only' \
    --profile probe --exec bash -c 'echo "seen=$(cat ro/lnk/f.md)" >>report'
  [ "$(report seen)" = HOST ]
}

@test "a link under copy-on-write, its target read-write: not refused, the real path pinned" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  mkdir -p "$W/c" "$W/real"
  printf 'HOST\n' >"$W/real/f.md"
  ln -s ../real "$W/c/lnk"
  behind_link --connect './c/ = copy-on-write' --connect './c/lnk/f.md = read-only'
}

@test "B1: a replaceable link in the middle of the source's resolution is refused, naming it (read-only project, ./rw/ read-write)" {
  mkdir -p "$W/rw" "$W/real/b"
  printf 'HOST\n' >"$W/real/b/f.md"
  ln -s rw/l2 "$W/lnk"
  ln -s ../real "$W/rw/l2"
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' --connect './rw/ = read-write' \
    --connect './lnk/b/f.md = read-only' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $W/rw/l2, a symbolic link in a directory the role can write"* ]]
  [[ "$output" == *"Declare the path it resolves to instead: $W/real/b/f.md. Refusing to launch"* ]]
}

@test "B1: an outside: source through a replaceable link in a read-write store is refused" {
  mkdir -p "$IHOME/store/realdir" "$W/cfg"
  printf 'HOST\n' >"$IHOME/store/realdir/x.md"
  ln -s realdir "$IHOME/store/l"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect './cfg/x.md = read-only outside:~/store/l/x.md' \
    --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/store/l, a symbolic link in a directory the role can write"* ]]
}

@test "B2: a link on the destination side only, the source elsewhere, is not refused; replacing it binds the same source at the role's directory" {
  mkdir -p "$W/real/b" "$I/ext"
  printf 'EXT\n' >"$I/ext/f.md"
  ln -s real "$W/lnk"
  local -a decl=(--connect "./lnk/b/f.md = read-only outside:$I/ext/f.md")
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    echo "seen1=$(cat lnk/b/f.md)" >>report
    rm lnk && mkdir -p lnk/b && (echo ROLE >lnk/b/f.md) 2>/dev/null; true'
  [ "$status" -eq 0 ]
  [ "$(report seen1)" = EXT ]
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo "seen2=$(cat lnk/b/f.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen2)" = EXT ]
}

@test "a link in a read-write host directory the role cannot write (root's) is not refused" {
  [[ -L /usr/share/groff/current && -f /usr/share/groff/current/tmac/an.tmac ]] || skip "no /usr/share/groff/current on this host"
  [[ -O /usr/share/groff || -w /usr/share/groff ]] && skip "/usr/share/groff is writable here"
  run_sandboxed "${BASE[@]}" -- --connect '/usr/share/groff/ = read-write' \
    --connect './an.tmac = read-only outside:/usr/share/groff/current/tmac/an.tmac' --profile probe --exec bash -c '
    python3 ops.py mv:rename:/usr/share/groff/current:/usr/share/groff/x'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EACCES ]
}

@test "a hide nested in the read-write base: its parents pinned, the hidden host content not reachable at the next launch" {
  printf '[agent]\nbase = ~/.probe\nhide = docs/a/hidden\n' >"$IPROFILES/probe/agent-sandbox"
  mkdir -p "$IHOME/.probe/docs/a/hidden"
  printf 'SECRET\n' >"$IHOME/.probe/docs/a/hidden/s.txt"
  run_sandboxed "${BASE[@]}" -- --profile probe --exec bash -c '
    echo "hidden=$(cat ~/.probe/docs/a/hidden/s.txt 2>/dev/null)" >>report
    python3 ops.py mv:rename:"$HOME/.probe/docs/a":"$HOME/.probe/docs/a.moved"'
  [ "$status" -eq 0 ]
  [ "$(report hidden)" = "" ]
  [ "$(report mv)" = EBUSY ]
  [ ! -e "$IHOME/.probe/docs/a.moved" ]
  run_sandboxed "${BASE[@]}" -- --profile probe --exec bash -c 'echo "seen=$(cat ~/.probe/docs/a.moved/hidden/s.txt ~/.probe/docs/a/hidden/s.txt 2>/dev/null)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = "" ]
}

@test "the role's own paths through a link the role can replace, covering a host file it sees, are refused: own, copy, copy-on-write, seed-only" {
  mkdir -p "$W/x/real/a"
  printf 'HOST\n' >"$W/x/real/a/f"
  ln -s real "$W/x/lnk"
  local mode
  for mode in own copy copy-on-write seed-only; do
    run_sandboxed "${BASE[@]}" -- --connect "./x/lnk/a/f = $mode" --profile probe --exec bash -c 'echo ran=yes >>report'
    [ "$status" -ne 0 ]
    [[ "$output" == *"$W/x/lnk/a/f goes through $W/x/lnk, a symbolic link in a directory the role can write, and covers $W/x/real/a/f, which the role sees"* ]]
    [ -z "$(report ran)" ]
  done
  [ "$(cat "$W/x/real/a/f")" = HOST ]
}

@test "an own path through a link the role cannot replace (in a read-only directory): not refused, the real path pinned" {
  mkdir -p "$W/ro" "$W/real/a"
  printf 'HOST\n' >"$W/real/a/f"
  ln -s ../real "$W/ro/lnk"
  run_sandboxed "${BASE[@]}" -- --connect './ro/ = read-only' --connect './ro/lnk/a/f = own' --profile probe --exec \
    python3 ops.py mv:rename:real:real.moved
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
  [ "$(cat "$W/real/a/f")" = HOST ]
}

@test "a destination-side link the role can replace: refused where the bind covers a host file the role sees, not where nothing is there" {
  mkdir -p "$W/real/b" "$I/ext"
  printf 'EXT\n' >"$I/ext/f.md"
  printf 'PROJ\n' >"$W/real/b/f.md"
  ln -s real "$W/lnk"
  run_sandboxed "${BASE[@]}" -- --connect "./lnk/b/f.md = read-only outside:$I/ext/f.md" --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"$W/lnk/b/f.md goes through $W/lnk, a symbolic link in a directory the role can write, and covers $W/real/b/f.md, which the role sees"* ]]
  run_sandboxed "${BASE[@]}" -- --connect "./lnk/b/new.md = read-only outside:$I/ext/f.md" --profile probe --exec bash -c 'echo "seen=$(cat lnk/b/new.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = EXT ]
}

@test "a read-only source another declaration shows read-write is a contradiction: refused; declared read-only at its own path too, it launches and the write fails at both paths" {
  mkdir -p "$IHOME/store/roles" "$W/cfg"
  printf 'HOST\n' >"$IHOME/store/roles/x.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  local -a decl=(--connect '~/store/ = read-write' --connect './cfg/x.md = read-only outside:~/store/roles/x.md')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"'./cfg/x.md = read-only' binds $IHOME/store/roles/x.md read-only at $W/cfg/x.md, and '~/store/ = read-write' shows it read-write at $IHOME/store/roles/x.md: the two contradict"* ]]
  [ -z "$(report ran)" ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --connect '~/store/roles/x.md = read-only' --profile probe --exec \
    python3 ops.py inplace:write:"$IHOME/store/roles/x.md":ROLE declared:write:cfg/x.md:ROLE \
    beside:write:"$IHOME/store/roles/new":N mv:rename:"$IHOME/store/roles":"$IHOME/store/roles.moved"
  [ "$status" -eq 0 ]
  [ "$(report inplace)" = EROFS ]
  [ "$(report declared)" = EROFS ]
  [ "$(report beside)" = ok ]
  [ "$(report mv)" = EBUSY ]
  [ "$(cat "$IHOME/store/roles/x.md")" = HOST ]
}

@test "final view: a read-write mount bound AFTER the read-only path (deeper) that shows its source is a contradiction (B1); with a link there, the link refuses" {
  mkdir -p "$IHOME/a/b/c/store/sub" "$IHOME/a/b/c/store/realdir"
  printf 'HOST\n' >"$IHOME/a/b/c/store/sub/x.md"
  printf 'HOST\n' >"$IHOME/a/b/c/store/realdir/x.md"
  ln -s realdir "$IHOME/a/b/c/store/l"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/a/b/c/store/ = read-write' --connect './x.md = read-only outside:~/a/b/c/store/sub/x.md' \
    --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"shows it read-write at $IHOME/a/b/c/store/sub/x.md: the two contradict"* ]]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/a/b/c/store/ = read-write' --connect './x.md = read-only outside:~/a/b/c/store/l/x.md' \
    --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/a/b/c/store/l, a symbolic link in a directory the role can write"* ]]
}

@test "final view: a deeper read-only declaration bound AFTER makes the link's directory read-only: not refused (B2)" {
  mkdir -p "$IHOME/store/p/q/r/links" "$IHOME/store/realdir" "$W/a/b"
  printf 'HOST\n' >"$IHOME/store/realdir/x.md"
  ln -s ../../../../realdir "$IHOME/store/p/q/r/links/l"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect '~/store/p/q/r/links/ = read-only' \
    --connect '~/store/realdir/ = read-only' --connect './a/b/x.md = read-only outside:~/store/p/q/r/links/l/x.md' \
    --profile probe --exec bash -c 'echo "seen=$(cat a/b/x.md)" >>report
      python3 ops.py mvlinks:rename:"$HOME/store/p/q/r/links":"$HOME/store/p/q/r/links.x" rmlink:unlink:"$HOME/store/p/q/r/links/l"'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
  [ "$(report mvlinks)" = EBUSY ]
  [ "$(report rmlink)" = EROFS ]
}

@test "a link in a read-only project is not refused; nor under --preset native" {
  mkdir -p "$W/real"
  printf 'HOST\n' >"$W/real/f.md"
  ln -s real "$W/lnk"
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' --connect './lnk/f.md = read-only' \
    --profile probe --exec bash -c 'echo "seen=$(cat lnk/f.md)" >&2' # the project is read-only: no report
  [ "$status" -eq 0 ]
  [[ "$output" == *"seen=HOST"* ]]
  TEST_PRESET='' run_sandboxed "${BASE[@]}" -- --preset native --connect './lnk/f.md = read-only' \
    --profile probe --exec bash -c 'echo "seen=$(cat lnk/f.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

@test "B2: a pin beside a copy-on-write directory launches (never between --overlay-src and --overlay)" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  mkdir -p "$W/a/cow" "$W/a/z"
  printf 'HOST\n' >"$W/a/z/f.md"
  run_sandboxed "${BASE[@]}" -- --connect './a/cow/ = copy-on-write' --connect './a/z/f.md = read-only' \
    --profile probe --exec python3 ops.py mv_a:rename:a:a.moved cow:write:a/cow/w:W
  [ "$status" -eq 0 ]
  [ "$(report mv_a)" = EBUSY ]
  [ "$(report cow)" = ok ]
  [ ! -e "$W/a/cow/w" ] # the overlay's, not the project's
}

@test "round 6, B1: a read-write FILE declaration of the read-only source, or of a file inside a read-only directory source, is a contradiction: refused" {
  mkdir -p "$IHOME/store/d" "$W/cfg"
  printf 'HOST\n' >"$IHOME/store/x.md"
  printf 'HOST\n' >"$IHOME/store/d/y.md"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/x.md = read-write' --connect './cfg/x.md = read-only outside:~/store/x.md' \
    --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"'./cfg/x.md = read-only' binds $IHOME/store/x.md read-only at $W/cfg/x.md, and '~/store/x.md = read-write' shows it read-write at $IHOME/store/x.md: the two contradict"* ]]
  [ -z "$(report ran)" ]
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/d/y.md = read-write' --connect './cfg/ = read-only outside:~/store/d/' \
    --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"shows $IHOME/store/d/y.md, inside it, read-write at $IHOME/store/d/y.md"* ]]
  [ -z "$(report ran)" ]
  [ "$(cat "$IHOME/store/x.md")" = HOST ]
}

@test "round 6, B2: under a linked \$HOME the read-write channel's source is compared resolved: a read-only source in it is a contradiction" {
  ln -s home "$I/hlink"
  printf 'HOST\n' >"$IHOME/.probe/extra/n.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" HOME="$I/hlink" -- --connect './cfg/n.md = read-only outside:~/.probe/extra/n.md' \
    --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"binds $IHOME/.probe/extra/n.md read-only at $W/cfg/n.md"*"the two contradict"* ]]
  [ -z "$(report ran)" ]
}

@test "round 6, B2: under a linked \$HOME a replaceable link in a read-write channel is refused" {
  ln -s home "$I/hlink"
  mkdir -p "$IHOME/.probe/extra/realdir"
  printf 'HOST\n' >"$IHOME/.probe/extra/realdir/n.md"
  ln -s realdir "$IHOME/.probe/extra/l"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" HOME="$I/hlink" -- --connect './cfg/n.md = read-only outside:~/.probe/extra/l/n.md' \
    --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/.probe/extra/l, a symbolic link in a directory the role can write"* ]]
  [ -z "$(report ran)" ]
}

@test "round 6, B3: a part read-write at its own place, shown read-write at a second path too, launches: project = read-only with ./out/ and an alias of it" {
  mkdir -p "$W/out" "$IHOME/out-alias"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' --connect './out/ = read-write' \
    --connect "~/out-alias/ = read-write outside:$W/out/" --profile probe --exec bash -c '
      echo A >out/a && echo B >"$HOME/out-alias/b" && echo "wrote=yes" >&2' # the project is read-only: no report
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote=yes"* ]]
  [ "$(cat "$W/out/a")" = A ]
  [ "$(cat "$W/out/b")" = B ]
  # without ./out/ read-write in place it is one, and the project is named as declared
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' \
    --connect "~/out-alias/ = read-write outside:$W/out/" --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"'project = read-only' binds $W read-only at $W, and '~/out-alias/ = read-write' shows $W/out, inside it, read-write at $IHOME/out-alias: the two contradict"* ]]
}

@test "round 6, B3: a read-only source whose build/ is read-write in place and at ./build/ launches; without it in place it is refused" {
  mkdir -p "$IHOME/src/libfoo/build" "$W/ref"
  printf 'SRC\n' >"$IHOME/src/libfoo/a.c"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a decl=(--connect './ref/ = read-only outside:~/src/libfoo/' --connect './build/ = read-write outside:~/src/libfoo/build/')
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --connect './ref/build/ = read-write outside:~/src/libfoo/build/' \
    --profile probe --exec python3 ops.py src:write:ref/a.c:R b1:write:ref/build/o1:1 b2:write:build/o2:2
  [ "$status" -eq 0 ]
  [ "$(report src)" = EROFS ]
  [ "$(report b1)" = ok ]
  [ "$(report b2)" = ok ]
  [ "$(cat "$IHOME/src/libfoo/a.c")" = SRC ]
  [ -e "$IHOME/src/libfoo/build/o1" ]
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"shows $IHOME/src/libfoo/build, inside it, read-write at $W/build: the two contradict"* ]]
}

@test "round 6, B5: another name of the read-only file (a hard link) in a read-write directory is a contradiction: refused, naming it" {
  mkdir -p "$I/ext" "$IHOME/store" "$W/cfg"
  printf 'HOST\n' >"$I/ext/x.md"
  ln "$I/ext/x.md" "$IHOME/store/alias.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect "./cfg/x.md = read-only outside:$I/ext/x.md" \
    --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"shows it, as $IHOME/store/alias.md (another name of the same file), read-write at $IHOME/store/alias.md"* ]]
  [ -z "$(report ran)" ]
  rm "$IHOME/store/alias.md" # one name again: it launches
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect "./cfg/x.md = read-only outside:$I/ext/x.md" \
    --profile probe --exec bash -c 'echo "seen=$(cat cfg/x.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

@test "round 7, B2: another name of the read-only file declared read-write as a single file is a contradiction: refused, naming it" {
  mkdir -p "$I/ext" "$IHOME/store" "$W/cfg"
  printf 'HOST\n' >"$I/ext/x.md"
  ln "$I/ext/x.md" "$IHOME/store/alias.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect "./cfg/x.md = read-only outside:$I/ext/x.md" \
    --connect './alt.md = read-write outside:~/store/alias.md' --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"shows it, as $IHOME/store/alias.md (another name of the same file), read-write at $W/alt.md"* ]]
  [ -z "$(report ran)" ]
  [ "$(cat "$I/ext/x.md")" = HOST ]
}

@test "round 7, smaller 1: a part own in place inside a read-only directory, read-write elsewhere, launches" {
  part_in_place own
}

@test "round 7, smaller 1: a part copy in place" {
  part_in_place copy
}

@test "round 7, smaller 1: a part copy-on-write in place (its overlay's lower the host directory: the role's writes stay in its layer)" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  part_in_place copy-on-write
}

@test "the role cannot get a file of its own to the protected path, and the next launch reads the host's" {
  run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec bash -c '
    python3 ops.py mv_b:rename:a/b:a/b2 write:write:a/b/f.md:ROLE unlink:unlink:a/b/f.md \
      mine:write:a/b/mine:ROLE over:rename:a/b/mine:a/b/f.md ln:link:a/b/mine:a/b/f.md
    mkdir -p x/b && echo ROLE >x/b/f.md && python3 ops.py swap:rename:x:a'
  [ "$status" -eq 0 ]
  [ "$(report mv_b)" = EBUSY ]
  [ "$(report write)" = EROFS ]
  [ "$(report unlink)" = EBUSY ]
  [ "$(report mine)" = ok ]
  [ "$(report over)" = EBUSY ]
  [ "$(report ln)" = EEXIST ]
  [ "$(report swap)" = EBUSY ]
  [ "$(cat "$W/a/b/f.md")" = HOST ]
  run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec bash -c 'echo "seen=$(cat a/b/f.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

@test "ordinary work inside and beside a pinned directory works; a rename or link across its boundary is EXDEV, mv copies" {
  run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec bash -c '
    python3 ops.py new:write:a/b/new:N tmp:write:a/b/.save.tmp:SAVED save:rename:a/b/.save.tmp:a/b/saved \
      md:mkdir:a/b/d rd:rmdir:a/b/d side:write:a/side:S side_mv:rename:a/side:a/side2 \
      across:rename:a/b/new:a/new across_ln:link:a/b/new:a/lnk
    mv a/b/new a/moved 2>>err && echo mv_across=ok >>report
    echo append >>a/b/other && echo append=ok >>report'
  [ "$status" -eq 0 ]
  [ "$(report new)" = ok ]
  [ "$(report save)" = ok ]
  [ "$(report md)" = ok ]
  [ "$(report rd)" = ok ]
  [ "$(report side_mv)" = ok ]
  [ "$(report across)" = EXDEV ]
  [ "$(report across_ln)" = EXDEV ]
  [ "$(report mv_across)" = ok ]
  [ "$(report append)" = ok ]
  [ "$(cat "$W/a/b/saved")" = SAVED ] # on the host
  [ "$(cat "$W/a/moved")" = N ]
  [ ! -e "$W/a/b/new" ]
  [ -e "$W/a/side2" ]
  [ "$(tail -1 "$W/a/b/other")" = append ]
}

@test "a join sees the same pins" {
  local i
  engine_cmd
  (cd "$IWORK" && exec env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PRESET=shared "${BASE[@]}" "${ENGINE_CMD[@]}" "${RO[@]}" --profile probe --exec sh -c \
    'touch a.in; until [ -e release.all ]; do sleep 0.05; done') </dev/null >"$I/a.out" 2>&1 3>&- &
  BGS+=("$!")
  for ((i = 0; i < 300; i++)); do
    [[ -e "$W/a.in" ]] && break
    sleep 0.05
  done
  [ -e "$W/a.in" ]
  run_sandboxed "${BASE[@]}" -- "${RO[@]}" --profile probe --exec bash -c '
    python3 ops.py mv_a:rename:a:a.moved mv_b:rename:a/b:a/b.moved
    echo "ns=$(readlink /proc/self/ns/mnt)" >>report
    grep -q "cannot be renamed or removed ($PWD/a, $PWD/a/b)" /run/agent-sandbox/briefing.md && echo brief=pins >>report
    grep -q "agent-sandbox: the pinned directories" /run/agent-sandbox/briefing.md || echo marker=gone >>report'
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned, above"* ]] # a join builds nothing
  [ "$(report brief)" = pins ] # the keeper's briefing, which the launch filled in
  [ "$(report marker)" = gone ]
  [ "$(report mv_a)" = EBUSY ]
  [ "$(report mv_b)" = EBUSY ]
  [ ! -e "$W/a.moved" ]
  : >"$W/release.all"
}

@test "the roles model's Supervisor: .asb and .asb/roles pinned, every other .asb bind beneath them as declared" {
  roles_project
  run_sandboxed "${BASE[@]}" -- --role supervisor --profile probe --exec bash -c '
    r() { mv "$1" "$2" 2>/dev/null && echo "$3=ok" >>report || echo "$3=refused" >>report; }
    w() { (echo x >"$1") 2>/dev/null && echo "$2=ok" >>report || echo "$2=refused" >>report; }
    r .asb .asb.moved mv_asb
    r .asb/roles .asb/roles.moved mv_roles
    w .asb/coord/x coord
    w .asb/coord/supervisor/x coord_supervisor
    w .asb/coord/to/x coord_to
    w .asb/scratch/x scratch
    w .asb/roles/supervisor.md purpose
    w .asb/new asb_inside
    echo "busy=$(mv .asb .asb.moved 2>&1)" >>report'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned, above a read-only, hidden or own path (the role cannot rename or remove them): ./.asb, ./.asb/roles"* ]]
  [ "$(report mv_asb)" = refused ]
  [ "$(report mv_roles)" = refused ]
  [[ "$(report busy)" == *"Device or resource busy"* ]]
  [ "$(report coord)" = refused ]
  [ "$(report coord_supervisor)" = ok ]
  [ "$(report coord_to)" = ok ]
  [ "$(report scratch)" = ok ]
  [ "$(report purpose)" = refused ]
  [ "$(report asb_inside)" = ok ]
  [ ! -e "$W/.asb.moved" ]
  [ ! -e "$W/.asb/roles.moved" ]
  [ -f "$W/.asb/roles/supervisor.md" ]
  [ -f "$W/.asb/coord/supervisor/x" ] # on the host: read-write
  [ ! -e "$W/.asb/scratch/x" ]        # the role's own store, not the project's
  [ -f "$W/.asb/new" ]
}

@test "the roles model's Implementer: nothing pinned, its read-only project refuses the rename itself" {
  roles_project
  run_sandboxed "${BASE[@]}" -- --role implementer-1 --profile probe --exec bash -c '
    echo "mv=$(mv .asb .asb.moved 2>&1)" >.asb/coord/implementer-1/seen # its own directory: the project is read-only to it'
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned, above"* ]]
  [[ "$(cat "$W/.asb/coord/implementer-1/seen")" == *"Read-only file system"* ]]
  [ ! -e "$W/.asb.moved" ]
}
