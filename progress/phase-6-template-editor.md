# Phase 6 — Template editor (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-6-template-editor` · no PR (merged into main directly) · live spend **$0.00**.

**Hand checks (user, 2026-11-08):** all passed.
- [x] Make a spread with an image across both pages and a cream rounded text panel. Snap guides appear while dragging. Undo each step.
- [x] Apply it to two pages: both update when you move the panel in the editor.
- [x] Rotate an image box by 5°: the page canvas and the PDF both show it rotated, with the image clipped correctly.


- Contracts (main thread): `TextBoxStyle` overrides (`fontSize`, `alignment`, `color`); `BookCommand.addTemplate/updateTemplate(_, actionName:)/deleteTemplate`; `BookDocument.beginUndoGroup()/endUndoGroup(actionName:)`; `BookContent.pages(using:)`; `BBLayout/TemplateEditing.swift` (trim/normalized conversion, per-page safe areas, rotated hit-testing and handles, snapping, align/distribute).
- Wave 1 (parallel): L1 model/commands/store (sonnet); L2 BBLayout geometry + renderer overrides + sample preview (sonnet).
- Wave 2 (parallel, after wave 1): L3 canvas split + layout editing controller (opus); L4 Layouts tab UI (sonnet).
- **Session A done (2026-11-08):** all four lanes merged (L1 `e8ea78c`, L2 `7e4a23a`, L3 `879ec5d`, L4 `fbc5b66`); `scripts/test.sh all` green. architecture.md §4.2, §6.2, §6.3 updated (as built).
- **For Session B:** nothing has been run in the GUI yet: the Layouts tab, `TemplateCanvas` and box inspector need a full hand-check pass. Watch: L4 assumed the undo manager's `groupsByEvent = false` in tests; check that one drag is one undo step in the real app (where `groupsByEvent` is true). Selecting a bundled preset in the list copies it into the book as an "Add Layout" undo step (consider copying on first edit instead). Colour wells/steppers group edits with a 0.6 s timer (`updateContinuously`).
- **Lane open issues (candidates for follow-ups):** no snapping during ⇧ aspect-locked corner resize; handles only for a single selection (no multi-box resize); `PageRenderer`'s built-in guides draw one safe area across a spread (the editor overdraws per-page areas; the page canvas still shows the single one); the in-place text editor isn't rotated for rotated text boxes; a page restored by undoing its deletion lacks slots for image boxes added to its template since (Phase 8 should create slots lazily); `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` failed once (flaky).
- Assumptions: snap "guides" are fixed guides (margins, trim edges, page centres, fold) plus other boxes; no user-placed guides. A template's kind can't change after creation. Editing a bundled preset copies it into the book first (same ID); since Session B the copy happens on the first edit, not on selection.
- **Session B (2026-11-08):** gate green (`scripts/test.sh all`, 215 kit tests, no warnings). Two fix rounds:
  - Round 1: undo/redo during an open undo group (inspector 0.6 s burst or drag) corrupted history; the group now registers its one undo step at its first edit, and mouse-up always closes a drag's group. Hit-testing now follows draw order (text boxes before image boxes, A §8). Selecting a bundled preset no longer copies it (copy on first edit, in that edit's undo step; Delete disabled on an uncopied preset). Return commits inspector number fields.
  - Round 2: ⌘Z mid-drag no longer lets the drag continue (interaction token); the replay handler is per group (throwaway `TemplateEditorModel`s from body re-evaluation are harmless); `endUndoGroup` no longer adds an empty undo step (colour change needed two undos); inspector labels no longer wrap or duplicate; `CommitField` keeps half-typed text.
  - Agent-driven hand checks: Layouts tab, delete-blocked with where-used, spread with full-bleed image + cream rounded panel, fold, snap guides, one drag = one undo, overrides (size, alignment, panel), rotate/layer/align/distribute, two pages updating live, 5° rotation on the page canvas all passed. Not verified by agents: a changed text colour, and image clipping of a rotated image box in the PDF (no image could be placed without an API call; a rotated panel exported correctly).
  - `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` failed once again (EINVAL writing `.journal/staged`), passed on re-run; logged as a follow-up.

