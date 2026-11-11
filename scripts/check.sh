#!/usr/bin/env bash
# Repository checks, the same ones CI runs: syntax, shellcheck, shfmt (settings
# come from .editorconfig), the Python components compile, install.sh is in
# sync with install.sh.in + components/, the Markdown prose a branch adds is at
# most 88 columns wide, the installer's --dry-run works against a throwaway
# HOME, and the bats suites (unit + integration) when `bats` is on PATH (it
# comes from environment.yml). Run from anywhere:
# scripts/check.sh
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
step() { printf '\n==> %s\n' "$*"; }
# All file lists come from `git ls-files`, so the checks judge what is TRACKED,
# not whatever happens to sit in the working tree. A stray local note or a
# review artifact under a gitignored dir used to fail an otherwise-clean tree
# (it tripped shfmt, and a repo-wide grep in docs.bats) -- CI, on a clean
# checkout, stayed green while a maintainer's local run went red for no real
# defect.
# probes/ are host-only scripts, never run in CI -- but they are shell, and the
# bats suites show what happens to code the linter is not pointed at.
mapfile -t shell_files < <(git ls-files -- agent-sandbox install.sh install.sh.in 'scripts/*.sh' 'profiles/*.sh' 'profiles/*/test.bash' tests/run.sh 'tests/helpers/*.sh' 'tests/helpers/*.bash' 'probes/*.sh' 'probes/*/*.sh' 'models/*/bin/*')
# The bats suites are shell too, and ShellCheck parses @test natively. They
# were left out of this list once, and 50 negative assertions that could not
# fail (`! cmd`; SC2314) accumulated where the one linter that knows about
# that bug was not looking. Not under `bash -n`: @test is not bash syntax.
mapfile -t bats_files < <(git ls-files -- 'tests/*/*.bats')
# Everything shfmt formats, tracked only (the engine and a model's bin/ scripts have no
# extension).
mapfile -t fmt_files < <(git ls-files -- '*.sh' '*.bash' '*.bats' agent-sandbox install.sh.in 'models/*/bin/*')

step "bash -n"
for f in "${shell_files[@]}"; do bash -n "$f"; done

step "shellcheck"
shellcheck -x "${shell_files[@]}"
step "shellcheck (bats suites)"
shellcheck -x "${bats_files[@]}"
step "no bare negation in the bats suites (\`! cmd\` asserts nothing; use \`run ! cmd\`)"
# SC2314 above flags `! cmd` in an @test, but not in a function registered with
# bats_test_function (tests/*/profile-contract.bats, the live and e2e agent tests), which
# ShellCheck does not take for a test: measured, `fn() { ! true; echo after; }` registered
# so runs ok, unflagged. This grep is the guard there. `run !`, `[ ! ...` and `[[ ! ...`
# do not start with `!`, so they pass.
if grep -nE '^[[:space:]]*![[:space:]]' "${bats_files[@]}"; then
  echo "a bare negation in a bats suite (above) asserts nothing: write \`run ! cmd\`" >&2
  exit 1
fi

step "shfmt -d (tracked files, formatting per .editorconfig)"
shfmt -d "${fmt_files[@]}"

step "python components compile"
python3 -m py_compile components/*.py profiles/*/*.py probes/*.py probes/*/*.py scripts/*.py
rm -rf components/__pycache__ profiles/*/__pycache__ probes/__pycache__ probes/*/__pycache__ scripts/__pycache__

step "ruff (Python lint, rules pinned in ruff.toml)"
ruff check --no-cache components/ profiles/ probes/ scripts/

step "Markdown prose this branch adds keeps to 88 columns (scripts/prose-width.py)"
# Judged against where the branch left main, so an old line is never blamed on a new
# change: on a pull request the workflow's base branch (CI checks out the full history for
# it), else origin/main, else main. When HEAD is the base itself -- CI's push to main, or a
# local run on main -- a push compares against the previous commit and a local run against
# HEAD, which leaves the uncommitted edits.
pw_ref="${GITHUB_BASE_REF:+origin/$GITHUB_BASE_REF}"
if [[ -z "$pw_ref" ]]; then
  pw_ref=main
  if git rev-parse -q --verify origin/main >/dev/null; then pw_ref=origin/main; fi
fi
pw_base="$(git merge-base HEAD "$pw_ref")"
if [[ "$pw_base" == "$(git rev-parse HEAD)" && "${GITHUB_EVENT_NAME:-}" == push ]]; then
  pw_base="$(git rev-parse HEAD~1)"
fi
echo "base: $pw_ref, merge base ${pw_base:0:12}"
python3 scripts/prose-width.py --base "$pw_base"

step "seccomp generator compiles a filter for x86_64 and aarch64 (pyseccomp)"
if python3 -c 'import pyseccomp' 2>/dev/null; then
  sc_tmp="$(mktemp -d)"
  for sc_arch in x86_64 aarch64; do
    python3 components/seccomp/gen-seccomp.py components/seccomp/moby-default.json "$sc_arch" "$sc_tmp/$sc_arch.bpf" 2>/dev/null
    [[ -s "$sc_tmp/$sc_arch.bpf" ]] || {
      echo "gen-seccomp.py produced no filter for $sc_arch" >&2
      rm -rf "$sc_tmp"
      exit 1
    }
  done
  echo "ok: $(wc -c <"$sc_tmp/x86_64.bpf") bytes x86_64, $(wc -c <"$sc_tmp/aarch64.bpf") bytes aarch64"
  rm -rf "$sc_tmp"
else
  echo "pyseccomp not importable; skipping (mamba env update -n agent-sandbox -f environment.yml)"
fi

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
if ! HOME="$tmp/home" PATH="$tmp/home/.local/bin:/usr/bin:/bin" ./install.sh --dry-run >"$tmp/dry.out" 2>&1; then
  cat "$tmp/dry.out" >&2
  exit 1
fi
grep -qE 'symlinked .*/\.local/bin/asb ' "$tmp/dry.out" || {
  echo "dry run did not create the asb symlink:" >&2
  cat "$tmp/dry.out" >&2
  exit 1
}
# and nothing at the agent's own name (#151)
[[ ! -e "$tmp/home/.local/bin/claude" ]] || {
  echo "dry run put something at ~/.local/bin/claude:" >&2
  ls -l "$tmp/home/.local/bin/claude" >&2
  exit 1
}

step "bats: unit + integration (tests/run.sh)"
# AGENT_SANDBOX_CHECK_TESTS=0 skips them: CI runs the suites as a matrix of shards.
if [[ "${AGENT_SANDBOX_CHECK_TESTS:-1}" == 0 ]]; then
  echo "skipped (AGENT_SANDBOX_CHECK_TESTS=0)"
elif command -v bats >/dev/null; then
  tests/run.sh
else
  echo "bats not on PATH; skipping the test suites (mamba env update -n agent-sandbox -f environment.yml)" >&2
fi

printf '\nall checks passed\n'
