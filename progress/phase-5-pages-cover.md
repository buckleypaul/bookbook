# Phase 5 — Pages tab, ordering and cover (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-5-pages-cover` · no PR (merged into main directly) · live spend **$0.00**.

**Hand checks (user, 2026-11-08):** all passed.
- [x] Import a 12-paragraph `.rtf` story with `---` markers: preview shows 12 pages, Import creates them, one ⌘Z removes all 12.
- [x] Drag a spread-template page to an odd position: warning with "Insert blank page" keeps the spread intact.
- [x] Change "image on top" to "text left / image right": text and image move into the new boxes.
- [x] Set the title in Book Settings: the cover updates. PDF page numbers skip the cover and dedication.


**Contracts** (commit `feat(phase-5): contracts`): `PageNumberStyle` (position, font, size, colour, start, skip front matter, skipped pages; tolerant decoding), `PageNumberPosition`, `PageRole` + `Template.pageRole`, `TemplateReassignment` (BBModel); `PageSequencer`/`SequenceLayout`/`Opening`, `PageNumbering`, `StoryTextImporter`, `RenderOptions.pageNumbers`/`PageNumberMark` (BBLayout); `Presets` IDs 0003–000A; new `BookCommand` cases (`duplicatePage`, `reorderPages`, `setPageTemplate`, `importStoryText`, `setPageDone`, `setPageNumberStyle`, `fixSplits` on structural commands); `BookDocument.wouldSplitSpread(_:)`, `setAuthor(_:)`.

**Lanes:** wave 1: L1 model/layout logic + tests, L2 presets JSON, L4 renderer/export (page numbers, cover). Wave 2: L3 BookDocument commands, L5 UI (overview, story import, Book Settings, page numbers sheet).

**Assumptions (plan defaults, overrule if wrong):**
- Page numbers are positional: position `p` shows `start + p − 1`; skipped pages keep their number but don't draw it. The cover is never numbered.
- A split spread is fixed by inserting one text-only blank page right before it.
- Template change: role-matched boxes first, then reading order; leftover text is appended to the last text box, leftover images are dropped from the page (sessions kept).
- Presets missing from an older book are copied in when a command first uses them.
- Book Settings title uses the existing `rename(to:)`; author is set the same way (not undoable; PD §8.10 doesn't list them).
- Page-number settings live in a sheet from the Pages overview until the Style tab (Phase 7).

**Session A result (all lanes merged, package + app build warning-free, `swift test` green):**
- L1 `PageSequencer` (cover is opening 0, on the right), `PageNumbering`, `StoryTextImporter`, `TemplateReassignment` (only boxes that have content take part) + exhaustive n ≤ 8 tests.
- L2 presets 0003–000A, an author box on the Cover, `Presets.template(_:)` public, `textOnlyTemplate()`.
- L3 page commands as single undo steps (`compound` edit); `wouldSplitSpread` simulates on a copy. **Deviation:** copying a preset into an older book is irreversible (DirtySet can't delete template files); undo removes the pages, the unused template stays.
- L4 renderer page numbers (slot box or margin band) and bound title/author; the cover is the first PDF page; the library thumbnail uses the cover.
- L5 Overview/Editor modes (toolbar segmented control, ⌥⌘1/⌥⌘2), Cover row in the sidebar, Page menu, drag-drop reorder (SwiftUI, no AppKit fallback), split-warning alert, story import, Book Settings, Page Numbers sheets.
- Integration: `PageNumberMarks` helper drives PDF and on-screen numbers (positional: the dedication keeps its number, so story pages after it start at 2); the canvas draws spreads at double width with a fold; title/author boxes aren't text-editable (double-click opens Book Settings).

**For Session B:**
- **Fix first:** PDF export draws a spread-template page squashed into one page box; export it as two PDF pages (one per half).
- Nothing is hand-checked yet: drag-drop vs double-click on thumbnails, the split alert, story import from `.rtf`, Book Settings.
- Commit `bbec99e` doesn't build on its own (the next commit fixes it); harmless.

**Session B result:**
- Gate: `scripts/test.sh all` green (all stages), no Swift warnings; secret scan clean. No live checks, $0.00.
- Fixes merged: spread pages export as two trim-size PDF pages with their own numbers (`PDFExporter`, new `PageRenderer.draw(…visibleRect:)` overload); the Page Numbers sheet stores PostScript names (family picker); body text never goes into bound `.title`/`.author` boxes; **New Book from Story…** (library toolbar, empty library, File menu): creates a book and opens the story-import sheet. The first review flagged the last one as a missing spec deliverable ("into a new or existing book").
- Re-review of the fixes: no must-fix. Should-fix items are in Open follow-ups.
- Agent-driven hand checks: story import (12 pages, one ⌘Z), Book Settings → cover, PDF numbers (cover and dedication unnumbered, spreads as two pages), double-click opens the editor, New Book from Story, page-number font all passed. Not machine-verifiable: drag-drop reorder (synthetic drags never land; the split alert and Insert Blank Page were checked via Change Layout), image moving on a template change (no image placed). The title-box bold check moved to Phase 7 (bound boxes aren't editable).
- Docs: no architecture changes (A already describes spread halves as clip + offset).
