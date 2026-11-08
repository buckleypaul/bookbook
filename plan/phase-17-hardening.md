# Phase 17 — Hardening and v1.0 (M) · **M5**

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** confidence for real household use.

**Deliverables**
- XCUITest smoke suite (A §12): open the sample, edit text, undo, export a PDF.
- Performance pass on a 40-page book with 150 versions (open time, scrolling the overview, export time).
- Accessibility basics: VoiceOver labels in the sidebar, panel and queue; keyboard navigation.
- Catalog and price-list refresh, with a live list-models check.
- Final live pass through every provider capability.
- Schema v1 frozen, with a migration fixture committed.
- README and user notes.
- Release `v1.0.0` through Phase 15.

**Acceptance (by hand):** make a complete 16-page book for your household from the wizard to a printed booklet, with no blocking bugs. The UI smoke suite is green in CI. `v1.0.0` installs through the tap.

**Risks:** scope creep from household feedback (log it, and triage into v1.x unless it blocks).
