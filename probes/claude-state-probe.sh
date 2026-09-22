#!/usr/bin/env bash
# Step 4 of the session-isolation plan: find out which parts of ~/.claude Claude
# Code actually NEEDS, before we hide any of them.
#
#   bash probes/claude-state-probe.sh          RUN ON THE HOST (not in a sandbox)
#
# Method: run the real agent inside a throwaway bubblewrap that inherits the host
# filesystem and network (--bind / /) and differs only in which ~/.claude paths
# are blanked -- a tmpfs over a directory, an empty writable file over
# history.jsonl. If the agent still completes a turn, that path is not needed.
# A control run with nothing blanked comes first: if the control fails, the
# harness is wrong and every later result would be meaningless.
#
# It makes a handful of short Haiku calls, and creates one throwaway project
# under ~/.claude/projects (printed at the end so you can remove it). It never
# deletes or writes anything else in ~/.claude: the blanking is mount-only and
# lives and dies with each bwrap.
set -uo pipefail

die() {
  echo "claude-state-probe: $*" >&2
  exit 2
}
[[ -r /proc/1/cmdline ]] && [[ "$(tr '\0' ' ' </proc/1/cmdline)" == bwrap* ]] \
  && die "this is inside a sandbox; run it on the host (nested namespaces are blocked, and with AGENT_SANDBOX_SECCOMP=on unshare is denied)"
command -v bwrap >/dev/null || die "bwrap not found"
MODEL="${MODEL:-claude-haiku-4-5-20251001}"
# shellcheck disable=SC2012 # version directory names; sort -V is the point
CB="$(ls -d "$HOME"/.local/share/claude/versions/*/claude 2>/dev/null | sort -V | tail -1)"
# shellcheck disable=SC2012 # version directory names; sort -V is the point
[[ -x "$CB" ]] || CB="$(ls -d "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -V | tail -1)"
[[ -x "$CB" ]] || die "no Claude Code binary under ~/.claude... (~/.local/share/claude/versions)"
C="$HOME/.claude"
DIRS=(paste-cache file-history session-env sessions jobs shell-snapshots plans)
# Paths with NO disposition in profiles/claude.sh -- the leak study's rows 15-18 and
# the issues they produced (#52, #74-#80, #83-#86). Each of those issues is blocked on
# the same question this probe answers: does a session still work without it? A PASS
# here does not settle a disposition on its own (a path can be unneeded at startup and
# still matter to a feature, as usage-data does to /insights), but it is the input they
# are waiting on.
UNCLASSIFIED=(agent-memory usage-data feedback-bundles image-cache tasks backups
  downloads uploads output-styles agents workflows rules)
EMPTY="$(mktemp)"
trap 'rm -f "$EMPTY"' EXIT

# blank_args NAME...: bwrap arguments that blank the named paths
blank_args() {
  local n
  for n in "$@"; do
    if [[ "$n" == history.jsonl ]]; then
      printf '%s\0%s\0%s\0' --bind "$EMPTY" "$C/history.jsonl"
    elif [[ -d "$C/$n" ]]; then
      printf '%s\0%s\0' --tmpfs "$C/$n"
    fi
  done
}

# inventory NAME...: what is actually on this host, before anything is blanked. Half
# the blocked issues say "the directory does not exist on the host that measured this",
# so this is the first thing they need.
inventory() {
  local n p
  for n in "$@"; do
    p="$C/$n"
    if [[ -d "$p" ]]; then
      printf '  %-20s dir   %5s entries  %7s\n' "$n" \
        "$(find "$p" -mindepth 1 2>/dev/null | wc -l)" "$(du -sh "$p" 2>/dev/null | cut -f1)"
    elif [[ -f "$p" ]]; then
      printf '  %-20s file  %7s\n' "$n" "$(du -h "$p" 2>/dev/null | cut -f1)"
    else
      printf '  %-20s ABSENT\n' "$n"
    fi
  done
}

# try LABEL CWD -- NAMES...: one agent turn with NAMES blanked; prints PASS/FAIL
try() {
  local label="$1" cwd="$2"
  shift 3
  local -a b=()
  mapfile -d '' -t b < <(blank_args "$@")
  # A PATH THAT DOES NOT EXIST GETS NO --tmpfs, so the turn runs with nothing
  # blanked and passes -- indistinguishable from "not needed". That is a false
  # negative, and it is exactly the case several of these issues are in ("the
  # directory does not exist on the host that measured this"). Say so instead.
  # Only when names WERE given: a run with no names is a deliberate control
  # (the harness check at the top, the slug check below), which must actually run.
  if (($# > 0)) && ((${#b[@]} == 0)); then
    printf '  %-46s SKIPPED (absent: nothing was blanked)\n' "$label"
    return 0
  fi
  local out rc
  out=$(cd "$cwd" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
    "${b[@]}" "$CB" -p 'Reply with the single word ok' --model "$MODEL" </dev/null 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "${out,,}" == *ok* ]]; then
    printf '  %-46s PASS\n' "$label"
    return 0
  fi
  printf '  %-46s FAIL (rc=%s) %s\n' "$label" "$rc" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  return 1
}

echo "claude-state-probe: agent $CB, model $MODEL"
echo
echo "== control: nothing blanked (must PASS, or the rest is meaningless) =="
try "control" "$PWD" -- || die "control failed: the harness itself is wrong, not the blanking"

echo
echo "== the whole target set blanked at once =="
ALL=(history.jsonl "${DIRS[@]}")
if try "history.jsonl + ${#DIRS[@]} directories" "$PWD" -- "${ALL[@]}"; then
  echo "  -> nothing in the target set is needed to start a session"
else
  echo
  echo "== bisecting: one path at a time =="
  for n in "${ALL[@]}"; do try "$n blanked" "$PWD" -- "$n"; done
fi

echo
echo "== inventory: paths with no disposition, as they are on THIS host =="
inventory "${UNCLASSIFIED[@]}"

echo
echo "== unclassified paths, one at a time =="
echo "   (PASS = a session starts without it. Not a disposition on its own.)"
for n in "${UNCLASSIFIED[@]}"; do try "$n blanked" "$PWD" -- "$n"; done

echo
echo "== how Claude Code names a project directory (the profile must match it) =="
# The claude profile computes the slug by replacing "/" with "-" only. If Claude
# Code also rewrites other characters, memory scoping would bind a directory that
# does not exist -- silently, for any project path containing one. Test with a
# path that has both a dot and a dash.
SLUGWORK="$(mktemp -d)/probe.a-b"
mkdir -p "$SLUGWORK"
EXPECT="${SLUGWORK//\//-}"
STAMP="$C/projects/.probe-stamp"
: >"$STAMP"
if try "create a session in '$(basename "$SLUGWORK")'" "$SLUGWORK" --; then
  ACTUAL="$(find "$C/projects" -maxdepth 1 -mindepth 1 -type d -newer "$STAMP" -printf '%f\n' 2>/dev/null | head -1)"
  if [[ -z "$ACTUAL" ]]; then
    echo "  no new project directory appeared at all (print mode may not persist a session)"
  elif [[ "$ACTUAL" == "${EXPECT#-}" || "$ACTUAL" == "$EXPECT" ]]; then
    printf '  %-46s MATCH (%s)\n' "slug scheme: replace / only" "$ACTUAL"
  else
    printf '  %-46s MISMATCH\n' "slug scheme"
    echo "    profile would compute: $EXPECT"
    echo "    Claude Code actually used: $ACTUAL"
    echo "    -> profiles/claude.sh _claude_project_slug is wrong for such paths"
  fi
fi
rm -f "$STAMP"

echo
echo "== resume: does replaying a transcript survive the blanking? =="
# Deterministic: create with a known --session-id, then resume that id.
RWORK="$(mktemp -d)"
SID="$(cat /proc/sys/kernel/random/uuid)"
if (cd "$RWORK" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
  "$CB" -p 'Reply with the single word ok' --model "$MODEL" --session-id "$SID" </dev/null >/dev/null 2>&1); then
  printf '  %-46s PASS\n' "create a session with a known id"
  rb=()
  mapfile -d '' -t rb < <(blank_args "${ALL[@]}")
  out=$(cd "$RWORK" && timeout 120 bwrap --bind / / --dev-bind /dev /dev --proc /proc --share-net \
    "${rb[@]}" "$CB" -p --resume "$SID" 'Reply with the single word ok' --model "$MODEL" </dev/null 2>&1)
  rc=$?
  if [[ $rc -eq 0 && "${out,,}" == *ok* ]]; then
    printf '  %-46s PASS\n' "resume that id with the target set blanked"
  else
    printf '  %-46s FAIL (rc=%s) %s\n' "resume with the target set blanked" "$rc" "$(tr '\n' ' ' <<<"$out" | cut -c1-90)"
  fi
else
  printf '  %-46s FAIL -- cannot test resume\n' "create a session with a known id"
fi

echo
echo "claude-state-probe: done."
echo "  throwaway dirs to delete: $SLUGWORK, $RWORK"
echo "  and any new dir under $C/projects for those paths"
