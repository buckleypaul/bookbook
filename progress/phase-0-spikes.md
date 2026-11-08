# Phase 0 — Live-API spikes and fixtures (2026-11-07)

**Status:** done (hand checks passed, PR #2 squash-merged 2026-11-07) · branch `phase-0-spikes` · PR [#2](https://github.com/buckleypaul/bookbook/pull/2) · live spend **$0.44** (37 calls, LiveSpendGuard estimate; allotment $3).

**Built:**
- `Spikes/` SwiftPM package:
  - `SpikeKit`: env/key access with a redacted, non-reflectable `APIKey`; a URLSession client; multipart; an OpenAI client; usage parsing and pricing; `LiveSpendGuard`; `FixtureRecorder` with in-memory key and pattern checks, a header allowlist, ID placeholders and masked-key redaction; synthetic test images. 43 offline tests.
  - `OpenAISpikeTests` (`LiveProviderTests` SP-1…SP-7, plus SP-4b/c/d follow-ups).
  - `LocalSpikeTests` (SL-1, SL-2) and `SL3WindowGroupApp` with run scripts.
- Fixtures in `Spikes/Fixtures/openai/`; `Spikes/REPORT.md`; `Spikes/notes/local-spikes.md`; seeds in `Spikes/Seeds/` (`ModelCatalog.json`, `PriceList.json`; moved to `BookBookKit/Sources/BBAI/Resources/` in Phase 1b).

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
- [x] OpenAI dashboard: was the request cancelled at 2026-11-07 23:39 UTC (high 1024×1536, ~$0.08) billed?
- [x] OpenAI dashboard total for 2026-11-07 is within ~20% of $0.44.
- [x] Read `Spikes/REPORT.md`: every A §14 row a live API can answer has an answer or a reason.
- [x] `scripts/secret-scan.sh` / `git grep` for key patterns finds nothing.
- [x] Optional: the SL-3 by-hand steps in `Spikes/notes/local-spikes.md`.

**Follow-ups:**
- ~~**Product decision:** should BookBook always reopen the last-open books at relaunch?~~ Decided 2026-11-07: yes, always (option b). PD §8.1, A §6.1 and the Phase 3 deliverables and hand checks are updated.
- **Phase 11 (blocking):** re-check OpenAI masked edits on a real illustration, and choose the region-edit approach (masked edit / unmasked edit plus composite / black-fill detection plus fallback).
- **Phase 2 / BBNet:**
  - redact provider-masked key echoes (`sk-…****…`) from error `raw`;
  - port `SpikeKit`'s recorder and redaction, including `CustomReflectable` on key-holding types;
  - add an offline test for cancellation mapping.
- **Phase 9:**
  - measure the input tokens for a 1536×1024 reference;
  - check the `gpt-6-luna` / `gpt-6.1-terra` per-token prices (placeholders in the seed);
  - transport errors, such as timeouts on long generations, may still be billed, so record them as estimates, not $0.
- ~~**Phase 1b:** move `Spikes/Seeds/*.json` into the bundled resources.~~ Done in 1b.
- ~~**Phase 1b:** CI should run `swift test` in `Spikes/` too, or exclude it explicitly.~~ Done in 1b: CI runs it; live suites and SL-2 skip themselves.
- **Phase 13:** run SG-1…SG-8 first.
- **From 1a, still open:** `live-tests.sh` exits 0 when no test matches the filter.

