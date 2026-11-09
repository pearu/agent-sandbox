#!/usr/bin/env bats
# An agent asb installed (#6), with the real bwrap: a scratch profile `fakei` with an
# install recipe (`tar bin/fakei`) and a fake resolver reading a fake release source
# (AGENT_SANDBOX_INSTALL_BASE), as tests/unit/install.bats has it; `asb --install` puts two
# versions side by side, the second current. `asb fakei` then runs the current one --
# nothing named fakei is on PATH -- whose tarball also holds lib/sibling.txt: inside, the
# binary runs, its sibling is there, the version's directory is read-only, and outside
# `native` the other version is not.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  load "$BATS_TEST_DIRNAME/../helpers/integration"
  require_bwrap
  make_integration <<<'#!/bin/sh'
  F="$IPROFILES/fakei"
  SRC="$I/src"
  ROOT="$IHOME/.local/state/agent-sandbox/fakei/install"
  mkdir -p "$F" "$SRC"
  printf 'profile_command=fakei\n' >"$F/profile.sh"
  printf '[agent]\ninstall = tar bin/fakei\n' >"$F/agent-sandbox"
  printf '1.0.0\n1.1.0 pinned\n' >"$F/versions"
  cat >"$F/resolve.sh" <<'EOF'
#!/usr/bin/env bash
d="${3#file://}/$1"
[[ -f "$d/sum" ]] || exit 1
printf 'file://%s/asset\t%s\t\n' "$d" "$(cat "$d/sum")"
EOF
  chmod +x "$F/resolve.sh"
  local v
  for v in 1.0.0 1.1.0; do
    mkdir -p "$I/tree-$v/bin" "$I/tree-$v/lib" "$SRC/$v"
    # the agent: reports, from inside, what it finds beside it and whether it can write there
    cat >"$I/tree-$v/bin/fakei" <<'AGENT'
#!/usr/bin/env bash
R="$PWD/report"; : >"$R"; say() { printf '%s=%s\n' "$1" "$2" >>"$R"; }
d="$(cd -- "$(dirname -- "$0")/.." && pwd)"
say ran "$(basename -- "$d")"
say self "$0"
say sibling "$(cat "$d/lib/sibling.txt" 2>/dev/null)"
say write_new "$(touch "$d/lib/new" 2>/dev/null && echo yes || echo no)"
say write_sibling "$( (printf x >>"$d/lib/sibling.txt") 2>/dev/null && echo yes || echo no)"
say write_install "$(touch "$d/../planted" 2>/dev/null && echo yes || echo no)"
say other "$([[ -e "$d/../1.0.0" ]] && echo seen || echo absent)"
say current "$(readlink "$d/../current")"
say state "$(ls -A "$d/../.." 2>/dev/null | tr '\n' ' ')"
AGENT
    chmod +x "$I/tree-$v/bin/fakei"
    printf 'SIBLING %s\n' "$v" >"$I/tree-$v/lib/sibling.txt"
    tar -C "$I/tree-$v" -czf "$SRC/$v/asset" bin lib
    sha256sum "$SRC/$v/asset" | cut -d' ' -f1 >"$SRC/$v/sum"
    run_sandboxed AGENT_SANDBOX_INSTALL_BASE="$SRC" -- --install "fakei@$v"
    [ "$status" -eq 0 ] || {
      echo "$output"
      false
    }
  done
  [ "$(readlink "$ROOT/current")" = 1.1.0 ]
  # a role store of fakei's beside the installs, which no sandbox should see
  mkdir -p "$IHOME/.local/state/agent-sandbox/fakei/other-store"
}

@test "isolated: the current version runs from its directory, read-only, alone; the other version and the rest of the state are not there" {
  TEST_PRESET=isolated run_sandboxed AGENT_SANDBOX_NET=none -- fakei
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
  [ "$(report ran)" = 1.1.0 ]
  [ "$(report self)" = "$ROOT/1.1.0/bin/fakei" ]
  [ "$(report sibling)" = "SIBLING 1.1.0" ]
  [ "$(report write_new)" = no ]
  [ "$(report write_sibling)" = no ]
  [ "$(report write_install)" = no ]
  [ "$(report other)" = absent ]
  [ "$(report current)" = 1.1.0 ]    # made inside, so an asb run there resolves the same
  [ "$(report state)" = "install " ] # <state>/fakei holds the install alone, no store
  # nothing changed on the host
  [ "$(cat "$ROOT/1.1.0/lib/sibling.txt")" = "SIBLING 1.1.0" ]
  [ ! -e "$ROOT/1.1.0/lib/new" ]
  [ ! -e "$ROOT/planted" ]
}

@test "native: the current version runs read-only too, over the host's read-write HOME" {
  TEST_PRESET= run_sandboxed AGENT_SANDBOX_NET=none -- --preset native fakei
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
  [ "$(report ran)" = 1.1.0 ]
  [ "$(report sibling)" = "SIBLING 1.1.0" ]
  [ "$(report write_new)" = no ]
  [ "$(report write_sibling)" = no ]
  # the rest of $HOME is the host's under native, the install/ beside the version too
  [ "$(report other)" = seen ]
  [ "$(cat "$ROOT/1.1.0/lib/sibling.txt")" = "SIBLING 1.1.0" ]
  [ ! -e "$ROOT/1.1.0/lib/new" ]
}

@test "not installed: refused with the line that installs it, before any sandbox" {
  rm -rf "$ROOT"
  TEST_PRESET=isolated run_sandboxed AGENT_SANDBOX_NET=none -- fakei
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: fakei is not installed for agent-sandbox: install it, agent-sandbox --install fakei"* ]]
}
