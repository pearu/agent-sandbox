#!/usr/bin/env bash
# Run "$@" with the installer's root check seeing euid 0, without being root.
# The guard calls `id -u`, so a shim earlier on PATH answers 0 for that one
# question and defers to the real id for everything else. (This is why the
# guard does not read $EUID: bash keeps it readonly and always set, so there
# would be no way to exercise the check without actually being root.)
set -euo pipefail
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
# The $1/$@ below belong to the generated script, not to this one.
# shellcheck disable=SC2016
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi\n' >"$d/id"
chmod +x "$d/id"
PATH="$d:$PATH" exec "$@"
