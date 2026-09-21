#!/usr/bin/env bash
# Part 1, mode `live`: A and B steer each other, with no delay and in both directions.
#
# THE ONE MODE THAT RUNS TODAY. `live` is what the engine does with no knob at all --
# ~/.claude bound read-write -- so this suite exercises the harness itself from the
# first run, and is the comparison arm every other mode is read against. If these
# three fail, the instrument is broken, not the engine.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-read-write

conn_cell L1 read-write "the source's instructions are readable inside"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the file-shaped channel carries the source's canary"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "the directory-shaped channel carries it too"

conn_cell L2 read-write "a write inside reaches the source -- the direction #90 reports"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the write succeeded inside"
grep -q "$inside" "$CONN_SOURCE/$CONN_CHANNEL_FILE" && got=reached || got=kept
conn_expect_host reached "$got" "and it reached the source (live is a two-way channel)"

conn_cell L3 read-write "a source change reaches the next launch"
tok1="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok1"
conn_expect obtained "launch 1 sees the first canary"
tok2="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok2"
conn_expect obtained "launch 2 sees the source's change"

conn_summary
