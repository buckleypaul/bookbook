#!/usr/bin/env bash
# Secret scan (implementation-plan.md §2.2).
#
#   scripts/secret-scan.sh            scan every tracked file in the work tree (what CI runs)
#   scripts/secret-scan.sh --staged   scan the index, i.e. exactly what the next commit will hold
#                                     (what the pre-commit and pre-merge-commit hooks run)
#
# Binary files are scanned as text. It prints the file and line number of each hit, never the
# matching text. Exit codes: 0 clean, 1 a possible key was found, 2 usage or scan error.
set -euo pipefail
set +x +v

# OpenAI keys (sk-…, including sk-proj-… and sk-svcacct-…) and Google API keys (AIza…).
# The sk- pattern needs a left boundary so words like "mask-…" or "disk-…" don't match.
PATTERN='(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}'

mode="${1:-all}"
case "$mode" in
  all|--all) where=() ;;
  --staged)  where=(--cached) ;;
  *) echo "usage: $0 [--all|--staged]" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)"

# Only "path:line" leaves the subshell. git grep exits 0 on a match, 1 on none, >1 on error.
set +e
hits="$(git grep ${where[@]+"${where[@]}"} --text -n -E -e "$PATTERN" -- . | cut -d: -f1,2 | sort -u
        exit "${PIPESTATUS[0]}")"
status=$?
set -e

case "$status" in
  0)
    while IFS= read -r hit; do
      echo "secret-scan: possible API key in $hit${where[@]+ (staged)}" >&2
    done <<< "$hits"
    echo "secret-scan: refusing. Remove the key, and rotate it if it was real." >&2
    exit 1
    ;;
  1)
    echo "secret-scan: clean ($mode)"
    ;;
  *)
    echo "secret-scan: git grep failed (exit $status); treating as not clean" >&2
    exit 2
    ;;
esac
