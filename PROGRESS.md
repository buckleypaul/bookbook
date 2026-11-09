# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `done (hand checks deferred)` · `done` · `deferred` · `blocked` · `post-MVP`

**Live API spend so far:** $0.56 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

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
| 11 | Region editing | done (hand checks deferred) | `phase-11-region-editing` | — | $0.04 | Live check `SP11_maskedEditRealIllustration` passed. [Log](progress/phase-11-region-editing.md) |
| 12 | Consistency check and AI templates (M3) | done (hand checks deferred) | `phase-12-consistency-ai-templates` | — | $0.007 | Live check `SP12_templateAndConsistency` passed. [Log](progress/phase-12-consistency-ai-templates.md) |
| 13 | Gemini provider | post-MVP | | | | Out of scope for v1.0 (decided 2026-11-08). Spec kept in `plan/post-mvp/phase-13-gemini.md`. |
| 14 | Export and print | done (hand checks deferred) | `phase-14-export-print` | — | $0.00 | No live checks listed. [Log](progress/phase-14-export-print.md) |
| 15 | Release pipeline (M4) | deferred | | | | Deferred by you on 2026-11-08: finish the product work first, then do the tap. Phase 16 runs before it. Not picked as "next" until you un-defer it; Phase 17 still needs it. |
| 16 | Import, book settings, onboarding, sample | in progress | `phase-16-import-onboarding` | — | | |
| 17 | Hardening and v1.0 (M5) | not started | | | | |

## Standing decisions

Facts later phases depend on. Detail is in the logs under `progress/`.

- The cover page is created with every book (`Book.coverPageID` is valid) but is hidden, not edited and not exported until Phase 5 ([Phase 2](progress/phase-2-thin-slice.md)).
- The app accepts a `-BookBookLibraryRoot <path>` launch argument (argument domain only, never saved) for throwaway libraries in automated runs ([Phase 2](progress/phase-2-thin-slice.md)).
- BBAITests prompt snapshots live in `Tests/BBAISnapshots/`; BBLayoutTests excludes `__Snapshots__` ([Phase 2](progress/phase-2-thin-slice.md)).
- Page commands never touch sessions; TextKit 2 layout, rendering and export are `@MainActor` for now ([Phase 2](progress/phase-2-thin-slice.md)).
- Gemini (Phase 13, including spikes SG-1...SG-8) is post-MVP (decided 2026-11-08). v1.0 ships with OpenAI only ([Phase 0](progress/phase-0-spikes.md)).
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

### Phase 11 — Region editing
- Brush Pip's scarf, "make the scarf yellow": only the scarf changes; flipping old/new versions shows identical pixels outside the mask (needs a generation).
- Lasso the sky and replace it: feathered edge, no hard seam (needs a generation).

### Phase 12 — Consistency check and AI templates
- Pip with "a blue scarf" (reference red): the warning badge reads "scarf is blue; reference is red"; the one-click fix shows its estimate first, then gives a red scarf (needs a generation).
- Consistency switch off: the estimate drops (sub-cent, hidden by rounding to whole cents) and no follow-up is queued after a generation.
- "Big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box": a sensible template opens in the editor, snapped to the margins (needs a template call).
- Confirm-cost alert wording for a check or fix (Session A noted it says "Generate").
- Real-person photo: Check Consistency shows the notice first, then the cost step.

### Phase 14 — Export and print
- Letter booklet of a 10-page 5.5×8.5 in book: print double-sided (short-edge flip), fold and staple; the pages read in order. Also try one with the cover included (inside-front-cover blank).
- Print-shop PDF: open in Acrobat and confirm the TrimBox/BleedBox (PDFKit confirmed them) and that crop marks look right in Preview.
- Spreads option: a book with a spread exported as single pages and as double-width pages.
- Export progress and Cancel on a large book with many images (small books finish before progress shows).
- Undo after Turn On Bleed in the export sheet.

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.


### Phase 16
- Hand-check the title-box bold state: title/author boxes are bound and not text-editable (double-click opens Book Settings), so B is disabled there. Check it once the Style tab owns the title font: B shows on over the bold title face, and pressing it gives the regular weight (from Phase 4, moved by Phases 5 and 7; unreachable in Phase 7 because the box opens Book Settings).
- A read-only open of an older-schema book has no in-memory migration (from Phase 3; or Phase 17).

### Phase 17
- Phase 14 review should-fixes: export cache files are written straight to their final path and `fileExists` counts as a hit, so a truncated file breaks that image forever (write to temp and rename, `ExportImagePreparer.swift:52`); `ImageFiles.decode` is lazy, so the 300 DPI bitmap decodes on the main actor during `ctx.draw` (use `kCGImageSourceShouldCacheImmediately`); `canExport` doesn't wait for preflight, so you can export before issues load; preflight isn't re-run after Turn On Bleed (soft-image "needs" stays at the no-bleed size); preflight ignores the page range and cover exclusion; a word misspelled twice in one box gives duplicate `PreflightIssue.id`s; the export cache in `~/Library/Caches/BookBook/<id>/export` is never pruned (from Phase 14).
- Phase 14 nits: `RenderOptions.Target.print` is unused (print renders `.pdfTrim`); a spread exported as single pages prepares its images twice; the soft-image detail gives width only and flags any crop under 600 px even when downsampled for a small box; `LiveExportServices.print` captures `NSApp.keyWindow` (the sheet) before the PDF is built (from Phase 14).
- Phase 14 app pass: "Exported N pages." stays in the sheet footer after options change; preflight rows all read "Image box has no image" with no page number; the save panel starts at "Macintosh HD" when the app is launched via `open` (from Phase 14).
- Stacked landscape booklets bind at the top; landscape picture books are usually bound on the left. Product call: confirm or add a rotated side-by-side layout (from Phase 14).
- Export image prep ignores box rotation (crop is the unrotated footprint), and crops round out by up to 2 px (from Phase 14).
- Crop marks are plain black, not registration colour (from Phase 14).
- `SystemSpellingChecker` (NSSpellChecker) has no test; the text-overflow preflight detail is generic (from Phase 14).
- v1.0 is OpenAI only: make sure no Gemini choice shows in the app (there's a Gemini mention in `ModelCatalog.json`, plus Gemini text in `RealPersonNotice.swift` and `VersionDetailsContent.swift`), and that the final live pass covers only OpenAI (Gemini moved to post-MVP 2026-11-08).
- Flaky: `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` fails now and then (NSCocoaError 512 / POSIX 22 saving `.journal/<id>/staged`) and passes on re-run (seen in Phase 12 Session B and Phase 14 Session B).
- Confirm-cost alert's button says "Generate" for a consistency check (from Phase 12).
- Chat `refusal` maps to stage `.output`, which is a guess; confirm it against a real refusal (from Phase 12).
- The SP12 live test hardcodes model IDs; read them from the catalog (from Phase 12).
- "Regenerate with Same Settings" on a fix version keeps `versionSource`, so the new version is labelled `.consistencyFix` too (from Phase 12).
- "Mark Images as OK" (`BookDocument.swift` ~535) doesn't clear the consistency-warning flag (from Phase 12).
- A failed check records nothing of what was sent, so Version details can't show it (from Phase 12).
- `GenerationQueue.retry` puts a failed check at the back of the queue, and a retry can run beside a newer check of the same version (from Phase 12).
- `runConsistencyCheck` fails with `.unknown` when the book is gone; drop it quietly instead (from Phase 12).
- Template "What was sent" is filled in on `.missingKey`, when nothing was sent (from Phase 12).
- `TemplateNormalizer.snapLines` doesn't mirror margins on a spread's right page (from Phase 12).
- `TemplateNormalizer` throws `.noBoxes` and doesn't make a fallback box; note this in A §7.7 (from Phase 12).
- A throwaway `-BookBookLibraryRoot` library showed "Resume 13 queued requests", so the queue file seems shared across library roots (from Phase 12 app pass).
- Duplicate `.fixedSize` modifiers on two footers in `ModelSettings.swift` (from Phase 12).

### Later
- Phase 11 review should-fixes: `finishSuccess` ignores a cancel during the off-thread composite (`GenerationQueue.swift:482`); `startRegionEdit` reads the image with blocking `Data(contentsOf:)` on the main actor (`SessionPanel.swift:363`); SP11 live test builds its own white mask instead of `ImageOps.providerMaskPNG`'s black, so the app's wire mask is untested live (`LiveProviderTests.swift:177`); `RegionEditAvailability` unused and its Gemini wording differs from `RegionEditRefusal.maskUnsupported`; mask bytes are outside `ReferenceSelector`'s byte budget (`ContextAssembler.swift:354`); blank/failed-composite results report `attempts: 1` after retries (`GenerationQueue.swift:485`); gray/CMYK bases composite via sRGB (from Phase 11 review).
- Phase 11 known items: a region edit queued >24 h can lose its mask to the open-time image sweep; the editor's ⌘Z/⇧⌘Z capture takes text undo from the prompt field; the cost alert button says "Generate" for region edits; no zoom/pan in the editor; Version details shows mask/raw output as text only; cancelling the cost confirm loses the painted mask and prompt (the sheet closes first); Edit Region is hidden, not disabled, with no image version (from Phase 11).
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
- `AspectFitter.snap` returns nil for fixed-ratio models (no snapping; matters once Gemini lands, post-MVP) and ignores its `quality` parameter (from Phase 8 fixes; post-MVP Gemini).
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

### Phase 16 — Library import, book settings, onboarding, sample

**Stage:** B

- 2026-11-08: Phase 15 deferred at your request; Phase 16 started (its dependencies 3, 10 and 14 are done).
- Contracts: `BBStore/Phase16/Phase16Contracts.swift` (import, clean-up plan, `NewBookSpec`).
- Lanes, all merged:
  - **L1 store:** `BookImporter` (clashes, build with ID remapping, image copy deduplicated by hash), `CleanUp` (plan, apply, immediate file delete), `BookStore.sizeOnDisk`, and duplicate `Book.id` resolution on library refresh (Phase 3 follow-up).
  - **L2 onboarding:** a "Guided Setup" window scene that opens on first launch (flag `onboardingCompleted`; not under XCTest or when a key is saved), with typical costs from the price list. It can be reopened from Settings › API Keys and the Help menu.
  - **L3 wizard and sample:** a five-step `NewBookWizard` (each step skippable), `NewBookSpec.apply`, `Library.createBook(spec:)`, `StylePreset.sampleImage` (optional; none bundled yet), the bundled placeholder sample book "Pip and the Missing Moon" (text only), and Open Sample Book in the library toolbar, the empty state and the File menu.
  - **L4 import and clean-up UI:** the `.importFromBook` command, `ImportFromBookSheet` (book menu and File › Import from Book…), and Book Settings › Storage (size on disk, Clean Up… with confirmation). Book Settings cost labels now read images / consistency checks / templates.
- Assumptions:
  - The real sample book and the preset sample images are content you make in the app, per the content note. The bundled sample is a text-only placeholder made by `SampleBookGenerator` (`BOOKBOOK_GENERATE_SAMPLE=1`). To add the real ones, see the READMEs in `Resources/SampleBook/` and `Resources/Presets/Samples/`.
  - Read-only open of an older-schema book (Phase 16/17 follow-up) is left for Phase 17.
- **For Session B:**
  - Run the full `scripts/test.sh all`.
  - Check that Guided Setup's OpenAI billing and organization URLs are current.
  - Check undo of import, and that Clean up handles dangling `parent`/`refines` lineage (L1 noted it doesn't check `Session+Lineage`).
  - Check that the sample opens with no key, and that the onboarding window doesn't pop up in automated app runs.
