# Phase 11 — Region editing (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** change only part of an image.

**Scope:** A §6.2 region editor, §7.6 region editing (mask polarity from SP-4, local compositing). PD §8.6 region editing. Modules: `BBUI` (overlay), `BBAI`/`BBOpenAI` (mask payload), Core Image compositing in `BBAI` or `BBExport` (plan decision: a small `ImageOps` helper in `BBAI`). **Depends on Phase 9**, for the model picker and catalog capabilities in Settings.

**Deliverables**
- Brush and lasso tools at the version's pixel size, with brush-size control, erase and invert.
- Mask PNG with the polarity found by SP-4.
- Local feathered composite (feather width from SP-4).
- A `.regionEdit` version, with the raw provider output kept for Details.
- The tool is disabled, with an explanation, for models without `supportsMask`.

**Acceptance (by hand)**
- Brush over Pip's scarf and ask for "make the scarf yellow". Only the scarf changes. Flip between the old and new versions: pixels outside the mask are identical.
- Lasso the sky and replace it. The edge is feathered with no hard seam.
- Switch the model to a Gemini entry in Settings (the catalog row is enough, even before Phase 13): the region tool is greyed out with an explanation.

**Tests added:** mask rasterisation (brush and lasso to a bitmap), polarity encoding, the composite leaving outside pixels unchanged (exact equality away from the feather band), and feather width. Phase-end live check: one masked edit.

**Risks:** large images make the overlay slow (draw the mask at screen resolution and rasterise at full size on commit).
