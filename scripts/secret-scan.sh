#!/usr/bin/env bash
# Secret scan (implementation-plan.md §2.2).
#
#   scripts/secret-scan.sh            scan every tracked file (what CI runs)
#   scripts/secret-scan.sh --staged   scan only the staged changes (what the pre-commit hook runs)
#
# It prints the file and line number of each hit, never the matching text.
# Exit codes: 0 clean, 1 a possible key was found, 2 usage error.
set -euo pipefail
set +x +v

# OpenAI keys (sk-…, including sk-proj-… and sk-svcacct-…) and Google API keys (AIza…).
PATTERN='sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}'

mode="${1:-all}"
cd "$(git rev-parse --show-toplevel)"

found=0
report() { # $1 = where; never print the matched text
  echo "secret-scan: possible API key in $1" >&2
  found=1
}

case "$mode" in
  all|--all)
    # Every tracked file, including __Snapshots__ and fixtures. -I skips binary files.
    while IFS= read -r hit; do
      report "$hit"
    done < <(git grep -I -n -E -o "$PATTERN" -- . | cut -d: -f1,2 | sort -u)
    ;;
  --staged)
    # The staged contents of every added, copied, modified or renamed file.
    while IFS= read -r -d '' path; do
      while IFS= read -r line; do
        report "$path:$line (staged)"
      done < <(git show ":$path" | LC_ALL=C grep -I -n -E -o "$PATTERN" | cut -d: -f1 | sort -un || true)
    done < <(git diff --cached --name-only -z --diff-filter=ACMR)
    ;;
  *)
    echo "usage: $0 [--all|--staged]" >&2
    exit 2
    ;;
esac

if [ "$found" -ne 0 ]; then
  echo "secret-scan: refusing. Remove the key, and rotate it if it was real." >&2
  exit 1
fi
echo "secret-scan: clean ($mode)"
