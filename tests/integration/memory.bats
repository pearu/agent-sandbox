#!/usr/bin/env bats
# Memory and every project's state, as channels (#196), with the REAL bwrap and the claude
# profile: a stub Claude binary reports, from inside the sandbox, which projects' memory
# it can see. The harness runs `shared`, where memory is your native memory.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  I="$(mkdir -p "$BATS_TEST_TMPDIR/i" && cd "$BATS_TEST_TMPDIR/i" && pwd -P)"
  IHOME="$I/home"
  IWORK="$I/work"
  mkdir -p "$IHOME/.local/share/claude/versions/9.9.9" "$IWORK"
  cat >"$IHOME/.local/share/claude/versions/9.9.9/claude" <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
w() { touch "$1" 2>/dev/null && { rm -f "$1"; echo yes; } || echo no; }
cur="${PWD//\//-}"
say projects "$(ls -A "$HOME/.claude/projects" 2>/dev/null | sort | tr '\n' ' ')"
say current_writable "$(w "$HOME/.claude/projects/$cur/memory/probe")"
say current_native "$([[ -f $HOME/.claude/projects/$cur/memory/MEMORY.md ]] && echo yes || echo no)"
say shared_readable "$([[ -f $HOME/.claude/projects/$SHARED_SLUG/memory/note.md ]] && echo yes || echo no)"
say shared_writable "$(w "$HOME/.claude/projects/$SHARED_SLUG/memory/probe")"
say other_visible "$([[ -e $HOME/.claude/projects/$OTHER_SLUG ]] && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  CUR_SLUG="${IWORK//\//-}"
  OTHER="$I/other-proj"
  SHARED="$I/shared-proj"
  OTHER_SLUG="${OTHER//\//-}"
  SHARED_SLUG="${SHARED//\//-}"
  mkdir -p "$IHOME/.claude/projects/$CUR_SLUG/memory" \
    "$IHOME/.claude/projects/$OTHER_SLUG/memory" \
    "$IHOME/.claude/projects/$SHARED_SLUG/memory"
  echo "current" >"$IHOME/.claude/projects/$CUR_SLUG/memory/MEMORY.md"
  echo "other secret" >"$IHOME/.claude/projects/$OTHER_SLUG/memory/note.md"
  echo "shared note" >"$IHOME/.claude/projects/$SHARED_SLUG/memory/note.md"
}

# run_claude [ENV=val ...] : engine as claude, from IWORK, real bwrap, net=none
# shellcheck disable=SC2120 # optional env overrides; the callers here pass none
run_claude() {
  rm -f "$IWORK/report"
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" \
    AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" \
    AGENT_SANDBOX_FORWARD="SHARED_SLUG OTHER_SLUG" SHARED_SLUG="$SHARED_SLUG" OTHER_SLUG="$OTHER_SLUG" \
    "$@" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$IWORK" "$ENGINE" "$IHOME/.local/share/claude/versions/9.9.9/claude" probe
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

trust_here() {
  mkdir -p "$IHOME/.config/agent-sandbox/trust"
  sha256sum "$IWORK/.agent-sandbox" | cut -d' ' -f1 \
    >"$IHOME/.config/agent-sandbox/trust/$(printf '%s' "$IWORK" | sha256sum | cut -d' ' -f1)"
}

@test "scoped by an approved dot-file: current writable, shared memory read-only, other project invisible" {
  printf '[share-memory]\n%s\n' "$SHARED" >"$IWORK/.agent-sandbox"
  trust_here
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[current_writable]}" = yes ]
  [ "${M[shared_readable]}" = yes ]
  [ "${M[shared_writable]}" = no ]
  [ "${M[other_visible]}" = no ]
  [[ " ${M[projects]} " == *" $CUR_SLUG "* ]]
  [[ " ${M[projects]} " == *" $SHARED_SLUG "* ]]
  [[ " ${M[projects]} " != *" $OTHER_SLUG "* ]]
}

@test "scoped is the default: with no dot-file and no config, other projects are invisible" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[current_writable]}" = yes ] # its own project's memory still works
  [ "${M[other_visible]}" = no ]     # and nothing else is reachable
  [ "${M[shared_readable]}" = no ]
}

@test "[share-memory] all opts out: every project's memory stays visible" {
  printf '[share-memory]\nall\n' >"$IWORK/.agent-sandbox"
  trust_here
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[other_visible]}" = yes ]
  [ "${M[shared_readable]}" = yes ]
  [ "${M[current_native]}" = yes ]
}

@test "under inherit, memory is the role's own: your native memory is not in view, and a write stays in the role (#196)" {
  TEST_PRESET=inherit run_claude
  [ "$status" -eq 0 ]
  [ "${M[current_native]}" = no ]    # the native MEMORY.md is not the role's
  [ "${M[current_writable]}" = yes ] # but the role writes its own
  [ "${M[other_visible]}" = no ]
  # a note written inside reaches the role's next launch, never the native tree
  local store
  store="$(find "$IHOME/.local/state/agent-sandbox/claude" -path '*/memory/own/*' -type d -name '*_memory' | head -1)"
  [ -d "$store" ]
  printf 'role note\n' >"$store/MEMORY.md"
  TEST_PRESET=inherit run_claude
  [ "${M[current_native]}" = yes ]
  [ "$(cat "$IHOME/.claude/projects/$CUR_SLUG/memory/MEMORY.md")" = current ]
}

@test "an unapproved dot-file grants nothing: the launch refuses, and its share is never made (#143)" {
  printf '[share-memory]\n%s\n' "$SHARED" >"$IWORK/.agent-sandbox"
  run_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"has never been approved"*"--trust"* ]]
  [ ! -e "$IWORK/report" ] # the agent never ran, so nothing of $SHARED was read
}
