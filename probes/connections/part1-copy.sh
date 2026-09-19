#!/usr/bin/env bash
# Part 1, mode `copy`: seeded once from the source, refreshed where the sandbox has not
# touched a file, never written back.
#
# These eight cells are the whole definition. They exist because "copy" has a dozen
# plausible refresh rules and only one that is consistent with the mode's three
# clauses (the source reaches the sandbox at launch; the sandbox reaches the source
# never; the sandbox keeps its own state): a FILE-LEVEL three-way. No textual merge --
# with a natural-language instruction file a merge invents text nobody wrote -- no
# overwrite of the sandbox's work, and nothing written back, ever.
set -euo pipefail
# shellcheck source=probes/connections/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
conn_setup part1-copy

conn_cell C1 copy "the first launch is seeded from the source"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "the seed carries the source's canary"
dtok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$dtok"
conn_expect obtained "the directory shape is seeded too"

conn_cell C2 copy "a write inside never reaches the source"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
before="$(conn_source_sha "$CONN_CHANNEL_FILE")"
conn_write_inside "$CONN_CHANNEL_FILE" "$(leak_token INSIDE)"
conn_expect obtained "the write succeeded inside"
conn_expect_host "$before" "$(conn_source_sha "$CONN_CHANNEL_FILE")" \
  "and the source is byte-identical (no write-back, ever)"

conn_cell C3 copy "what the sandbox changed stays the sandbox's"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the next launch still has the sandbox's version"

conn_cell C4 copy "a source change to an untouched file arrives"
tok1="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$tok1"
conn_expect obtained "launch 1 is seeded"
tok2="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$tok2"
conn_expect obtained "launch 2 has the source's new version (refresh)"

conn_cell C5 copy "a conflict keeps the sandbox's file, and is named"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"   # the sandbox changes it
newtok="$(conn_source_write "$CONN_CHANNEL_FILE")" # and so does the source
# THE FIRST LAUNCH AFTER THE SOURCE MOVED is the one that must speak, and the one this
# asserts on. Reading a later launch's stderr would quietly demand that the engine repeat
# the warning for ever, which the design does not promise and a reasonable engine would
# not do.
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "the sandbox's version wins"
conn_expect_said "$CONN_CHANNEL_FILE" \
  "and THAT launch, the first after the source moved, NAMES the file it did not refresh"
conn_read "$CONN_CHANNEL_FILE" "$newtok"
conn_expect not-obtained-absent "the source's newer version did not overwrite it"

conn_cell C6 copy "a file the source deletes goes, if the sandbox never touched it"
tok="$(conn_source_write "$CONN_CHANNEL_DIR/topic.md")"
conn_read "$CONN_CHANNEL_DIR" "$tok"
conn_expect obtained "launch 1 is seeded"
conn_source_delete "$CONN_CHANNEL_DIR/topic.md"
conn_read "$CONN_CHANNEL_DIR" "$tok"
conn_expect "not-obtained-absent|not-obtained-unreachable" "launch 2 no longer has it"

conn_cell C7 copy "a file the sandbox deletes stays deleted"
tok="$(conn_source_write "$CONN_CHANNEL_FILE")"
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect obtained "launch 1 is seeded"
conn_write_inside "$CONN_CHANNEL_FILE" "" # empty text = delete
conn_read "$CONN_CHANNEL_FILE" "$tok"
conn_expect "not-obtained-absent|not-obtained-unreachable" \
  "the next launch does not resurrect it from the source"
conn_expect_host yes "$(conn_source_exists "$CONN_CHANNEL_FILE")" \
  "and the source still has its own copy"

conn_cell C8 copy "reset re-seeds from the source, and the conflict is over"
conn_source_write "$CONN_CHANNEL_FILE" >/dev/null
inside="$(leak_token INSIDE)"
conn_write_inside "$CONN_CHANNEL_FILE" "$inside"
newtok="$(conn_source_write "$CONN_CHANNEL_FILE")" # C5's conflict, now to be cleared
# A LAUNCH THAT SEES THE CONFLICT FIRST. Without it no launch ever warned, and "the
# warning is gone" afterwards would hold on an engine whose reset does nothing at all --
# an assertion about a state the cell never established.
conn_read "$CONN_CHANNEL_FILE" "$inside"
conn_expect obtained "before the reset the sandbox's version still wins"
conn_expect_said "$CONN_CHANNEL_FILE" "and the launch names the conflict"
conn_reset
conn_expect_host 0 "$CONN_RESET_RC" "the reset verb succeeded"
conn_read "$CONN_CHANNEL_FILE" "$newtok"
conn_expect obtained "after the reset the source's version is back"
# The plan's C8 asks for both halves. A warning that outlives the conflict it describes
# teaches the reader to ignore warnings, which costs C5 its value.
conn_expect_said_not "$CONN_CHANNEL_FILE" "and this launch no longer names it"

conn_summary
