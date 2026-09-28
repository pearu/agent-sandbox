#!/usr/bin/env bash
# Part 1, mode `seed-only`: copied from the source once, when the sandbox's store is
# first created, and the sandbox's own from then on (#120).
#
# Its promises are copy's with the refresh taken out: seeded at the first launch, never
# written back, the sandbox's writes kept -- and a source change after that first launch
# never arrives and is never mentioned. That last one is the mode's reason to exist:
# `copy` on a file the sandbox writes at every launch would warn at every launch.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-seed-only

# THE CONTROLS' LAUNCH IS THE STORE'S FIRST LAUNCH. Every cell runs its positive controls
# before its body, and for `seed-only` that launch seeds the store -- from a source the
# cell has not written yet. `copy` never shows this, because its refresh brings the
# cell's writes in later. So a cell that asserts on the seed first writes the source,
# then discards what the controls seeded, and only then reads: that read is a first
# seeding of the source the cell set up. Measured: without it S1 and S3's first reads
# found an empty seed.
seed_fresh() {
  conn_reset
  conn_expect_host 0 "$CONN_RESET_RC" "the store the controls' launch seeded is discarded"
}

conn_cell S1 seed-only "the first launch is seeded from the source"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
seed_fresh
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the seed carries the source's canary"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "the directory shape is seeded too"

conn_cell S2 seed-only "a write inside never reaches the source"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
conn_write_inside "$CONN_CHANNEL_FILE" "$(leak_token INSIDE)"
conn_expect obtained "the write succeeded inside"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "and the source is byte-identical (no write-back, ever)"

conn_cell S3 seed-only "a source change after the first launch never arrives, and nothing is said"
tok1="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
seed_fresh
conn_read "$CONN_CHANNEL_DIR" "$tok1"
conn_expect obtained "launch 1 is seeded"
tok2="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$tok2"
conn_expect not-obtained-absent "launch 2 does not have the source's new version (no refresh)"
conn_expect_said_not "$CONN_CHANNEL_DIR" "and that launch says nothing about it (no conflict to report)"

conn_cell S4 seed-only "what the sandbox wrote persists across launches"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the next launch still has the sandbox's version"

conn_cell S5 seed-only "reset discards the store, and the next launch seeds again"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
newtok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "before the reset the sandbox's version is what it has"
conn_reset
conn_expect_host 0 "$CONN_RESET_RC" "the reset verb succeeded"
conn_read "$CONN_CHANNEL_FILE" "$newtok"
conn_expect obtained "after the reset the source's current version is the new seed"

conn_summary
