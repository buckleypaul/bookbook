#!/usr/bin/env bash
# SL-3 (implementation-plan.md §4.3): WindowGroup(for: BookID.self) front-most and restoration.
# Builds the SL3WindowGroupApp product, wraps it in a minimal .app under Spikes/.build/sl3/
# (bundle id app.bookbook.spike.sl3) and opens it.
#
#   Spikes/scripts/sl3-run.sh          open the app for hand checks
#   Spikes/scripts/sl3-run.sh --auto   run the automated checks and print SPIKE-RESULT lines:
#     1. open-twice: open A, B, then A again; count windows per book and report the front window
#     2. restoration under the system default (no override): open A and B, quit with
#        NSApp.terminate (same path as Cmd-Q), relaunch, list the windows
#     3. the same with NSQuitAlwaysKeepsWindows=YES passed as a launch argument (what the user gets
#        with System Settings > Desktop & Dock > "Close windows when quitting an application" OFF)
#     4. relaunch under the system default while step 3's saved state is present (this also quits
#        under the default, which discards the saved windows and leaves things clean)
#
# Local only: no network, no keys. Needs a logged-in GUI session; windows appear for a few seconds.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
spikes="$(cd "$here/.." && pwd)"
# shellcheck source=lib-bundle.sh
source "$here/lib-bundle.sh"

bundle_id=app.bookbook.spike.sl3
name=SL3WindowGroupApp
out="$spikes/.build/sl3"
app="$out/$name.app"

(cd "$spikes" && swift build --product "$name" >/dev/null)
bin="$(cd "$spikes" && swift build --show-bin-path)"
mkdir -p "$out"
make_app_bundle "$bin/$name" "$app" "$bundle_id" "$name"

if [[ "${1:-}" != "--auto" ]]; then
  open "$app"
  echo "Opened $app (hand-check steps: Spikes/notes/local-spikes.md, SL-3)."
  exit 0
fi

# run <label> <app args...>: launch, wait for it to quit, print its SPIKE-RESULT lines.
run() {
  local label="$1"; shift
  local log="$out/$label.log"
  rm -f "$log"
  open -n -W --stdout "$log" --stderr "$out/$label.stderr.log" "$app" --args "$@"
  grep '^SPIKE-RESULT' "$log" || echo "SPIKE-RESULT SL-3 [$label] no output; see $log"
  sleep 1
}

global="$(defaults read NSGlobalDomain NSQuitAlwaysKeepsWindows 2>/dev/null || echo "unset")"
echo "SPIKE-RESULT SL-3 NSGlobalDomain NSQuitAlwaysKeepsWindows: $global" \
     "(unset/0 = 'Close windows when quitting an application' is ON, so no restoration on a normal quit)"

# AppKit keeps the saved window state outside ~/Library/Saved Application State on macOS 27 (in a
# protected container), so the script does not delete it. Instead the order keeps runs independent:
# a quit under the system default ("close windows" ON) discards the saved windows.
run open-twice --auto open-twice

echo "SPIKE-RESULT SL-3 --- restoration, system default (no override) ---"
run restore-setup-default --auto restore-setup
run restore-check-default --auto restore-check

echo "SPIKE-RESULT SL-3 --- restoration, NSQuitAlwaysKeepsWindows=YES (launch-argument override) ---"
run restore-setup-keep --auto restore-setup -NSQuitAlwaysKeepsWindows YES
run restore-check-keep --auto restore-check -NSQuitAlwaysKeepsWindows YES

echo "SPIKE-RESULT SL-3 --- saved state present, relaunched under the system default (also cleans up) ---"
run restore-check-stale --auto restore-check
