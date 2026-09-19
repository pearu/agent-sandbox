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
# W8 was blocked on "a host we do not have". It is not any more, and not because the
# question was dropped: on a host without an overlay `cow` IS `copy`, so the question
# became "does the fallback work and say so", which `[overlay] mode = off` lets any host
# ask. The other half of W8 -- that the two implementations agree at launch granularity --
# is not a cell at all: run-all.sh runs this whole suite twice, once each way, and diffs
# the verdicts, which compares the two implementations directly instead of comparing one
# against a memory of the other.
conn_cell W8 cow "with the overlay forced off, cow is copy, and the launch says so"
conn_overlay off
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the channel still works with no overlay"
conn_expect_said 'copy' "and the launch names the implementation it fell back to"
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "a write inside succeeds"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "and does not reach the source"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "and it is still the sandbox's at the next launch, as copy promises"

# W9 is no longer blocked: the engine's answer is settled (mount once, every session
# joins), so there is a promise to assert. What is asserted here is the BEHAVIOUR a user
# is promised. The platform premise underneath it -- that joining yields one superblock
# rather than a second mount over the same upper -- is asserted by
# tests/integration/overlay-sharing.bats on every platform CI covers, and deliberately not
# here: no cell inspects layout, and a behavioural cell could not tell the safe
# arrangement from the undefined one anyway, because two independent mounts also see each
# other's writes.
conn_cell W9 cow "two sessions of one sandbox at once"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
seta="$(leak_token SESSA)"
setb="$(leak_token SESSB)"
conn_write_pair "$CONN_CHANNEL_DIR/a.md" "$seta" "$CONN_CHANNEL_DIR/b.md" "$setb"
conn_pick A
conn_expect obtained "session A's write succeeded"
conn_pick B
conn_expect obtained "session B's concurrent write succeeded (neither session is refused)"
conn_read "$CONN_CHANNEL_DIR" "$seta"
conn_expect obtained "a later launch still has A's work"
conn_read "$CONN_CHANNEL_DIR" "$setb"
conn_expect obtained "and B's: two sessions at once did not lose each other's writes"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "and the source is byte-identical throughout"

conn_summary
