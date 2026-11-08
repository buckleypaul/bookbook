# Phase 1a — Bootstrap (2026-11-07)

**Status:** done (hand checks passed, PR #1 squash-merged 2026-11-07) · branch `phase-1a-bootstrap` · PR #1 · live spend $0.00 (no provider calls; a zero-test dry run of `live-tests.sh` and `record-fixtures.sh` against a throwaway package confirmed the build-then-inline path).

**Built:** `.gitignore`; `scripts/secret-scan.sh` (full tree or `--staged` index, binary read as text, prints `file:line` only, fails closed on grep errors); `.githooks/pre-commit` plus `scripts/install-hooks.sh` (installed as pre-commit **and** pre-merge-commit in the shared hooks dir, fails closed without a scanner); `scripts/live-tests.sh` / `scripts/record-fixtures.sh` (§2.2 shape, `bash -p`, absolute tool paths, refuse tracing); `scripts/tests/test-bootstrap.sh` (28 offline checks); repo `CLAUDE.md` with the key rules.

**Decisions / deviations (plan defaults, easy to overrule):**
- `live-tests.sh` takes `--package <folder>` (default `BookBookKit`), so Phase 0 can run `scripts/live-tests.sh --package Spikes openai SP1`. Phase 0's live suite must be named `LiveProviderTests`.
- `record-fixtures.sh` sets `BOOKBOOK_RECORD_FIXTURES=1` and delegates to `live-tests.sh`, so the key is read in only one place. Tests in record mode should check that variable.
- Hooks are installed into `.git/hooks` instead of using `core.hooksPath`, so branches made before this merge still fail closed (independent review finding).
- No docs in `architecture.md` changed.

**Review:** fresh opus review. Fixed: type-change and NUL-byte files that the scan missed, `:` in file names, swallowed grep errors, no merge hook, the hook missing on old branches, `mask-`/`disk-` false positives, exported-function/`BASH_ENV` hijack, `--package ..`, unset `$USER`.

**Follow-ups:**
- The secret scan doesn't decode UTF-16 files (e.g. `Localizable.strings`). Revisit if the app ever stores such files with secrets nearby. GitHub push protection is the backstop.
- Phase 1b: run `scripts/secret-scan.sh` in CI, add branch protection, and extend `CLAUDE.md` with the module map.
- `live-tests.sh` exits 0 when no test matches the filter (SwiftPM prints "No matching test cases were run"). Phase 0 could make the spend guard or the suite report counts.

