# Phase 7 — Style guide and page setup (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** set the book's look and print geometry, and see what is out of date after a change.

**Scope:** A §4.1 revisions, §4.4 flags, §8.2 bleed and safe area. PD §8.2 in full (presets without sample images; those come in Phase 16), §8.5 flags and **Mark as OK**. Modules: `BBModel`, `BBLayout`, `BBUI`.

**Deliverables**
- Style tab: preset picker (text-only presets), visual description, style reference images, negative guidance pre-filled.
- Page setup: every size preset and custom size, orientation, margins.
- Bleed on/off with an amount. Trim line and safe-area overlays in both editors.
- Page-setup change handling: frames are kept normalized and focal points re-clamped.
- `visualRevision` bumps. **Style changed** and **layout changed** flags on thumbnails. Mark as OK.
- Undo for every field edit.

**Acceptance (by hand)**
- Change Letter to 8×8 in: boxes keep their relative positions, and the images whose box shape changed show "layout changed". Mark one as OK and its flag clears.
- Edit the visual description: placed images show "style changed". Typography edits don't trigger it.
- Turn bleed on: full-bleed boxes grow into the bleed, and the trim and safe-area lines show in both editors.

**Tests added:** flag derivation tables (A §4.4), focal-point clamping across size changes, render-rect bleed expansion, and revision bump rules.

**Risks:** the edge cases in "crops are kept where possible" (cover them with snapshot tests on extreme aspect changes).
