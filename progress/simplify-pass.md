# Simplify pass (2026-11-15 to 2026-11-21)

A whole-codebase quality pass over the production code (`BookBookKit/Sources`, `App/BookBook`, scripts, Makefile): reuse, simplification, efficiency and altitude. Not a bug hunt. Branch `simplify-pass`.

## How it ran
- Seven read-only reviewers: four angles on BBUI (reuse, simplification, efficiency, structure), one each for BBModel/BBStore/BBLayout, BBAI/BBAICore/BBNet/BBOpenAI, and BBExport/app/scripts plus cross-target duplication. About 100 findings.
- Six fix lanes, one git worktree each, with strict file ownership; the main thread merged them and did the cross-lane items.
- `scripts/test.sh all` green on the merged branch. No snapshot or fixture was re-recorded. No live checks, $0.00.

## What changed
- **BBModel / BBStore / BBLayout:** package layout names and the outside-package guard in one place; bundled presets decoded once; one bleed/fold rule (in BBModel); `BookStore.withLock`; one `readAll`; `Typography.applying(TextBoxStyle)` beside the role resolution; `drawFlipped` and one cached-or-fresh layout helper; `SnapTargets.make` without `isSpread`; one pairing helper in `TemplateReassignment`; `Asset` uses the synthesized `encode(to:)`; one schema probe and `book.json` reader; `TextBoxLayout` computes its fixed results once. `GenerationTarget` is now a typealias of `SessionOwner` (same wire format).
- **BBExport / package / config:** `swift-collections` removed (unused); eight dead module markers and their smoke tests deleted; unused test-target dependencies dropped; one page selection for export and preflight (`Preflight.exportedPages`); `ImagePixelSize.of(source:)`; `PrintResolution` owns the print arithmetic; pipeline-only types made internal; per-target xcconfig settings shared between Debug and Release; `scripts/test.sh app` no longer builds twice.
- **BBAI / BBAICore / BBNet / BBOpenAI:** the cost estimate no longer encodes a placeholder mask; one box resolver and section renderer in the assemblers; one structured text request/result type; `PromptTemplates` in its own file with shared helpers (layout and consistency prompt text now pinned by tests); sensitive-term regexes compiled once and only scanned for refusals; unused `Codable` dropped from catalog types; one rate lookup and cost sum on `PriceEntry`; the OpenAI adapter builds error raw only on failure and has one JSON-root parser; `RGBA` hex helpers in BBModel; test-only helpers narrowed to internal.
- **BBUI panels:** `SessionVersionSelection`, `SessionPanelHeader`, `VersionDetailsDisclosure` and the thread bubbles shared by the session and text-style panels; one AI-availability check (`UnavailableText.blocker`, `AppModel.aiBlocker`); shared text-model lookup and ledger write; the generation API gathered in `AppModel+Generation.swift`; `generateRegionEdit` takes the intent the panel already built.
- **BBUI document / canvas:** `BookDocument.swift` split into `+Edits` and `+Commands`; `BookEditor`, `BookSidebar`, `PagesOverviewModel` and `RichTextFormatting` in their own files; one delivery body in `BookMutations.applyDelivery`; canvas box selection lives on `PagesController` (the deferred `Task` is gone); one Typography sheet; the dead second text-box resolver removed; `lastSaveError` written only when it changes; missing fonts refreshed only after edits that can change them; one thumbnail cache entry per page and height; the region editor redraws only the brush ring on hover.
- **BBUI chrome:** `messageAlert` and `isPresent()`; real-person sheets on the shared scaffold; `AssetThumbnail`'s unreachable view-larger path removed; one `ImagePreview` presentation; one duplicate-book action; `BoxInspector` edits through one method; `ExportSheetModel.runJob`; `PageNumbersSheet.content` non-optional; `CostText` without a `NumberFormatter` per call; the installed font family list cached.
- **Makefile:** `build` and `install` share one `xcbuild` macro (left uncommitted with the `make install` change it belongs to).

## Bug fixed on the way
- `PageThumbnailRenderer.Key` left out `page.textStyles`, so choosing or removing an AI text style left a stale sidebar/overview thumbnail (`fix(ui)`, with a test).

## Not applied
Listed under Open follow-ups ▸ Phase 17 in `PROGRESS.md`. Also judged not worth doing or not equivalent: merging `CommitTextEditor` into `CommittedTextField` (adds an accessibility label), sharing the API-key test result view between Settings and onboarding (visible change), `DirtySet` reordering, removing legacy-format acceptance, a per-book reference thumbnail cache for consistency checks, and moving OpenAI specifics out of BBAI before a second provider exists.

## Hand checks
Deferred; listed under Deferred hand checks ▸ Simplify pass in `PROGRESS.md`.
