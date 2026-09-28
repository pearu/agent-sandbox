#!/usr/bin/env bash
# file-cow-spike.sh -- can `copy-on-write` work on a single FILE?
#
# overlayfs mounts directories only, so today copy-on-write on a file is `copy`. The idea
# measured here: mount an overlay whose LOWER is the file's native parent directory, at a
# staging path the sandbox never sees (as the holder/keeper does), and bind ONLY the one
# file out of the merged view at the file's path. Questions, each printed with its answer:
#
#   Q1  the file reads through from the source
#   Q2a a native rewrite IN PLACE (same inode) reaches the sandbox live
#   Q2  a native rewrite BY RENAME (how Claude Code writes its files) reaches the sandbox
#       live -- a hardlinked lower would miss it; does a parent-directory lower?
#   Q3  an in-place write inside lands in the role's upper layer, and the source is untouched
#   Q4  a rename over the file inside fails (it is a mount point), so writers fall back
#   Q5  after the copy-up, a native change is hidden (the file is the role's now)
#   Q6  nothing else of the parent directory reaches the sandbox
#
# Needs bubblewrap >= 0.11 (--overlay). No Claude Code, no network, no login.
#   bash probes/file-cow-spike.sh
set -uo pipefail
bwrap --help 2>&1 | grep -q -- '--overlay ' || {
  echo "bubblewrap has no --overlay (needs >= 0.11): $(bwrap --version)" >&2
  exit 2
}
T="$(mktemp -d /tmp/file-cow-XXXXXX)"
N="$T/native" U="$T/upper" W="$T/work" M="$T/merged" IN="$T/inside"
mkdir -p "$N" "$U" "$W" "$M" "$IN"
printf 'V1\n' >"$N/bar.txt"
printf 'SIBLING\n' >"$N/secret.txt"
: >"$IN/bar.txt" # the mount point for the one file
echo "kernel $(uname -r); $(bwrap --version); dir $T"

# native_rename TEXT -- rewrite the native file the way Claude Code does: temp + rename
native_inplace() { printf '%s\n' "$1" >"$N/bar.txt"; }
native_rename() {
  printf '%s\n' "$1" >"$N/.bar.txt.tmp" && mv -f "$N/.bar.txt.tmp" "$N/bar.txt"
}
wait_for() { # wait_for FILE -- until the inner script reaches a step
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e "$1" ]] && return 0
    sleep 0.1
  done
  echo "timed out waiting for $1" >&2
  return 1
}

# The inner script runs INSIDE the sandbox: it sees only $IN/bar.txt, bound from the merged view.
cat >"$T/inner.sh" <<'INNER'
#!/usr/bin/env bash
IN="$1" T="$2"
say() { printf '%s=%s\n' "$1" "$2" >>"$T/report"; }
say q1_read "$(cat "$IN/bar.txt")"
: >"$T/step0"
while [[ ! -e "$T/go1" ]]; do sleep 0.05; done
say q2a_after_native_inplace "$(cat "$IN/bar.txt")"
: >"$T/step1"
while [[ ! -e "$T/go2" ]]; do sleep 0.05; done
say q2_after_native_rename "$(cat "$IN/bar.txt")"
printf 'INSIDE\n' >"$IN/bar.txt" && say q3_inplace_write ok || say q3_inplace_write failed
say q3_reads_back "$(cat "$IN/bar.txt")"
printf 'RENAMED\n' >"$IN/.tmp" 2>/dev/null
mv "$IN/.tmp" "$IN/bar.txt" 2>"$T/mv.err" && say q4_rename_over succeeded || say q4_rename_over "failed: $(tr -d '\n' <"$T/mv.err")"
rm -f "$IN/.tmp"
: >"$T/step3"
while [[ ! -e "$T/go4" ]]; do sleep 0.05; done
say q5_after_second_native_rename "$(cat "$IN/bar.txt")"
say q6_inside_listing "$(ls -A "$IN" | tr '\n' ' ')"
INNER
chmod +x "$T/inner.sh"

# Outer bwrap = the keeper stand-in: it mounts the overlay at the staging path $M and runs the
# inner bwrap, which binds only $M/bar.txt at $IN/bar.txt. The inner one is the "session".
bwrap --dev-bind / / --overlay-src "$N" --overlay "$U" "$W" "$M" -- \
  bwrap --dev-bind / / --bind "$M/bar.txt" "$IN/bar.txt" -- "$T/inner.sh" "$IN" "$T" &
pid=$!
wait_for "$T/step0" && native_inplace V2A && : >"$T/go1"
wait_for "$T/step1" && native_rename V2 && : >"$T/go2"
wait_for "$T/step3" && native_rename V3 && : >"$T/go4"
wait "$pid"
echo "sandbox exit=$?"
echo
cat "$T/report"
echo
echo "host: native bar.txt = $(cat "$N/bar.txt"); upper has: [$(find "$U" -mindepth 1 -printf "%f ")]; upper bar.txt = $(cat "$U/bar.txt" 2>/dev/null || echo '-')"
echo
echo "expected: q1 V1 | q2a V2A (live after an in-place write) | q2 V2 (live after a native rename) | q3 ok, INSIDE | q4 failed (EBUSY) |"
echo "          q5 INSIDE (shadowed) | q6 bar.txt only | native V3 untouched by the sandbox | upper holds bar.txt"
chmod -R u+rwX "$T" 2>/dev/null
rm -rf -- "$T"
