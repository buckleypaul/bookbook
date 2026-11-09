# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `done (hand checks deferred)` · `done` · `blocked` · `skipped (floating)`

**Live API spend so far:** $0.51 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

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
| 9 | Queue, cost, errors and settings (M2) | done | `phase-9-queue-cost-settings` | — | $0.04 | Live check `SP9_twoRequestsAndCancel` passed. [Log](progress/phase-9-queue-cost-settings.md) |
| 10 | Assets and character sheets | done (hand checks deferred) | `phase-10-assets-characters` | — | $0.00 | No live checks listed. [Log](progress/phase-10-assets-characters.md) |
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

## Deferred hand checks

Hand checks are deferred to the end of the build (decided 2026-11-08). Each phase adds the checks its automated pass couldn't confirm. Run them all after the last phase.

### Phase 10 — Assets and character sheets
- Page 3 "@Pip yawning by the fire": Version details lists Pip's primary reference, then *sleepy*, then three-quarter view (needs a generation).
- Rename Pip → Pippa: a sent page 3 prompt shows "Pippa"; changing Pippa's description shows "asset changed" on pages with her placed images.
- Real-person photo: on first generation the notice appears with OpenAI's policy link and the children's-photos advice; also from Generate Whole Sheet and Draft All.
- Delete an asset in use: afterwards its mentions are plain text, including in Version details and Regenerate with Same Settings.
- Undo/redo with a real keyboard for asset create, rename, description edit and checklist toggle (inconclusive under synthetic input).
- Generate Whole Sheet: real generation of all 8 items at low quality (about $0.13).

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.

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
- Phase 10 review should-fixes: `RealPersonCheck` sets byte counts to 0, so a skipped (missing/too-large) image can hide a later real-person photo from the check; Generate Whole Sheet runs with no primary chosen (warn or block); undoing New Asset after it's mentioned leaves dangling tokens; `AssetEditor` `CommittedTextField` writes a stale draft back over an undo made while focused; where-used ignores mentions in asset-session prompts; synonym inflections over-match ("beams", "glare", "tear"); a slot label containing `{{name}}` is substituted; `SheetRequests.referenceMessageText` unused; the notice isn't re-checked when a queued item actually sends; the batch notice opens while the cost alert is closing (hand-check it); a token whose answered message is gone still renders empty (from Phase 10 review).
- Asset delete is irreversible (PD §8.10), so undo can't restore rewritten mentions; confirm that's intended (from Phase 10 fixes).
- `queue.json` lives in `~/Library/Application Support/BookBook/` regardless of `-BookBookLibraryRoot`, so throwaway libraries see and add to the real queue (from Phase 10 hand checks).
- Pages grid: thumbnails for pages 2 and 3 overlapped after adding a page; double-clicking Add Page added a page before the layout sheet was confirmed (from Phase 10 hand checks).
- Phase 9 review should-fixes: `queue.json` saves run in a detached task that quit doesn't await (`GenerationQueue.swift:291`); a newer-schema `queue.json` is ignored then overwritten (`QueueFileStore.swift:23`); one corrupt `costs.jsonl` line makes `costRecords` return `[]` so totals read $0 (`OpenBooks.swift:328`); Recent Requests caps at 50 while the total sums all (`Cost.swift:88`); an unknown estimate is ledgered as $0 with `includesEstimates` false (`GenerationQueue.swift:495`); `restoredCount` doesn't shrink as restored items are removed (`GenerationQueue.swift:101`); `.offline` retries (nothing sent) are charged at the estimate (`QueueRetryPolicy.swift:70`); `OpenAIErrorMapper` key-occurrence check misses JSON-escaped keys and the mask stops at `.`; `CostLedger.repair()` runs without the book lock (from Phase 9 review).
- Cached input tokens are attributed to text first, then image (OpenAI gives one cached count); revisit if image caching matters (from Phase 9).
- The 16×16 patch rule underestimates large reference images (1536×1024 measured 1536, rule gives 704); measure more sizes or switch the fallback rule (from Phase 9).
- Draft all counts the cover's image box ("13 requests" for a 12-page book); confirm that's intended (from Phase 9 hand checks).
- Sidebar queue badge says "13 in queue" while paused; consider showing "paused" (from Phase 9 hand checks).
- Ad-hoc rebuilt app builds trigger Keychain access prompts for `app.bookbook.api-key` on every rebuild (signing identity changes) (from Phase 9 hand checks).
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

None running.
