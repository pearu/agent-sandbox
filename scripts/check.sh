#!/usr/bin/env bash
# Repository checks, the same ones CI runs: syntax, shellcheck, shfmt (settings
# come from .editorconfig), the Python components compile, install.sh is in
# sync with install.sh.in + components/, the installer's --dry-run works
# against a throwaway HOME, and the bats suites (unit + integration) when
# `bats` is on PATH (it comes from environment.yml). Run from anywhere:
# scripts/check.sh
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
step() { printf '\n==> %s\n' "$*"; }
shell_files=(agent-sandbox install.sh install.sh.in scripts/*.sh profiles/*.sh tests/run.sh tests/helpers/*.sh tests/helpers/*.bash)

step "bash -n"
for f in "${shell_files[@]}"; do bash -n "$f"; done

step "shellcheck"
shellcheck -x "${shell_files[@]}"

step "shfmt -d . (formatting per .editorconfig)"
shfmt -d .

step "python components compile"
python3 -m py_compile components/*.py
rm -rf components/__pycache__

step "install.sh is in sync with install.sh.in + components/"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp install.sh "$tmp/install.sh.before"
scripts/bundle.sh >/dev/null
if ! cmp -s "$tmp/install.sh.before" install.sh; then
  echo "install.sh was stale; scripts/bundle.sh regenerated it. Commit the result." >&2
  exit 1
fi

step "install.sh --dry-run against a throwaway HOME"
mkdir -p "$tmp/home"
if ! HOME="$tmp/home" PATH="/usr/bin:/bin" ./install.sh --dry-run >"$tmp/dry.out" 2>&1; then
  cat "$tmp/dry.out" >&2
  exit 1
fi
grep -q 'symlinked .*/claude' "$tmp/dry.out" || {
  echo "dry run did not create the claude symlink:" >&2
  cat "$tmp/dry.out" >&2
  exit 1
}

step "bats: unit + integration (tests/run.sh)"
if command -v bats >/dev/null; then
  tests/run.sh
else
  echo "bats not on PATH; skipping the test suites (mamba env update -n agent-sandbox -f environment.yml)" >&2
fi

printf '\nall checks passed\n'
