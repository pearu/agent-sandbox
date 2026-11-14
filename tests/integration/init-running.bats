#!/usr/bin/env bats
# --init and --apply while a role runs (#389), under the REAL bwrap. A running sandbox
# has the dot-file and its role's purpose file bound read-only as single files; a host
# rename over such a file detaches that bind, and under a project the role has
# read-write the path then leads to the host's new file, writable. So the dot-file is
# written in place (its bind holds), and an --init that would replace a running
# read-write role's purpose file is refused until the role is shut down; a role with
# the project read-only just sees the new text. A tiny model of two single roles: writer
# (project read-write) and reader (project read-only, out/ read-write for its marker).
# shellcheck disable=SC2016 # the --exec scripts expand inside the sandbox, not here

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  command -v python3 >/dev/null || skip "python3 not installed"
  command -v flock >/dev/null || skip "flock not installed (util-linux)"
  make_integration <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  M="$I/models/tiny"
  mkdir -p "$M/roles" "$IWORK/out"
  cat >"$M/agent-sandbox" <<'MODEL'
[connect:writer]
project = read-write
[briefing:writer]
[connect:reader]
project = read-only
./out/ = read-write
[briefing:reader]
MODEL
  printf 'You are the writer.\n' >"$M/roles/writer.md"
  printf 'You are the reader.\n' >"$M/roles/reader.md"
  BASE=(AGENT_SANDBOX_NET=none XDG_STATE_HOME="$IHOME/.local/state" AGENT_SANDBOX_MODELS_DIR="$I/models")
  BGS=()
  asb_host --init tiny
  [ "$status" -eq 0 ]
  approve
}

teardown() {
  local p f spid
  : >"$IWORK/out/release.all" 2>/dev/null
  for p in ${BGS[@]+"${BGS[@]}"}; do kill "$p" 2>/dev/null; done
  for f in "$IHOME"/.local/state/agent-sandbox/probe/*/*/keeper/id; do
    [[ -r "$f" ]] || continue
    read -r spid _ <"$f" 2>/dev/null && [[ -n "$spid" ]] && kill "$spid" 2>/dev/null
  done
  return 0
}

# asb_host ARGS... -- the engine on the host, in the project, nothing on stdin
asb_host() {
  run_sandboxed "${BASE[@]}" -- "$@" </dev/null
}

# approve -- the project's .agent-sandbox approved as it is now, through --trust
approve() {
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PROFILE_DIR="$4" "${@:5}" --trust 2>&1' \
    _ "$IWORK" "$IHOME" "$I/bin:/usr/bin:/bin" "$IPROFILES" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved."* ]]
}

# start ROLE [DIR] -- the role launched in the background, a command held in it until the
# teardown (or stop), its marker in DIR (default out/, a directory the role can write);
# returns once it is inside
start() {
  local i m="${2:-out}"
  engine_cmd
  (cd "$IWORK" && exec env -i HOME="$IHOME" PATH="$I/bin:/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$IPROFILES" AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PRESET=shared "${BASE[@]}" "${ENGINE_CMD[@]}" --role "$1" --profile probe --exec sh -c \
    "touch $m/$1.in; until [ -e out/release.all ]; do sleep 0.05; done") </dev/null >"$I/$1.out" 2>&1 3>&- &
  BGS+=($!)
  for ((i = 0; i < 300; i++)); do
    [[ -e "$IWORK/$m/$1.in" ]] && return 0
    sleep 0.05
  done
  echo "start $1: did not join:" >&2
  cat "$I/$1.out" >&2
  return 1
}

# inside ROLE FILE -- a join into the running ROLE: FILE's text as it sees it, whether
# it can write it, and whether FILE is still a mount point of its own there
inside() {
  run_sandboxed "${BASE[@]}" -- --role "$1" --profile probe --exec sh -c \
    'cat "$1"; if (echo x >>"$1") 2>/dev/null; then echo "WRITE=yes"; else echo "WRITE=no"; fi
     awk -v m="$PWD/$1" '"'"'$5 == m { n++ } END { print "MOUNT=" n + 0 }'"'"' /proc/self/mountinfo' _ "$2"
}

@test "a role with the project read-write keeps the dot-file read-only through --apply and an --init that changes only the dot-file: the new text, the mount, no write" {
  start writer
  inside writer .agent-sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOUNT=1"* ]]
  local ino
  ino="$(stat -c %i "$IWORK/.agent-sandbox")"
  engine_cmd
  run bash -c 'cd "$1" && printf "y\n" | env -i HOME="$2" PATH="$3" AGENT_SANDBOX_PROFILE_DIR="$4" "${@:5}" --apply "[allow:writer]" example.org 2>&1' \
    _ "$IWORK" "$IHOME" "$I/bin:/usr/bin:/bin" "$IPROFILES" "${ENGINE_CMD[@]}"
  [ "$status" -eq 0 ]
  inside writer .agent-sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"example.org"* ]]
  [[ "$output" == *"WRITE=no"* ]]
  [[ "$output" == *"MOUNT=1"* ]]
  [ "$(stat -c %i "$IWORK/.agent-sandbox")" = "$ino" ]
  # an --init whose only change is the dot-file: a section the model gained
  printf '[connect:third]\nproject = read-only\n' >>"$M/agent-sandbox"
  asb_host --init tiny
  [ "$status" -eq 0 ]
  [[ "$output" == *"added to .agent-sandbox: [connect:third]"* ]]
  approve
  inside writer .agent-sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"[connect:third]"* ]]
  [[ "$output" == *"WRITE=no"* ]]
  [[ "$output" == *"MOUNT=1"* ]]
  run ! grep -qx x "$IWORK/.agent-sandbox"
}

@test "an --init that would change a running read-write role's purpose file is refused, nothing written; after --shutdown it goes ahead" {
  start writer
  printf 'Now also this.\n' >>"$M/roles/writer.md"
  cp "$IWORK/.asb/roles/writer.md" "$I/writer.before"
  asb_host --init tiny
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'writer': .asb/roles/writer.md would become writable for it -- first: "*" --role writer --shutdown probe"* ]]
  cmp "$I/writer.before" "$IWORK/.asb/roles/writer.md"
  inside writer .asb/roles/writer.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITE=no"* ]]
  [[ "$output" == *"MOUNT=1"* ]]
  asb_host --role writer --shutdown probe
  [ "$status" -eq 0 ]
  asb_host --init tiny
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/writer.md from model 'tiny'"* ]]
  [ "$(tail -1 "$IWORK/.asb/roles/writer.md")" = "Now also this." ]
}

@test "a role with the project read-only keeps running through an --init that changes its purpose file, and sees the new text, read-only" {
  start reader
  printf 'Now also this.\n' >>"$M/roles/reader.md"
  asb_host --init tiny
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/reader.md from model 'tiny'"* ]]
  approve
  inside reader .asb/roles/reader.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"Now also this."* ]]
  [[ "$output" == *"WRITE=no"* ]]
  [ -e "$IWORK/out/reader.in" ]
  [ "$(tail -1 "$IWORK/.asb/roles/reader.md")" = "Now also this." ]
}

@test "a role with a copy of its own over its purpose file, the project read-write: an --init that would replace the file under the copy is refused, nothing written; after --shutdown it goes ahead" {
  sed -i '/^\[connect:writer\]$/a .asb/roles/writer.md = copy' "$IWORK/.agent-sandbox"
  approve
  start writer
  inside writer .asb/roles/writer.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITE=yes"* ]] # its own copy
  [[ "$output" == *"MOUNT=1"* ]]
  [ "$(cat "$IWORK/.asb/roles/writer.md")" = "You are the writer." ] # the project's file untouched
  printf 'Now also this.\n' >>"$M/roles/writer.md"
  asb_host --init tiny
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'writer': .asb/roles/writer.md would become writable for it -- first: "*" --role writer --shutdown probe"* ]]
  [ "$(cat "$IWORK/.asb/roles/writer.md")" = "You are the writer." ]
  inside writer .asb/roles/writer.md
  [[ "$output" == *"MOUNT=1"* ]] # its copy still over the file
  asb_host --role writer --shutdown probe
  [ "$status" -eq 0 ]
  asb_host --init tiny
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated .asb/roles/writer.md from model 'tiny'"* ]]
}

@test "re-adding an instance while its old sandbox runs on its clone is refused, the clone still there for it; after --shutdown it goes ahead" {
  # a model with numbered workers, each with a clone of the project, read-write
  git -C "$IWORK" init -q
  git -C "$IWORK" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init
  M2="$I/models/clones"
  mkdir -p "$M2"
  cat >"$M2/agent-sandbox" <<'MODEL'
[connect:worker-{n}]
#@ clone = .asb/impl/{n}/ .asb/git/{n}/ impl-{n}
project = read-only
.asb/impl/{n}/ = read-write
.asb/git/{n}/ = read-write
MODEL
  rm -f "$IWORK/.agent-sandbox"
  asb_host --init clones worker=2
  [ "$status" -eq 0 ]
  approve
  start worker-2 .asb/impl/2
  asb_host --init clones worker=1 # removed while it runs: no file of it goes (#389 ii)
  [ "$status" -eq 0 ]
  [ -d "$IWORK/.asb/impl/2" ]
  asb_host --init clones worker=2
  [ "$status" -eq 2 ]
  [[ "$output" == *"role 'worker-2': .asb/impl/2 would be moved from under it"*" --role worker-2 --shutdown probe"* ]]
  [ ! -e "$IWORK/.asb/backup" ]
  run_sandboxed "${BASE[@]}" -- --role worker-2 --profile probe --exec sh -c 'ls .asb/impl/2/worker-2.in && touch .asb/impl/2/still-mine && echo WROTE'
  [[ "$output" == *"WROTE"* ]]
  [ -e "$IWORK/.asb/impl/2/still-mine" ] # its clone is where it was, and still its
  asb_host --role worker-2 --shutdown probe
  [ "$status" -eq 0 ]
  asb_host --init clones worker=2
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker-2 is added again"* ]]
  [ -d "$IWORK/.asb/backup" ]
}
