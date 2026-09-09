#!/usr/bin/env bash
# Build and install kcov (bash line coverage of the engine, for scripts/coverage.sh)
# from source. kcov is not on conda-forge, nor in Ubuntu 24.04's repositories; its
# BUILD dependencies, however, are on conda-forge (preferred). binutils/libiberty
# are optional (per kcov's INSTALL.md) and are skipped.
#
# Preferred (conda-forge): have an environment with these on it, then run this:
#   mamba install -n <env> -c conda-forge cmake make pkg-config cxx-compiler \
#                                          openssl libcurl elfutils zlib
# apt fallback, only where a dep is not taken from conda:
#   sudo apt install binutils-dev build-essential cmake libssl-dev \
#        libcurl4-openssl-dev libelf-dev libstdc++-12-dev zlib1g-dev libdw-dev
#
#   scripts/install-kcov.sh [PREFIX]
# Installs into PREFIX (default: $CONDA_PREFIX if set, else /usr/local). Installing
# into the conda prefix is preferred: kcov then finds its conda libs at runtime.
set -euo pipefail
KCOV_VERSION="${KCOV_VERSION:-v43}"
PREFIX="${1:-${CONDA_PREFIX:-/usr/local}}"

for tool in git cmake make; do
  command -v "$tool" >/dev/null || {
    echo "install-kcov: '$tool' not found; install the build deps (see the header)" >&2
    exit 2
  }
done

if [[ -x "$PREFIX/bin/kcov" ]] && "$PREFIX/bin/kcov" --version 2>&1 | grep -q "$KCOV_VERSION"; then
  echo "install-kcov: $("$PREFIX/bin/kcov" --version 2>&1 | head -1) already at $PREFIX/bin/kcov"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "install-kcov: cloning kcov $KCOV_VERSION"
git clone --depth 1 --branch "$KCOV_VERSION" https://github.com/SimonKagstrom/kcov.git "$tmp/kcov"
mkdir -p "$tmp/kcov/build"
(
  cd "$tmp/kcov/build"
  cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release ..
  make -j"$(nproc 2>/dev/null || echo 2)"
  make install
)
echo "install-kcov: installed $("$PREFIX/bin/kcov" --version 2>&1 | head -1) -> $PREFIX/bin/kcov"
