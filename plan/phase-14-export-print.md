# Phase 14 — Export and print, complete (L) · **M4** begins

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** print-ready output for home, booklets and print shops.

**Scope:** A §9 in full, §8.4 RenderOptions (bleed, marks, print), §10. PD §8.8. Modules: `BBExport`, `BBLayout`, `BBUI` (export sheet). **Depends on** Phases 4, 5, 7 and 8 (imported images for the softness check). Preflight items for the asset-changed and consistency flags are added here if Phases 10 and 12 have merged, or by those phases otherwise.

**Deliverables**
- `ExportImagePreparer`: crop, 300 DPI target, Core Image upscaling (`Upscaler` protocol), the softness warning, "Preview upscaled", and the cache.
- Print-shop output: bleed, crop marks, `TrimBox`/`BleedBox`. It requires bleed, and offers to turn it on.
- Booklet imposition on Letter, A4, Tabloid and A3: padding (reporting how many blanks were added), scale-to-fit with a notice, printing instructions, cover as the outer sheet or excluded (exported separately).
- Options: cover, page range, spreads as single pages or double-width pages.
- Preflight sheet with grouped issues linking to pages (empty boxes, overflow, spelling, soft images, flags, consistency, missing fonts), and Export anyway.
- **Print** through `PDFDocument.printOperation`.
- PNG/JPEG export for single pages.
- Export runs in the background with progress and cancel.

**Acceptance (by hand)**
- A 10-page book with a 5.5×8.5 in page size, exported as a Letter booklet: "2 blank pages added", plus instructions. Print it double-sided, fold and staple: the pages read in order.
- Print-shop PDF: Preview shows crop marks, and Acrobat (or `PDFKit` box inspection in a test) shows the TrimBox and BleedBox.
- Place a 512 px image across a full-page box: preflight lists it as "will look soft", and Preview upscaled shows it at 100%.
- ⌘P prints through the standard macOS dialog.

**Tests added:** booklet ordering for n = 4…32 (A §9.3 formula), PDF box attributes, mark geometry, upscaler thresholds, preflight issue detection per type, and snapshot tests of imposed sheets.

**Risks:** printer duplex differences (the instructions are text, so print a test sheet first). Memory use on large books (prepare images in a stream, one page at a time).
