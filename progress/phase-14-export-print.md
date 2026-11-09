# Phase 14 — Export and print

**Stage:** done (hand checks deferred), merged 2026-11-08


- Started 2026-11-08. Follow-ups picked up: consistency-warning preflight item; export off the main actor.
- Contracts (main thread): `BBExport/ExportContracts.swift` (options, results, booklet imposition formula, crop marks, image prep, preflight, `ImagePreparing`), `BBLayout/Contracts.swift` (`BoxImageKey`, `PreparedImageSource`, `RenderOptions.Target.pdfBleed/.print`), with compiling stubs per lane.
- Decision: page drawing stays on the main actor (TextKit 2), one page per step with suspensions; image preparation runs off it in the `ExportImagePreparer` actor. Written into A §9.1.
- Lanes: **images** (sonnet: upscaler, planner, preparer, cache); **preflight** (sonnet); **pipeline** (opus: renderer prepared images, booklet/marks, `BookExporter`, PDF boxes, bitmaps); **ui** (sonnet: export sheet, preflight list, Print ⌘P, page-as-image, menus; owns `BookDocument` this phase).
- Session A done 2026-11-08: all four lanes merged; `scripts/test.sh all` green, no warnings, no stubs left.
  - images: `CoreImageUpscaler`, `ImagePixelSize` (EXIF-aware), `ImagePreparationPlanner`, `ExportImagePreparer` (one source in memory at a time; cache `<hash>-<w>x<h>.jpg|png`).
  - preflight: `Preflight.run` + `SystemSpellingChecker`; cover text included; each missing font reported once per book (first page needing it).
  - pipeline: `PageRenderer.prepared`, `.pdfBleed`/`.print`, booklet layout + crop marks, `BookExporter` (standard / print shop with TrimBox+BleedBox / booklet, cover-only PDF, 300 DPI PNG/JPEG, progress, cancel, temp-file write). `PDFExporter` kept as a sync wrapper over shared `OutputPageDrawing`. Booklet blanks go at the end. Print-shop spread halves show the facing half in the fold-side bleed. Added a `__Snapshots__` exclude to BBExportTests in `Package.swift`.
  - ui: `BBUI/Export/` (`ExportSheetModel`, `ExportSheet`, `LiveExportServices`); File ▸ Export… (⇧⌘E), Export Page as Image…, Print… (⌘P = direct Standard print); the sheet's Print… uses the chosen options. Turn On Bleed uses `.setPageSetup` (undoable). Old `PDFExportAction` removed (`StatusTextTests` updated).
  - For Session B: the UI was only tested against fakes during Session A; the hand-check pass must exercise the real export/print/preview paths end to end. No live checks in this phase.

**Session B (2026-11-08):**
- `scripts/test.sh all` green at `f4dc634` (all seven steps, no compiler warnings). The first run hit the known flake `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` (EINVAL on `.journal/<id>/staged`); it passed on re-run and in the next three full runs.
- App pass (real export/print paths, throwaway library, no provider calls). Confirmed: Letter booklet of a 10-page 5.5×8.5 in book (cover excluded) says 2 blanks and "flip on short edge", sheet sides impose correctly; print-shop PDF has TrimBox 27,27 396×612 / BleedBox 18,18 414×630 and crop marks; bleed-off print shop offers Turn On Bleed; a 512 px image across a full page is listed soft ("332 px available; needs 1650 px") and Preview Upscaled shows the 1650×2550 image; ⌘P opens the standard print dialog; PNG/JPEG page export at 300 DPI; preflight groups and Export Anyway; cover and range options. Not reached: spreads option (no spread in the test book), progress/cancel (exports finished in under 3 s).
- Review fixes, round 1: booklet story pages now keep `PageSequencer`'s side (inside-front-cover blank when the cover is included, a leading blank for an even-starting range; all blanks counted); stacked landscape booklets say "flip on short edge" (long edge put the wrong page behind each slot); gray/CMYK sources render into sRGB (export used to abort). The UI's predicted blank count includes the leading blank.
- Round 2: the shared `PageRangeWidening.selected` helper makes the predicted blank count match the exporter when a range cuts a spread; `flattened` uses `renderingColorSpace(for:)`. The re-review was clean.
- Docs: architecture.md §9.3 (cover/parity blank rule; flip instruction).
- Booklet snapshots re-recorded (three moved to a 6-page book so they show content).
- Live spend: $0.00 (no live checks listed).
