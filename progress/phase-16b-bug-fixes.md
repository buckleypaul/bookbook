# Phase 16b — Bug fixes and edge cases (log)

**Session A done (2026-11-09):** lanes L1–L8 all merged into `phase-16b-bug-fixes`. The main thread also switched closed-book deliveries to `acquireLockExclusively()` (#3c), wired the #76a colour undo group through `TextEditingController`/`CanvasView`, and wired the undelivered count into the library-switch warning. `scripts/test.sh all` is green after a test-only fix (`SystemSpellingCheckerTests` trapped in `MainActor.assumeIsolated` inside an `.enabled(if:)` condition). For Session B: the review covers the whole phase diff (`main..phase-16b-bug-fixes`). Watch `LibraryActionsTests.duplicate_flushesAnOpenSourceFirst`, which flaked in some lane runs. "Open Anyway" relies on the per-process lock hold count (a temporary store holds the lock while `BookDocument.open` re-enters it). #47 and #48 have no automated tests. The app pass should re-check the menus, Guided Setup, the overview, the export sheet and the Open Anyway alert.

- 2026-11-09: Session A started. Triage of the Phase 17 and Later follow-ups in progress.
- Triage: 181 rows in 4 batches. Product calls are under Standing decisions ("Phase 16b product calls"). `architecture.md` updated (§4.4, §5.5, §7.7, §7.9).
- Lanes (wave 1: L1-L3; wave 2: L4-L8). New tests per lane:
  - L1 Store (opus): journal race, lock liveness and takeover, sweep protection, library actions on foreign locks. Phase16bStoreTests, Phase16bLockTests, FaultInjectionTests additions.
  - L2 Queue and app model (opus): queue.json per library root and durable saves, undeliverable pictures redelivered at launch, retry order, quiet drop for gone books. Phase16bQueueTests, Phase16bQueueFileTests, Phase16bAppModelTests, Phase16bAppSupportTests, AppSmokeTests additions.
  - L3 Book Settings, cost and import (sonnet): ledger and cost summary fixes, retry policy, offline codes, import clash handling, Clean Up protecting queued versions. Phase16bCostImportTests, Phase16bLedgerSummaryTests, Phase16bRetryPolicyTests, Phase16bOfflineCodesTests, Phase16bBookSettingsTests.
  - L4 BookDocument (sonnet): flags and acknowledgements, split warning, mark-as-OK, font refresh, normalizer fallback box. Phase16bBookDocumentTests, Phase16bStyleFlagTests.
  - L5 Sessions, assets and AI (sonnet): session panel, cost-alert wording, context resolution, asset editor, Draft All count, queue badge. Phase16bSessionTests, Phase16bContextTests, PromptTemplateKeysTests.
  - L6 Export (sonnet): export cache and preflight, export sheet, save panel, crop marks, booklet caption. Phase16bExportTests, SystemSpellingCheckerTests, Phase16bExportSheetTests.
  - L7 Text, fonts and template editor (opus): colour undo burst, pasted attributes, fold bleed, new-box cascade, story import types, reassignment. Phase16bTextEditingTests, Phase16bLayoutEditingTests, Phase16bTextImportTests, Phase16bReassignmentTests.
  - L8 App shell (sonnet): Guided Setup, File menu, Book menu toggle, Open Anyway UI, style-drop URLs, live-tests.sh zero-match guard. Phase16bAppShellTests, test-bootstrap.sh checks.

| Status | Rows |
|---|---|
| Fix now (fixed; includes duplicates #68 and #32a) | 92 |
| Decision only (#72a, in Standing decisions) | 1 |
| Dropped | 13 |
| v1.x (still open) | 55 + 4 new (60 lines incl. the #9 follow-on) |
| Phase 17 (still open) | 20 + 1 new (the `duplicate_flushesAnOpenSourceFirst` flake) |
| **Total triage rows** | **181** |

**Session B (2026-11-09):**
- `scripts/test.sh all` green with no warnings in our sources, before and after the fixes. `duplicate_flushesAnOpenSourceFirst` didn't flake.
- Review of `aab4f8c..phase-16b-bug-fixes` (Session A lanes plus the later /simplify refactors): no must-fix issues. Two should-fixes that this phase introduced were fixed in round 1, and their re-review found nothing:
  - Redelivery is idempotent: `applyDelivery` skips a version ID already in the book, and `GenerationQueue.attemptRedeliveries` doesn't overlap itself (`Phase16bRedeliveryIdempotenceTests`).
  - A colour-burst undo group now closes if the inline editor is freed without `tearDown()` (`isolated deinit`; `Phase16bTextEditingTests.editorDroppedWithoutTearDown_closesTheBurst`).
  - The other three should-fixes went to Open follow-ups › Phase 17.
- App pass (throwaway library, no key): ticked Book Settings in the File menu, the Page-menu toggles, the overview grid (no overlap; double-click opens the page), the export sheet's preflight and "binds at the top" caption, story import with cancel keeping the empty book, Open Anyway on a fake foreign lock, and no crashes. Inconclusive: Guided Setup relaunch, the colour burst, Draft All's text, and the wizard's 10 × 8 orientation (all under Deferred hand checks).
- Secret scan clean. Live spend $0.00.
