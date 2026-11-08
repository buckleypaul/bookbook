#!/usr/bin/env bash
# Runs locally exactly what CI runs (implementation-plan.md §5, Phase 1; architecture.md §12).
#
#   scripts/test.sh [all|secrets|bootstrap|kit|spikes|xcodeproj|app|release]   (default: all)
#
# KEY HYGIENE: this script never touches API keys. It does not read the Keychain and it clears the
# live-test switches, so live tests always skip. Live runs go only through scripts/live-tests.sh.
# Refuse if started with tracing (bash -x / -v), then make sure it is off.
case "$-" in *x*|*v*) set +x +v; echo "test: refusing to run with shell tracing on" >&2; exit 2 ;; esac
set -euo pipefail
set +x +v

unset BOOKBOOK_LIVE_TESTS OPENAI_API_KEY GEMINI_API_KEY BOOKBOOK_RECORD_FIXTURES

XCODEGEN_VERSION="2.46.0"

usage() { echo "usage: $0 [all|secrets|bootstrap|kit|spikes|xcodeproj|app|release]" >&2; exit 2; }
[ $# -le 1 ] || usage
step="${1:-all}"
case "$step" in all|secrets|bootstrap|kit|spikes|xcodeproj|app|release) ;; *) usage ;; esac

cd "$(git rev-parse --show-toplevel)"

# Pipe through xcbeautify when installed; xcodebuild's exit status is kept by pipefail.
pretty() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi; }

step_secrets()   { scripts/secret-scan.sh; }
step_bootstrap() { scripts/tests/test-bootstrap.sh; }
step_kit()       { (cd BookBookKit && swift test --parallel); }
# Spikes: live suites skip themselves (no env switch, no key). SL-2 skips without a GUI session.
step_spikes()    { (cd Spikes && swift test); }

step_xcodeproj() {
  command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen $XCODEGEN_VERSION is required (brew install xcodegen)" >&2; return 1; }
  local have; have="$(xcodegen --version | sed -n 's/^Version: *//p')"
  [ "$have" = "$XCODEGEN_VERSION" ] || { echo "xcodegen must be exactly $XCODEGEN_VERSION, found '$have'" >&2; return 1; }
  xcodegen generate --spec project.yml
  if ! git diff --exit-code -- BookBook.xcodeproj; then
    echo "BookBook.xcodeproj differs from project.yml: run 'xcodegen generate' and commit" >&2; return 1
  fi
  if [ -n "$(git ls-files --others --exclude-standard -- BookBook.xcodeproj)" ]; then
    git ls-files --others --exclude-standard -- BookBook.xcodeproj >&2
    echo "untracked files under BookBook.xcodeproj: run 'xcodegen generate' and commit" >&2; return 1
  fi
}

xcb() {
  xcodebuild -project BookBook.xcodeproj -scheme BookBook -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData "$@" 2>&1 | pretty
}
step_app()     { xcb -configuration Debug build test; }
step_release() { xcb -configuration Release build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""; }

if [ "$step" = all ]; then steps=(secrets bootstrap kit spikes xcodeproj app release); else steps=("$step"); fi

results=(); failed=0
for s in "${steps[@]}"; do
  echo "==> test: $s"
  if "step_$s"; then results+=("ok    $s"); else results+=("FAIL  $s"); failed=1; break; fi
done

echo "==> summary"
printf '  %s\n' "${results[@]}"
exit "$failed"
