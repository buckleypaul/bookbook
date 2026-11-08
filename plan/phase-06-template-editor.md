# Phase 6 — Template editor (L)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** design your own page layouts visually.

**Scope:** A §4.2 `Template`/`Box`, §6.2 canvas editing mode, §8.2 rotation and radius. PD §8.4 (except AI generation, which is Phase 12). Modules: `BBUI` (`CanvasView` edit mode, the Layouts tab), `BBLayout` (hit-testing, snapping). **Depends on Phase 5**, for applying templates to pages and placing spreads.

**Deliverables**
- Layouts tab: the template list, duplicate, delete (blocked while in use, with where-used).
- Visual editor: add image and text boxes, drag, resize, rotate, corner radius, layer order, full-bleed edge toggles, snapping to margins, guides and other boxes, align and distribute.
- Text-box style overrides: size, alignment, colour, background panel.
- Preview with sample text and placeholder art. Fold shown on spreads.
- Every edit undoable, with each drag as one group.
- Editing a template updates the pages that use it live.

**Acceptance (by hand)**
- Make a spread with an image across both pages and a cream rounded text panel. Snap guides appear while dragging. Undo each step.
- Apply it to two pages: both update when you move the panel in the editor.
- Rotate an image box by 5°: the page canvas and the PDF both show it rotated, with the image clipped correctly.

**Tests added:** hit-testing with rotation (inverse transform), snapping maths, align and distribute, normalized-frame conversion for single and spread pages, and an undo group per drag.

**Risks:** `CanvasView` is shared with Phases 4, 7 and 11. Split it early into `CanvasView` plus per-mode controllers (`TextEditingController`, `LayoutEditingController`, `PlacementController`) so lanes don't collide.
