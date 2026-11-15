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
  # an overlay's workdir keeps a mode-000 directory bats could not remove
  chmod -R u+rwX "$IHOME/.local/state" 2>/dev/null
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
  [[ "$output" == *"if $W/x/real/f.md is what you mean, declare that path instead. Refusing to launch"* ]]
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
  [[ "$output" == *"if $W/real/b/f.md is what you mean, declare that path instead. Refusing to launch"* ]]
  # the hint followed: the resolved path declared instead launches
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' --connect './rw/ = read-write' \
    --connect './real/b/f.md = read-only' --profile probe --exec cat real/b/f.md
  [ "$status" -eq 0 ]
  [[ "$output" == *HOST* ]]
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
  [[ "$output" == *"if $IHOME/store/realdir/x.md is what you mean, declare that path instead. Refusing to launch"* ]]
  # the hint followed: the resolved source declared instead launches
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect "./cfg/x.md = read-only outside:$IHOME/store/realdir/x.md" \
    --profile probe --exec bash -c 'echo "seen=$(cat cfg/x.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

@test "a channel of one path whose relocated source goes through a link the role can replace: the hint names outside: as a way out, and following it launches" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt/realextra"
  printf 'R\n' >"$IHOME/alt/realextra/r"
  ln -s realextra "$IHOME/alt/extra"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = copy' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"$IHOME/alt/extra points to $IHOME/alt/realextra: make it the directory or file it should be, or, if $IHOME/alt/realextra is what you mean, give the channel its mode with outside:$IHOME/alt/realextra. Refusing to launch"* ]]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect "extra = copy outside:$IHOME/alt/realextra" \
    --profile probe --exec bash -c 'echo "seen=$(cat "$HOME/.probe/extra/r")" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = R ]
}

@test "R3: a declared path through a link the role can replace is refused, in every mode and with its source elsewhere too" {
  mkdir -p "$W/real/b" "$I/ext/d"
  printf 'EXT\n' >"$I/ext/f.md"
  ln -s real "$W/lnk"
  local m
  for m in "read-only outside:$I/ext/f.md" "read-write outside:$I/ext/f.md" "copy outside:$I/ext/f.md" own; do
    run_sandboxed "${BASE[@]}" -- --connect "./lnk/b/f.md = $m" --profile probe --exec bash -c 'echo ran=yes >>report'
    [ "$status" -ne 0 ]
    [[ "$output" == *"$W/lnk/b/f.md: its path goes through $W/lnk, a symbolic link in a directory the role can write: declared paths are fixed for the role"* ]]
    [ -z "$(report ran)" ]
  done
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

@test "R3: own, copy, copy-on-write and seed-only paths through a link the role can replace are refused (its key, or its source, through the link)" {
  mkdir -p "$W/x/real/a"
  printf 'HOST\n' >"$W/x/real/a/f"
  ln -s real "$W/x/lnk"
  local mode
  for mode in own copy copy-on-write seed-only; do
    run_sandboxed "${BASE[@]}" -- --connect "./x/lnk/a/f = $mode" --profile probe --exec bash -c 'echo ran=yes >>report'
    [ "$status" -ne 0 ]
    [[ "$output" == *"$W/x/lnk/a/f: its "*" goes through $W/x/lnk, a symbolic link in a directory the role can write"* ]]
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

@test "a read-only source another declaration shows read-write launches: each path its own access, the write through the read-write path as declared; the source fixed there (R1)" {
  mkdir -p "$IHOME/store/roles" "$W/cfg"
  printf 'HOST\n' >"$IHOME/store/roles/x.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  local -a decl=(--connect '~/store/ = read-write' --connect './cfg/x.md = read-only outside:~/store/roles/x.md')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    python3 ops.py rw:write:"$HOME/store/roles/x.md":ROLE ro:write:cfg/x.md:R \
      mvsrc:rename:"$HOME/store/roles/x.md":"$HOME/store/roles/y.md" mvdir:rename:"$HOME/store/roles":"$HOME/store/r2"
    echo "seen=$(cat cfg/x.md)" >>report'
  [ "$status" -eq 0 ]
  [[ "$output" != *contradict* ]]
  [ "$(report rw)" = ok ]
  [ "$(report ro)" = EROFS ]
  [ "$(report seen)" = ROLE ]
  [ "$(report mvsrc)" = EBUSY ]
  [ "$(report mvdir)" = EBUSY ]
}

@test "final view: a read-write mount bound AFTER the read-only path (deeper) that shows its source launches; with a link there the role can replace, the link refuses" {
  mkdir -p "$IHOME/a/b/c/store/sub" "$IHOME/a/b/c/store/realdir"
  printf 'HOST\n' >"$IHOME/a/b/c/store/sub/x.md"
  printf 'HOST\n' >"$IHOME/a/b/c/store/realdir/x.md"
  ln -s realdir "$IHOME/a/b/c/store/l"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/a/b/c/store/ = read-write' --connect './x.md = read-only outside:~/a/b/c/store/sub/x.md' \
    --profile probe --exec true
  [ "$status" -eq 0 ]
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

@test "a read-only project with ./out/ read-write and ~/out-alias/ read-write from the same directory launches, and without ./out/ declared too" {
  mkdir -p "$W/out" "$IHOME/out-alias"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' --connect './out/ = read-write' \
    --connect "~/out-alias/ = read-write outside:$W/out/" --profile probe --exec bash -c '
      echo A >out/a && echo B >"$HOME/out-alias/b" && echo "wrote=yes" >&2' # the project is read-only: no report
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote=yes"* ]]
  [ "$(cat "$W/out/a")" = A ]
  [ "$(cat "$W/out/b")" = B ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect 'project = read-only' \
    --connect "~/out-alias/ = read-write outside:$W/out/" --profile probe --exec bash -c 'echo C >"$HOME/out-alias/c" && echo "wrote=yes" >&2'
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote=yes"* ]]
  [ "$(cat "$W/out/c")" = C ]
}

@test "a read-only source whose build/ is read-write at ./build/ launches, with or without build/ read-write in place too" {
  mkdir -p "$IHOME/src/libfoo/build" "$W/ref"
  printf 'SRC\n' >"$IHOME/src/libfoo/a.c"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a decl=(--connect './ref/ = read-only outside:~/src/libfoo/' --connect './build/ = read-write outside:~/src/libfoo/build/')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec python3 ops.py src:write:ref/a.c:R b2:write:build/o2:2
  [ "$status" -eq 0 ]
  [ "$(report src)" = EROFS ]
  [ "$(report b2)" = ok ]
  [ "$(cat "$IHOME/src/libfoo/a.c")" = SRC ]
}

@test "hard links: another name of the read-only file in a read-write directory launches: the role writes it there, as declared, and the read-only name shows it" {
  mkdir -p "$I/ext" "$IHOME/store" "$W/cfg"
  printf 'HOST\n' >"$I/ext/x.md"
  ln "$I/ext/x.md" "$IHOME/store/alias.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect "./cfg/x.md = read-only outside:$I/ext/x.md" \
    --profile probe --exec bash -c 'python3 ops.py ro:write:cfg/x.md:R alias:write:"$HOME/store/alias.md":ROLE
      echo "seen=$(cat cfg/x.md)" >>report'
  [ "$status" -eq 0 ]
  [[ "$output" != *"hard link"* ]]
  [ "$(report ro)" = EROFS ]
  [ "$(report alias)" = ok ]
  [ "$(report seen)" = ROLE ]
}

@test "hard links: another name of the read-only file declared read-write as a single file launches with one warning; the write through it lands, the read-only name shows it" {
  mkdir -p "$I/ext" "$IHOME/store" "$W/cfg"
  printf 'HOST\n' >"$I/ext/x.md"
  ln "$I/ext/x.md" "$IHOME/store/alias.md"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect "./cfg/x.md = read-only outside:$I/ext/x.md" \
    --connect './alt.md = read-write outside:~/store/alias.md' --profile probe --exec bash -c '
      python3 ops.py ro:write:cfg/x.md:R alt:write:alt.md:ROLE
      echo "seen=$(cat cfg/x.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'is another name (a hard link) of' <<<"$output")" -eq 1 ]
  [[ "$output" == *"$I/ext/x.md (read-only at $W/cfg/x.md) is another name (a hard link) of $IHOME/store/alias.md, which this launch shows read-write at $W/alt.md: writing one changes the other"* ]]
  [ "$(report ro)" = EROFS ]
  [ "$(report alt)" = ok ]
  [ "$(report seen)" = ROLE ]
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

@test "ey shape 2 launches: the read-write file's directory fixed (R1), the role's rename there EBUSY" {
  mkdir -p "$IHOME/store/roles" "$W/cfg/sub"
  printf 'HOST\n' >"$IHOME/store/roles/x.md"
  printf 'OTHER\n' >"$IHOME/other.md"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a decl=(--connect '~/store/ = read-write' --connect '~/store/roles/x.md = read-write outside:~/other.md'
    --connect './cfg/sub/x.md = read-only outside:~/store/roles/x.md')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    python3 ops.py mv:rename:"$HOME/store/roles":"$HOME/store/r2"'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
}

@test "R1, the key side: a read-write or read-only outside: directory over a project directory fixes the directory above it; content writes go on" {
  mkdir -p "$W/a/data" "$IHOME/big"
  printf 'HOST\n' >"$W/a/data/f"
  printf 'BIG\n' >"$IHOME/big/f"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './a/data/ = read-write outside:~/big/' --profile probe --exec bash -c '
    echo "seen=$(cat a/data/f)" >>report
    python3 ops.py mv:rename:a:a.moved in:write:a/data/new:N beside:write:a/beside:B'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = BIG ]
  [ "$(report mv)" = EBUSY ]
  [ "$(report in)" = ok ]
  [ "$(report beside)" = ok ] # the project's declaration governs what is beside it (R2)
  [ "$(cat "$IHOME/big/new")" = N ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './a/data/ = read-only outside:~/big/' --profile probe --exec python3 ops.py mv:rename:a:a.moved
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
}

@test "R1, the source side (the measured leak): a read-write, copy or copy-on-write source in a read-write store cannot be replaced by a link; the next launch binds the declared source" {
  local m
  for m in read-write copy copy-on-write; do
    if [[ "$m" == copy-on-write ]]; then
      command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' || continue
    fi
    rm -rf "$IHOME/store" "$IHOME/secret" "$W/x"
    mkdir -p "$IHOME/store/real" "$IHOME/secret" "$W/x"
    printf 'REAL\n' >"$IHOME/store/real/f"
    printf 'SECRET\n' >"$IHOME/secret/f"
    # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
    local -a decl=(--connect '~/store/ = read-write' --connect "./x/d/ = $m outside:~/store/real/")
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
      echo "seen1=$(cat x/d/f)" >>report
      python3 ops.py mv:rename:"$HOME/store/real":"$HOME/store/real.old" rm:rmdir:"$HOME/store/real" \
        key:write:x/d/k:K src:write:"$HOME/store/real/s":S'
    [ "$status" -eq 0 ]
    [ "$(report seen1)" = REAL ]
    [ "$(report mv)" = EBUSY ]
    [ "$(report rm)" = EBUSY ]
    [ "$(report key)" = ok ]
    [ "$(report src)" = ok ]
    [ -d "$IHOME/store/real" ]
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo "seen2=$(cat x/d/f)" >>report'
    [ "$status" -eq 0 ]
    [ "$(report seen2)" = REAL ]
  done
}

@test "R1, a single-file source a read-write view shows: written in place, never renamed, removed or replaced by a temp-file rename" {
  mkdir -p "$IHOME/store" "$W/x"
  printf 'REAL\n' >"$IHOME/store/x.md"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect './x/x.md = read-only outside:~/store/x.md' \
    --profile probe --exec bash -c '
      printf T >"$HOME/store/x.md.tmp"
      python3 ops.py inplace:write:"$HOME/store/x.md":IN mv:rename:"$HOME/store/x.md":"$HOME/store/y.md" \
        rm:unlink:"$HOME/store/x.md" tmp:rename:"$HOME/store/x.md.tmp":"$HOME/store/x.md"'
  [ "$status" -eq 0 ]
  [ "$(report inplace)" = ok ]
  [ "$(report mv)" = EBUSY ]
  [ "$(report rm)" = EBUSY ]
  [ "$(report tmp)" = EBUSY ]
  [ "$(cat "$IHOME/store/x.md")" = IN ]
}

@test "an outside: naming the declaration's own host path through a link is a declaration at its own path: ./a pinned, the next launch reads the host's file" {
  mkdir -p "$W/a/b"
  printf 'HOST\n' >"$W/a/b/f.md"
  ln -s "$W" "$IHOME/wl"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  local -a decl=(--connect './a/b/f.md = read-only outside:~/wl/a/b/f.md')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    python3 ops.py mv:rename:a:a.m
    mkdir -p a/b 2>/dev/null; echo ROLE >a/b/f.md 2>/dev/null; true'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
  [ ! -e "$W/a.m" ]
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'echo "seen=$(cat a/b/f.md)" >>report'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = HOST ]
}

@test "R1, a channel whose source the profile relocates: in copy mode the source cannot be moved away and replaced by a link; through a link the role can replace it is refused (copy, copy-on-write, seed-only, read-only, read-write)" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt/extra" "$IHOME/secret"
  printf 'REAL\n' >"$IHOME/alt/extra/r"
  printf 'S\n' >"$IHOME/secret/s"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  local -a decl=(--connect '~/alt/ = read-write' --connect 'extra = copy')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
    echo "seen1=$(ls "$HOME/.probe/extra" | tr "\n" " ")" >>report
    python3 ops.py mv:rename:"$HOME/alt/extra":"$HOME/alt/extra.m"'
  [ "$status" -eq 0 ]
  [ "$(report seen1)" = "r " ]
  [ "$(report mv)" = EBUSY ]
  [ -d "$IHOME/alt/extra" ]
  # the source already a link the role can replace: refused in every mode
  mv "$IHOME/alt/extra" "$IHOME/alt/realextra"
  ln -s realextra "$IHOME/alt/extra"
  local m
  for m in copy copy-on-write seed-only read-only read-write; do
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect "extra = $m" --profile probe --exec bash -c 'echo ran=yes >>report'
    [ "$status" -ne 0 ] || {
      echo "$m launched: $output" >&2
      return 1
    }
    [[ "$output" == *"goes through $IHOME/alt/extra, a symbolic link in a directory the role can write"* ]]
    [ -z "$(report ran)" ]
  done
}

@test "a channel's relocated source that does not exist: nothing made on the host on the way to it and nothing pinned (copy, own, copy-on-write); the launch that finds it there resolves it again" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/deep/er/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt" "$IHOME/secret"
  local m
  for m in copy own copy-on-write; do
    rm -f "$W/report"
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect "extra = $m" --profile probe --exec bash -c '
      echo "seen=$(ls -A "$HOME/.probe/extra" | tr "\n" " ")" >>report; echo W >"$HOME/.probe/extra/w" && echo wrote=yes >>report'
    [ "$status" -eq 0 ]
    [ "$(report wrote)" = yes ] # the role's own, an empty start in every mode
    [ -z "$(ls -A "$IHOME/alt")" ] || {
      echo "$m: made $(ls -A "$IHOME/alt")" >&2
      return 1
    }
    [[ "$output" != *"pinned, on the way"* ]]
  done
  # the role puts a link there: the next launch that reads the source refuses it
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = copy' --profile probe --exec bash -c '
    mkdir -p "$HOME/alt/deep/er" && ln -s "$HOME/secret" "$HOME/alt/deep/er/extra"'
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = copy' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"goes through $IHOME/alt/deep/er/extra, a symbolic link in a directory the role can write"* ]]
}

@test "a join-scoped path declaration's source is fixed (copy, seed-only, copy-on-write): the role cannot move it away and put a link there; a link the role can replace there is refused" {
  local m
  for m in copy seed-only copy-on-write; do
    rm -rf "$IHOME/store" "$IHOME/secret" "$W/x" "$W/report"
    mkdir -p "$IHOME/store/real" "$IHOME/secret"
    printf 'R\n' >"$IHOME/store/real/r"
    printf 'SECRET\n' >"$IHOME/secret/s"
    # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
    local -a decl=(--connect '~/store/ = read-write' --connect "./x/d/ = $m join-scoped outside:~/store/real/")
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
      python3 ops.py mv:rename:"$HOME/store/real":"$HOME/store/real.old"'
    [ "$status" -eq 0 ]
    [ "$(report mv)" = EBUSY ] || {
      echo "$m: rename $(report mv)" >&2
      return 1
    }
    [ -d "$IHOME/store/real" ]
    # a link the role can replace on the way: refused, nothing of ~/secret seeded
    mv "$IHOME/store/real" "$IHOME/store/realdir"
    ln -s realdir "$IHOME/store/real"
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec true
    [ "$status" -ne 0 ]
    [[ "$output" == *"its source goes through $IHOME/store/real, a symbolic link in a directory the role can write"* ]]
  done
}

@test "a launch the link check refuses has read nothing through the link: no seed-only store from ~/secret, and the launch after the user's repair shows none (seed-only); a copy store holds nothing of it (copy)" {
  local m
  for m in seed-only copy; do
    rm -rf "$IHOME/store" "$IHOME/secret" "$W/x" "$IHOME/.local/state" "$W/report"
    mkdir -p "$IHOME/store" "$IHOME/secret"
    printf 'SECRET\n' >"$IHOME/secret/s"
    # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
    local -a decl=(--connect '~/store/ = read-write' --connect "./x/d/ = $m outside:~/store/real/")
    # launch 1: the source is missing (skipped); the role puts a link there
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'ln -s ../secret "$HOME/store/real"'
    [ "$status" -eq 0 ]
    # launch 2: refused, and nothing was read through the link
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec true
    [ "$status" -ne 0 ]
    [[ "$output" == *"its source goes through $IHOME/store/real, a symbolic link in a directory the role can write"* ]]
    run ! grep -rqs SECRET "$IHOME/.local/state"
    # launch 3, after the user's repair: the role sees the real source, never ~/secret
    rm "$IHOME/store/real"
    mkdir "$IHOME/store/real"
    printf 'MINE\n' >"$IHOME/store/real/m"
    run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c '
      echo "seen=$(cat x/d/* 2>/dev/null | tr "\n" " ")" >>report'
    [ "$status" -eq 0 ]
    [ "$(report seen)" = "MINE " ] || {
      echo "$m: saw [$(report seen)]" >&2
      return 1
    }
  done
}

@test "git rebase works across pinned directories: ./a and ./a/b pinned above a read-only file, a branch rebased onto another that changed files in them" {
  rm -rf "$W/a" "$W/ops.py"
  git -C "$W" init -q -b main
  mkdir -p "$W/a/b" "$W/a/c"
  printf 'HOST\n' >"$W/a/b/f.md"
  printf '1\n' >"$W/a/x"
  printf '1\n' >"$W/a/c/y"
  git -C "$W" add -A
  git -C "$W" -c user.name=t -c user.email=t@example.org commit -q -m base
  git -C "$W" branch feature
  printf '2\n' >"$W/a/c/y"
  git -C "$W" -c user.name=t -c user.email=t@example.org commit -q -am main-change
  run_sandboxed "${BASE[@]}" -- --connect './a/b/f.md = read-only' --profile probe --exec bash -c '
    g() { git -c user.name=t -c user.email=t@example.org "$@"; }
    g checkout -q feature && mkdir -p a/d && printf "n\n" >a/d/z && printf "f\n" >a/x &&
      g add -A && g commit -q -m feature-change && g rebase -q main >/dev/null 2>&1
    echo "rebase=$?" >>report
    echo "files=$(cat a/c/y a/x a/d/z | tr "\n" " ")" >>report'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./a, ./a/b"* ]]
  [ "$(report rebase)" = 0 ]
  [ "$(report files)" = "2 f n " ]
  [ "$(git -C "$W" log --format=%s -3 | tr '\n' ' ')" = "feature-change main-change base " ]
}

# THE ONE WAY THE ENGINE TOUCHES A SOURCE (_as_src_guard): each place that reads, hashes
# or makes something at a source, through a link the role planted, refuses and leaves
# nothing behind.

@test "source guard, a join's seed: a join-scoped copy or seed-only source missing at launch, made a link by the role meanwhile, is not copied at the next join" {
  local m i
  for m in copy seed-only; do
    rm -rf "$IHOME/store" "$IHOME/secret" "$W/x" "$W/report" "$W/a.in" "$W/release.all"
    mkdir -p "$IHOME/store" "$IHOME/secret/real"
    printf 'SECRET\n' >"$IHOME/secret/real/s"
    # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
    local -a D=(--connect '~/store/ = read-write' --connect "./x/d/ = $m join-scoped outside:~/store/sub/real/")
    engine_cmd
    (cd "$IWORK" && exec env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
      AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE=0 \
      AGENT_SANDBOX_PRESET=shared "${BASE[@]}" "${ENGINE_CMD[@]}" "${D[@]}" --profile probe --exec sh -c \
      'ln -s "$HOME/secret" "$HOME/store/sub"; touch a.in; until [ -e release.all ]; do sleep 0.05; done') </dev/null >"$I/a.out" 2>&1 3>&- &
    local bg=$!
    for ((i = 0; i < 300; i++)); do
      [[ -e "$W/a.in" ]] && break
      sleep 0.05
    done
    [ -e "$W/a.in" ]
    run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- "${D[@]}" --profile probe --exec bash -c 'echo "seen=$(cat x/d/s 2>/dev/null)" >>report'
    [ "$status" -ne 0 ]
    [[ "$output" == *"its source goes through $IHOME/store/sub, a symbolic link made since the launch resolved it"* ]]
    [ -z "$(report seen)" ]
    : >"$W/release.all"
    wait "$bg" 2>/dev/null || true
  done
}

# shellcheck disable=SC2030 # run's status, the test's own
@test "source guard, the shadows walk: a copy-on-write source through a link the role can replace is refused before it is walked or hashed (channel and declaration)" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/store" "$IHOME/secret"
  printf 'SECRET\n' >"$IHOME/secret/s"
  ln -s ../secret "$IHOME/store/real"
  local d
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  for d in 'extra = copy-on-write outside:~/store/real/' './x/d/ = copy-on-write outside:~/store/real/'; do
    rm -rf "$IHOME/.local/state"
    # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
    run_sandboxed "${BASE[@]}" -- --connect '~/store/ = read-write' --connect "$d" --profile probe --exec true
    [ "$status" -ne 0 ]
    [[ "$output" == *"its source goes through $IHOME/store/real, a symbolic link in a directory the role can write"* ]]
    run ! grep -rqs '"s"' "$IHOME/.local/state"
  done
}

# plant_docs TARGET -- launch 1: the role makes the probe's missing docs channel a link
plant_docs() {
  rm -rf "$IHOME/.probe/docs"
  run_sandboxed "${BASE[@]}" -- --connect 'docs = read-write' --profile probe --exec bash -c "ln -s $1 \"\$HOME/.probe/docs\""
  # shellcheck disable=SC2031 # run's status, read in the same function
  [ "$status" -eq 0 ]
  [ -L "$IHOME/.probe/docs" ]
}

@test "source guard, a source made when missing: a copy-on-write channel at its own path, a link the role planted there, is refused and nothing is made through it" {
  plant_docs ../made
  run_sandboxed "${BASE[@]}" -- --connect 'docs = copy-on-write' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/.probe/docs, a symbolic link in a directory the role can write"* ]]
  [ ! -e "$IHOME/made" ]
}

@test "source guard, a source the profile makes when missing: a read-only channel the profile creates, a link the role planted there, is refused and nothing is made through it" {
  printf '%s\n' 'profile_channel_create=(docs)' >>"$IPROFILES/probe/profile.sh"
  plant_docs ../made
  run_sandboxed "${BASE[@]}" -- --connect 'docs = read-only' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/.probe/docs, a symbolic link in a directory the role can write"* ]]
  [ ! -e "$IHOME/made" ]
}

@test "source guard, the role's own state tree: a read-write channel at its own path under an own declaration covering the state directory -- a link the role planted in another launch is refused, not bound nor made through" {
  mkdir -p "$IHOME/secret"
  printf 'SECRET\n' >"$IHOME/secret/s"
  plant_docs ../made
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/.probe/ = own' --connect 'docs = read-write' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/.probe/docs, a symbolic link"* ]]
  [ ! -e "$IHOME/made" ]
  # an existing target: refused too, never bound
  rm "$IHOME/.probe/docs"
  ln -s ../secret "$IHOME/.probe/docs"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/.probe/ = own' --connect 'docs = read-write' --profile probe --exec bash -c '
    echo "seen=$(cat "$HOME/.probe/docs/s" 2>/dev/null)" >>report'
  [ "$status" -ne 0 ]
  [ -z "$(report seen)" ]
}

@test "a join-scoped copy-on-write declaration whose source is missing makes nothing on the host: each join reads an empty stand-in" {
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './x/d/ = copy-on-write join-scoped outside:~/nowhere/deep/' --profile probe --exec bash -c '
    echo "seen=$(ls -A x/d | tr "\n" " ")" >>report; echo W >x/d/w && echo wrote=yes >>report'
  [ "$status" -eq 0 ]
  [ ! -e "$IHOME/nowhere" ]
  [ -z "$(report seen)" ]
  [ "$(report wrote)" = yes ]
}

# sbx_native SPEC_KEY SOURCE -- a sandbox: source naming a project with no record, so it
# resolves to the native path through the profile's relocation of SPEC_KEY to SOURCE
sbx_native() {
  printf '%s\n' "profile_channel_sources=(\"\$HOME/.probe/$1\"\$'\\t'\"\$HOME/alt/$2\")" >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt" "$IHOME/secret" "$I/P"
  printf 'TOPSECRET\n' >"$IHOME/secret/g"
}

@test "a sandbox: source that resolves to a native path of the user's (no record) is a declared source: a link the role planted there is refused (file)" {
  sbx_native NOTES.md notes.md
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a D=(--connect '~/alt/ = read-write' --connect "~/.probe/NOTES.md = read-only sandbox:$I/P")
  run_sandboxed "${BASE[@]}" -- "${D[@]}" --profile probe --exec bash -c 'ln -s ../secret/g "$HOME/alt/notes.md"'
  [ "$status" -eq 0 ]
  run_sandboxed "${BASE[@]}" -- "${D[@]}" --profile probe --exec bash -c 'echo "seen=$(cat "$HOME/.probe/NOTES.md" 2>/dev/null)" >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/alt/notes.md, a symbolic link in a directory the role can write"* ]]
  [[ "$(report seen)" != *TOPSECRET* ]]
}

@test "a sandbox: source that resolves to a native path of the user's (no record) is a declared source: a link the role planted there is refused (directory)" {
  sbx_native extra extra
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a D=(--connect '~/alt/ = read-write' --connect "~/.probe/extra/ = read-only sandbox:$I/P")
  run_sandboxed "${BASE[@]}" -- "${D[@]}" --profile probe --exec bash -c 'ln -s ../secret "$HOME/alt/extra"'
  [ "$status" -eq 0 ]
  run_sandboxed "${BASE[@]}" -- "${D[@]}" --profile probe --exec bash -c 'echo "seen=$(cat "$HOME/.probe/extra/g" 2>/dev/null)" >>report'
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/alt/extra, a symbolic link in a directory the role can write"* ]]
  [[ "$(report seen)" != *TOPSECRET* ]]
}

@test "directories on the way made for a hide get the mode bwrap gives a tmpfs's (0755); for a bind, 0700" {
  printf '%s\n' 'profile_base="$HOME/.probe"' 'profile_hide=(missing/a/s)' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/big"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- --connect './n1/n2/key/ = read-only outside:~/big/' --profile probe --exec true
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$IHOME/.probe/missing")" = 755 ]
  [ "$(stat -c %a "$IHOME/.probe/missing/a")" = 755 ]
  [ "$(stat -c %a "$W/n1")" = 700 ]
  [ "$(stat -c %a "$W/n1/n2")" = 700 ]
}

# shellcheck disable=SC2030,SC2031 # run's status, the test's own
@test "a join-scoped channel under a linked HOME: each join seeds from the source the launch resolved (copy, seed-only, copy-on-write; a directory and a file)" {
  ln -s home "$I/hl"
  printf 'DOC\n' >"$IHOME/.probe/docs/a.md"
  printf 'NOTE\n' >"$IHOME/.probe/NOTES.md"
  local m
  for m in copy seed-only copy-on-write; do
    rm -f "$W/report"
    run_sandboxed "${BASE[@]}" HOME="$I/hl" AGENT_SANDBOX_PRESET=isolated -- --connect "docs = $m join-scoped" \
      --profile probe --exec bash -c 'echo "seen=$(cat "$HOME/.probe/docs/a.md" "$HOME/.probe/NOTES.md" 2>&1 | tr "\n" " ")" >>report'
    [ "$status" -eq 0 ] || {
      echo "$m: $output" >&2
      return 1
    }
    [ "$(report seen)" = "DOC NOTE " ]
  done
}

# layer_link TARGET -- a copy-on-write project; launch 1, the declared source missing: the
# role replaces ./a with a link to TARGET in its own layer; then the source appears
layer_link() {
  mkdir -p "$IHOME/x"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  LAYER_D=(--connect 'project = copy-on-write' --connect './a/f = read-only outside:~/x/f')
  run_sandboxed "${BASE[@]}" -- "${LAYER_D[@]}" --profile probe --exec bash -c "rm -rf a; mkdir -p a.role; ln -s $1 a"
  # shellcheck disable=SC2031 # run's status, read in the same function
  [ "$status" -eq 0 ]
  printf 'HOSTF\n' >"$IHOME/x/f"
}

@test "a key through a link the role made in its own copy-on-write layer is refused (a relative link)" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  layer_link a.role
  run_sandboxed "${BASE[@]}" -- "${LAYER_D[@]}" --profile probe --exec bash -c 'echo "seen=$(cat a/f)"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect: $W/a/f: its path goes through $W/a, a symbolic link the role made in its own layer of the copy-on-write mount at $W"* ]]
  [[ "$output" != *"seen="* ]]
}

@test "a key through a link the role made in its own copy-on-write layer is refused (an absolute link)" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  layer_link "$W/a.role"
  run_sandboxed "${BASE[@]}" -- "${LAYER_D[@]}" --profile probe --exec bash -c 'echo "seen=$(cat a/f)"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect: $W/a/f: its path goes through $W/a, a symbolic link the role made in its own layer of the copy-on-write mount at $W"* ]]
  [[ "$output" != *"bwrap:"* ]]
}

@test "in a copy-on-write project, directories on the way to a read-only key that only the role's layer has are pinned: no rename, and the key stays read-only" {
  command -v bwrap >/dev/null && bwrap --help 2>&1 | grep -q -- '--overlay ' \
    || skip "bubblewrap has no --overlay (needs >= 0.11)"
  mkdir -p "$IHOME/x"
  printf 'HOSTF\n' >"$IHOME/x/f"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect 'project = copy-on-write' --connect './new/deep/f.md = read-only outside:~/x/f' \
    --profile probe --exec bash -c 'mv new new.m 2>/dev/null; echo mv=$?; echo W >new/side && echo side=ok
      echo ROLE >new/deep/f.md 2>/dev/null; echo write=$?; echo "seen=$(cat new/deep/f.md)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./new, ./new/deep"* ]]
  [[ "$output" == *"mv=1"* ]]
  [[ "$output" == *"side=ok"* ]] # writable inside, as the project's layer
  [[ "$output" == *"write=1"* ]]
  [[ "$output" == *"seen=HOSTF"* ]]
  [ ! -e "$W/new" ] # nothing on the host
}

# relo_link TARGET -- the probe's extra channel relocated to ~/alt/extra, a link to TARGET
relo_link() {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt" "$IHOME/secret" "$IHOME/plain"
  printf 'SECRET\n' >"$IHOME/secret/s"
  ln -s "$1" "$IHOME/alt/extra"
}

@test "a channel whose path a declaration takes over: its copy is not read in that launch (nothing shows it), so nothing goes through its source's link -- not into its store, not to another role reading that store" {
  relo_link ../secret
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = copy' \
    --connect '~/.probe/extra/ = read-only outside:~/plain/' --profile probe --exec true
  [ "$status" -eq 0 ]
  run ! grep -rqs SECRET "$IHOME/.local/state"
  run_sandboxed "${BASE[@]}" -- --role r2 --connect 'extra = read-only sandbox:@default' --profile probe --exec bash -c '
    echo "seen=$(cat "$HOME/.probe/extra/s" 2>/dev/null)" >>report'
  [ "$status" -eq 0 ]
  [ -z "$(report seen)" ]
}

@test "a channel whose path an own declaration takes over: its relocated source is nobody's, so a link there neither refuses nor is read" {
  relo_link realextra
  mkdir -p "$IHOME/alt/realextra"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = copy' \
    --connect '~/.probe/extra/ = own' --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -eq 0 ]
  [ "$(report ran)" = yes ]
}

@test "--reset of a copy reads nothing from the source: the store is discarded, and the next launch refuses the link the role planted there" {
  relo_link ../secret
  rm "$IHOME/alt/extra"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  local -a decl=(--connect '~/alt/ = read-write' --connect 'extra = copy')
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec bash -c 'ln -s ../secret "$HOME/alt/extra"'
  [ "$status" -eq 0 ]
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --reset extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"its copy discarded, the next launch copies it from yours again"* ]]
  run ! grep -rqs SECRET "$IHOME/.local/state"
  run_sandboxed "${BASE[@]}" -- "${decl[@]}" --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its source goes through $IHOME/alt/extra, a symbolic link in a directory the role can write"* ]]
  run ! grep -rqs SECRET "$IHOME/.local/state"
}

@test "an own channel does not read its relocated source: a link there launches, and a directory there is the role's to rename as ~/alt/ = read-write grants" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt/realextra"
  ln -s realextra "$IHOME/alt/extra"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = own' --profile probe --exec bash -c 'echo ran=yes >>report'
  [ "$status" -eq 0 ]
  [ "$(report ran)" = yes ]
  rm "$IHOME/alt/extra"
  mv "$IHOME/alt/realextra" "$IHOME/alt/extra"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect '~/alt/ = read-write' --connect 'extra = own' --profile probe --exec bash -c '
    python3 ops.py mv:rename:"$HOME/alt/extra":"$HOME/alt/extra.m"'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = ok ]
  [ -d "$IHOME/alt/extra.m" ]
}

@test "a copy-on-write channel with a relocated directory source reads that source, as copy does (the profile's relocation and outside:); a write lands in the role's layer, not in the source nor at the path" {
  printf '%s\n' 'profile_channel_sources=("$HOME/.probe/extra"$'"'"'\t'"'"'"$HOME/alt/extra")' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/alt/extra" "$IHOME/.probe/extra" "$IHOME/alt2/extra"
  printf 'RELOC\n' >"$IHOME/alt/extra/r"
  printf 'PATH\n' >"$IHOME/.probe/extra/p"
  printf 'OUT\n' >"$IHOME/alt2/extra/o"
  local m want
  for m in copy-on-write copy "copy-on-write outside:~/alt2/extra" "copy outside:~/alt2/extra"; do
    want=r
    [[ "$m" == *outside:* ]] && want=o
    rm -f "$W/report"
    run_sandboxed "${BASE[@]}" -- --connect "extra = $m" --profile probe --exec bash -c '
      echo "seen=$(ls "$HOME/.probe/extra" | grep -v "^w$" | tr "\n" " ")" >>report
      echo W >"$HOME/.probe/extra/w" && echo wrote=yes >>report'
    [ "$status" -eq 0 ]
    [ "$(report seen)" = "$want " ] || {
      echo "$m: saw [$(report seen)], expected [$want ]" >&2
      return 1
    }
    [ "$(report wrote)" = yes ]
    [ ! -e "$IHOME/alt/extra/w" ]
    [ ! -e "$IHOME/alt2/extra/w" ]
    [ ! -e "$IHOME/.probe/extra/w" ]
  done
}

@test "R1, a read-write channel at its own path, under a state bind that already shows it: the role cannot rename it away (it is a mount point)" {
  mkdir -p "$IHOME/.probe/docs"
  printf 'D\n' >"$IHOME/.probe/docs/d"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- --connect 'docs = read-write' --profile probe --exec bash -c '
    python3 ops.py mv:rename:"$HOME/.probe/docs":"$HOME/.probe/docs.m" in:write:"$HOME/.probe/docs/n":N'
  [ "$status" -eq 0 ]
  [ "$(report mv)" = EBUSY ]
  [ "$(report in)" = ok ] # writable inside, as declared
  [ -d "$IHOME/.probe/docs" ]
  [ ! -e "$IHOME/.probe/docs.m" ]
  [ "$(cat "$IHOME/.probe/docs/n")" = N ]
}

# hide_link -- the probe profile on a base (~/.probe) with lnk -> real, real/secret/s TOPSECRET.
hide_link() {
  printf '%s\n' 'profile_base="$HOME/.probe"' >>"$IPROFILES/probe/profile.sh"
  mkdir -p "$IHOME/.probe/real/secret" "$IHOME/.probe/other"
  printf 'TOPSECRET\n' >"$IHOME/.probe/real/secret/s"
  ln -s real "$IHOME/.probe/lnk"
}

@test "the profile's hide through a link the role can replace is refused: the role cannot retarget the link to uncover what it hides" {
  hide_link
  printf '%s\n' 'profile_hide=(lnk/secret)' >>"$IPROFILES/probe/profile.sh"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- --profile probe --exec bash -c '
    cd "$HOME/.probe" && rm lnk && ln -s other lnk && echo swapped=yes >>"'"$W"'/report"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect: $IHOME/.probe/lnk/secret: its path goes through $IHOME/.probe/lnk, a symbolic link in a directory the role can write"* ]]
  [ -z "$(report swapped)" ]
  [ "$(readlink "$IHOME/.probe/lnk")" = real ]
}

@test "a project's [probe] hide through a link the role can replace is refused the same way" {
  hide_link
  printf '%s\n' 'profile_dotfile_keys=(hide)' >>"$IPROFILES/probe/profile.sh"
  printf '[probe]\nhide = lnk/secret\n' >"$W/.agent-sandbox"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\nn\n" | env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PROFILE_DIR="$4" "${@:5}" --trust --profile probe 2>&1' \
    _ "$W" "$IHOME" "$I/bin:/usr/bin:/bin" "$IPROFILES" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- --profile probe --exec bash -c '
    cd "$HOME/.probe" && rm lnk && ln -s other lnk && echo swapped=yes >>"'"$W"'/report"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"connect: $IHOME/.probe/lnk/secret: its path goes through $IHOME/.probe/lnk, a symbolic link in a directory the role can write"* ]]
  [ -z "$(report swapped)" ]
  # with the link made the directory it points to, the hide is fixed and still hides
  rm "$IHOME/.probe/lnk"
  mv "$IHOME/.probe/real" "$IHOME/.probe/lnk"
  run_sandboxed "${BASE[@]}" AGENT_SANDBOX_PRESET=shared -- --profile probe --exec bash -c '
    echo "seen=$(cat "$HOME/.probe/lnk/secret/s" 2>&1)" >>"'"$W"'/report"'
  [ "$status" -eq 0 ]
  [[ "$(report seen)" != *TOPSECRET* ]]
}

@test "R1 at the first launch: directories on the way to a key that the host does not have yet are made where bwrap would make them, and pinned already" {
  mkdir -p "$IHOME/big"
  printf 'BIG\n' >"$IHOME/big/f"
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './n1/n2/key/ = read-only outside:~/big/' --profile probe --exec bash -c '
    echo "seen=$(cat n1/n2/key/f)" >>report
    python3 ops.py mvn2:rename:n1/n2:n1/n2.m mvn1:rename:n1:n1.m'
  [ "$status" -eq 0 ]
  [ "$(report seen)" = BIG ]
  [ "$(report mvn2)" = EBUSY ]
  [ "$(report mvn1)" = EBUSY ]
  [ -d "$W/n1/n2/key" ] # what bwrap makes there anyway
  [ ! -e "$W/n1.m" ]
}

@test "the directories on the way made for the pins: none when a later check refuses the launch (it leaves the host as it was), and mode 0700 as bwrap makes them" {
  mkdir -p "$IHOME/big" "$W/real/a/b"
  ln -s real "$W/lnk"
  # shellcheck disable=SC2088 # the declarations' own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './n1/n2/key/ = read-only outside:~/big/' \
    --connect './lnk/a/b/c/d/ = read-write outside:~/big/' --profile probe --exec true
  [ "$status" -ne 0 ]
  [[ "$output" == *"its path goes through $W/lnk"* ]]
  [ ! -e "$W/n1" ]
  [ ! -e "$W/real/a/b/c" ]
  # shellcheck disable=SC2088 # the declaration's own ~, the engine's to expand
  run_sandboxed "${BASE[@]}" -- --connect './n1/n2/key/ = read-only outside:~/big/' --profile probe --exec true
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$W/n1")" = 700 ]
  [ "$(stat -c %a "$W/n1/n2")" = 700 ]
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
    grep -q "cannot be renamed, removed or replaced ($PWD/a, $PWD/a/b)" /run/agent-sandbox/briefing.md && echo brief=pins >>report
    grep -q "agent-sandbox: the pinned directories" /run/agent-sandbox/briefing.md || echo marker=gone >>report'
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned, on the way"* ]] # a join builds nothing
  [ "$(report brief)" = pins ]              # the keeper's briefing, which the launch filled in
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
  [[ "$output" == *"pinned, on the way to a declared path or its source (the role cannot rename, remove or replace them): ./.asb, ./.asb/roles"* ]]
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

@test "the roles model in normal operation under R1: inbox written by temp file + rename, messages.md by Write/Edit's rename, git commit/branch/checkout/stash/merge in the Supervisor's tree and an Implementer's clone" {
  roles_project
  [ -d "$W/.asb/impl/1" ] || skip "no Implementer clone made by --init here"
  run_sandboxed "${BASE[@]}" -- --role supervisor --profile probe --exec bash -c '
    st() { "$@" >/dev/null 2>&1 && echo ok || echo "failed"; }
    G="git -c user.name=t -c user.email=t@example.org"
    printf "report\n" >>.git/info/exclude # the report stays out of the stash
    printf "task\n" >.asb/coord/to/.implementer-1.md.tmp
    echo "inbox=$(st mv .asb/coord/to/.implementer-1.md.tmp .asb/coord/to/implementer-1.md)" >>report
    printf "m\n" >.asb/coord/supervisor/.messages.md.tmp
    echo "messages=$(st mv .asb/coord/supervisor/.messages.md.tmp .asb/coord/supervisor/messages.md)" >>report
    echo "a" >work.txt
    echo "add=$(st $G add work.txt)" >>report
    echo "commit=$(st $G commit -qm one)" >>report
    echo "branch=$(st $G checkout -qb side)" >>report
    echo "b" >>work.txt
    echo "commit2=$(st $G commit -qam two)" >>report
    echo "back=$(st $G checkout -q -)" >>report
    # (a tracked change: `stash --include-untracked` would remove the untracked .agent-sandbox,
    # a mount point at every launch, with or without the pins)
    echo "c" >>work.txt
    echo "stash=$(st $G stash -q)" >>report
    echo "pop=$(st $G stash pop -q)" >>report
    $G checkout -q -- work.txt # the merge below wants a clean tree
    echo "merge=$(st $G merge -q --no-edit side)" >>report'
  [ "$status" -eq 0 ]
  local k
  for k in inbox messages add commit branch commit2 back stash pop merge; do
    [ "$(report "$k")" = ok ] || {
      echo "supervisor $k: $(report "$k"); output: $output; report: $(cat "$W/report" 2>&1)" >&2
      return 1
    }
  done
  run_sandboxed "${BASE[@]}" -- --role implementer-1 --profile probe --exec bash -c '
    st() { "$@" >/dev/null 2>&1 && echo ok || echo "failed"; }
    G="git -c user.name=t -c user.email=t@example.org -C .asb/impl/1"
    printf "m\n" >.asb/coord/implementer-1/.messages.md.tmp
    mv .asb/coord/implementer-1/.messages.md.tmp .asb/coord/implementer-1/messages.md && echo messages=ok >.asb/coord/implementer-1/r || echo messages=failed >.asb/coord/implementer-1/r
    echo "x" >.asb/impl/1/impl.txt
    for c in "add impl.txt" "commit -qm impl" "checkout -qb feature" "checkout -q -" "stash list" "merge -q --no-edit feature"; do
      echo "$c=$(st $G $c)" >>.asb/coord/implementer-1/r
    done'
  [ "$status" -eq 0 ]
  run ! grep -q failed "$W/.asb/coord/implementer-1/r"
  grep -qx 'messages=ok' "$W/.asb/coord/implementer-1/r"
}

@test "the roles model's Implementer: nothing pinned, its read-only project refuses the rename itself" {
  roles_project
  run_sandboxed "${BASE[@]}" -- --role implementer-1 --profile probe --exec bash -c '
    echo "mv=$(mv .asb .asb.moved 2>&1)" >.asb/coord/implementer-1/seen # its own directory: the project is read-only to it'
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned, on the way"* ]]
  [[ "$(cat "$W/.asb/coord/implementer-1/seen")" == *"Read-only file system"* ]]
  [ ! -e "$W/.asb.moved" ]
}
