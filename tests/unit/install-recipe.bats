#!/usr/bin/env bats
# The install recipe as profile data (#6): [agent] install in a profile's dot-file, the
# versions table profiles/<name>/versions, and the facts _as_profile_facts emits of
# them. Read only, no launch changes: the engine sources itself and reads a scratch
# profile, "other".

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  source_engine
  P="$BATS_TEST_TMPDIR/profiles/other"
  mkdir -p "$P"
  printf 'profile_command=true\n' >"$P/profile.sh"
  # shellcheck disable=SC2034 # the profile the engine's messages name
  profile=other
}

# install_of LINE -- profile_install after reading a dot-file whose [agent] has LINE;
# what the engine says goes to $BATS_TEST_TMPDIR/said.
install_of() {
  printf '[agent]\n%s\n' "$1" >"$P/agent-sandbox"
  (
    local -a profile_install=()
    _as_profile_dotfile "$P/agent-sandbox" 2>"$BATS_TEST_TMPDIR/said" || :
    printf '%s\n' "${profile_install[*]-}"
  )
}

@test "[agent] install: 'file' and 'tar PATH' are read; any other shape is said and ignored" {
  [ "$(install_of 'install = file')" = file ]
  [ ! -s "$BATS_TEST_TMPDIR/said" ]
  [ "$(install_of 'install = tar codex-x86_64/bin/codex')" = "tar codex-x86_64/bin/codex" ]
  [ ! -s "$BATS_TEST_TMPDIR/said" ]
  local bad
  for bad in 'install = tar' 'install = file bin/x' 'install = zip x' 'install = tar a b' \
    'install = tar /abs/codex' 'install = tar ../codex' 'install = tar bin/../codex' \
    'install = tar ./codex' 'install = tar bin//codex' 'install = tar bin/' 'install =' \
    'install = tar -codex' 'install = tar bin/-codex' 'install = tar --x/codex'; do
    [ -z "$(install_of "$bad")" ]
    grep -qxF "agent-sandbox: profile 'other': $P/agent-sandbox: [agent] install takes 'file', or 'tar PATH' with PATH the binary's relative path inside the tarball; ignoring" \
      "$BATS_TEST_TMPDIR/said"
  done
}

# versions_of LINES... -- the table with these lines, read: `versions V...`, `pin V`;
# what the engine says goes to $BATS_TEST_TMPDIR/said.
versions_of() {
  printf '%s\n' "$@" >"$P/versions"
  (
    local -a profile_versions=()
    local profile_version_pin=""
    _as_profile_versions "$P/versions" 2>"$BATS_TEST_TMPDIR/said"
    printf 'versions %s\npin %s\n' "${profile_versions[*]-}" "$profile_version_pin"
  )
}

@test "versions table: one exact version per line, the pinned one marked; comments and blank lines skipped" {
  run versions_of '# tested live' '' '2.1.300' '2.1.321 pinned   # the one asb installs' '  2.2.0-rc.1' '3.0.0+b2' '1'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'versions 2.1.300 2.1.321 2.2.0-rc.1 3.0.0+b2 1\npin 2.1.321')" ]
  [ ! -s "$BATS_TEST_TMPDIR/said" ]
  # no table, no versions, nothing said
  rm "$P/versions"
  (
    local -a profile_versions=()
    local profile_version_pin=""
    _as_profile_versions "$P/versions" 2>"$BATS_TEST_TMPDIR/said"
    [ "${#profile_versions[@]}" -eq 0 ]
    [ -z "$profile_version_pin" ]
  )
  [ ! -s "$BATS_TEST_TMPDIR/said" ]
}

@test "versions table: a range, a word other than pinned, extra words and a repeat are each said and ignored" {
  run versions_of '2.1.321 pinned' '>=2.1.0' '2.1.*' '~2.1' '2.1' '2.1.3 latest' '2.1.4 pinned extra' 'v2.1.5' '2.1.321'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'versions 2.1.321 2.1\npin 2.1.321')" ]
  local f="$P/versions"
  [ "$(cat "$BATS_TEST_TMPDIR/said")" = "agent-sandbox: profile 'other': $f:2: '>=2.1.0' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:3: '2.1.*' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:4: '~2.1' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:6: '2.1.3 latest' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:7: '2.1.4 pinned extra' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:8: 'v2.1.5' is not VERSION or VERSION pinned, with VERSION exact (1.2.3); ignoring
agent-sandbox: profile 'other': $f:9: 2.1.321 is listed again; ignoring" ]
}

@test "versions table: two pinned is no pin, and versions with none pinned is said" {
  run versions_of '2.1.300 pinned' '2.1.321 pinned'
  [ "$output" = "$(printf 'versions 2.1.300 2.1.321\npin ')" ]
  [ "$(cat "$BATS_TEST_TMPDIR/said")" = "agent-sandbox: profile 'other': $P/versions: more than one version is pinned (2.1.300 2.1.321); none is the pin" ]
  run versions_of '2.1.300' '2.1.321'
  [ "$output" = "$(printf 'versions 2.1.300 2.1.321\npin ')" ]
  [ "$(cat "$BATS_TEST_TMPDIR/said")" = "agent-sandbox: profile 'other': $P/versions: no version is pinned" ]
}

@test "_as_profile_facts emits install, version and pin lines; a profile with neither emits none" {
  printf '[agent]\ninstall = tar pkg/bin/other\n' >"$P/agent-sandbox"
  printf '1.0.0\n1.1.0 pinned\nbad line here\n' >"$P/versions"
  _as_profile_facts "$P/profile.sh" >"$BATS_TEST_TMPDIR/facts"
  [ "$(grep -E '^(install|version|pin)\b' "$BATS_TEST_TMPDIR/facts")" = "$(printf 'install\tother\ttar\tpkg/bin/other\nversion\tother\t1.0.0\nversion\tother\t1.1.0\npin\tother\t1.1.0')" ]
  printf '[agent]\ninstall = file\n' >"$P/agent-sandbox"
  _as_profile_facts "$P/profile.sh" >"$BATS_TEST_TMPDIR/facts"
  grep -qxF "$(printf 'install\tother\tfile')" "$BATS_TEST_TMPDIR/facts"
  rm "$P/agent-sandbox" "$P/versions"
  _as_profile_facts "$P/profile.sh" >"$BATS_TEST_TMPDIR/facts"
  grep -qx 'loaded.other' "$BATS_TEST_TMPDIR/facts"
  run ! grep -qE '^(install|version|pin)\b' "$BATS_TEST_TMPDIR/facts"
}
