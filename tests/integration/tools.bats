#!/usr/bin/env bats
# The tools env with the real bwrap: install.sh's slot bound read-only, its gh found
# before /usr/bin, `current` there so a launch from inside finds the same slot; and no
# tools env, no tools.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<'PROBE'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
w() { touch "$1" 2>/dev/null && { rm -f "$1"; echo yes; } || echo no; }
T="$HOME/.local/share/agent-sandbox/tools"
say gh "$(command -v gh)"
say gh_says "$(gh 2>/dev/null)"
say python_from_tools "$([[ "$(command -v python3)" == "$T"/* ]] && echo yes || echo no)"
say current "$(readlink "$T/current")"
say slot_writable "$(w "$T/a/env/bin/x")"
say other_slot "$([[ -e "$T/b" ]] && echo yes || echo no)"
say pkgs "$([[ -e "$T/pkgs" ]] && echo yes || echo no)"
PROBE
  T="$IHOME/.local/share/agent-sandbox/tools"
}

@test "the tools env's gh is found before /usr/bin; its slot read-only, the other slot and the cache not there" {
  mkdir -p "$T/a/env/bin" "$T/a/bin" "$T/b/bin" "$T/pkgs"
  printf '#!/bin/sh\necho tools-gh\n' >"$T/a/env/bin/gh"
  printf '#!/bin/sh\necho tools-python\n' >"$T/a/env/bin/python3"
  chmod +x "$T/a/env/bin/gh" "$T/a/env/bin/python3"
  ln -s ../env/bin/gh "$T/a/bin/gh"
  ln -s a "$T/current"
  run_sandboxed AGENT_SANDBOX_NET=none -- probe run
  [ "$status" -eq 0 ]
  [ "$(report gh)" = "$T/a/bin/gh" ]
  [ "$(report gh_says)" = tools-gh ]
  [ "$(report python_from_tools)" = no ] # in the env, not linked into bin/
  [ "$(report current)" = a ]
  [ "$(report slot_writable)" = no ]
  [ "$(report other_slot)" = no ]
  [ "$(report pkgs)" = no ]
}

@test "under --preset native too: gh from the tools env, its slot read-only over the host's home, current the host's own" {
  mkdir -p "$T/a/env/bin" "$T/a/bin"
  printf '#!/bin/sh\necho tools-gh\n' >"$T/a/env/bin/gh"
  chmod +x "$T/a/env/bin/gh"
  ln -s ../env/bin/gh "$T/a/bin/gh"
  ln -s a "$T/current"
  TEST_PRESET="" run_sandboxed AGENT_SANDBOX_NET=none -- --preset native probe run
  [ "$status" -eq 0 ]
  [ "$(report gh)" = "$T/a/bin/gh" ]
  [ "$(report gh_says)" = tools-gh ]
  [ "$(report current)" = a ]
  [ "$(report slot_writable)" = no ]
}

@test "no tools env: gh is whatever the system has" {
  run_sandboxed AGENT_SANDBOX_NET=none -- probe run
  [ "$status" -eq 0 ]
  [[ "$(report gh)" != "$T"/* ]]
  [ "$(report current)" = "" ]
}
