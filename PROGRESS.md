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
| 16 | Import, book settings, onboarding, sample | done (hand checks deferred) | `phase-16-import-onboarding` | — | $0.00 | No live checks listed. Sample book and preset samples are placeholders until you make them. [Log](progress/phase-16-import-onboarding.md) |
| 16b | Bug fixes and edge cases | done (hand checks deferred) | `phase-16b-bug-fixes` | — | $0.00 | Merged 2026-11-09. 181 follow-ups triaged; 92 fixed. No live checks. [Log](progress/phase-16b-bug-fixes.md) |
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
- One image per asset (decided 2026-11-11): every asset has exactly one image, made in one session; reference slots, the primary toggle and the character sheet are removed from the model and UI, and page generation sends each mentioned or checked asset's chosen image. Legacy books keep the primary slot on open and drop other slots and sheet items (PD §8.3, A §4.2, §7.4).
- Phase 16b product calls (decided 2026-11-09): an imported style guide keeps the target's page-number style; switching library folders with queued requests asks first; a lock from another Mac offers "Open Anyway", and Macs are identified by hardware UUID; undeliverable pictures are saved to disk, listed in `queue.json` and redelivered at launch; Draft All keeps counting the cover's box and says "cover + N pages"; after Reset Session → Keep Versions the next prompt makes a new picture until a version is clicked (PD §8.6); choosing a different version clears the old "style changed" acknowledgement (undo restores it; A §4.4); landscape booklets stay top-bound for v1.0 with "binds at the top" in the caption (left-bound layout is v1.x); imported RTF drops font family and size but keeps bold/italic/underline/alignment; cancelling story import keeps the new empty book; asset delete stays irreversible as PD §8.10 says.

## Deferred hand checks

Hand checks are deferred to the end of the build (decided 2026-11-08). Each phase adds the checks its automated pass couldn't confirm. Run them all after the last phase.

### Phase 10 — Assets and character sheets
- Page 3 "@Pip yawning by the fire": Version details lists Pip's image (needs a generation).
- Assets tab (one image per asset, 2026-11-11): list on the left, editor in the middle, the selected asset's session always on the right; clicking a version makes it the asset's image, and Undo puts the old one back; importing a file adds a version in that session.
- An old book with reference slots and a character sheet opens with the primary slot's image as the asset's image, and its sheet items and queued sheet requests are gone.
- Rename Pip → Pippa: a sent page 3 prompt shows "Pippa"; changing Pippa's description or choosing a different image shows "asset changed" on pages with her placed images.
- Real-person photo: on first generation the notice appears with OpenAI's policy link and the children's-photos advice; also from an asset session and Draft All.
- Delete an asset in use: afterwards its mentions are plain text, including in Version details and Regenerate with Same Settings.
- Undo/redo with a real keyboard for asset create, rename, description edit and checklist toggle (inconclusive under synthetic input).

### Phase 11 — Region editing
- Brush Pip's scarf, "make the scarf yellow": only the scarf changes; flipping old/new versions shows identical pixels outside the mask (needs a generation).
- Lasso the sky and replace it: feathered edge, no hard seam (needs a generation).

### Phase 12 — Consistency check and AI templates
- Pip with "a blue scarf" (reference red): the warning badge reads "scarf is blue; reference is red"; the one-click fix shows its estimate first, then gives a red scarf (needs a generation).
- Consistency switch off: the estimate drops (sub-cent, hidden by rounding to whole cents) and no follow-up is queued after a generation.
- "Big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box": a sensible template opens in the editor, snapped to the margins (needs a template call).
- Layouts chat (2026-11-11): New Layout with AI → describe it → the blank layout fills in; then "make the picture full-bleed" changes only that box, pages using the layout keep their text and picture, Undo and Restore This work, and the panel switches to Box when a box is clicked (needs template calls).
- Confirm-cost alert wording for a check or fix (Session A noted it says "Generate").
- Real-person photo: Check Consistency shows the notice first, then the cost step.

### Phase 14 — Export and print
- Letter booklet of a 10-page 5.5×8.5 in book: print double-sided (short-edge flip), fold and staple; the pages read in order. Also try one with the cover included (inside-front-cover blank).
- Print-shop PDF: open in Acrobat and confirm the TrimBox/BleedBox (PDFKit confirmed them) and that crop marks look right in Preview.
- Spreads option: a book with a spread exported as single pages and as double-width pages.
- Export progress and Cancel on a large book with many images (small books finish before progress shows).
- Undo after Turn On Bleed in the export sheet.

### Phase 16 — Import, book settings, onboarding, sample
- Fresh macOS user account: first run shows Guided Setup (the automated pass used `-onboardingCompleted NO` instead).
- The real sample book (6–8 pages, Standard quality, under 15 MB) and the ~8 preset sample images: make them in the app and bundle them (see the READMEs in `Resources/SampleBook/` and `Resources/Presets/Samples/`), then explore the sample with no key.
- Wizard with a name-only main character (no description) creates the asset (the automated run was inconclusive).
- Import a template: the copy shows in the template list, and editing it doesn't change the original.
- Clean up a book with 30 unused unstarred versions: the count and MB shown, the confirmation, and size on disk dropping by that amount (needs generations).
- Book Settings cost breakdown by type (images / consistency checks / templates) and recent requests on a book with spend.
- Guided Setup's OpenAI links (api-keys, billing overview, organization general) open the right pages; `curl` got 403s from Cloudflare.

### Phase 16b — Bug fixes and edge cases
- Batch notice opening while the cost alert is closing: it shouldn't flash or stack (#30j; a hand check only, no automated test).
- Open Anyway on a lock from another Mac: the warning shows first, then the book opens editable.
- A burst of text-colour changes in the format bar undoes in one step (#76a).
- Importing a style guide copies its fonts into the book (#3d; no automated test).
- Reset Session → Keep Versions, then a prompt, makes a new picture (#48); undoing Choose Version clears the session panel's selection (#47). No automated tests.
- "Book Settings…" shows in the File menu (#5).
- Guided Setup closed with the close button doesn't reappear on the next launch (#4a). The app pass saw `onboardingCompleted` set, but `-BookBookLibraryRoot` suppresses Guided Setup, so relaunch with the default library.
- Draft All's cost text says "cover + N pages" (needs a key; the menu item is disabled without one).
- Open Anyway: the app pass saw the lock prompt and the book open editable, but not the extra confirm alert; check it shows.
- New Book wizard: choosing 10 × 8 in gave a portrait book in the app pass (possibly a synthetic-input miss); check that it comes out landscape.

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.

### Phase 17
- Layouts chat: replies are only a summary line plus a diagram, since the shared `TemplateDraft` schema has no message field; consider adding a short `reply` field (changes the wire schema for every adapter). Threads aren't saved (decided 2026-11-11) (from the Layouts chat change).
- Performance: a spread exported as single pages prepares its images twice (from Phase 14).
- Simplify leftovers (from the 2026-11-09 whole-codebase simplify pass): cache `FontFamilies.all` with an app-wide font-registration revision; add `PageStatus.title` shared by `StatusBadge`, `PagesOverview` and `BookWindow`; have `BookDocument.sequence(of:)` use `PageSequencer.layout(for:)`; `PDFExporter` is only used by tests (move them to `BookExporter.pdfData` and delete it).
- OpenAI-only wording cleanup: v1.0 is OpenAI only, so make sure no Gemini choice shows in the app (a Gemini mention in `ModelCatalog.json`, plus Gemini text in `RealPersonNotice.swift` and `VersionDetailsContent.swift`), and that the final live pass covers only OpenAI (Gemini moved to post-MVP 2026-11-08).
- Chat `refusal` maps to stage `.output`, which is a guess; confirm it against a real refusal (live) (from Phase 12).
- The SP12 live test hardcodes model IDs; read them from the catalog (from Phase 12).
- SP11 live test builds its own white mask instead of `ImageOps.providerMaskPNG`'s black, so the app's wire mask is untested live (`LiveProviderTests.swift:177`) (from Phase 11 review).
- `OpenAIErrorMapper` key-occurrence check misses JSON-escaped keys and the mask stops at `.` (key-hygiene hardening for the security pass) (from Phase 9 review).
- The 16×16 patch rule underestimates large reference images (1536×1024 measured 1536, rule gives 704); measure more sizes or switch the fallback rule (needs live measurements and a price-list refresh) (from Phase 9).
- Ad-hoc rebuilt app builds trigger Keychain access prompts for `app.bookbook.api-key` on every rebuild (signing identity changes) (from Phase 9 hand checks).
- Overview: double-clicking a page thumbnail may not open it (seen with synthesized clicks only; UI smoke suite) (from Phase 8 hand checks).
- A project run skill (launch, `-BookBookLibraryRoot`, accessibility driving) would speed up automated hand checks (smoke-suite tooling) (from Phase 8 hand checks).
- Template-editor drag throttle: each drag tick copies `BookContent`, schedules a save and refreshes missing fonts inside `BookDocument.perform`; needs coalescing there (from Phase 6, still open after Phase 7).
- No regression tests for the Typography form fixes (UI smoke suite) (from Phase 7).
- Overview thumbnails hash whole `Page`/`Template`/`StyleGuide` per cell per redraw; key on IDs plus a revision (from Phase 5 review).
- `refreshMissingFonts()` walks every page on each undoable edit (performance) (from Phase 4).
- Undo-coalescing tests spin the run loop once per keystroke (`TestRunLoop`); watch them for CI flakiness (from Phase 4).
- `BookEditorLayoutTests` opens a real `NSWindow` (it needs a GUI session) and depends on the measured 830 pt SwiftUI minimum; it doesn't test widened sidebar or inspector panels with a narrow window (UI smoke suite) (from Phase 4 review).
- The canvas loads images synchronously on the main thread (move to an actor `ThumbnailCache`) (from Phase 2).
- App icon and `UTTypeIcons` for `.bookbook` documents are placeholders (Finder shows a generic package icon) (from Phase 1b).
- The `xcode-27` runner image is "preview", and Xcode 27.2 is an RC there; the `xcode-select` path may change (from Phase 1b).
- `actions/checkout` v4.2.2 / `actions/cache` v4.2.0 are Node 20 actions; bump them when GitHub retires Node 20 (from Phase 1b).
- Flaky: `LibraryActionsTests.duplicate_flushesAnOpenSourceFirst` failed in several lane runs ("Operation not permitted" removing `.journal`, or the duplicate not found); it passed in both Session B full runs, so keep watching it (from Phase 16b).
- `Library.duplicate` now takes the source's lock, so duplicating a book in a read-only location (or one open read-only here) fails; it worked before (from Phase 16b review).
- `BookLock.isLive` compares wall-clock times (`started > acquiredAt + 5`); a clock jump back can make a live lock on this Mac look stale and get taken over (from Phase 16b review).
- A stale `.lock` from an earlier boot whose PID matches this process reads as held by another holder, so closed-book deliveries stay `.bookUnavailable` until the book is opened (from Phase 16b review).

### v1.x
- Preflight spelling uses `language: nil`, so macOS auto-detects the language and accepts "teh" (a Malay word); real English typos are still flagged. Pinning the book's language is a product call (from Phase 16b).
- A read-only open of an older-schema book has no in-memory migration (no older schema can exist in v1.0; needed with the first migration) (from Phase 3, moved by Phase 16).
- `RenderOptions.Target.print` is unused (print renders `.pdfTrim`) (a dead enum case with no user impact) (from Phase 14).
- Left-bound side-by-side landscape booklet layout; v1.0 stays top-bound with "binds at the top" in the caption (by product decision) (from Phase 14).
- Export image crops round out by up to 2 px (under 1 source pixel per edge, invisible in print) (from Phase 14).
- The text-overflow preflight detail is generic (a more specific detail needs layout measurement; polish) (from Phase 14).
- A failed check records nothing of what was sent, so Version details can't show it (needs a schema change) (from Phase 12).
- `startRegionEdit` reads the image with blocking `Data(contentsOf:)` on the main actor (`SessionPanel.swift:363`) (a single small local read; not worth restructuring the view) (from Phase 11 review).
- Mask bytes are outside `ReferenceSelector`'s byte budget (`ContextAssembler.swift:354`) (budget accuracy only; the mask is small) (from Phase 11 review).
- Blank/failed-composite results report `attempts: 1` after retries (`GenerationQueue.swift:485`) (a cosmetic attempt count) (from Phase 11 review).
- Gray/CMYK bases composite via sRGB (a colour-space nuance on rare imports; risky to change blind) (from Phase 11 review).
- Region edit queued >24 h: the sweep keeps its versions, but file-name protection can't cover refine bases or attached references of waiting items (versions stay in book JSON, so the sweep keeps them anyway) (from Phase 16b).
- The region editor's ⌘Z/⇧⌘Z capture takes text undo from the prompt field (responder-chain polish) (from Phase 11).
- Region editor: no zoom/pan (a feature) (from Phase 11).
- Version details shows the mask and raw output as text only (polish) (from Phase 11).
- Cancelling the region-edit cost confirm loses the painted mask and prompt, because the sheet closes first (needs the flow restructured; the alert only shows above the confirm limit) (from Phase 11).
- Edit Region is hidden, not disabled, with no image version (cosmetic; there's nothing to edit with no picture) (from Phase 11).
- `RealPersonCheck` sets byte counts to 0, so a skipped (missing/too-large) image can hide a later real-person photo from the check (only matters at the image-count cap; the check errs towards showing the notice) (from Phase 10 review).
- Undoing New Asset after it's mentioned leaves dangling tokens (rare: a mention followed by an immediate undo) (from Phase 10 review).
- Where-used ignores mentions in asset-session prompts (display only; `UsageSite` is page-based) (from Phase 10 review).
- The real-person notice isn't re-checked when a queued item actually sends (needs a host hook into the queue) (from Phase 10 review).
- A token whose answered message is gone still renders empty (rare; same family as the undo-after-mention item) (from Phase 10 review).
- Pages grid: thumbnails for pages 2 and 3 overlapped after adding a page (can't reproduce from code; recheck in the app pass) (from Phase 10 hand checks).
- Recent Requests caps at 50 while the total sums all (`Cost.swift:88`) (polish; the total is correct) (from Phase 9 review).
- `CostLedger.repair()` runs without the book lock (multi-process only) (from Phase 9 review).
- Cached input tokens are attributed to text first, then image (OpenAI reports a single cached count; minor accuracy) (from Phase 9).
- Unclassified OpenAI 403s still map to `.unknown(raw)` (documented in `OpenAIErrorMapper`); classify codes as they're seen (from Phase 2, kept in Phase 9).
- A brief lock held by a delivery/snapshot makes a concurrent open in another process see "locked" (multi-process only; feature-sized) (from Phase 3, not addressed in Phase 9).
- Ledger lines are appended even while another process holds the book's lock; `CostLedger.repair()` there could trim a line being written (multi-process only; `flock` on `costs.jsonl` later) (from Phase 9).
- Version numbers are strip positions (`versionNumber`), so deleting a version renumbers later ones; "refined version N" tags and "Refined from" then point at the wrong version (IDs resolve correctly; a stable number is a schema addition) (from Phase 8 review).
- After undoing a Keep Versions reset, the session panel won't refine the placed version until a version is clicked (#48) (from Phase 16b).
- `baseImageTooLarge` / a refine on a deleted base (`baseVersionGone`) only fail at request time; the panel could warn or disable Refine (failures already show advice; a panel warning is polish) (from Phase 8 review and lanes).
- `AspectFitter.snap` returns nil for fixed-ratio models and ignores its `quality` parameter (only matters for post-MVP Gemini) (from Phase 8 fixes).
- The safe area uses `box.bleedEdges` without checking that the box reaches the trim (prompt guidance only) (from Phase 8 lanes).
- No two-image-box template preset (new preset content; users can build one now that boxes no longer stack) (from Phase 8 hand checks).
- Style tab: `TextEditor` typing may log to the window undo manager, so a second ⌘Z while focused undoes typing into the draft (can't confirm offline; risky undo plumbing) (from Phase 7 review).
- Style tab: picking a preset while Description has uncommitted typing drops the typing (the preset replaces the description anyway; low value) (from Phase 7 review).
- Template editor: no snapping during ⇧ aspect-locked resize (needs new snapping math) (from Phase 6).
- Template editor: no multi-box resize handles (a feature) (from Phase 6).
- Template editor: the in-place text editor isn't rotated for rotated text boxes (risky canvas and TextKit work for a rare case; touches `CanvasView`) (from Phase 6).
- Page setup has one uniform margin field; per-edge margins aren't editable (a feature) (from Phase 7).
- `.rtfd` story import is unsupported (needs package reading; rare) (from Phase 5).
- Imported RTF keeps its text colour (the product call on RTF import didn't mention colour) (from Phase 16b).
- `PageRenderer` half culling uses `CGRect.intersects`, inconsistent for an edge exactly on the gutter (content stream only; output is clipped) (from Phase 5 review).
- Format bar: there's no typed size field, only ±1 pt steps (a feature) (from Phase 4 review).
- Pasted text with no requested font still uses the family match (the current behaviour is reasonable; design choice) (from Phase 4).
- The `fsType` embedding check runs only on import: a restricted system font picked from the menus isn't flagged (needs `fsType` inspection of installed fonts; system fonts are embeddable in practice) (from Phase 4 review).
- A trailing empty paragraph loses its alignment and formatting on a round trip (needs typing-attribute plumbing for an invisible state) (from Phase 4).
- A family with only a bold face stores `bold: true` but can't draw it; consider disabling B (polish for rare font families) (from Phase 4).
- Calm-area guidance only for overlapping text boxes, not adjacent ones (a prompt tweak that needs live generations to judge) (from Phase 2).
- Versions dropped as invalid on load can leave dangling placements, which resolve to nil (only hand-edited JSON triggers it; it renders as an empty box) (from Phase 2).
- The secret scan doesn't decode UTF-16 files (e.g. `Localizable.strings`) (no UTF-16 files are tracked; push protection is the backstop) (from Phase 1a).
- Library actions have no menu-bar items (`BookBookCommands.swift`) (menu-bar parity is polish; context menu and toolbar already cover it) (from Phase 3).
- A restored window for a deleted book may flash briefly after ⌥⌘Q (cosmetic, and owned by SwiftUI) (from Phase 3).
- The app's own autosaves trigger full library rescans (performance only; needs an own-writes ledger) (from Phase 3 review).
- Read-only `load()` skips recovery, so it can show a half-applied save from the writer (a transient read-only view; overlaying staged files is M work for little value) (from Phase 3 review).
- Moving the library closes only books already in `documents`; a book mid-open reopens at the old URL (needs a library-wide barrier; rare and user-initiated) (from Phase 3 review).
- `BookLock.acquireHold` holds the process-wide `Mutex` across file I/O and a blocking `flock` (the stall is theoretical; restructuring the hold count is risky) (from Phase 3 review).
- A throwaway `-BookBookLibraryRoot` library gets its own `pricelist.json` (from Phase 16b).

## Current phase log

The running phase writes its log here; when it is marked done, move the entry to `progress/phase-<id>-<slug>.md`.

_No phase running._
