#!/usr/bin/env bash
# SL-2 (implementation-plan.md §4.3): TextKit 2 NSTextView + continuous spelling/grammar, no TextKit 1
# fallback. Builds Spikes/scripts/sl2-app/main.swift into a minimal .app under Spikes/.build/sl2/,
# opens it (so it can become the active app with a key window, which continuous checking needs),
# and prints its SPIKE-RESULT lines.
#
#   Spikes/scripts/sl2-run.sh            TextKit 2 run (the real question)
#   Spikes/scripts/sl2-run.sh --control  also run the TextKit 1 control (touches .layoutManager)
#
# Local only: no network, no keys. Needs a logged-in GUI session; the window appears for a few seconds.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
spikes="$(cd "$here/.." && pwd)"
# shellcheck source=lib-bundle.sh
source "$here/lib-bundle.sh"

out="$spikes/.build/sl2"
mkdir -p "$out"
xcrun swiftc -swift-version 6 -enable-upcoming-feature ExistentialAny -O \
  -target arm64-apple-macos27.0 -o "$out/SL2SpellCheck" "$here/sl2-app/main.swift"
app="$out/SL2SpellCheck.app"
make_app_bundle "$out/SL2SpellCheck" "$app" app.bookbook.spike.sl2 SL2SpellCheck

run_mode() {
  local mode="$1" log="$out/$1.log"
  rm -f "$log"
  open -n -W --stdout "$log" --stderr "$out/$1.stderr.log" "$app" --args --mode "$mode"
  grep '^SPIKE-RESULT' "$log" || { echo "no results; see $log and $out/$1.stderr.log" >&2; return 1; }
}

run_mode tk2
if [[ "${1:-}" == "--control" ]]; then
  run_mode tk1-control
fi
