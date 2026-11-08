# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `awaiting hand checks` · `done` · `blocked` · `skipped (floating)`

**Live API spend so far:** $0.47 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

| Phase | Name | Status | Branch | PR | Live spend | Notes |
|---|---|---|---|---|---|---|
| 1a | Bootstrap (gitignore, hooks, key scripts) | done | `phase-1a-bootstrap` | [#1](https://github.com/buckleypaul/bookbook/pull/1) | $0.00 | Repo and remote were created on 2026-11-07. [Log](progress/phase-1a-bootstrap.md) |
| 0 | Live-API spikes and fixtures | done | `phase-0-spikes` | [#2](https://github.com/buckleypaul/bookbook/pull/2) | $0.44 | OpenAI + local spikes; Gemini spikes (§4.2) moved to Phase 13. [Log](progress/phase-0-spikes.md) |
| 1b | Project setup and CI | done | `phase-1b-setup-ci` | [#3](https://github.com/buckleypaul/bookbook/pull/3) | $0.00 | XcodeGen project; CI on `xcode-27`. [Log](progress/phase-1b-setup-ci.md) |
| 2 | Thin vertical slice (M1) | done | `phase-2-thin-slice` | [#4](https://github.com/buckleypaul/bookbook/pull/4) | $0.006 | [Log](progress/phase-2-thin-slice.md) |
| 3 | Storage and library | done | `phase-3-storage-library` | [#7](https://github.com/buckleypaul/bookbook/pull/7) | $0.00 | No live checks. [Log](progress/phase-3-storage-library.md) |
| 4 | Text and typography | done | `phase-4-text-typography` | [#8](https://github.com/buckleypaul/bookbook/pull/8) | $0.00 | No live checks. From Phase 5 on, no PRs: merge into main and push directly. [Log](progress/phase-4-text-typography.md) |
| 5 | Pages tab, ordering and cover | done | `phase-5-pages-cover` | — | $0.00 | No live checks. [Log](progress/phase-5-pages-cover.md) |
| 6 | Template editor | done | `phase-6-template-editor` | — | $0.00 | No live checks. [Log](progress/phase-6-template-editor.md) |
| 7 | Style guide and page setup | done | `phase-7-style-page-setup` | — | $0.00 | No live checks. [Log](progress/phase-7-style-page-setup.md) |
| 8 | Sessions and versions | done | `phase-8-sessions-versions` | — | $0.02 | Live check `SP8_refinementLowQuality` passed. [Log](progress/phase-8-sessions-versions.md) |
| 9 | Queue, cost, errors and settings (M2) | in progress | `phase-9-queue-cost-settings` | — | $0.00 | |
| 10 | Assets and character sheets | not started | | | | |
| 11 | Region editing | not started | | | | |
| 12 | Consistency check and AI templates (M3) | not started | | | | |
| 13 | Gemini provider (floating) | not started | | | | Needs the `gemini-api-key` Keychain item |
| 14 | Export and print | not started | | | | |
| 15 | Release pipeline (M4) | not started | | | | |
| 16 | Import, book settings, onboarding, sample | not started | | | | |
| 17 | Hardening and v1.0 (M5) | not started | | | | |

## Standing decisions

Facts later phases depend on. Detail is in the logs under `progress/`.

- The cover page is created with every book (`Book.coverPageID` is valid) but is hidden, not edited and not exported until Phase 5 ([Phase 2](progress/phase-2-thin-slice.md)).
- The app accepts a `-BookBookLibraryRoot <path>` launch argument (argument domain only, never saved) for throwaway libraries in automated runs ([Phase 2](progress/phase-2-thin-slice.md)).
- BBAITests prompt snapshots live in `Tests/BBAISnapshots/`; BBLayoutTests excludes `__Snapshots__` ([Phase 2](progress/phase-2-thin-slice.md)).
- Page commands never touch sessions; TextKit 2 layout, rendering and export are `@MainActor` for now ([Phase 2](progress/phase-2-thin-slice.md)).
- Gemini spikes (SG-1...SG-8) moved to the start of Phase 13; there is no `gemini-api-key` yet ([Phase 0](progress/phase-0-spikes.md)).
- Books always reopen at relaunch (decided 2026-11-07; PD §8.1, A §6.1, Phase 3) ([Phase 0](progress/phase-0-spikes.md)).
- OpenAI masked edits are unreliable; the region-edit approach is chosen in Phase 11 ([Phase 0](progress/phase-0-spikes.md)).

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.

### Phase 9
- Session B live pass: `SP9_twoRequestsAndCancel` (≈ $0.10) also **measures input tokens for a 1536×1024 reference**; put the figure into `PriceList.json` `inputImageTokens` (the patch rule predicts 704).

### Phase 11
- **Blocking:** re-check OpenAI masked edits on a real illustration, and choose the region-edit approach (masked edit / unmasked edit plus composite / black-fill detection plus fallback) (from Phase 0).

### Phase 13
- Run SG-1...SG-8 first (from Phase 0).

### Phase 14
- Export off the main actor (from Phase 2).

### Phase 16
- Hand-check the title-box bold state: title/author boxes are bound and not text-editable (double-click opens Book Settings), so B is disabled there. Check it once the Style tab owns the title font: B shows on over the bold title face, and pressing it gives the regular weight (from Phase 4, moved by Phases 5 and 7; unreachable in Phase 7 because the box opens Book Settings).
- A Finder copy of a package keeps the same `Book.id`; give one a new ID on detection (from Phase 3).
- A read-only open of an older-schema book has no in-memory migration (from Phase 3; or Phase 17).

### Later
- Unclassified OpenAI 403s still map to `.unknown(raw)` (documented in `OpenAIErrorMapper`); classify more codes as they're seen (from Phase 2, kept in Phase 9).
- A brief lock held by a delivery/snapshot makes a concurrent open in another process see "locked" (from Phase 3, not addressed in Phase 9).
- Deliveries to a book locked by another process are retried from memory only; they're lost if the app quits first, and each retry re-reports the "couldn't save" problem until it lands (from Phase 9).
- Ledger lines are appended even while another process holds the book's lock; `CostLedger.repair()` there could trim a line being written (from Phase 9).
- `scripts/test.sh app` runs the app as test host, so with an in-app key saved, launch makes a free `/models` call with the app's own key; consider skipping it under XCTest (from Phase 9).
- Template and consistency default-model settings (PD §8.11) wait for Phase 12 (from Phase 9).
- Version numbers are strip positions (`versionNumber`), so deleting a version renumbers later ones; "refined version N" tags and "Refined from" then point at the wrong version. Consider a stable per-session number (from Phase 8 review).
- Undoing `chooseVersion` leaves the panel's selected version on one that's no longer placed, so the next prompt refines a picture not on the page (from Phase 8 review).
- After Reset Session → Keep Versions the next prompt still refines the placed version; confirm against PD §8.6 "starts fresh" (from Phase 8 review).
- `SessionPanel.swift` drop handler returns true even when no file URLs survive the filter (from Phase 8 review).
- `baseImageTooLarge` / a refine on a deleted base (`baseVersionGone`) only fail at request time; the panel could warn or disable Refine (from Phase 8 review and lanes).
- `AspectFitter.snap` returns nil for fixed-ratio models (no snapping; matters once Gemini lands) and ignores its `quality` parameter (from Phase 8 fixes; Phase 13).
- `ContextAssembler.resolve`: if no slot holds the session and the target box ID now belongs to another session's box, that box's shape is used (from Phase 8 re-review).
- The safe area uses `box.bleedEdges` without checking that the box reaches the trim; deleting a mid-lineage version leaves children's `parent` dangling, so their lineage stops at the gap (from Phase 8 lanes).
- No two-image-box template preset; new image boxes in the template editor stack on top of each other (from Phase 8 hand checks).
- Overview: double-clicking a page thumbnail may not open it (seen with synthesized clicks only) (from Phase 8 hand checks).
- A project run skill (launch, `-BookBookLibraryRoot`, accessibility driving) would speed up automated hand checks (from Phase 8 hand checks).
- Style tab: does SwiftUI `TextEditor` typing log to the window undo manager, so a second ⌘Z while focused undoes typing into the draft, which leaving the field commits as a new edit and clears redo? Picking a preset while Description has uncommitted typing now drops the typing (from Phase 7 review).
- Flags: an image generated at revision N+1, followed by an undo of the style edit back to N, isn't flagged "style changed" (documented decision; revisit now that revisions are never reused). No tests for undo → redo → different edit, or for decoding a high-water mark below `visualRevision` (from Phase 7 review).
- Choosing a different version keeps the old image's `acknowledged.styleRevision`, so an older version can hide "style changed"; A §4.4 needs a decision (from Phase 7 review).
- Style reference drops accept any URL; a non-file URL is read with blocking `Data(contentsOf:)` on the main actor. Accept file URLs only (from Phase 7 review).
- No UI path to import an image into a box yet, so hand checks needed placed versions written into package JSON (from Phase 7 hand checks; Phase 10/16).
- The negative-guidance box once showed duplicated text while `style.json` was correct; not reproduced (from Phase 7 hand checks).
- Template-editor drag throttle: each drag tick copies `BookContent`, schedules a save and refreshes missing fonts inside `BookDocument.perform`; needs coalescing there (from Phase 6, still open after Phase 7).
- Template editor: dragging an edge off a spread's fold makes its bleed reappear after the drag (outline jumps 9 pt) (from Phase 7).
- Template editor: no snapping during ⇧ aspect-locked resize; no multi-box resize handles; the in-place text editor isn't rotated for rotated text boxes (from Phase 6).
- Page setup has one uniform margin field; per-edge margins aren't editable (from Phase 7).
- No regression tests for the Page Numbers Done font-keep fix or the Typography form fixes (from Phase 7).
- `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` is flaky (EINVAL writing `.journal/staged` under concurrent saves/opens); failed in Phase 6 Sessions A and B, passed on re-run. Likely a real race in BBStore journal-folder handling (from Phase 6).
- After a split is accepted ("Continue Anyway"), every later structural command shows the split warning again; compare against the split state before the command (`BookDocument.wouldSplitSpread`) (from Phase 5 review).
- An old bound title/author box whose text has no same-role target in the new template falls through to the generic mapping and lands in a body box; `pageNumberSlot` isn't excluded from body text (from Phase 5).
- Story import picks the file type by extension only (`txt`/`rtf`); `.text`, `.md`, `.rtfd` give "unsupported type". Imported RTF keeps its own font (e.g. Helvetica-Light), not the body font (from Phase 5).
- New Book from Story: cancelling leaves an empty book; the pending-import flag isn't cleared if the book opens read-only or its editor never opens (`BookWindow.swift:162`, `AppModel.swift:158`); two `.sheet(isPresented:)` on `LibraryView` can collide (from Phase 5 review).
- The toolbar Book menu's `.disabled(!isEditable)` also disables the view-only "Show Page Numbers in Overview" toggle (from Phase 5 review).
- Overview thumbnails hash whole `Page`/`Template`/`StyleGuide` per cell per redraw; key on IDs plus a revision (from Phase 5 review).
- `PageRenderer` half culling uses `CGRect.intersects`, inconsistent for an edge exactly on the gutter (content stream only; output is clipped) (from Phase 5 review).
- Spreads export as two PDF pages; a double-width spread export option isn't built (from Phase 5; Phase 14).
- Format bar: the colour picker adds one undo step per colour-panel change (debounce it like the Typography form); there's no typed size field, only ±1 pt steps (from Phase 4 review).
- Importing a font clears only that window's layout cache and missing-font list; other open books keep stale fallback layouts and banners (from Phase 4 review).
- Pasted rich text keeps attributes the model drops (kerning, paragraph spacing, links) in the editor until reload; pasted text with no requested font still uses the family match (from Phase 4).
- `refreshMissingFonts()` walks every page on each undoable edit, but isn't refreshed on coalesced typing, so a paste that brings in a missing font shows no banner (from Phase 4).
- The `fsType` embedding check runs only on import: a restricted system font picked from the menus isn't flagged, and bitmap-only embedding (bit 9) isn't checked (from Phase 4 review).
- A trailing empty paragraph loses its alignment and formatting on a round trip; a family with only a bold face stores `bold: true` but can't draw it (consider disabling B) (from Phase 4).
- Undo-coalescing tests spin the run loop once per keystroke (`TestRunLoop`); watch them for CI flakiness (from Phase 4).
- `BookEditorLayoutTests` opens a real `NSWindow` (it needs a GUI session) and depends on the measured 830 pt SwiftUI minimum; it doesn't test widened sidebar or inspector panels with a narrow window (from Phase 4 review).
- The export save panel's default folder carries over from the font-import panel (from Phase 4 hand checks).
- The canvas loads images synchronously on the main thread (move to an actor `ThumbnailCache`) (from Phase 2).
- Calm-area guidance only for overlapping text boxes, not adjacent ones (from Phase 2).
- A test that every prompt template key exists (from Phase 2).
- Versions dropped as invalid on load can leave dangling placements, which resolve to nil (from Phase 2).
- Hand check 6 wording: it should name where macOS 27 keeps saved state, since the `Saved Application State` path doesn't exist (from Phase 2).
- `live-tests.sh` exits 0 when no test matches the filter (SwiftPM prints "No matching test cases were run"); make the spend guard or the suite report counts (from Phase 1a, 0 and 1b).
- The secret scan doesn't decode UTF-16 files (e.g. `Localizable.strings`); revisit if the app ever stores such files with secrets nearby. GitHub push protection is the backstop (from Phase 1a).
- App icon and `UTTypeIcons` for `.bookbook` documents are placeholders (Finder shows a generic package icon) (from Phase 1b).
- The `xcode-27` runner image is "preview", and Xcode 27.2 is an RC there; the `xcode-select` path may change (from Phase 1b).
- `actions/checkout` v4.2.2 / `actions/cache` v4.2.0 are Node 20 actions; bump them when GitHub retires Node 20 (from Phase 1b).
- Library actions have no menu-bar items (`BookBookCommands.swift`) (from Phase 3).
- A restored window for a deleted book may flash briefly after ⌥⌘Q (from Phase 3).
- `LibraryIndex` FSEvents context uses `passUnretained` with no retain/release; an in-flight callback during `stop()` could touch a freed box (from Phase 3 review).
- The app's own autosaves trigger full library rescans (the "filter own writes" risk isn't really handled) (from Phase 3 review).
- Lock liveness: a reused PID keeps a stale lock "live" forever, and foreign-host locks can never be taken over; compare process start time with `acquiredAt` (from Phase 3 review).
- `storeImage` returns early on an existing file without touching its mtime, so a just-stored image identical to a >24 h orphan can be swept before its JSON is saved (from Phase 3 review).
- Read-only `load()` skips recovery, so it can show a half-applied save from the writer; read staged files of a committed transaction or retry (from Phase 3 review).
- Rename racing a closing window falls back to a background rename outside OpenBooks' per-book ordering; the closing flush can overwrite the new title (from Phase 3 review).
- `Library.trash`/`duplicate`/`moveBooks` ignore a foreign `.lock`; duplicate can copy mid-save and drops `.journal` (from Phase 3 review).
- Moving the library closes only books already in `documents`; a book mid-open reopens at the old URL (from Phase 3 review).
- `BookLock.acquireHold` holds the process-wide `Mutex` across file I/O and a blocking `flock`; the lock refcount key uses `standardizedFileURL` (no symlink resolution); a `BookStore` dropped without `releaseLock()` leaks its count so `.lock` stays until exit (from Phase 3 review).
- Library grid thumbnails are blank white for empty books (check once books have content) (from Phase 3 hand checks).

## Current phase log

The running phase writes its log here; when it is marked done, move the entry to `progress/phase-<id>-<slug>.md`.

### Phase 9 — Queue, cost, errors and settings

**Stage:** B

**Contracts (main thread, 2026-11-08):** `BBModel/Cost.swift` (`CostRecord`, `LedgerSummary`); `BBAI/CostContracts.swift` (`PriceList`, `CostEstimate`, `ImageEstimateInput`, `CostPricing`, `CostDecision`); `BBAI/Contracts.swift` queue types (`QueueItem` now Codable with `estimate`/`display`/`enqueuedAt`, `QueueFailure`, `.retrying`, `QueuePause`, `QueuePosition`, `DeliveryResult`, `GenerationHost.recordCost`, `QueuePersistence`, `PersistedQueue`; `AssemblyReport` Codable with `storyText`); `BBAI/AdvisorContracts.swift` (`FailureAdvice`, `AdviceContext`, `CustomModelSpec`, `ModelAvailability`); BBAICore `ProviderError` Codable, `ModelLister`, `CatalogModel.copiesFrom`; `BBStore/AppSupportFiles.swift`; `Resources/SensitiveTerms.json`.

**Assumptions (plan defaults; overrule if wrong):**
- Confirmation threshold default **$0.50** per request or batch.
- Money is `Decimal` USD throughout (matches `Book.budget`).
- One ledger line per provider request, including automatic retries. $0 for HTTP 4xx/5xx failures; the estimate for cancels, timeouts and transport errors (they may be billed).
- Custom model IDs and the default model/quality/threshold are stored in `UserDefaults` (A §5.5 put catalog overrides in `pricelist.json`; recorded in architecture.md).
- Template and consistency default-model settings wait for Phase 12 (nothing uses them yet).
- "Retry with <other provider>" is computed but hidden until Phase 13 (only OpenAI is configured).
- A delivery to a book locked by another process is kept in memory by the queue and retried; it's lost if the app quits first.
- Prices checked against OpenAI's pricing page on 2026-11-08: image models unchanged; `gpt-6-luna` $0.10/$0.50 and `gpt-6.1-terra` $1.00/$5.00 per 1M (no longer placeholders); the other four image models got entries reusing the 2.5-sunburst output-token table (unmeasured).

**Session A lanes (all merged into the phase branch):**
- Cost (sonnet): `PriceList` loading/override, `CostEstimator` (+ `estimateInput` via `ContextAssembler.plan`), `CostCalculator`, `CostPolicy`. 12 Draft 1024² ≈ $0.072.
- Queue (opus): full A §7.9 queue: retries/backoff/`Retry-After`, 300 s timeout, pause reasons, persistence and restore, ledger per request, redelivery for locked books. `QueueRetryPolicy.swift`.
- OpenAI (sonnet): `OpenAIModelLister`, error mapping tests for every fixture plus synthetic bodies, shared transport mapping, cancellation test, live test `SP9_twoRequestsAndCancel` (written, **not run**).
- Advisor/catalog (sonnet): `RefusalAdvisor` (ordered rules), `SensitiveTerms`, `ModelCatalog.adding/resolve/imageModels/availability`, `AssemblyReport.storyText`.
- Views (sonnet): Queue window, sidebar badge, resume/offline banners, cost next to Generate + confirm/budget alert, cancel notice, `FailureAdviceView`, Draft All Empty Boxes…, Book Settings cost + budget, Version details cost, Settings (Test Connection, Models tab, Cost tab with price list editor).
- Wiring (opus): AppModel on the new queue (restore-gated op chain), `QueueFileStore`, `NetworkMonitor`, ledger writes open/closed, `DeliveryResult`, Draft all planner, list-models at launch, custom-model catalog and pricing pushes.

**State at end of Session A:** `swift build --build-tests` clean (no warnings); all package tests pass; `scripts/test.sh app` passes. `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` failed once again and passed on re-run (known flaky, Later).

**For Session B:** run `scripts/test.sh all`; the live pass `scripts/live-tests.sh openai SP9` (≈ $0.10, total stays well under $8) and record the 1536×1024 input-token figure; hand checks need a throwaway library (`-BookBookLibraryRoot`) and the in-app key; review should look hard at `GenerationQueue.swift`, `AppModel.swift` / `AppModel+Phase9.swift` (op chain, restore gate) and `OpenBooks.swift` (ledger/delivery under locks).

