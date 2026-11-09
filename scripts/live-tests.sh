#!/bin/bash -p
# Runs the opt-in live provider tests (implementation-plan.md §2.2, §2.3).
#
#   scripts/live-tests.sh [--package DIR] [openai|gemini] [filter]
#
#   --package DIR  Swift package folder at the repo root (default: BookBookKit; Phase 0 uses
#                  Spikes). A plain folder name only, no paths.
#   provider       openai (default) or gemini. Picks the dev Keychain item to use.
#   filter         optional regex narrowing the run within LiveProviderTests, e.g. SP4_maskPolarity.
#                  Live suites must be named LiveProviderTests, or nothing matches.
#
# Environment passed through: BOOKBOOK_LIVE_BUDGET (spend cap in USD, default 10, enforced by
# LiveSpendGuard), BOOKBOOK_RECORD_FIXTURES (set by scripts/record-fixtures.sh).
#
# KEY HYGIENE: this script and scripts/record-fixtures.sh (which calls it) are the only places the
# dev key is read. It is inlined into the environment of the single `swift test` command below and
# nowhere else: no export, no set -x, no echo, no env dumps, no files. The build runs first, without
# the key, so the compiler and build tools never see it. Do not change that shape.
# `bash -p` ignores BASH_ENV and exported functions; tools are called by absolute path.
# Refuse if started with tracing (bash -x / -v), then make sure it is off.
case "$-" in *x*|*v*) set +x +v; echo "live-tests: refusing to run with shell tracing on" >&2; exit 2 ;; esac
set -euo pipefail
set +x +v

usage() { echo "usage: $0 [--package DIR] [openai|gemini] [filter]" >&2; exit 2; }

package="BookBookKit"
if [ "${1:-}" = "--package" ]; then
  [ $# -ge 2 ] || usage
  package="$2"
  shift 2
fi
provider="${1:-openai}"
filter="${2:-}"
[ $# -le 2 ] || usage

case "$provider" in
  openai) service="openai-api-key" ;;
  gemini) service="gemini-api-key" ;;
  *) usage ;;
esac

# Test filter: always inside LiveProviderTests, optionally narrowed. Only safe regex characters.
if [ -n "$filter" ]; then
  case "$filter" in
    *[!A-Za-z0-9_./*-]*) echo "live-tests: filter may only use letters, digits and _ . / * -" >&2; exit 2 ;;
  esac
  test_filter="LiveProviderTests.*${filter}"
else
  test_filter="LiveProviderTests"
fi

case "$package" in
  ""|*[!A-Za-z0-9_-]*) echo "live-tests: --package takes a folder name at the repo root, e.g. Spikes" >&2; exit 2 ;;
esac

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pkg_dir="$root/$package"
if [ ! -f "$pkg_dir/Package.swift" ]; then
  echo "live-tests: no Package.swift in $package/ (it is created in Phase 1b, or Spikes/ in Phase 0)" >&2
  exit 1
fi

# Check the Keychain item exists without reading the secret (no -w; output discarded).
account="${USER:-$(/usr/bin/id -un)}"
if ! /usr/bin/security find-generic-password -a "$account" -s "$service" >/dev/null 2>&1; then
  echo "live-tests: no Keychain item '$service' for account '$account'; nothing run" >&2
  exit 1
fi

swift_bin="$(/usr/bin/xcrun --find swift)"
cd "$pkg_dir"

echo "live-tests: building $package tests (no key in this step)"
"$swift_bin" build --build-tests

# Zero-tests check, still without the key: `swift test list` ignores --filter, so match the same
# regex against its output. SwiftPM exits 0 when a filter matches nothing; that must not look green.
listed="$("$swift_bin" test --skip-build list 2>/dev/null || true)"
matched=0
if [ -n "$listed" ]; then
  matched="$(printf '%s\n' "$listed" | /usr/bin/grep -Ec -e "$test_filter" || true)"
fi
if [ "${matched:-0}" -eq 0 ]; then
  echo "live-tests: no test matches '$test_filter' in $package; nothing run" >&2
  exit 1
fi
echo "live-tests: $matched test(s) match"

mode="live"
[ "${BOOKBOOK_RECORD_FIXTURES:-}" = "1" ] && mode="record"
echo "live-tests: running $test_filter against $provider ($mode mode, budget \$${BOOKBOOK_LIVE_BUDGET:-10})"

status=0
if [ "$provider" = "openai" ]; then
  OPENAI_API_KEY="$(/usr/bin/security find-generic-password -a "$account" -s openai-api-key -w)" \
    BOOKBOOK_LIVE_TESTS=1 "$swift_bin" test --skip-build --filter "$test_filter" || status=$?
else
  GEMINI_API_KEY="$(/usr/bin/security find-generic-password -a "$account" -s gemini-api-key -w)" \
    BOOKBOOK_LIVE_TESTS=1 "$swift_bin" test --skip-build --filter "$test_filter" || status=$?
fi

echo "live-tests: finished with exit status $status (spend log: ~/Library/Caches/BookBook-dev/live-spend.jsonl)"
exit "$status"
