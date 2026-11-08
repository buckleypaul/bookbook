# Phase 12 — Consistency check and AI templates (M) · completes **M3**

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** catch drift automatically and fix it in one click, and turn layout descriptions into templates.

**Scope:** A §7.7, §7.8. PD §8.9, §8.4 AI generation. Modules: `BBAI` (`VisionProvider`, `LayoutProvider`, `TemplateDraft` validation and normalization), `BBOpenAI`, `BBUI`.

**Deliverables**
- Consistency follow-up queue items that jump the queue and are included in the parent's estimate.
- Warning badge using the catalog thresholds, a difference list, dismiss, one-click fix (estimate first, `.consistencyFix`), on-demand check for any version, and the global switch in Settings.
- Consistency warning flag on thumbnails, plus its preflight item if Phase 14 has already merged.
- Settings: default provider and model for **templates** and for the **consistency check**. PD §8.11 lists these separately from images.
- AI template generation from a description, with presets as few-shot examples, normalization (clamp, snap, bleed edges, degenerate boxes), opening in the editor.
- Refusals go through the normal error path.

**Acceptance (by hand)**
- Generate a page with Pip, deliberately asking for "a blue scarf" (his reference is red). A warning badge appears with "scarf is blue; reference is red". One-click fix shows its estimate, then produces a version with a red scarf.
- Turn the switch off: estimates drop, and no follow-ups are queued.
- Describe "big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box": a sensible template opens in the editor, snapped to the margins.

**Tests added:** schema validation and normalization (fuzzed bad drafts), badge thresholds, correction-prompt composition, queue jump ordering, and estimates including follow-ups. Adapter tests from the SP-7 fixtures. Phase-end live pass: one check and one template.

**Risks:** false positives in the vision check (thresholds are catalog data; keep warnings advisory).
