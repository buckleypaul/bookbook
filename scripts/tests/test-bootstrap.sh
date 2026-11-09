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

echo "scan edge cases (staged)"
r="$(new_repo edge)"
commit_blocked() { # $1 = label; expects the staged change to be refused
  if git -C "$r" commit -qm "$1" >/dev/null 2>&1; then bad "$1"; git -C "$r" reset -q --hard HEAD~1; else ok "$1"; fi
  git -C "$r" reset -q --hard HEAD; git -C "$r" clean -qfd
}
echo base > "$r/base.txt"; ln -s base.txt "$r/lnk"
git -C "$r" add -A; git -C "$r" commit -qm base >/dev/null
rm "$r/lnk"; printf '%s\n' "$fake_openai" > "$r/lnk"; git -C "$r" add lnk
commit_blocked "symlink changed to a file with a key is blocked"
printf 'x\000y\n%s\n' "$fake_google" > "$r/blob.bin"; git -C "$r" add blob.bin
commit_blocked "key in a file with NUL bytes is blocked"
printf '%s\n' "$fake_openai" > "$r/1:x"; git -C "$r" add "1:x"
commit_blocked "key in a file named with a colon is blocked"
printf 'see the %s\n' "$fake_openai" > "$r/part.txt"; git -C "$r" add part.txt; printf 'clean\n' > "$r/part.txt"
commit_blocked "staged key is blocked even if the work tree is clean"
for word in disk mask task; do
  printf 'uses the %s-arbitration-framework-helper-v2\n' "$word" > "$r/fp-$word.md"
done
git -C "$r" add fp-*.md
if git -C "$r" commit -qm fp >/dev/null 2>&1; then ok "words like mask-/disk-/task- are not flagged"; else bad "words like mask-/disk-/task- are not flagged"; fi
git -C "$r" reset -q --hard HEAD; git -C "$r" clean -qfd

echo "merges, worktrees and old branches"
git -C "$r" checkout -qb lane
printf '%s\n' "$fake_openai" > "$r/lane.txt"; git -C "$r" add lane.txt; git -C "$r" commit -q --no-verify -m lane-leak
git -C "$r" checkout -q -
echo other > "$r/other.txt"; git -C "$r" add other.txt; git -C "$r" commit -qm other >/dev/null
if git -C "$r" merge -q --no-edit lane >/dev/null 2>&1; then bad "merge bringing in a key is blocked"; git -C "$r" reset -q --hard HEAD~1; else ok "merge bringing in a key is blocked"; git -C "$r" merge --abort 2>/dev/null || true; fi
git -C "$r" worktree add -q "$work/edge-wt" -b wt >/dev/null 2>&1
printf '%s\n' "$fake_google" > "$work/edge-wt/wt.txt"; git -C "$work/edge-wt" add wt.txt
if git -C "$work/edge-wt" commit -qm wt >/dev/null 2>&1; then bad "hook runs in a linked worktree"; else ok "hook runs in a linked worktree"; fi
git -C "$r" checkout -q --orphan old; git -C "$r" rm -rq --cached . >/dev/null; rm -rf "$r/scripts" "$r/.githooks"
echo old > "$r/old.txt"; git -C "$r" add old.txt
out="$(git -C "$r" commit -qm old 2>&1)" && st=0 || st=$?
if [ "$st" -ne 0 ] && [[ "$out" == *"missing"* ]]; then ok "hook fails closed on a checkout without the scanner"; else bad "hook fails closed on a checkout without the scanner"; fi

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
for p in ../Pkg Pkg/sub .selftest; do
  out="$(cd "$r" && scripts/live-tests.sh --package "$p" openai 2>&1)" && st=0 || st=$?
  if [ "$st" -eq 2 ]; then ok "--package '$p' is rejected"; else bad "--package '$p' is rejected (exit $st)"; fi
done
# bash -p: an exported function named swift or security must not be picked up.
out="$(cd "$r" && env 'BASH_FUNC_security%%=() { echo HIJACKED; }' scripts/live-tests.sh --package Pkg openai 2>&1)" || true
case "$out" in *HIJACKED*) bad "exported functions are ignored" ;; *) ok "exported functions are ignored" ;; esac

# Zero-test guard (#90): a stub swift lists tests; the Keychain name is made non-existent and the
# existence check bypassed, so no real item is read. The stub never sees or prints the environment.
r="$(new_repo live-zero)"
mkdir -p "$r/Pkg" "$r/stub"; printf '// swift-tools-version: 6.0\n' > "$r/Pkg/Package.swift"
cat > "$r/stub/swift" <<'STUB'
#!/bin/bash
case "$*" in
  *"build --build-tests"*) exit 0 ;;
  *" list"*) printf '%s\n' "BBTests.Other/a()" "BBOpenAITests.LiveProviderTests/SP4_maskPolarity()"; exit 0 ;;
  *) echo "STUB-RAN $*" ; exit 0 ;;
esac
STUB
chmod +x "$r/stub/swift"
sed -i '' -e "s#^swift_bin=.*#swift_bin=\"$r/stub/swift\"#" \
  -e 's/openai-api-key/bookbook-selftest-no-such-item/g' \
  -e 's#^if ! /usr/bin/security find-generic-password -a "$account" -s "$service" >/dev/null 2>&1; then#if false; then#' "$r/scripts/live-tests.sh"
out="$(cd "$r" && scripts/live-tests.sh --package Pkg openai zzz_nothing 2>&1)" && st=0 || st=$?
if [ "$st" -eq 1 ] && [[ "$out" == *"no test matches"* ]] && [[ "$out" != *STUB-RAN* ]]; then ok "a filter matching zero tests exits 1 before the key step"; else bad "a filter matching zero tests exits 1 before the key step (exit $st)"; fi
out="$(cd "$r" && scripts/live-tests.sh --package Pkg openai SP4_maskPolarity 2>&1)" && st=0 || st=$?
if [ "$st" -eq 0 ] && [[ "$out" == *"1 test(s) match"* ]] && [[ "$out" == *STUB-RAN* ]]; then ok "a matching filter runs the tests"; else bad "a matching filter runs the tests (exit $st)"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
