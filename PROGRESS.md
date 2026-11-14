# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `done (hand checks deferred)` · `done` · `deferred` · `blocked` · `post-MVP`

**Live API spend so far:** $0.58 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

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
| — | UI polish pass | done (hand checks deferred) | `ui-polish` | — | $0.00 | 2026-11-14. Six audits (five of the code, one of the running app), ten fix lanes, two code reviews and an on-screen check. No live checks. [Log](progress/ui-polish.md) |
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
- Assets generate from their description (decided 2026-11-11): the Assets tab has no session panel; the editor's description drives Generate / Regenerate (always a fresh picture, never a refinement), the newest generated or imported picture always becomes the asset's image, and earlier versions aren't shown. Import Image…, quality and the cost estimate stay; image details show what was sent. Tags are removed (they were never used) (PD §8.3, A §4.2, §7.3).
- Asset reference photo (decided 2026-11-11): an asset can have an optional reference photo (`Asset.referencePhoto`). Generate sends it with the description so the illustration keeps the likeness. It goes only with the asset's own requests, never with page or cover requests. It's stored scaled down (1536 px) with its metadata removed. Setting and removing it is undoable, and it doesn't count as "asset changed". Live check `SP10_referencePhotoToIllustration` passed ($0.015; fixture in `Tests/BBOpenAITests/Fixtures/openai/reference-photo/`) (PD §8.3, A §4.2, §7.3, §7.4, §11).
- Sidebar cards (decided 2026-11-11): the book window's sidebar, canvas and inspector are rounded cards on a darker desk (no split view). The panels are never hidden: the Session panel's toolbar toggle is removed, and it's always shown on Pages. Sidebar and inspector widths are resizable by dragging the gaps and are remembered. Page rows are white mini cards with a page thumbnail and the layout name, with the selected one filled tomato; the desk is a cooler taupe with a faint grain, and the sidebar tab icons show their own crayon colours (A §6.2).
- No title-bar items (decided 2026-11-11): the Pages tab's Overview / Editor switch is a two-segment control on the sidebar card under the tab picker, and the Offline indicator sits above the queue badge at the foot of the sidebar, so the title bar is the same height on every tab.
- Phase 16b product calls (decided 2026-11-09): an imported style guide keeps the target's page-number style; switching library folders with queued requests asks first; a lock from another Mac offers "Open Anyway", and Macs are identified by hardware UUID; undeliverable pictures are saved to disk, listed in `queue.json` and redelivered at launch; Draft All keeps counting the cover's box and says "cover + N pages"; after Reset Session → Keep Versions the next prompt makes a new picture until a version is clicked (PD §8.6); choosing a different version clears the old "style changed" acknowledgement (undo restores it; A §4.4); landscape booklets stay top-bound for v1.0 with "binds at the top" in the caption (left-bound layout is v1.x); imported RTF drops font family and size but keeps bold/italic/underline/alignment; cancelling story import keeps the new empty book; asset delete stays irreversible as PD §8.10 says.
- UI conventions (decided 2026-11-14, UI polish pass): Title Case for buttons, menu items and pop-up items; sentence case for alert and dialog titles, section headings and form labels; British spelling (Centre, Colour); "…" on anything that opens a dialog first; "image box", "requests" (queue), "Style Default", "OpenAI API key" and "Settings ▸ API Keys" as the fixed wording. Sheets use the shared scaffold (`CrayonHeader`, `crayonSheet`, `CrayonSheetFooter` / `CrayonSheetDoneFooter`); banners use `CrayonBanner`; inline status lines use `CrayonInlineMessage` with `Crayon.danger` / `warning` / `success`; empty states use `CrayonEmptyState`. Labels on crayon fills are chosen by contrast (`CrayonContrast`), which makes them dark ink (`Crayon.onFill`) in both appearances; `CrayonContrastTests` holds the rule. The Settings window stays a native grouped form. A text-style session's versions are called "versions", as picture sessions are. Stop in the text-style panel and the Layouts chat shows the PD §5 cancel notice first ([log](progress/ui-polish.md)).

## Deferred hand checks

Hand checks are deferred to the end of the build (decided 2026-11-08). Each phase adds the checks its automated pass couldn't confirm. Run them all after the last phase.

### Phase 10 — Assets and character sheets
- Page 3 "@Pip yawning by the fire": Version details lists Pip's image (needs a generation).
- Assets tab (generate from description, 2026-11-11): list on the left, editor on the right, no session panel. Type a description and press Generate: the status shows while it runs, and the picture becomes the image. Edit the description and press Regenerate: the new picture replaces the old one. Import Image… asks the real-person question and replaces the image. Image details shows the description as the request.
- An old book with reference slots and a character sheet opens with the primary slot's image as the asset's image, and its sheet items and queued sheet requests are gone.
- Rename Pip → Pippa: a sent page 3 prompt shows "Pippa"; changing Pippa's description or choosing a different image shows "asset changed" on pages with her placed images.
- Real-person photo: on first generation the notice appears with OpenAI's policy link and the children's-photos advice; also from an asset session and Draft All.
- Delete an asset in use: afterwards its mentions are plain text, including in Version details and Regenerate with Same Settings.
- Reference photo (2026-11-11): Add Photo… on an asset asks the real-person question and shows a thumbnail; Generate with an empty description draws the asset from the photo in the book's style, and the first time shows the real-person notice; Image details lists "Reference photo (photo)" as sent; a page that mentions the asset sends the illustration, not the photo; Replace… and Remove work, and Undo restores them (needs a generation).
- Undo/redo with a real keyboard for asset create, rename, description edit and checklist toggle (inconclusive under synthetic input).

### Phase 11 — Region editing
- Brush Pip's scarf, "make the scarf yellow": only the scarf changes; flipping old/new versions shows identical pixels outside the mask (needs a generation).
- Lasso the sky and replace it: feathered edge, no hard seam (needs a generation).

### Phase 12 — Consistency check and AI templates
- Pip with "a blue scarf" (reference red): the warning badge reads "scarf is blue; reference is red"; the one-click fix shows its estimate first, then gives a red scarf (needs a generation).
- Consistency switch off: the estimate drops (sub-cent, hidden by rounding to whole cents) and no follow-up is queued after a generation.
- "Big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box": a sensible template opens in the editor, snapped to the margins (needs a template call).
- Layouts chat (2026-11-11): New Layout with AI → describe it → the blank layout fills in; then "make the picture full-bleed" changes only that box, pages using the layout keep their text and picture, Undo and Restore This work, and the panel switches to Box when a box is clicked (needs template calls).
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
- Real-person notice after the cost alert (2026-11-11): open Generate's cost alert, give the asset a reference photo marked as a real person from another pane, then confirm: the notice sheet opens as the alert closes (no flash or stacking), and Continue sends the request without a second cost alert.
- A book with a HEIC style reference made before 2026-11-11 opens with it converted, and page generation works.
- Batch notice opening while the cost alert is closing: it shouldn't flash or stack (#30j; a hand check only, no automated test).
- Open Anyway on a lock from another Mac: the warning shows first, then the book opens editable.
- A burst of text-colour changes in the format bar undoes in one step (#76a).
- Importing a style guide copies its fonts into the book (#3d; no automated test).
- Reset Session → Keep Versions, then a prompt, makes a new picture (#48); undoing Choose Version clears the session panel's selection (#47). No automated tests.
- "Book Settings…" shows in the File menu (#5).
- Guided Setup closed with the close button doesn't reappear on the next launch (#4a). The app pass saw `onboardingCompleted` set, but `-BookBookLibraryRoot` suppresses Guided Setup, so relaunch with the default library.
- Draft All's cost text says "cover + N pages" (needs a key; the menu item is disabled without one).
- Open Anyway: the app pass saw the lock prompt and the book open editable, but not the extra confirm alert; check it shows.

### Sidebar cards (2026-11-11)
- Dark mode in the real app (an offscreen render looked right).
- Page-row thumbnails update when a page's picture or text changes.
- Drag the sidebar and Session gaps: the column-resize cursor shows, widths stay in range and persist after relaunch.
- The selected page row shows no grey system highlight peeking above the tomato card.

### AI text styling (2026-11-11)
- Click a story page's text box: the panel shows "Text Style". "Gold storybook frame with vines, playful font": "Designing the style…" shows, then the queued decoration; when it lands, the frame draws behind the text, the font/size/colour change, and the words stay editable (type in the box), spell-checked and inside the frame (needs a design and an image call).
- Transparency: no gpt-image model in the catalog claims `background: transparent` (unverified), so decorations are asked for on plain white and the white is keyed out locally. Check the frame's edges on a coloured illustration behind it for a white halo; if OpenAI supports transparency for the catalog models, set `supportsTransparentBackground` in `ModelCatalog.json` and re-check.
- Follow-up "make the frame blue" restyles the selected version (the old decoration is the base image); typography only ("bigger, bold font, no frame") makes a version at once without a picture.
- Cover title: single-click selects it for styling (double-click still opens Book Settings); a banner behind the title prints correctly.
- Version strip shows "Aa" samples; choosing an older style, Remove Style, and Undo/Redo of both work; Delete and Reset (discard) remove the style from the page.
- Version details lists the design (font, size, colour, inset, panel, decoration), the design prompts and parameters, and both costs; Repaint with Same Settings re-paints the decoration with the same typography.
- Export PDF and booklet: decorations print behind real text at full resolution; the text stays selectable.
- Duplicate a styled page: the copy keeps the style and has its own session. Change the page's layout: a style on a box the new layout lacks disappears and comes back on Undo.

### UI polish (2026-11-14)
An agent ran the app after the fixes and saw the composer, box inspector, overview, canvas caret placement, wizard (a 10 × 8 in book came out landscape), Settings and every sheet. These it couldn't reach or produce:
- Session composer with several attached references: the chips wrap onto further lines and nothing truncates at the narrowest inspector.
- A failed request in the thread shows Try Again and Dismiss; after Try Again the bubble shows waiting, then running (not "No picture from this request."), and Draft All skips that box. A request that's retrying shows "Retrying in N s (attempt 2 of 4)" (needs a failing request).
- Fix, Check Consistency and Regenerate with Same Settings show their estimate before they run; the cost alert's question matches the action ("Check this picture?").
- Read-only book: Generate, Regenerate, Reference Another Image…, Choose Image…, Reset Session…, Delete Version… and Try Again are disabled; Edit Typography… and Edit Page Numbers… open with their controls disabled and close normally; the asset editor's Where used links, View Larger and Image details still work; no I-beam over text boxes.
- Region editor on a real picture: the sheet is themed and titled, the cost pill follows the prompt as @mentions are typed, Redo is next to Undo, and the crosshair shows for the lasso only.
- Stop in the text-style panel and in the Layouts chat asks first, with the "may still be charged" notice.
- Text box rotated a few degrees: the first click places the caret at the click.
- Missing-fonts banner shows a "Typography…" button; a save error shows the banner with Try Again (needs a missing font, and a write failure).
- Library: right-clicking a book selects it; arrow keys move the selection. Settings ▸ Library ▸ Switch Anyway (with queued requests) shows the "Move your books…" alert after the first closes.
- Guided Setup's paste-key step: Return saves and tests the key and stays on the step (needs typing a key).
- Page Numbers with a decimal-comma region: typing "10,5" for the size saves 10.5.
- An enabled sunflower or bubblegum button (e.g. the save-error Try Again) has readable dark text; Settings ▸ API Keys and Models in Dark Mode.
- Opening a book that another copy of BookBook has locked shows one message with Open Read-Only, Open Anyway… and Close, and Open Anyway… shows its confirmation.

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.

### Phase 17
- UI polish 2026-11-14, left for a product call (the pass fixed only unambiguous polish; detail in the [log](progress/ui-polish.md)):
  - A read-only book's canvas ignores clicks, so boxes can't be selected to look at their versions or Version details.
  - The sidebar numbers story pages by position ("Page 4") while the overview and the canvas show printed numbers; after a spread or with Start at ≠ 1 they disagree.
  - The page canvas has no context menu and no Reset Crop.
  - Rotated text boxes are edited upright on the page canvas too (already listed for the template editor), and drag-selecting inside one uses unrotated coordinates.
  - The queue badge hides when only failed requests are left, so failures are easy to miss (the badge is the only in-window way into the Queue).
  - Page-menu edits (Duplicate, Delete, Mark as Done, Skip Page Number, Export Page as Image…) stay enabled on the Assets, Style and Layouts tabs and act on a page that isn't showing.
  - Book Settings ▸ Clean Up deletes at once although the sheet has Cancel and Save.
  - The Pages, Assets and Layouts lists add, delete and draw their rows three different ways (page rows are tomato cards; the others are system rows).
  - "Template" still appears where everything else says "Layout": Import from Book, Import Story Text, Settings ▸ Models ("Templates"), Book Settings' cost line.
  - The Layouts chat confirms cost inline (Back / Send) where everything else uses the "Confirm cost" alert.
  - The reference picker lists every earlier version of an asset, though earlier asset versions aren't shown anywhere else.
  - Same job, different words: "Retry" (Queue) vs "Try Again"; "Choose Image…" (session) vs "Import Image…" (asset); "Done" applies in Page Numbers, only closes in Typography, and cancels in Export.
  - Export shows no "Show in Finder" afterwards, and Export Cover Separately… shows no progress or result.
  - Style reference images can be dragged in and accept four formats; asset images and reference photos can't be dragged in and accept any image.
  - The asset editor shows the reference photo below the description; PD §8.3 lists it first.
  - Unchecked checkboxes almost disappear on the dark paper, and single-line fields are near-black beside the card-tinted editors: both need Crayon toggle and field styles applied app-wide.
  - Disabled pickers are nearly invisible in the dark Page Numbers sheet.
  - The Library and Queue windows have a grey system toolbar strip; book windows are themed edge to edge.
  - Sheet primary buttons are tomato, grass, sky or grape depending on the sheet.
  - Light-mode contrast just under 4.5:1: `Crayon.inkSoft` on paper (4.45) and `Crayon.warning` on paperDeep (4.41). Blob-icon glyphs stay white on the fills.
  - A new book's window opens screen-sized; the sample book's opens at 1200 × 780.
  - The wizard's Skip discards what was typed on that step.
  - A layout preset the book hasn't copied yet shows greyed, like a disabled row.
  - The canvas exposes no accessibility elements for its boxes; @mention suggestions can't be moved through with the arrow keys.
  - `PixelSize.description` (BBModel) prints "1024x1536"; BBUI now writes "1024 × 1536".
  - At the minimum window height, list content shows in the margin under the book-switcher card.
  - Settings ▸ General and API Keys have about 100 pt spare at the bottom (pane heights were estimated).
  - Tomato-tinted system segmented pickers (Chat / Box, Portrait / Landscape, Export's Output, Typography's Alignment, Edit Region's Brush / Lasso) keep white labels, beside the dark-ink labels everywhere else, and are low-contrast in Dark Mode; a Crayon segmented control would fix it.
  - The Edit Region sheet opens at 920 × 700 so its tool labels fit, which is larger than a book window at its 840 × 552 minimum (it was 720 × 600 minimum before, also taller than that window); icon-only tools would let it shrink.
  - "New" and "…" in the Layouts list and the "+" in Assets still draw in the light tomato fill colour, not the readable accent; in the box inspector Padding's "pt" sits left of the other unit labels, and "Background panel" shrinks at the narrowest width.
  - Accent text (selected names, "New", "+", chevrons) uses `Crayon.danger` for its readable light-mode tomato; it wants its own token name.
  - In a read-only book the open-hand cursor still shows over a placed, selected image box.
  - The compact page-status badges in the page rows keep white glyphs on sky, grass and grape; the box inspector's "Override font size" stepper shows its value beside the label, unlike Padding.
- AI text styling (2026-11-11): changing a page's layout doesn't carry a text box's style over to the matching box of the new layout (it stays keyed by the old box); the font list is a curated set plus the book's fonts, so a family the user installed but didn't use isn't offered; `TextStyleFonts.allowed` scans the installed families on every estimate (cache it with the font-registration revision); confirm `background: transparent` support for the catalog's gpt-image models (live) and turn off the local white key where it works.
- Layouts chat: replies are only a summary line plus a diagram, since the shared `TemplateDraft` schema has no message field; consider adding a short `reply` field (changes the wire schema for every adapter). Threads aren't saved (decided 2026-11-11) (from the Layouts chat change).
- Simplify leftovers (from the 2026-11-09 whole-codebase simplify pass): cache `FontFamilies.all` with an app-wide font-registration revision; add `PageStatus.title` shared by `StatusBadge`, `PagesOverview` and `BookWindow`.
- Simplify pass 2026-11-11 leftovers. **Wording (needs a product call):** `ProviderErrorText` duplicates `RefusalAdvisor` with drifted wording; asset type names/symbols differ between `AssetEditing` ("Place / Scene", `person`) and `AssetTypeText` ("Place", `person.crop.circle`); cost kinds read "Images"/"Templates" in `BookSettingsSheet` but "Pictures"/"Layout suggestions" in `CostText`; onboarding `TypicalCosts.format` formats money unlike `CostText.amount`; `FontFamilies.regularFace` and `PageNumberFontNames` pick a family's regular face differently. **Larger refactors:** narrow what `BookEditor` observes and skip unchanged canvas redraws; per-edit font/usage bookkeeping in `scheduleSave`; give `QueueItem.Kind` its per-kind behaviour (consistency checks); one BBModel "home of a session" query; merge `GenerationTarget` into `SessionOwner`; share the region-mask replay between `RegionMaskPreview` and `ImageOps.rasterize`, and redraw the region editor incrementally; lift `fixSplits` out of the BookCommand payloads; a content-addressed `ImageRef` helper shared by the queue and `BookStore` (needs CryptoKit in BBModel); ~250 stale phase/lane comments in production code.
- Second-order leftovers from the 2026-11-11 likely-bug fixes (the first six leftovers were fixed on `fix-likely-bug-leftovers`):
  - Import From Book copies style references as-is; a bad (HEIC/mislabelled) one imported into an open book is only repaired the next time that book opens.
  - Clean Up's hand-out generation doesn't cover a caller that got an image ref before Clean Up started and holds it across further awaits (e.g. `OpenBooks.storeImage` storing a region edit's extra images, then the main result). Closing it needs callers to register held refs.
  - `BookStore.imageHandOuts` gains one entry per distinct file stored and is never pruned.
  - If recording the real-person acknowledgement fails (e.g. read-only book), Continue shows the notice again instead of enqueuing.
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
