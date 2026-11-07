# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `awaiting hand checks` · `done` · `blocked` · `skipped (floating)`

**Live API spend so far:** $0.44 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

| Phase | Name | Status | Branch | PR | Live spend | Notes |
|---|---|---|---|---|---|---|
| 1a | Bootstrap (gitignore, hooks, key scripts) | done | `phase-1a-bootstrap` | [#1](https://github.com/buckleypaul/bookbook/pull/1) | $0.00 | Repo and remote were created on 2026-11-07 |
| 0 | Live-API spikes and fixtures | awaiting hand checks | `phase-0-spikes` | PR_LINK | $0.44 | OpenAI + local spikes; Gemini spikes (§4.2) moved to Phase 13 |
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

**Status:** awaiting hand checks · branch `phase-0-spikes` · PR PR_LINK · live spend **$0.44** (37 calls, LiveSpendGuard estimate; allotment $3).

**Built:**
- `Spikes/` SwiftPM package:
  - `SpikeKit`: env/key access with a redacted, non-reflectable `APIKey`; a URLSession client; multipart; an OpenAI client; usage parsing and pricing; `LiveSpendGuard`; `FixtureRecorder` with in-memory key and pattern checks, a header allowlist, ID placeholders and masked-key redaction; synthetic test images. 43 offline tests.
  - `OpenAISpikeTests` (`LiveProviderTests` SP-1…SP-7, plus SP-4b/c/d follow-ups).
  - `LocalSpikeTests` (SL-1, SL-2) and `SL3WindowGroupApp` with run scripts.
- Fixtures in `Spikes/Fixtures/openai/`; `Spikes/REPORT.md`; `Spikes/notes/local-spikes.md`; seeds in `Spikes/Seeds/` (`ModelCatalog.json`, `PriceList.json`).

**Spend by spike:** SP-1 $0.006 · SP-2 $0.092 · SP-3 $0.073 · SP-4 $0.114 (incl. follow-ups) · SP-5 $0 · SP-6 $0.152 (incl. $0.08 assumed for the cancelled request) · SP-7 $0.005.

**Key findings** (details in `Spikes/REPORT.md`):
- All seed models are present and the org is verified.
- Output tokens aren't proportional to pixels.
- `size: auto` on edits changes the size, so the adapter always sends an explicit size.
- An unknown model gives 400, not 404.
- Refusals come back as 400 `moderation_blocked`.
- The upload cap is 50 MB per image.
- Chat Completions handles both strict structured output and vision (P-5 holds).
- **OpenAI masked edits often return a black area and put changes outside the mask. This is open and blocking for Phase 11.**
- SL-1 and SL-2 confirmed the TextKit 2 approach.
- SL-3: book windows are restored only when the user's macOS setting allows it.

**Assumptions and deviations:**
- No `gemini-api-key` Keychain item exists, so §4.2 (SG-1…SG-8) moves to the start of Phase 13.
- The plan names both `spikes/REPORT.md` and `Spikes/Fixtures/`; on case-insensitive APFS these are the same folder, so everything lives under `Spikes/`.
- The seed catalog and price list go in `Spikes/Seeds/` for Phase 1b to move into the resource folders.
- Spike tests use Swift Testing. Observations are printed as `SPIKE-RESULT` lines.
- The dev key initially returned 401. You replaced it mid-session, and that first run cost $0.
- Added beyond the plan's table, after the independent review: SP-4 follow-ups (a second quadrant, masked-area content, an RGB-filled mask), about $0.07.

**Docs changed:**
- `architecture.md` §6.1: restoration qualifier.
- §7.6: explicit size, 50 MB cap, mask findings, mandatory composite.
- §7.10: measured token tables.
- §7.11: error mapping.
- §8.3: editor/renderer container settings; spelling markers.
- §14: rows updated.

**Review:** a fresh opus review found three must-fix items, all fixed:
- the SP-4 conclusion was overstated, so the extra live check was run and the row marked open;
- the input-token formula didn't match the fixtures, so it's replaced by measured values;
- `PROGRESS.md` was incomplete.

Also fixed from the nice-to-haves: `dump()`/reflection redaction for `APIKey` and `HTTPRequest`, the prompt-length claim, the "not billed" inference, and the masked-echo wording.

**Hand checks:**
- [ ] OpenAI dashboard: was the request cancelled at 2026-11-07 23:39 UTC (high 1024×1536, ~$0.08) billed?
- [ ] OpenAI dashboard total for 2026-11-07 is within ~20% of $0.44.
- [ ] Read `Spikes/REPORT.md`: every A §14 row a live API can answer has an answer or a reason.
- [ ] `scripts/secret-scan.sh` / `git grep` for key patterns finds nothing.
- [ ] Optional: the SL-3 by-hand steps in `Spikes/notes/local-spikes.md`.

**Follow-ups:**
- **Product decision:** should BookBook always reopen the last-open books at relaunch, given macOS's default doesn't (SL-3)? Options are in `Spikes/REPORT.md`.
- **Phase 11 (blocking):** re-check OpenAI masked edits on a real illustration, and choose the region-edit approach (masked edit / unmasked edit plus composite / black-fill detection plus fallback).
- **Phase 2 / BBNet:**
  - redact provider-masked key echoes (`sk-…****…`) from error `raw`;
  - port `SpikeKit`'s recorder and redaction, including `CustomReflectable` on key-holding types;
  - add an offline test for cancellation mapping.
- **Phase 9:**
  - measure the input tokens for a 1536×1024 reference;
  - check the `gpt-6-luna` / `gpt-6.1-terra` per-token prices (placeholders in the seed);
  - transport errors, such as timeouts on long generations, may still be billed, so record them as estimates, not $0.
- **Phase 1b:** move `Spikes/Seeds/*.json` into the bundled resources.
- **Phase 1b:** CI should run `swift test` in `Spikes/` too, or exclude it explicitly (`LocalSpikeTests` SL-2 needs a GUI session and skips without one).
- **Phase 13:** run SG-1…SG-8 first.
- **From 1a, still open:** `live-tests.sh` exits 0 when no test matches the filter.
