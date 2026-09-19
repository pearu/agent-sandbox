#!/usr/bin/env bash
# Part 1, mode `none`: nothing of the source reaches the sandbox, nothing of the
# sandbox reaches the source, and what the sandbox creates is its own and persists.
#
# This is the floor of the scale and the shape of the `independent` preset. Its cells
# are what "completely independent" has to mean for one channel.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-none

conn_cell N1 none "the source is not there at all"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
# Closed is closed whether the path is absent or present-and-empty: which one is the
# implementation's choice, and asserting one of them would pin a decision this study
# does not own.
conn_expect "not-obtained-absent|not-obtained-unreachable" "the source's canary is not inside"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect "not-obtained-absent|not-obtained-unreachable" "nor is the directory's"

conn_cell N2 none "a write inside does not reach the source"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
conn_write_inside "$CONN_CHANNEL_FILE" "$(leak_token INSIDE)"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "the source is byte-identical after a write inside"

conn_cell N3 none "what the sandbox writes is its own, and survives the next launch"
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the write succeeded inside"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "and the next launch still has it"

conn_summary
