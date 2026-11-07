# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `awaiting hand checks` · `done` · `blocked` · `skipped (floating)`

**Live API spend so far:** $0.00 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

| Phase | Name | Status | Branch | PR | Live spend | Notes |
|---|---|---|---|---|---|---|
| 1a | Bootstrap (gitignore, hooks, key scripts) | done | `phase-1a-bootstrap` | [#1](https://github.com/buckleypaul/bookbook/pull/1) | $0.00 | Repo and remote were created on 2026-11-07 |
| 0 | Live-API spikes and fixtures | in progress | `phase-0-spikes` | | | OpenAI + local spikes; Gemini spikes (§4.2) wait for the key |
| 1b | Project setup and CI | not started | | | | |
| 2 | Thin vertical slice (M1) | not started | | | | |
| 3 | Storage and library | not started | | | | |
| 4 | Text and typography | not started | | | | |
| 5 | Pages tab, ordering and cover | not started | | | | |
| 6 | Template editor | not started | | | | |
| 7 | Style guide and page setup | not started | | | | |
| 8 | Sessions and versions | not started | | | | |
| 9 | Queue, cost, errors and settings (M2) | not started | | | | |
| 10 | Assets and character sheets | not started | | | | |
| 11 | Region editing | not started | | | | |
| 12 | Consistency check and AI templates (M3) | not started | | | | |
| 13 | Gemini provider (floating) | not started | | | | Needs the `gemini-api-key` Keychain item |
| 14 | Export and print | not started | | | | |
| 15 | Release pipeline (M4) | not started | | | | |
| 16 | Import, book settings, onboarding, sample | not started | | | | |
| 17 | Hardening and v1.0 (M5) | not started | | | | |

## Phase log

<!-- Each session adds a section here: what was built, deviations from the plan, docs changed, follow-ups, and the hand-check list. -->

### Phase 1a — Bootstrap (2026-11-07)

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

### Phase 0 — Live-API spikes and fixtures (2026-11-07)

**Status:** in progress · branch `phase-0-spikes`.

**Assumptions (plan defaults, easy to overrule):**
- No `gemini-api-key` Keychain item exists, so §4.2 (SG-1…SG-8) is deferred to Phase 13 (or whenever the key appears). This phase runs §4.1 (SP-1…SP-7) and §4.3 (SL-1…SL-3).
- The plan names both `spikes/REPORT.md` and `Spikes/Fixtures/`; on case-insensitive APFS these are the same folder, so everything lives under `Spikes/` (`Spikes/REPORT.md`).
- `ModelCatalog.json` / `PriceList.json` don't exist until Phase 1b creates the resource folders, so this phase writes their first real values to `Spikes/Seeds/` for 1b to move in.
- Spike tests use Swift Testing (`@Suite(.serialized) struct LiveProviderTests` in `OpenAISpikeTests`); observations are printed as `SPIKE-RESULT` lines and copied into the report.
