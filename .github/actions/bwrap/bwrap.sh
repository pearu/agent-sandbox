#!/bin/bash
# The steps of .github/actions/bwrap (action.yml), and the e2e job's dry-run checks:
#   bwrap.sh key                 the cache key and the package version the rebuild makes
#   bwrap.sh install HIT KEY VER bubblewrap 0.12.0 from apt, the cache or a build
#   bwrap.sh dry-run [after]     ./install.sh --rebuild-bwrap --dry-run says what it should
# Run from the checkout's root. Writes step outputs to $GITHUB_OUTPUT.
set -euo pipefail

CACHE_DIR=${BWRAP_CACHE_DIR:-/tmp/agent-sandbox-bwrap-deb}
OS_RELEASE=${OS_RELEASE:-/etc/os-release}

die() {
  echo "::error::$*" >&2
  exit 1
}
output() { echo "$1=$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }
# VER >= 0.12.0, as install.sh's bwrap_fixed
fixed() { printf '%s\n' 0.12.0 "$1" | sort -V -C; }
# apt's candidate version of bubblewrap, empty when apt has none (install.sh's own test)
candidate() {
  apt-cache policy bubblewrap 2>/dev/null | awk '/^ *Candidate:/ && $2 != "(none)" && !c {c = $2} END {if (c) print c}'
}
installed() { dpkg-query -W -f='${Status} ${Version}\n' bubblewrap 2>/dev/null | awk '$3 == "installed" {print $4}'; }
bwrap_version() { bwrap --version 2>/dev/null | awk '{print $2}' || true; }

# The key: the rebuild's source version, the release, the architecture, and a hash of
# install.sh's BWRAP_SRC_* block (version, URL, pinned sums) and its rebuild_bwrap
# function, so a change to what or how it builds rebuilds, and nothing else in the
# installer does.
key() {
  local ins=install.sh n ver block fn codename arch hash
  n=$(grep -c '^BWRAP_SRC_VERSION=' "$ins" || true)
  [[ $n == 1 ]] || die "$ins: $n lines BWRAP_SRC_VERSION=, not exactly one"
  ver=$(sed -n 's/^BWRAP_SRC_VERSION=//p' "$ins")
  [[ -n $ver ]] || die "$ins: BWRAP_SRC_VERSION is empty"
  block=$(sed -n '/^BWRAP_SRC_VERSION=/,/^$/p' "$ins")
  n=$(grep -cE '[0-9a-f]{64}  bubblewrap_' <<<"$block" || true)
  [[ $n == 3 ]] || die "$ins: $n pinned SHA-256 sums in the BWRAP_SRC_ block, not three"
  fn=$(sed -n '/^rebuild_bwrap() {$/,/^}$/p' "$ins")
  [[ $fn == *$'\n}' ]] || die "$ins: no rebuild_bwrap() { ... } function"
  codename=$(sed -n 's/^VERSION_CODENAME=//p' "$OS_RELEASE" | tr -d "\"'")
  [[ -n $codename ]] || die "$OS_RELEASE: no VERSION_CODENAME"
  arch=$(dpkg --print-architecture)
  hash=$(printf '%s\n%s\n' "$block" "$fn" | sha256sum | cut -c1-16)
  output key "bwrap-$ver-$codename-$arch-$hash"
  output version "$ver~${codename}1"
  echo "key: bwrap-$ver-$codename-$arch-$hash"
}

# check [VER] -- bwrap runs a user-namespace sandbox, and is package version VER (and
# bwrap 0.12.0), or with no VER, any bwrap 0.12.0 or newer
check() {
  local v d
  v=$(bwrap_version)
  d=$(installed)
  echo "bwrap --version: ${v:-none}; package: ${d:-none}${1:+; wanted: $1}"
  if [[ -n ${1:-} ]]; then
    [[ $v == 0.12.0 && $d == "$1" ]] || return 1
  else
    [[ -n $v ]] && fixed "$v" || return 1
  fi
  bwrap --ro-bind / / --unshare-user --unshare-pid -- true
}

# the one .deb in the cached directory, installed with apt; its dependencies are not
# assumed present: when the first try fails, apt-get update and a second try
install_cached() {
  local debs
  mapfile -t debs < <(compgen -G "$CACHE_DIR/bubblewrap_*_$(dpkg --print-architecture).deb" || true)
  if [[ ${#debs[@]} != 1 ]]; then
    echo "the cache entry holds ${#debs[@]} bubblewrap .deb files, not one"
    return 1
  fi
  sudo apt-get install -y "${debs[0]}" \
    || { sudo apt-get update && sudo apt-get install -y "${debs[0]}"; }
}

from_apt() {
  echo "apt offers bubblewrap $1, 0.12.0 or newer: installing it; the cache is not used"
  sudo apt-get install -y bubblewrap
  check || die "bubblewrap from apt ($1) does not report 0.12.0 or newer, or cannot run a sandbox"
  output save false
}

# ./install.sh --rebuild-bwrap, and its package copied to the cached directory: the work
# directory is the one the rebuild names in its last line, the .deb the one there. Sets
# FROM_APT=1 when the rebuild found apt offering 0.12.0 instead, and installs that.
FROM_APT=0
build() {
  local log work debs c
  log=$(mktemp)
  ./install.sh --rebuild-bwrap 2>&1 | tee "$log"
  work=$(sed -e 's/\x1b\[[0-9;]*m//g' "$log" \
    | sed -n 's/^ *the package stays in \(.*\): sudo apt-get install .* reinstalls it$/\1/p')
  if [[ -z $work ]]; then
    c=$(candidate) # the rebuild has run apt-get update by now
    if [[ -n $c ]] && fixed "$c"; then
      from_apt "$c"
      FROM_APT=1
      return 0
    fi
    die "./install.sh --rebuild-bwrap built nothing (its output is above)"
  fi
  mapfile -t debs < <(compgen -G "$work/bubblewrap_*_$(dpkg --print-architecture).deb" || true)
  [[ ${#debs[@]} == 1 ]] || die "$work holds ${#debs[@]} bubblewrap .deb files, not one"
  rm -rf "$CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  cp "${debs[0]}" "$CACHE_DIR/"
}

install() {
  local hit=$1 key=$2 want=$3 c
  c=$(candidate)
  if [[ -n $c ]] && fixed "$c"; then
    from_apt "$c"
    return 0
  fi
  if [[ $hit == true ]]; then
    if install_cached && check "$want"; then
      output save false
      return 0
    fi
    echo "::warning::the cache entry $key does not give bubblewrap $want that runs a sandbox; building it instead. A saved entry is never overwritten: delete this one with  gh cache delete $key"
    # a wrong package left installed would make the rebuild see 0.12.0 and stop
    if [[ -n $(installed) ]]; then
      sudo dpkg -r bubblewrap || die "removing the bubblewrap the cache entry left failed"
    fi
  fi
  build
  ((FROM_APT)) && return 0
  check "$want" || die "the built bubblewrap is not $want, or cannot run a sandbox"
  # only a miss saves: an entry that exists under this key cannot be replaced
  output save "$([[ $hit == true ]] && echo false || echo true)"
}

# What the dry run must say on this host: nothing to rebuild on an installed 0.12.0 or
# newer, apt's own package when apt offers one, otherwise the plan. `after` (the action
# has run) also requires the first.
dry_run() {
  local have c out want
  have=$(bwrap_version)
  c=$(candidate)
  if [[ -n $have ]] && fixed "$have"; then
    want='is installed, 0.12.0 or newer: nothing to rebuild'
  elif [[ ${1:-} == after ]]; then
    die "bwrap --version is '${have:-none}' after the action, not 0.12.0 or newer"
  elif [[ -n $c ]] && fixed "$c"; then
    want="apt offers bubblewrap $c, 0.12.0 or newer: run  sudo apt install bubblewrap  instead"
  else
    want='would run: sudo apt-get build-dep -y ./bubblewrap_0.12.0-1.dsc'
  fi
  out=$(./install.sh --rebuild-bwrap --dry-run)
  printf '%s\n' "$out"
  echo "expected: ... $want"
  grep -qF -- "$want" <<<"$out" || die "the dry run does not say: $want"
  if [[ $want != would* ]] && grep -q 'would run:' <<<"$out"; then
    die "the dry run prints a plan where it should not"
  fi
}

case ${1:-} in
  key) key ;;
  install) install "$2" "$3" "$4" ;;
  dry-run) dry_run "${2:-}" ;;
  *) die "usage: bwrap.sh key | install HIT KEY VERSION | dry-run [after]" ;;
esac
