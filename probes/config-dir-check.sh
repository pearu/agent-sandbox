#!/usr/bin/env bash
# Viability probe for the cross-project leak study (#56): can a study run be
# confined to a throwaway CLAUDE_CONFIG_DIR, leaving the real ~/.claude and
# ~/.claude.json untouched?
#
# Runs a PINNED native claude with CLAUDE_CONFIG_DIR pointed at a throwaway
# directory and measures the real config with probes/snapshot.py before/after.
#
# The host normally has a live claude session writing its own transcript into
# ~/.claude, so a bare before/after would be full of someone else's writes. A
# CONTROL window (same measurement, no claude-under-test) is taken first:
# whatever moves during it is ambient noise, and the report subtracts it.
#
# Usage:
#   probes/config-dir-check.sh [--version V] [--control SECONDS]
#                              [--prompt] [--shared-keyring] [--project-dir DIR]
#
#   --project-dir DIR  run the session in DIR instead of a directory under the
#                      results tree. Use it to place the session OUTSIDE any git
#                      repository: the default location is nested inside this
#                      repo, and a run there produced a second project slug for
#                      the repo ROOT (holding memory/) alongside the cwd slug.
#
#   --prompt           also run `claude -p` (a real API call; costs tokens).
#                      Without it only `--version` runs, which makes no request.
#   --shared-keyring   set CLAUDE_SECURESTORAGE_CONFIG_DIR= (empty) so the run
#                      reuses the DEFAULT credential account. Setting
#                      CLAUDE_CONFIG_DIR alone gives the secure store a
#                      config-dir-derived account suffix, i.e. no credentials.
#                      This deliberately lets the run reach the real store, so
#                      expect ~/.claude/.credentials.json to be read.
#
# Results (manifests, diffs, captured output) land in probes/results/, which is
# git-ignored. Nothing here is committed or sent anywhere.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP="$REPO/probes/snapshot.py"

version=2.1.270
control=15
do_prompt=0
shared_keyring=0
project_dir=
matrix=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?--version needs a value}"
      shift 2
      ;;
    --control)
      control="${2:?--control needs a value}"
      shift 2
      ;;
    --prompt)
      do_prompt=1
      shift
      ;;
    --shared-keyring)
      shared_keyring=1
      shift
      ;;
    --project-dir)
      project_dir="${2:?--project-dir needs a value}"
      shift 2
      ;;
    --matrix)
      matrix=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

bin="$HOME/.local/share/claude/versions/$version"
[[ -x "$bin" && ! -d "$bin" ]] || {
  echo "no runnable claude at $bin" >&2
  exit 1
}
[[ -z "${CLAUDE_CONFIG_DIR:-}" ]] || {
  echo "CLAUDE_CONFIG_DIR is already set in this shell ($CLAUDE_CONFIG_DIR); refusing" >&2
  exit 1
}

work="$REPO/probes/results/config-dir-check.$(date +%Y%m%dT%H%M%S)"
ccd="$work/config"
proj="${project_dir:-$work/project}"
mkdir -p "$ccd" "$proj"
proj="$(cd "$proj" && pwd)"

# Which git repository, if any, encloses the session's cwd -- the project slug
# recorded under the config dir's projects/ is read against this.
enclosing_repo="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null || echo '(none)')"

# Enough to get past first-run onboarding without consulting the real config.
printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false}' >"$ccd/.claude.json"

snap() { python3 "$SNAP" manifest "$HOME/.claude" "$HOME/.claude.json" >"$1"; }

# Claude Code's project-slug scheme, as derived by probe in profiles/claude.sh.
slug() { printf '%s\n' "${1//[^A-Za-z0-9-]/-}"; }

tree_root=
short() {
  local s="${1/#$work\//}"
  [[ -n "$tree_root" ]] && s="${s/#$tree_root\//tree/}"
  printf '%s\n' "$s"
}

# List the project slugs a run recorded under one config dir, and what each
# holds: memory/ and the session transcript can land under DIFFERENT slugs.
report_slugs() {
  local cfg="$1" d n mem tx
  if [[ ! -d "$cfg/projects" ]]; then
    echo "      (no projects/ was created)"
    return 0
  fi
  for d in "$cfg"/projects/*; do
    [[ -e "$d" ]] || continue
    n="$(basename "$d")"
    mem=no
    tx=no
    [[ -d "$d/memory" ]] && mem=yes
    if compgen -G "$d/*.jsonl" >/dev/null; then tx=yes; fi
    printf '      memory=%-3s transcript=%-3s %s\n' "$mem" "$tx" "$n"
  done
}

# One matrix cell: a fresh config dir, a cwd with a given VCS shape, and a `-p`
# run that stops at the login check -- enough to create the project state, and
# free. API-key variables are unset so this cannot silently become a real call.
layout() {
  local name="$1" dir="$2"
  shift 2
  local cfg="$work/cfg-$name" top
  mkdir -p "$cfg" "$dir"
  printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false}' >"$cfg/.claude.json"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo '(none)')"
  echo "-- $name"
  echo "      cwd          : $(short "$dir")"
  echo "      git toplevel : $(short "$top")"
  echo "      slug(cwd)    : $(slug "$dir")"
  [[ "$top" != "(none)" ]] && echo "      slug(toplevel): $(slug "$top")"
  (
    cd "$dir" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CONFIG_DIR="$cfg" DISABLE_AUTOUPDATER=1 "$@" "$bin" -p 'probe'
  ) >"$work/out-$name" 2>&1 || true
  report_slugs "$cfg"
}

# Each matrix cell uses a FRESH config dir, so it shows what ONE session records.
# Sessions accumulate, though: this runs four of them, from nested directories of
# one repository, into ONE config dir. Transcripts are per-directory and memory
# is per-repository, so the expectation is four slugs with memory in exactly one.
run_cumulative() {
  local cfg="$work/cfg-cumulative" d
  mkdir -p "$cfg"
  printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false}' >"$cfg/.claude.json"
  echo
  echo "== cumulative: four sessions from nested dirs of ONE repository, ONE config dir =="
  for d in "$tree_root/repo" "$tree_root/repo/a" "$tree_root/repo/a/b" "$tree_root/repo/a/b/c"; do
    (
      cd "$d" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CONFIG_DIR="$cfg" DISABLE_AUTOUPDATER=1 "$bin" -p 'probe'
    ) >>"$work/out-cumulative" 2>&1 || true
    echo "      ran in $(short "$d")"
  done
  echo "   slugs recorded after all four:"
  report_slugs "$cfg"
  echo "   total slugs: $(find "$cfg/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  echo "   with memory: $(find "$cfg/projects" -mindepth 2 -maxdepth 2 -name memory -type d 2>/dev/null | wc -l)"
}

# The transcripts doc says a converted name over 200 characters is truncated to
# 200 and given "a hash of the full path" -- without saying which hash, over what
# input, or how long the suffix is. This records real slugs for three lengths so
# the scheme can be derived rather than guessed.
run_longpath() {
  local cfg d conv seg s b i j
  seg="$(printf 'x%.0s' {1..60})"
  echo
  echo "== long project paths: how a converted name over 200 chars is truncated =="
  for i in 2 4 7; do
    d="$tree_root/long$i"
    j=1
    while ((j <= i)); do
      d="$d/$seg$j"
      j=$((j + 1))
    done
    mkdir -p "$d"
    cfg="$work/cfg-long$i"
    mkdir -p "$cfg"
    printf '%s\n' '{"hasCompletedOnboarding":true,"autoUpdates":false}' >"$cfg/.claude.json"
    (
      cd "$d" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CONFIG_DIR="$cfg" DISABLE_AUTOUPDATER=1 "$bin" -p 'probe'
    ) >"$work/out-long$i" 2>&1 || true
    conv="$(slug "$d")"
    echo "-- long$i"
    echo "      path                 : $d"
    echo "      path length          : ${#d}"
    echo "      converted length     : ${#conv}"
    echo "      converted            : $conv"
    for s in "$cfg"/projects/*; do
      [[ -e "$s" ]] || continue
      b="$(basename "$s")"
      echo "      recorded slug length : ${#b}"
      echo "      recorded slug        : $b"
    done
  done
}

run_matrix() {
  # The tree MUST NOT live under $work: probes/results/ is inside this git
  # repository, so a "no VCS" cell built there would still have a git toplevel
  # (the repo) and would silently test nothing.
  tree_root="$(mktemp -d "${TMPDIR:-/tmp}/as-leak-matrix.XXXXXX")"
  local tree="$tree_root"
  local -a gc=(-c user.email=probe@example.invalid -c user.name=probe -c init.defaultBranch=main)
  echo
  echo "   layout tree: $tree  (outside any git repository)"
  mkdir -p "$tree/norepo" "$tree/repo/sub" "$tree/repo/a/b/c" "$tree/nested/outer/inner" \
    "$tree/hgrepo/.hg" "$tree/hgrepo/sub"
  git "${gc[@]}" -C "$tree/repo" init -q
  git "${gc[@]}" -C "$tree/repo" commit -q --allow-empty -m init
  git "${gc[@]}" -C "$tree/nested/outer" init -q
  git "${gc[@]}" -C "$tree/nested/outer/inner" init -q
  git "${gc[@]}" -C "$tree/repo" worktree add -q "$tree/wt" -b probe-wt >/dev/null 2>&1 \
    || echo "   (git worktree setup failed; skipping that cell)"
  ln -sfn "$tree/repo/sub" "$tree/link"

  echo
  echo "== memory-root rule: which slug holds memory/ for each cwd shape =="
  layout no-vcs "$tree/norepo"
  layout git-root "$tree/repo"
  layout git-subdir "$tree/repo/sub"
  layout git-deep-subdir "$tree/repo/a/b/c"
  layout repo-in-repo "$tree/nested/outer/inner"
  [[ -d "$tree/wt" ]] && layout git-worktree "$tree/wt"
  layout hg-only "$tree/hgrepo/sub"
  layout via-symlink "$tree/link"
  layout projdirname "$tree/repo/sub" CLAUDE_CODE_PROJECT_DIR_NAME=probe-name
  run_cumulative
  run_longpath
  return 0
}

echo "== CLAUDE_CONFIG_DIR viability probe =="
echo "   claude    : $bin"
echo "   config dir: $ccd"
echo "   project   : $proj"
echo "   enclosing git repo: $enclosing_repo"
echo "   results   : $work"
echo "   keyring   : $([[ $shared_keyring == 1 ]] && echo 'default account (shared)' || echo 'config-dir-derived account')"
echo

echo "-- m0: snapshot of the real ~/.claude + ~/.claude.json"
snap "$work/m0"
echo "   $(wc -l <"$work/m0") paths recorded"

if [[ "$control" -gt 0 ]]; then
  echo "-- control window: ${control}s, no claude-under-test"
  sleep "$control"
fi
snap "$work/m1"
python3 "$SNAP" diff "$work/m0" "$work/m1" >"$work/diff-control"
echo "   ambient changes during the control window: $(wc -l <"$work/diff-control")"

run_claude() {
  local label="$1"
  shift
  local -a env_args=(CLAUDE_CONFIG_DIR="$ccd" DISABLE_AUTOUPDATER=1)
  [[ $shared_keyring == 1 ]] && env_args+=(CLAUDE_SECURESTORAGE_CONFIG_DIR=)
  echo "-- run: claude $*"
  local rc=0
  (cd "$proj" && env "${env_args[@]}" "$bin" "$@") >"$work/out-$label" 2>&1 || rc=$?
  echo "   exit $rc; first lines of output:"
  sed -n '1,8p' "$work/out-$label" | sed 's/^/   | /'
}

# --version short-circuits before the config subsystem initialises, so it is only
# a floor. `auto-mode config` prints the effective config -- a genuine read of
# settings + global config -- and still makes no network request.
if [[ $matrix == 1 ]]; then
  run_matrix
else
  run_claude version --version
  run_claude autoconfig auto-mode config
  if [[ $do_prompt == 1 ]]; then
    run_claude prompt -p 'Reply with exactly: OK'
  fi
fi

snap "$work/m2"
python3 "$SNAP" diff "$work/m1" "$work/m2" >"$work/diff-test"

# Subtract paths that also moved in the control window -- those are the live
# session's own writes, not the probe's.
cut -f2 "$work/diff-control" | sort -u >"$work/paths-control"
awk -F'\t' 'NR==FNR { c[$0] = 1; next } !($2 in c)' \
  "$work/paths-control" "$work/diff-test" >"$work/diff-test-only"

echo
echo "== real config: changes during the test window, ambient paths subtracted =="
if [[ -s "$work/diff-test-only" ]]; then
  sed 's/^/   /' "$work/diff-test-only"
  echo
  echo "   by class: $(cut -f1 "$work/diff-test-only" | sort | uniq -c | tr '\n' ' ')"
else
  echo "   (none -- the real ~/.claude and ~/.claude.json were untouched)"
fi

if [[ $matrix == 0 ]]; then
  echo
  echo "== throwaway config dir: what the run created there =="
  python3 "$SNAP" manifest "$ccd" >"$work/ccd"
  awk -F'\t' '{ print $1 "\t" $6 }' "$work/ccd" | sed "s|$ccd|.|" | sed 's/^/   /'

  echo
  echo "== project slugs recorded under the throwaway projects/ =="
  cwd_slug="$(slug "$proj")"
  repo_slug="$(slug "$enclosing_repo")"
  if [[ -d "$ccd/projects" ]]; then
    for d in "$ccd"/projects/*; do
      [[ -e "$d" ]] || continue
      n="$(basename "$d")"
      tag=
      [[ "$n" == "$cwd_slug" ]] && tag="   <- session cwd"
      [[ "$n" == "$repo_slug" ]] && tag="   <- ENCLOSING GIT REPO, not the cwd"
      echo "   $n$tag"
      find "$d" -mindepth 1 -maxdepth 1 -printf '       %y %f\n' 2>/dev/null | sort
    done
  else
    echo "   (no projects/ directory was created)"
  fi
fi

echo
echo "full manifests and diffs: $work"
