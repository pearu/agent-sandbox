#!/usr/bin/env bats
# The config file with the REAL bwrap. Claude Code writes ~/.claude.json the way
# it writes every file it owns: a lock directory and a temp file created BESIDE
# it, then a rename over it. Bound at $HOME/.claude.json, beside it is the
# read-only $HOME tmpfs, so the lock and the temp file failed with EROFS, no
# fallback ran, and every write a sandboxed session made -- folder trust,
# per-project allowed tools and MCP servers, app state -- was silently lost
# (measured, Claude Code 2.1.274). The profile therefore binds the host file
# INSIDE ~/.claude and points CLAUDE_CONFIG_DIR there. This probe performs the
# writer's steps from inside, one by one, and the test reads the host afterwards.

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
f="$HOME/.claude/.claude.json"
say config_dir_env "${CLAUDE_CONFIG_DIR-unset}"
say old_path_present "$([ -e "$HOME/.claude.json" ] && echo yes || echo no)"
say new_path_present "$([ -f "$f" ] && echo yes || echo no)"
say has_seed "$(grep -c '"seed": *1' "$f" 2>/dev/null)"
say own_entry "$(grep -c '"own": *true' "$f" 2>/dev/null)"
say other_project_visible "$(grep -q SECRET "$f" 2>/dev/null && echo yes || echo no)"
# the writer's steps: lock directory, temp file, rename over the target
say lock_mkdir "$(mkdir "$f.lock" 2>/dev/null && { rmdir "$f.lock"; echo yes; } || echo no)"
say tmp_create "$(: >"$f.tmp.probe" 2>/dev/null && echo yes || echo no)"
say rename_over "$(mv "$f.tmp.probe" "$f" 2>/dev/null && echo yes || echo no)"
rm -f "$f.tmp.probe"
# ...and the in-place rewrite Claude Code falls back to when the rename fails
say inplace_write "$(printf '{"written":"inside"}' >"$f" 2>/dev/null && echo yes || echo no)"
PROBE
  chmod +x "$IHOME/.local/share/claude/versions/9.9.9/claude"
  mkdir -p "$IHOME/.claude"
  # the host file: this project's entry, and another project's with a secret in it
  printf '{"seed":1,"projects":{"%s":{"own":true},"/elsewhere":{"lastSessionFirstPrompt":"SECRET"}}}' "$IWORK" >"$IHOME/.claude.json"
  cp "$IHOME/.claude.json" "$I/host-before.json"
  COPY="$IHOME/.local/state/agent-sandbox/claude/${IWORK//[^A-Za-z0-9-]/-}/claude.json"
}

run_claude() {
  rm -f "$IWORK/report"
  # shellcheck disable=SC2016 # $1/$@ are for the inner bash -c, not this shell
  run env -i HOME="$IHOME" PATH="/usr/bin:/bin" USER="$(id -un)" TERM=xterm \
    AGENT_SANDBOX_PROFILE_DIR="$REPO_ROOT/profiles" AGENT_SANDBOX_NET=none \
    AGENT_SANDBOX_SESSION_BASE="$I/base" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$IWORK" "$ENGINE" --profile claude probe
  declare -gA M=()
  local k v
  while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$IWORK/report" 2>/dev/null || true
}

@test "inside: the config file is at ~/.claude/.claude.json and is this project's copy (its own entry, no other project's); CLAUDE_CONFIG_DIR points there; lock and temp file work beside it; the rename fails on the mount point; the in-place write reaches the copy and never the host file" {
  run_claude
  [ "$status" -eq 0 ]
  [ "${M[config_dir_env]}" = "$IHOME/.claude" ]
  [ "${M[old_path_present]}" = no ] # nothing at $HOME/.claude.json any more
  [ "${M[new_path_present]}" = yes ]
  [ "${M[has_seed]}" = 1 ]
  [ "${M[own_entry]}" = 1 ]
  [ "${M[other_project_visible]}" = no ]
  # the lock directory and the temp file: beside a read-only $HOME both failed with EROFS
  [ "${M[lock_mkdir]}" = yes ]
  [ "${M[tmp_create]}" = yes ]
  [ "${M[rename_over]}" = no ] # EBUSY: a bind mount cannot be renamed over
  [ "${M[inplace_write]}" = yes ]
  # the project's copy carries what was written inside; the host's file is untouched
  [ "$(cat "$COPY")" = '{"written":"inside"}' ]
  cmp "$IHOME/.claude.json" "$I/host-before.json"
  # the empty mount-point file bwrap created inside ~/.claude is gone again
  [ ! -e "$IHOME/.claude/.claude.json" ]
  # and no session dir is left behind
  [ -z "$(ls -A "$I/base" 2>/dev/null)" ]
}
