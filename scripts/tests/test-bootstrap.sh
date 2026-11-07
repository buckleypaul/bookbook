#!/usr/bin/env bash
# Offline self-test for the Phase 1a tooling: secret scan, pre-commit hook, live-test scripts.
# Uses throwaway git repos in a temp folder. Never reads a real key or calls a provider.
#
#   scripts/tests/test-bootstrap.sh
set -euo pipefail
set +x +v

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# Fake keys, assembled at runtime so no key-shaped string is ever stored in the repo.
fake_openai="sk-""proj-$(printf 'A%.0s' {1..40})"
fake_google="AI""za$(printf 'B%.0s' {1..35})"

new_repo() { # $1 = name; copies the tooling in and installs the hook
  local d="$work/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.name test
  git -C "$d" config user.email test@example.invalid
  git -C "$d" config commit.gpgsign false
  cp -R "$repo_root/scripts" "$repo_root/.githooks" "$d/"
  (cd "$d" && scripts/install-hooks.sh >/dev/null)
  echo "$d"
}

echo "secret scan and pre-commit hook"
r="$(new_repo hook)"
echo "hello" > "$r/clean.txt"
git -C "$r" add clean.txt
if git -C "$r" commit -qm clean >/dev/null 2>&1; then ok "clean commit is allowed"; else bad "clean commit is allowed"; fi

for kind in openai google; do
  [ "$kind" = openai ] && key="$fake_openai" || key="$fake_google"
  printf 'let k = "%s"\n' "$key" > "$r/leak-$kind.swift"
  git -C "$r" add "leak-$kind.swift"
  out="$(git -C "$r" commit -qm leak 2>&1 || true)"
  if git -C "$r" log --oneline | grep -q leak; then bad "$kind key commit is blocked"; else ok "$kind key commit is blocked"; fi
  case "$out" in *"$key"*) bad "$kind hook output does not echo the key" ;; *) ok "$kind hook output does not echo the key" ;; esac
  git -C "$r" rm -q --cached "leak-$kind.swift"; rm "$r/leak-$kind.swift"
done

# Docs-style placeholders (sk-…, sk-proj-…) must not trip the scan.
printf 'Use an sk-... or sk-proj-xxxx placeholder.\n' > "$r/doc.md"
git -C "$r" add doc.md
if git -C "$r" commit -qm doc >/dev/null 2>&1; then ok "short placeholders are allowed"; else bad "short placeholders are allowed"; fi

# A file whose name has spaces is scanned too.
printf '%s\n' "$fake_openai" > "$r/with space.json"
git -C "$r" add "with space.json"
if git -C "$r" commit -qm spaced >/dev/null 2>&1; then bad "key in a file name with spaces is blocked"; else ok "key in a file name with spaces is blocked"; fi
git -C "$r" rm -q --cached "with space.json"; rm "$r/with space.json"

# Full-tree mode (what CI runs) finds a key that got in with --no-verify, without printing it.
printf '%s\n' "$fake_google" > "$r/fixture.json"
git -C "$r" add fixture.json
git -C "$r" commit -q --no-verify -m bypass
out="$(cd "$r" && scripts/secret-scan.sh 2>&1)" && st=0 || st=$?
if [ "$st" -eq 1 ]; then ok "full scan fails on a tracked key"; else bad "full scan fails on a tracked key (exit $st)"; fi
case "$out" in *"$fake_google"*) bad "full scan output does not echo the key" ;; *fixture.json:1*) ok "full scan names file:line without the key" ;; *) bad "full scan names file:line" ;; esac

echo "this repo"
if (cd "$repo_root" && scripts/secret-scan.sh >/dev/null 2>&1); then ok "repo is clean"; else bad "repo is clean"; fi

echo "live-test scripts (no key is read)"
r="$(new_repo live)"
out="$(cd "$r" && scripts/live-tests.sh 2>&1)" && st=0 || st=$?
if [ "$st" -ne 0 ] && [[ "$out" == *"no Package.swift"* ]]; then ok "missing package fails cleanly"; else bad "missing package fails cleanly"; fi
out="$(cd "$r" && scripts/live-tests.sh bogus 2>&1)" && st=0 || st=$?
if [ "$st" -eq 2 ]; then ok "unknown provider is a usage error"; else bad "unknown provider is a usage error (exit $st)"; fi
out="$(cd "$r" && scripts/live-tests.sh openai 'a;b' 2>&1)" && st=0 || st=$?
if [ "$st" -eq 2 ]; then ok "unsafe filter is rejected"; else bad "unsafe filter is rejected (exit $st)"; fi
out="$(cd "$r" && bash -x scripts/live-tests.sh 2>&1)" && st=0 || st=$?
if [ "$st" -eq 2 ] && [[ "$out" == *"shell tracing"* ]]; then ok "bash -x is refused"; else bad "bash -x is refused (exit $st)"; fi
out="$(cd "$r" && bash -x scripts/record-fixtures.sh 2>&1)" && st=0 || st=$?
if [ "$st" -eq 2 ]; then ok "record-fixtures under bash -x is refused"; else bad "record-fixtures under bash -x is refused (exit $st)"; fi
# A Keychain service that cannot exist, so no real item is touched.
mkdir -p "$r/Pkg"; printf '// swift-tools-version: 6.0\n' > "$r/Pkg/Package.swift"
sed -i '' 's/service="openai-api-key"/service="bookbook-selftest-no-such-item"/' "$r/scripts/live-tests.sh"
out="$(cd "$r" && scripts/live-tests.sh --package Pkg openai 2>&1)" && st=0 || st=$?
if [ "$st" -eq 1 ] && [[ "$out" == *"no Keychain item"* ]]; then ok "missing Keychain item fails before any build"; else bad "missing Keychain item fails before any build"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
