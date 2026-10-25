#!/usr/bin/env bats
# The tools env (install.sh's conda-forge CLI tools, gh by default): bound read-only, its
# bin/ on the sandbox's PATH after the conda env and before the system directories; no
# tools env, no change. Stub bwrap, so these assert on the argv.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  make_harness
  TOOLS="$H/home/.local/share/agent-sandbox/tools"
}

# a tools env as install.sh leaves it: slot a, current naming it, bin/gh a link into env/
fake_tools() {
  mkdir -p "$TOOLS/a/env/bin" "$TOOLS/a/bin"
  printf '#!/bin/sh\necho gh version 2.103.2\n' >"$TOOLS/a/env/bin/gh"
  chmod +x "$TOOLS/a/env/bin/gh"
  ln -s ../env/bin/gh "$TOOLS/a/bin/gh"
  ln -s a "$TOOLS/current"
}

@test "no tools env: PATH and the binds are what they were" {
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value PATH)" = "$H/bin:/usr/bin:/bin" ]
  run ! grep -qF "$TOOLS" "$H/argv"
  [[ "$output" != *"tools env"* ]]
  # a current that names no slot, or a slot without bin/: not used
  mkdir -p "$TOOLS/a"
  ln -s a "$TOOLS/current"
  run_engine -- asb claude --version
  [ "$(setenv_value PATH)" = "$H/bin:/usr/bin:/bin" ]
  rm "$TOOLS/current" && ln -s /etc "$TOOLS/current"
  run_engine -- asb claude --version
  [ "$(setenv_value PATH)" = "$H/bin:/usr/bin:/bin" ]
  run ! grep -qF "$TOOLS" "$H/argv"
}

@test "the tools env: its slot read-only, current naming it inside, bin/ before /usr/bin and after the rest" {
  fake_tools
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value PATH)" = "$H/bin:$TOOLS/a/bin:/usr/bin:/bin" ]
  [[ "$output" == *"tools env $TOOLS/a on PATH before the system directories: gh"* ]]
  argv_has --ro-bind "$TOOLS/a" "$TOOLS/a"
  argv_has --symlink a "$TOOLS/current"
  run ! argv_has --bind "$TOOLS/a" "$TOOLS/a"
  run ! argv_has --ro-bind "$TOOLS" "$TOOLS" # not the other slot, not the package cache
  # /usr/local/bin is a system directory too; the user's own directories stay ahead
  run_engine PATH="$H/bin:$H/home/.local/bin:/usr/local/bin:/usr/bin:/bin" -- asb claude --version
  [ "$(setenv_value PATH)" = "$H/bin:$H/home/.local/bin:$TOOLS/a/bin:/usr/local/bin:/usr/bin:/bin" ]
  # a launch from inside one (the outer's entry already on PATH): one copy, in place
  run_engine PATH="$TOOLS/a/bin:$H/bin:/usr/bin:/bin" -- asb claude --version
  [ "$(setenv_value PATH)" = "$H/bin:$TOOLS/a/bin:/usr/bin:/bin" ]
  # AGENT_SANDBOX_HOME relocates it, as it does micromamba
  mkdir -p "$H/elsewhere"
  mv "$TOOLS" "$H/elsewhere/tools"
  run_engine AGENT_SANDBOX_HOME="$H/elsewhere" -- asb claude --version
  [ "$(setenv_value PATH)" = "$H/bin:$H/elsewhere/tools/a/bin:/usr/bin:/bin" ]
  argv_has --ro-bind "$H/elsewhere/tools/a" "$H/elsewhere/tools/a"
}

@test "the tools env goes after the conda env and micromamba, so a project's own gh wins" {
  fake_tools
  local MM="$H/home/.local/share/agent-sandbox/micromamba/bin" ROOT="$H/home/.local/share/agent-sandbox/conda"
  mkdir -p "$MM" "$ROOT/envs/proj-env/conda-meta"
  printf '#!/bin/sh\n' >"$MM/micromamba" && chmod +x "$MM/micromamba"
  printf '#!/bin/sh\nexit 1\n' >"$H/bin/conda" && printf '#!/bin/sh\nexit 1\n' >"$H/bin/mamba"
  chmod +x "$H/bin/conda" "$H/bin/mamba"
  local proj
  proj="$(cd "$H/proj" && pwd -P)"
  printf '[conda]\nbase = sandbox\nname = proj-env\n' >"$proj/.agent-sandbox"
  mkdir -p "$H/home/.config/agent-sandbox/trust"
  sha256sum -- "$proj/.agent-sandbox" | cut -d" " -f1 >"$H/home/.config/agent-sandbox/trust/$(printf "%s" "$proj" | sha256sum | cut -d" " -f1)"
  run_engine -- asb claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value PATH)" = "$MM:$ROOT/envs/proj-env/bin:$H/bin:$TOOLS/a/bin:/usr/bin:/bin" ]
}

@test "under --preset native the tools env is on PATH too: which executables are there is not state isolation" {
  fake_tools
  TEST_PRESET="" run_engine -- asb --preset native claude --version
  [ "$status" -eq 0 ]
  [ "$(setenv_value PATH)" = "$H/bin:$TOOLS/a/bin:/usr/bin:/bin" ]
  argv_has --ro-bind "$TOOLS/a" "$TOOLS/a"
  run ! argv_has --symlink a "$TOOLS/current" # the host's $HOME, its own current with it, is bound whole
}

@test "_as_path_tools: before the first system directory, at the end when there is none, one copy" {
  source_engine
  local _inner_path=""
  PATH="/a:/b" run _as_path_tools /t
  [ "$output" = "/a:/b:/t" ]
  _inner_path="/t:/a:/snap/bin:/usr/bin"
  run _as_path_tools /t
  [ "$output" = "/a:/t:/snap/bin:/usr/bin" ]
  _inner_path="/a:/bin:/usr/sbin"
  run _as_path_tools /t
  [ "$output" = "/a:/t:/bin:/usr/sbin" ]
}
