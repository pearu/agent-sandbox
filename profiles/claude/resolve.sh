#!/usr/bin/env bash
# profiles/claude/resolve.sh -- the claude profile's resolver (#6): which file is
# Claude Code VERSION for PLATFORM, and what its SHA-256 must be.
#
#   resolve.sh VERSION PLATFORM [BASE]
#
# The engine's contract (docs/profiles.md, "The install recipe"): VERSION is exact (a
# line of profiles/claude/versions, or one the user asked for), PLATFORM is the
# engine's ARCH-LIBC (`uname -m`, then gnu or musl: x86_64-gnu, aarch64-musl), BASE a
# source to read instead of the vendor's -- an https:// or file:// URL, or a local
# directory -- for tests and mirrors. On success it prints one line,
# URL<TAB>SHA256<TAB>SIZE (SIZE in bytes, empty when the manifest states none), and
# exits 0; the engine downloads URL and refuses the file unless its SHA-256 is SHA256.
# A failure is said on stderr, nothing on stdout: exit 2 for arguments it does not
# take, 1 for everything else. It fetches only the manifest and its signature, never
# the binary, and runs nothing it fetched.
#
# What it trusts (vendor docs, code.claude.com/docs/en/setup, "Binary integrity and code
# signing", read 2026-11-09): each release has <BASE>/<VERSION>/manifest.json with
# platforms.<platform>.{binary,checksum,size}, signed with Anthropic's release key in
# manifest.json.sig ("from 2.1.89 onward"; an earlier version has no signature, and
# fails here). The key is release-key.asc beside this script, as published at
# https://downloads.claude.ai/keys/claude-code.asc (fetched 2026-11-09), fingerprint
# below, as the docs print it. The manifest is used only when its signature is good by
# that key and it names VERSION itself: a signed manifest of another release served at
# this VERSION's path is refused. The binary is <BASE>/<VERSION>/<platform>/<binary>
# (the vendor's install script, claude.ai/install.sh, read 2026-11-09). Platform names:
# linux-x64, linux-arm64, and the -musl variants of both.
#
# Needs curl and gpg on PATH (gpg will come with agent-sandbox's tools env). gpg runs
# in a scratch home it removes, with no agent: the user's keyring is never read.
set -euo pipefail

fpr=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
default_base=https://downloads.claude.ai/claude-code-releases

say() { printf 'claude resolve.sh: %s\n' "$*" >&2; }

if (($# < 2 || $# > 3)); then
  say "usage: resolve.sh VERSION PLATFORM [BASE]"
  exit 2
fi
version="$1" platform="$2" base="${3:-$default_base}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.]+)?$ ]] || {
  say "'$version' is not an exact version (1.2.3)"
  exit 2
}
[[ "$platform" =~ ^([a-z0-9_]+)-(gnu|musl)$ ]] || {
  say "'$platform' is not ARCH-LIBC (x86_64-gnu, aarch64-musl)"
  exit 2
}
case "${BASH_REMATCH[1]}" in
  x86_64) vplat=linux-x64 ;;
  aarch64 | arm64) vplat=linux-arm64 ;;
  *)
    say "Claude Code has no Linux build for ${BASH_REMATCH[1]}"
    exit 1
    ;;
esac
[[ "${BASH_REMATCH[2]}" == musl ]] && vplat+=-musl
case "$base" in
  https://* | file://*) ;;
  /*) base="file://$base" ;;
  *)
    say "BASE '$base' is not an https:// or file:// URL, nor an absolute directory"
    exit 2
    ;;
esac
base="${base%/}"
for t in curl gpg; do
  command -v "$t" >/dev/null || {
    say "needs $t on PATH"
    exit 1
  }
done
key="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/release-key.asc"
[[ -r "$key" ]] || {
  say "no release key at $key"
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fetch() {
  curl -fsSL --proto '=https,file' --max-filesize 1048576 -o "$2" -- "$1" 2>/dev/null || {
    say "cannot fetch $1"
    exit 1
  }
}
fetch "$base/$version/manifest.json" "$tmp/manifest.json"
fetch "$base/$version/manifest.json.sig" "$tmp/manifest.json.sig"

# The signature: good, and by the pinned key (VALIDSIG's last field is the primary key's
# fingerprint).
mkdir -m 700 -- "$tmp/gnupg"
g=(gpg --homedir "$tmp/gnupg" --batch --no-tty --no-autostart --quiet)
"${g[@]}" --import -- "$key" 2>/dev/null || {
  say "cannot read the release key $key"
  exit 1
}
if ! st="$("${g[@]}" --status-fd 1 --verify -- "$tmp/manifest.json.sig" "$tmp/manifest.json" 2>/dev/null)" \
  || ! grep -q '^\[GNUPG:\] GOODSIG ' <<<"$st" \
  || ! grep -qE "^\[GNUPG:\] VALIDSIG .* $fpr\$" <<<"$st"; then
  say "$base/$version/manifest.json: the signature is not a good one by the release key $fpr; not using it"
  exit 1
fi

# The manifest, as one line. Only the platform's own object is read ([^{}]: it holds
# no other), and only values of the shape the vendor's script accepts.
m="$(tr -d '\n\r\t' <"$tmp/manifest.json")"
[[ "$m" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" && "${BASH_REMATCH[1]}" == "$version" ]] || {
  say "$base/$version/manifest.json is signed, and is not version $version's; not using it"
  exit 1
}
[[ "$m" =~ \"$vplat\"[[:space:]]*:[[:space:]]*\{([^{}]*)\} ]] || {
  say "Claude Code $version has no $vplat build (its manifest lists none)"
  exit 1
}
obj="${BASH_REMATCH[1]}"
[[ "$obj" =~ \"checksum\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{64})\" ]] || {
  say "Claude Code $version's manifest gives $vplat no SHA-256 checksum"
  exit 1
}
sum="${BASH_REMATCH[1]}"
[[ "$obj" =~ \"binary\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_][A-Za-z0-9._-]*)\" ]] || {
  say "Claude Code $version's manifest gives $vplat no binary name"
  exit 1
}
bin="${BASH_REMATCH[1]}"
size=""
[[ "$obj" =~ \"size\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && size="${BASH_REMATCH[1]}"
printf '%s/%s/%s/%s\t%s\t%s\n' "$base" "$version" "$vplat" "$bin" "$sum" "$size"
