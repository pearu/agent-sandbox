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
  sed 's/^  _as_ro_pins_reuse _bwrap_opts _pinned_opts _pinned || return 1$/  : no pins/' "$ENGINE" >"$d/agent-sandbox"
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
    echo "ns=$(readlink /proc/self/ns/mnt)" >>report'
  [ "$status" -eq 0 ]
  [[ "$output" != *"read-only parents pinned"* ]] # a join builds nothing
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
  [[ "$output" == *"read-only parents pinned (the role cannot rename or remove them): ./.asb, ./.asb/roles"* ]]
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
  [[ "$output" != *"read-only parents pinned"* ]]
  [[ "$(cat "$W/.asb/coord/implementer-1/seen")" == *"Read-only file system"* ]]
  [ ! -e "$W/.asb.moved" ]
}
