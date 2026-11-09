#!/usr/bin/env bats
# `asb --install claude` (#6) end to end, offline: the claude profile as shipped but for
# its resolver's key (a test copy trusting the test-only key, as resolve.bats does) and
# its versions table (2.1.999 pinned), against a fake vendor in a scratch directory given
# as AGENT_SANDBOX_INSTALL_BASE: the signed test manifest (fixtures/manifest-good.json:
# linux-x64 is the SHA-256 of `fake claude 2.1.999\n`, 20 bytes) and that binary. Needs
# gpg and curl; the manifest has a linux-x64 build only, so x86_64 hosts only.

setup() {
  load "$BATS_TEST_DIRNAME/../../helpers/common"
  [[ "$(uname -m)" == x86_64 ]] || skip "the test manifest's build is linux-x64"
  command -v gpg >/dev/null || skip "no gpg"
  make_harness
  FX="$BATS_TEST_DIRNAME/fixtures"
  P="$H/profiles2"
  C="$P/claude"
  SRC="$H/vendor"
  I="$H/home/.local/state/agent-sandbox/claude/install"
  rm -rf "$I" # the harness's installed stub: these tests install it themselves
  mkdir -p "$P" "$SRC/2.1.999/linux-x64"
  cp -r "$REPO_ROOT/profiles/claude" "$C"
  sed -i "s/^fpr=.*/fpr=58D6AC13DA5C9314B3DC8E1E2A578F4CEAF33CC5/" "$C/resolve.sh"
  cp "$FX/test-release-key.asc" "$C/release-key.asc"
  printf '2.1.999 pinned\n' >"$C/versions"
  cp "$FX/manifest-good.json" "$SRC/2.1.999/manifest.json"
  cp "$FX/manifest-good.json.sig" "$SRC/2.1.999/manifest.json.sig"
  printf 'fake claude 2.1.999\n' >"$SRC/2.1.999/linux-x64/claude"
}

install() {
  run_engine AGENT_SANDBOX_PROFILE_DIR="$P" AGENT_SANDBOX_INSTALL_BASE="$SRC" -- asb --install "$@"
}

@test "--install claude: the pin, from the signed manifest's checksum, installed as claude/install/VERSION/claude" {
  install claude
  [ "$status" -eq 0 ]
  [ "$output" = "agent-sandbox: --install: downloading claude 2.1.999 for x86_64-gnu, 0 MB, from file://$SRC/2.1.999/linux-x64/claude
agent-sandbox: --install: claude 2.1.999 is installed at ~/.local/state/agent-sandbox/claude/install/2.1.999/claude, and is now claude's current version" ]
  [ "$(cat "$I/2.1.999/claude")" = "fake claude 2.1.999" ]
  [ -x "$I/2.1.999/claude" ]
  [ "$(readlink "$I/current")" = 2.1.999 ]
}

@test "--install claude: a binary that is not the manifest's, or a manifest not signed by the key, installs nothing" {
  printf 'evil claude 2.1.999\n' >"$SRC/2.1.999/linux-x64/claude"
  install claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-sandbox: --install: the SHA-256 of file://$SRC/2.1.999/linux-x64/claude is "*", not the b08125857419ec4cbb08c18e4f3264b9820c53ab5ee63bcfc7bca824bb3488e1 its resolver gives; nothing installed" ]]
  [ -z "$(find "$I" -mindepth 1 2>/dev/null)" ]
  printf 'fake claude 2.1.999\n' >"$SRC/2.1.999/linux-x64/claude"
  printf ' ' >>"$SRC/2.1.999/manifest.json"
  install claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude resolve.sh: file://$SRC/2.1.999/manifest.json: the signature is not a good one by the release key"* ]]
  [[ "$output" == *"agent-sandbox: --install: profile 'claude''s resolver could not say which file is claude 2.1.999 for x86_64-gnu (exit 1); nothing installed" ]]
  [ -z "$(find "$I" -mindepth 1 2>/dev/null)" ]
}

@test "--install claude as shipped: a version not in its table is said untested, and still needs the vendor's signature" {
  # the test manifest is signed by the test key, not Anthropic's: the shipped resolver refuses it
  run_engine AGENT_SANDBOX_INSTALL_BASE="$SRC" -- asb --install claude@2.1.999
  [ "$status" -eq 1 ]
  [[ "$output" == "agent-sandbox: --install: claude 2.1.999 is not in profile 'claude''s versions table: it has not been tested with asb
claude resolve.sh: file://$SRC/2.1.999/manifest.json: the signature is not a good one by the release key"* ]]
  [[ "$output" == *"agent-sandbox: --install: profile 'claude''s resolver could not say which file is claude 2.1.999 for x86_64-gnu (exit 1); nothing installed" ]]
  [ -z "$(find "$H/home/.local/state/agent-sandbox/claude/install" -mindepth 1 2>/dev/null)" ]
}
