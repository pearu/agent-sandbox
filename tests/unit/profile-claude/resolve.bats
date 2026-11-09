#!/usr/bin/env bats
# The claude profile's resolver, profiles/claude/resolve.sh (#6): VERSION and PLATFORM to
# the binary's URL and SHA-256, from the vendor's signed manifest. Offline: the vendor
# is a scratch directory given as BASE. Needs gpg and curl (file:// URLs).
#
# The fixtures (fixtures/): vendor-2.1.321-manifest.json and its .sig are the vendor's
# own, fetched 2026-11-09 from downloads.claude.ai/claude-code-releases/2.1.321/, so the
# shipped script checks a real signature by the pinned key. The rest are signed by a key
# made for these tests only, test-release-key.asc (its secret half was never kept):
# manifest-good.json lists linux-x64 (the SHA-256 of `fake claude 2.1.999\n`) and
# linux-arm64 but no -musl build; manifest-badsum.json is the same with linux-x64's
# checksum not a SHA-256. A test copy of the script trusts that key in place of the
# vendor's.

setup() {
  load "$BATS_TEST_DIRNAME/../../helpers/common"
  FX="$BATS_TEST_DIRNAME/fixtures"
  T="$BATS_TEST_TMPDIR"
  REAL="$REPO_ROOT/profiles/claude/resolve.sh"
  TESTFPR=58D6AC13DA5C9314B3DC8E1E2A578F4CEAF33CC5
  # the test copy: the script as shipped, but for the key and its fingerprint
  mkdir -p "$T/r"
  sed "s/^fpr=.*/fpr=$TESTFPR/" "$REAL" >"$T/r/resolve.sh"
  chmod +x "$T/r/resolve.sh"
  cp "$FX/test-release-key.asc" "$T/r/release-key.asc"
  grep -qx "fpr=$TESTFPR" "$T/r/resolve.sh"
}

# serve VERSION MANIFEST [SIG] -- the fake vendor at $T/src: VERSION's manifest and its
# signature (MANIFEST.sig unless SIG is given; `none` for no signature).
serve() {
  mkdir -p "$T/src/$1"
  cp "$FX/$2" "$T/src/$1/manifest.json"
  [[ "${3:-}" == none ]] || cp "$FX/${3:-$2.sig}" "$T/src/$1/manifest.json.sig"
}

@test "resolve.sh: the URL, SHA-256 and size of the platform's binary, from a manifest signed by the pinned key" {
  serve 2.1.999 manifest-good.json
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'file://%s/src/2.1.999/linux-x64/claude\tb08125857419ec4cbb08c18e4f3264b9820c53ab5ee63bcfc7bca824bb3488e1\t20' "$T")" ]
  [ -z "$stderr" ]
  # the same source as a file:// URL, with a trailing slash; arm64 by either name
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 aarch64-gnu "file://$T/src/"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'file://%s/src/2.1.999/linux-arm64/claude\t1111111111111111111111111111111111111111111111111111111111111111\t20' "$T")" ]
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 arm64-gnu "$T/src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/linux-arm64/claude"$'\t'* ]]
}

@test "resolve.sh as shipped: the vendor's real manifest, checked with the vendor's key" {
  serve 2.1.321 vendor-2.1.321-manifest.json
  run --separate-stderr "$REAL" 2.1.321 x86_64-gnu "$T/src"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'file://%s/src/2.1.321/linux-x64/claude\t426c33815ca6645a772f722fbff10dbf2cbdb124a8aeab733c1365dbf8bbf61f\t341910032' "$T")" ]
  run --separate-stderr "$REAL" 2.1.321 aarch64-musl "$T/src"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'file://%s/src/2.1.321/linux-arm64-musl/claude\td223ea603b4fe8521d35a47f1972fbb36f1028a40927f16160e6258e0b92d597\t325808392' "$T")" ]
  # and the key it ships is the one the vendor's docs print
  mkdir -m 700 "$T/g"
  gpg --homedir "$T/g" --batch --no-autostart --show-keys --with-colons "$REPO_ROOT/profiles/claude/release-key.asc" >"$T/keys" 2>/dev/null
  [ "$(grep -c '^pub:' "$T/keys")" -eq 1 ]
  grep -qx 'fpr:::::::::31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE:' "$T/keys"
  grep -qx 'fpr=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE' "$REAL"
}

@test "resolve.sh: a signature not by the pinned key, a manifest changed after signing, or none, is refused with nothing printed" {
  local msg="claude resolve.sh: file://$T/src/2.1.321/manifest.json: the signature is not a good one by the release key"
  # the vendor's genuine manifest, to a copy that trusts another key
  serve 2.1.321 vendor-2.1.321-manifest.json
  run --separate-stderr "$T/r/resolve.sh" 2.1.321 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "$msg $TESTFPR; not using it" ]
  # a test-signed manifest, to the script as shipped
  serve 2.1.999 manifest-good.json
  run --separate-stderr "$REAL" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "${msg//2.1.321/2.1.999} 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE; not using it" ]
  # a good signature by the key file beside the script, when that is not the pinned key
  mkdir -p "$T/swapped"
  cp "$REAL" "$T/swapped/resolve.sh"
  cp "$FX/test-release-key.asc" "$T/swapped/release-key.asc"
  run --separate-stderr "$T/swapped/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "${msg//2.1.321/2.1.999} 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE; not using it" ]
  # one checksum changed after signing
  sed -i 's/b08125857419ec4cbb08c18e4f3264b9820c53ab5ee63bcfc7bca824bb3488e1/c08125857419ec4cbb08c18e4f3264b9820c53ab5ee63bcfc7bca824bb3488e1/' "$T/src/2.1.999/manifest.json"
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "${msg//2.1.321/2.1.999} $TESTFPR; not using it" ]
  # no signature at all
  rm -rf "$T/src"
  serve 2.1.999 manifest-good.json none
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "claude resolve.sh: cannot fetch file://$T/src/2.1.999/manifest.json.sig" ]
  # no manifest: a version the vendor never released
  run --separate-stderr "$T/r/resolve.sh" 2.1.998 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ "$stderr" = "claude resolve.sh: cannot fetch file://$T/src/2.1.998/manifest.json" ]
}

@test "resolve.sh: a signed manifest of another version, a missing platform and a checksum that is not a SHA-256 are refused" {
  # a genuine signed manifest, served at another version's path
  serve 2.1.998 manifest-good.json
  run --separate-stderr "$T/r/resolve.sh" 2.1.998 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "claude resolve.sh: file://$T/src/2.1.998/manifest.json is signed, and is not version 2.1.998's; not using it" ]
  serve 2.1.999 manifest-good.json
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 x86_64-musl "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "claude resolve.sh: Claude Code 2.1.999 has no linux-x64-musl build (its manifest lists none)" ]
  rm -rf "$T/src"
  serve 2.1.999 manifest-badsum.json
  run --separate-stderr "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "claude resolve.sh: Claude Code 2.1.999's manifest gives linux-x64 no SHA-256 checksum" ]
}

@test "resolve.sh: arguments it does not take exit 2, a platform with no build exits 1, before anything is fetched" {
  local -a cases=(
    "2|claude resolve.sh: usage: resolve.sh VERSION PLATFORM [BASE]|2.1.999"
    "2|claude resolve.sh: usage: resolve.sh VERSION PLATFORM [BASE]|2.1.999 x86_64-gnu /a /b"
    "2|claude resolve.sh: '>=2.1.0' is not an exact version (1.2.3)|>=2.1.0 x86_64-gnu"
    "2|claude resolve.sh: 'stable' is not an exact version (1.2.3)|stable x86_64-gnu"
    "2|claude resolve.sh: 'x86_64' is not ARCH-LIBC (x86_64-gnu, aarch64-musl)|2.1.999 x86_64"
    "2|claude resolve.sh: 'linux-x64' is not ARCH-LIBC (x86_64-gnu, aarch64-musl)|2.1.999 linux-x64"
    "1|claude resolve.sh: Claude Code has no Linux build for riscv64|2.1.999 riscv64-gnu"
    "2|claude resolve.sh: BASE 'http://example.invalid' is not an https:// or file:// URL, nor an absolute directory|2.1.999 x86_64-gnu http://example.invalid"
    "2|claude resolve.sh: BASE 'src' is not an https:// or file:// URL, nor an absolute directory|2.1.999 x86_64-gnu src"
  )
  local c want msg
  local -a args=()
  for c in "${cases[@]}"; do
    want="${c%%|*}" c="${c#*|}" msg="${c%%|*}"
    read -r -a args <<<"${c#*|}"
    run --separate-stderr "$T/r/resolve.sh" "${args[@]}"
    [ "$status" -eq "$want" ]
    [ -z "$output" ]
    [ "$stderr" = "$msg" ]
  done
}

@test "resolve.sh: without gpg on PATH it refuses, and says so" {
  mkdir -p "$T/bin"
  local t
  for t in bash env curl dirname readlink mktemp rm mkdir tr grep; do
    ln -s "$(command -v "$t")" "$T/bin/$t"
  done
  serve 2.1.999 manifest-good.json
  run --separate-stderr env -i PATH="$T/bin" "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "claude resolve.sh: needs gpg on PATH" ]
  # with it, the same run resolves: the PATH above lacked only gpg
  ln -s "$(command -v gpg)" "$T/bin/gpg"
  run --separate-stderr env -i PATH="$T/bin" "$T/r/resolve.sh" 2.1.999 x86_64-gnu "$T/src"
  [ "$status" -eq 0 ]
}
