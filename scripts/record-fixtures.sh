#!/usr/bin/env bash
# Runs the live provider tests in fixture-record mode (implementation-plan.md §2.2).
#
#   scripts/record-fixtures.sh [--package DIR] [openai|gemini] [filter]
#
# Same arguments as scripts/live-tests.sh, which does the work: the key is read only there.
# The tests' fixture recorder saves response bodies plus allow-listed response headers, never
# request headers, and refuses to write any file whose bytes contain the key.
# Refuse if started with tracing (bash -x / -v), then make sure it is off.
case "$-" in *x*|*v*) set +x +v; echo "record-fixtures: refusing to run with shell tracing on" >&2; exit 2 ;; esac
set -euo pipefail
set +x +v

BOOKBOOK_RECORD_FIXTURES=1 exec "$(dirname "$0")/live-tests.sh" "$@"
