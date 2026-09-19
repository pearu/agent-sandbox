#!/usr/bin/env bash
# Part 1, mode `cow`: copy-on-write. Reads fall through to the source until the sandbox
# writes; a write makes a private copy that shadows the source's file from then on.
#
# It reads like `ro` and writes like `copy`, and it needs no refresh step at all, which
# is what makes it the default for the configuration channels: a source edit reaches
# every file the sandbox has not touched, with nothing to run and nothing to go stale.
#
# MEASURED BEFORE THESE CELLS WERE WRITTEN (bubblewrap 0.12.0, this host): deleting a
# source's file from inside an overlay does not expose anything -- it writes a WHITEOUT
# into the private layer, and the file stays hidden at every later launch while the
# source still has it. So "delete" under `cow` is a persistent hide (W5), and `reset`
# must remove whiteouts as well as copies (W6). A cell written from the intuition that
# deleting the copy "exposes the original again" would have asserted the opposite.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-cow

conn_cell W1 cow "the source reads through"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the source's canary is inside"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "the directory shape too"

conn_cell W2 cow "a source change to an untouched file arrives, with no refresh step"
tok1="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok1"
conn_expect obtained "launch 1 reads through"
tok2="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok2"
conn_expect obtained "launch 2 has the source's new version"

conn_cell W3 cow "a write shadows, and does not reach the source"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the write succeeded inside"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "the source is byte-identical"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "and the shadow persists to the next launch"

conn_cell W4 cow "a source change to a shadowed file is hidden, and named"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"   # shadow it
newtok="$(conn_source_write "$CONN_CHANNEL_FILE")" # then the source moves on
# On the FIRST launch after the source moved, for C5's reason.
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the sandbox's version still wins"
conn_expect_said "$CONN_CHANNEL_FILE" \
  "and THAT launch, the first after the source moved, NAMES the shadowed file"
conn_read "$CONN_CHANNEL_FILE" "$newtok"
conn_expect not-obtained-absent "the source's newer version is hidden by the shadow"

conn_cell W5 cow "a delete inside is a persistent hide, not a change to the source"
tok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$tok"
conn_expect obtained "launch 1 reads it through"
conn_write_inside "$CONN_CHANNEL_DIR/topic.md" "" # delete inside -> a whiteout
conn_read "$CONN_CHANNEL_DIR" "$tok"
conn_expect "not-obtained-absent|not-obtained-unreachable" "the next launch does not see it"
conn_expect_host yes "$(conn_source_exists "$CONN_CHANNEL_DIR/topic.md")" \
  "and the source still has it (the sandbox hid it, it did not delete it)"

conn_cell W6 cow "reset removes the shadow AND the whiteout"
# BOTH HALVES, because the whiteout is the half the measurement was about: a reset that
# only drops the layer's copies leaves a deleted file hidden for ever, and a cell that
# shadows without also deleting would never notice.
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"          # X, about to be shadowed
ztok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")" # Z, about to be hidden
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"  # shadow X
conn_write_inside "$CONN_CHANNEL_DIR/topic.md" "" # whiteout Z
# BOTH STATES OBSERVED BEFORE THE RESET, for C8's reason: a reset that does nothing
# passes this cell on an engine that never shadowed and never hid in the first place.
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the shadow is in place before the reset"
conn_read "$CONN_CHANNEL_DIR" "$ztok"
conn_expect "not-obtained-absent|not-obtained-unreachable" "and so is the hide"
conn_reset
conn_expect_host 0 "$CONN_RESET_RC" "the reset verb succeeded"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the shadowed file reads through from the source again"
conn_read "$CONN_CHANNEL_DIR" "$ztok"
conn_expect obtained "and the hidden one is back, so the whiteout went too"

conn_cell W7 cow "a file the source ADDS to a directory appears"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "launch 1 reads the directory through"
newtok="$(conn_source_write "$CONN_CHANNEL_DIR/second.md")"
conn_read "$CONN_CHANNEL_DIR" "$newtok"
conn_expect obtained "launch 2 sees the new entry (read-through is not only for changes)"

# W8 and W9 are recorded, not run. Each needs something this host cannot provide or the
# design has not decided, and a cell that quietly does not run is worse than one that
# says why.
conn_cell_blocked W8 cow "the emulation gives the same verdicts on a host without overlay support" \
  "needs a host with bubblewrap < 0.11 (this one has 0.12.0); run the W set there and diff the verdicts"

conn_cell_blocked W9 cow "two sessions of one sandbox at once" \
  "the engine has not decided: refuse the second session, serialise, or give each its own layer. Measured on this kernel: two overlay mounts on one upper directory are allowed and both sessions see each other's writes, which overlayfs documents as undefined -- so the cell asserts nothing until the engine chooses"

conn_summary
