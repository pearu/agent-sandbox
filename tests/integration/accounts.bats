#!/usr/bin/env bats
# Accounts (#355) with the REAL bwrap and the claude profile: a stub Claude binary
# reports, from INSIDE the sandbox, which login it sees at $CLAUDE_CONFIG_DIR and what
# else of the base is there. The unit suite (tests/unit/accounts.bats) pins the argv;
# only this shows the account's directory really is the state directory, the base's
# login really is out of reach, a channel still comes from the base, and so do the
# base's other entries (P7: a hook script, a symlink). Fixture files in a throwaway
# HOME, never a real login.

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
say hook_text "$(cat "$c/response-hook.py" 2>/dev/null || echo none)"
say link "$(readlink "$c/link" 2>/dev/null || echo none)"
say lock "$(cat "$c/.oauth_refresh.lock" 2>/dev/null || echo none)"
say skill "$(cat "$c/skills/s.md" 2>/dev/null || echo none)"
say wrote "$(printf 'inside\n' >"$c/written-inside" 2>/dev/null && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  printf 'BASE-LOGIN\n' >"$IHOME/.claude/.credentials.json"
  printf 'echo hook\n' >"$IHOME/.claude/response-hook.py"
  printf 'BASE-LOCK\n' >"$IHOME/.claude/.oauth_refresh.lock"
  ln -s somewhere "$IHOME/.claude/link"
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

@test "with an account, CLAUDE_CONFIG_DIR is the account's directory: its login, not the base's, which is nowhere inside; a channel and the base's other entries still from the base; a write lands in the account" {
  run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[config_dir]}" = "$IHOME/.claude" ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[base_login]}" = no ]
  [ "${M[hook]}" = yes ] # the base's hook script, bound at its path
  [ "${M[hook_text]}" = "echo hook" ]
  [ "${M[link]}" = somewhere ] # made again, as written
  [ "${M[lock]}" = none ]      # the base's refresh lock is the base's
  [ "${M[skill]}" = MY-SKILL ]
  [ "${M[wrote]}" = yes ]
  [ "$(cat "$ACC/written-inside")" = inside ]
  [ ! -e "$IHOME/.claude/written-inside" ]
  [ "$(cat "$IHOME/.claude/.credentials.json")" = BASE-LOGIN ]
  # no mount point left behind in the account's directory; in the base, the empty files
  # are the read-write file channels' sources it lacked that have no start: file, made
  # there on purpose (P7); one with a start: file is not made
  local left f
  left="$(find "$ACC" -maxdepth 1 -type f -empty)"
  [ -z "$left" ] || {
    echo "empty files left: $left"
    false
  }
  [ -f "$IHOME/.claude/CLAUDE.md" ]
  [ ! -e "$IHOME/.claude/policy-limits.json" ]
  [ ! -e "$IHOME/.claude/remote-settings.json" ]
  [ ! -e "$IHOME/.claude/policy-limits.json.stamp.json" ]
  while IFS= read -r f; do
    awk -v k="{base}/${f##*/}" '$1 == k && !/start:/ { found = 1 } END { exit !found }' "$REPO_ROOT/profiles/claude/agent-sandbox" || {
      echo "empty file in the base that is no file channel without a start: file: $f"
      false
    }
  done < <(find "$IHOME/.claude" -maxdepth 1 -type f -empty)
}

@test "without one, the base's login, as before" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[login]}" = BASE-LOGIN ]
  [ "${M[hook]}" = yes ]
}

@test "a channel nested in a base entry bound into an account role: its mount point is made in the base's entry, and removed after the launch" {
  mkdir -p "$IHOME/.claude/cache" # no changelog.md: the own store's mount point is made
  TEST_PRESET=isolated run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "${M[hook]}" = yes ]
  [ ! -e "$IHOME/.claude/cache/changelog.md" ]
  [ ! -e "$ACC/cache/changelog.md" ]
}

@test "a channel nested under a base entry that is a symlink: the mount point is made through the link, and removed from there after the launch" {
  mkdir -p "$IHOME/.claude/cache.real"
  ln -s cache.real "$IHOME/.claude/cache" # the changelog channel's directory, a link
  TEST_PRESET=isolated run_claude --account work
  [ "$status" -eq 0 ]
  [ "${M[login]}" = WORK-LOGIN ]
  [ "$(readlink "$ACC/cache")" = cache.real ] # made again in the account's directory
  [ ! -e "$IHOME/.claude/cache.real/changelog.md" ]
  [ ! -e "$ACC/cache.real/changelog.md" ]
}
