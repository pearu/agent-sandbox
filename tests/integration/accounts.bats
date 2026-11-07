#!/usr/bin/env bats
# Accounts (#355) with the REAL bwrap and the claude profile: a stub Claude binary
# reports, from INSIDE the sandbox, which login it sees at $CLAUDE_CONFIG_DIR and what
# else of the base is there. The unit suite (tests/unit/accounts.bats) pins the argv;
# only this shows the account's directory really is the state directory, the base's
# login really is out of reach, and a channel still comes from the base. Fixture files
# in a throwaway HOME, never a real login.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  I="$(mkdir -p "$BATS_TEST_TMPDIR/i" && cd "$BATS_TEST_TMPDIR/i" && pwd -P)"
  IHOME="$I/home"
  IWORK="$I/work"
  ACC="$IHOME/.local/state/agent-sandbox/claude/accounts/work"
  mkdir -p "$IHOME/.local/share/claude/versions/9.9.9" "$IWORK" "$IHOME/.claude/skills" "$ACC"
  cat >"$IHOME/.local/share/claude/versions/9.9.9/claude" <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
c="${CLAUDE_CONFIG_DIR:-unset}"
say config_dir "$c"
say login "$(cat "$c/.credentials.json" 2>/dev/null || echo none)"
say base_login "$(grep -rqs "BASE-LO""GIN" "$HOME" && echo yes || echo no)"
say hook "$([ -e "$c/response-hook.py" ] && echo yes || echo no)"
say skill "$(cat "$c/skills/s.md" 2>/dev/null || echo none)"
say wrote "$(printf 'inside\n' >"$c/written-inside" 2>/dev/null && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  printf 'BASE-LOGIN\n' >"$IHOME/.claude/.credentials.json"
  printf 'echo hook\n' >"$IHOME/.claude/response-hook.py"
  printf 'MY-SKILL\n' >"$IHOME/.claude/skills/s.md"
  printf 'WORK-LOGIN\n' >"$ACC/.credentials.json"
}

run_claude() {
  rm -f "$IWORK/report"
  engine_cmd
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm AGENT_SANDBOX_KEEPER_GRACE=0 \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" AGENT_SANDBOX_PRESET="${TEST_PRESET-shared}" \
    bash -c 'cd "$1" && shift && exec env "$@"' _ "$IWORK" "${ENGINE_CMD[@]}" "$@" "$IHOME/.local/share/claude/versions/9.9.9/claude" probe
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

@test "with an account, CLAUDE_CONFIG_DIR is the account's directory: its login, not the base's, which is nowhere inside; a channel still from the base; a write lands in the account" {
  run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[config_dir]}" = "$IHOME/.claude" ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[base_login]}" = no ]
  [ "${M[hook]}" = no ] # not before #355's per-entry binds
  [ "${M[skill]}" = MY-SKILL ]
  [ "${M[wrote]}" = yes ]
  [ "$(cat "$ACC/written-inside")" = inside ]
  [ ! -e "$IHOME/.claude/written-inside" ]
  [ "$(cat "$IHOME/.claude/.credentials.json")" = BASE-LOGIN ]
  # no mount point left behind in the account's directory, nor in the base
  local left
  left="$(find "$ACC" "$IHOME/.claude" -maxdepth 1 -type f -empty)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
}

@test "without one, the base's login, as before" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[login]}" = BASE-LOGIN ]
  [ "${M[hook]}" = yes ]
}
