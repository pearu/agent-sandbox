#!/usr/bin/env bash
# Part 1, mode `ro`: the source's files, live, and no writing.
#
# The cost of `ro` is a feature of the AGENT, not of the mount: /model and permission
# saves write `settings`, /workflows writes `workflows`. R2 asserts only that the mount
# refuses; which features that breaks is Part 2's per-class observation.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-ro

conn_cell R1 ro "the source is readable inside"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the source's canary is inside"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "the directory shape too"

conn_cell R2 ro "a write inside fails, and the source is untouched"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
conn_write_inside "$CONN_CHANNEL_FILE" "$(leak_token INSIDE)"
conn_expect "not-obtained-unreachable" "the write is refused (EROFS recorded in the reader)"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "and the source is byte-identical"

conn_cell R3 ro "a source change is visible at the next launch"
tok1="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok1"
conn_expect obtained "launch 1 sees the first canary"
tok2="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok2"
conn_expect obtained "launch 2 sees the change (ro reads live)"

conn_summary
