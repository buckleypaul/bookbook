# Phase 5 — Pages tab, ordering and cover (L)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** lay out a whole book: spreads in reading order, a cover, and story text brought in from a file.

**Scope:** A §8.1 `PageSequencer`, §4.4 status, §10 (cover row). PD §8.5 (except "Draft all", which is Phase 9), §8.7, §8.2 page numbers, §8.10 (page commands). Modules: `BBLayout` (sequencer, page numbers), `BBModel`, `BBUI` (overview). **Depends on Phase 4**, for RTF formatting in story import and the title font on the cover.

**Deliverables**
- Spread overview: the cover alone, then page 1 on the right, in facing pairs.
- Add, insert, duplicate, delete, and drag-and-drop reorder. A spread-split warning with the "insert blank page" variant.
- Choose or change a page's template, with text and images reassigned to the new boxes.
- All built-in single and spread presets from PD §8.4 (as data, in `TemplatePresets.json`).
- Status badges: empty, in progress, done.
- Page numbers: position, font, start, skip rules.
- Story-text import: paste, `.txt` or `.rtf`; split at blank lines or a marker; a preview; into a new or existing book; one undo step.
- The cover page with title and author `BoxRole`s bound to the book's title and author, plus a minimal Book Settings sheet for those two fields.
- Double-click to open the page editor.

**Acceptance (by hand)**
- Import a 12-paragraph story from an `.rtf` with `---` markers. The preview shows 12 pages, and choosing Import creates them. ⌘Z removes all 12 at once.
- Drag a spread-template page to an odd position: a warning appears with "Insert blank page", and choosing it keeps the spread intact.
- Change a page from "image on top" to "text left / image right": the text and image move into the new boxes.
- Set the title in Book Settings: the cover updates. Page numbers appear in the PDF, skipping the cover and the dedication page.

**Tests added:** `PageSequencer` cases (split detection, blank insertion, every reorder combination for n ≤ 8). Story splitting (blank lines, markers, CRLF, RTF formatting kept). Template reassignment mapping. Page-number skip rules. Status derivation.

**Risks:** drag-and-drop in SwiftUI grids over facing-page pairs (fall back to an AppKit collection view if SwiftUI fights it).
