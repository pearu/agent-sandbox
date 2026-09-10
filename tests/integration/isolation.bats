#!/usr/bin/env bats
# State isolation with the REAL bwrap: a stub Claude binary reports, from
# INSIDE the sandbox, whether another session's leavings are reachable. The
# unit suite asserts the argv; only this can show that the canary is actually
# invisible rather than merely unbound.

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
c="$HOME/.claude"
# the canary another session left: its verbatim file content, and its plan
say canary_readable "$(grep -rqs CANARY-FILE-CONTENT "$c/file-history" && echo yes || echo no)"
say plan_readable "$(grep -rqs CANARY-PLAN "$c/plans" && echo yes || echo no)"
say history_theirs "$(grep -qs THEIR-PROMPT "$c/history.jsonl" && echo yes || echo no)"
say history_mine "$(grep -qs MY-PROMPT "$c/history.jsonl" && echo yes || echo no)"
say paste_visible "$(ls -A "$c/paste-cache" 2>/dev/null | grep -q . && echo yes || echo no)"
# and the session can still write its own
mkdir -p "$c/file-history/MY-SESSION" 2>/dev/null
say can_write "$(printf 'mine\n' >"$c/file-history/MY-SESSION/f@v1" 2>/dev/null && echo yes || echo no)"
printf 'NEW-PROMPT\n' >>"$c/history.jsonl" 2>/dev/null
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  mkdir -p "$IHOME/.claude/projects/${IWORK//\//-}/memory" \
    "$IHOME/.claude/file-history/THEIR-SESSION" "$IHOME/.claude/plans" \
    "$IHOME/.claude/paste-cache"
  printf 'CANARY-FILE-CONTENT\n' >"$IHOME/.claude/file-history/THEIR-SESSION/abc@v1"
  printf 'CANARY-PLAN\n' >"$IHOME/.claude/plans/theirs.md"
  printf 'pasted\n' >"$IHOME/.claude/paste-cache/deadbeef.txt"
  printf '{"display":"THEIR-PROMPT","project":"/somewhere/else"}\n' >"$IHOME/.claude/history.jsonl"
  printf '{"display":"MY-PROMPT","project":"%s"}\n' "$IWORK" >>"$IHOME/.claude/history.jsonl"
}

run_claude() {
  rm -f "$IWORK/report"
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" "$@" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$IWORK" "$ENGINE" --profile claude probe
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

@test "another session's file contents, plans, prompts and pastes are unreachable from inside" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[canary_readable]}" = no ] # 40M of verbatim source on the real machine
  [ "${M[plan_readable]}" = no ]
  [ "${M[history_theirs]}" = no ]
  [ "${M[paste_visible]}" = no ]
  # ...while this project's own prompts are still there, and writing still works
  [ "${M[history_mine]}" = yes ]
  [ "${M[can_write]}" = yes ]
}

@test "what the session wrote reaches the host after it exits" {
  run_claude
  [ "$status" -eq 0 ]
  # copied out
  [ -f "$IHOME/.claude/file-history/MY-SESSION/f@v1" ]
  # appended back, exactly once, without disturbing what was there
  [ "$(grep -c NEW-PROMPT "$IHOME/.claude/history.jsonl")" -eq 1 ]
  [ "$(grep -c THEIR-PROMPT "$IHOME/.claude/history.jsonl")" -eq 1 ]
  [ "$(grep -c MY-PROMPT "$IHOME/.claude/history.jsonl")" -eq 1 ]
  # the other session's canary is exactly as it was
  grep -q CANARY-FILE-CONTENT "$IHOME/.claude/file-history/THEIR-SESSION/abc@v1"
  grep -q CANARY-PLAN "$IHOME/.claude/plans/theirs.md"
  # and no session dir is left behind
  [ -z "$(ls -A "$I/base" 2>/dev/null)" ]
}
