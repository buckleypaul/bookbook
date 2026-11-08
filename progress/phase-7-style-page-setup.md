# Phase 7 — Style guide and page setup (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-7-style-page-setup` · no PR (merged into main directly) · live spend **$0.00**.

**Hand checks (user, 2026-11-08):** all passed.
- [x] Change Letter to 8×8 in: boxes keep their relative positions, and the images whose box shape changed show "layout changed". Mark one as OK and its flag clears.
- [x] Edit the visual description: placed images show "style changed". Typography edits don't trigger it.
- [x] Turn bleed on: full-bleed boxes grow into the bleed, and the trim and safe-area lines show in both editors.

**Follow-ups filed:** see PROGRESS.md "Open follow-ups" (Phase 8 and Later, tagged "from Phase 7"). The title-box bold check moved to Phase 16 (Book Settings owns the title font).

Started 2026-11-08. Session A done 2026-11-08; `scripts/test.sh all` green at the end of A.

**Lanes (all merged into `phase-7-style-page-setup`):**
- Contracts (main thread): `PageSizePreset`, `Orientation.square`, `PageSetup.sizePreset` + `applying(preset:orientation:customSize:)`, `StyleVisual`/`StyleGuide.applying(_:)`, `ImageFlags` + `BookContent.imageFlags`, `BookCommand.setStyleVisual/.setPageSetup/.markFlagsOK`, `StylePreset` + `Presets.stylePresets()`.
- L1 model + commands (sonnet): presets and sizes, `PageSetup` decoder (missing `sizePreset` → `.usLetter` for 612×792, else `.custom`), revision bump, flag derivation, bleed/spread/fold-aware `boxAspect(_:in:)`, the three commands with undo, placing a version clears `acknowledged.boxAspect`; 8 text-only style presets.
- L2 UI (sonnet): Style tab (sidebar `.style`, now icon-only tabs to fit the minimum window width), preset picker, description, reference images (stored via `store.storeImage`), negative guidance, Typography sheet button, `PageSetupForm` (one uniform margin field), flag icons on thumbnails and page list, "Mark Images as OK" context menu, `ImageFlagsRow` with Mark as OK above the page editor's session panel.
- L3 canvas (opus): page canvas shows the bleed area; shared `PageRenderer.drawGuides` (trim line with bleed on, safe area per page half, box outlines) in both editors; fold rule; rotation about the render rect's centre everywhere; 8 new snapshots (`PageSetupSnapshotTests`), geometry tests. No existing snapshots re-recorded.
- L4 follow-ups (sonnet): template-editor undo grouping (burst closed before drags/one-shots, token `endInteraction`), layer-order controls disabled when they'd have no visible effect, Page Numbers skipped count and bold-face keep, Typography form fixes.

**Decisions (logged in architecture.md §4.4, §8.2):** style-changed formula is `max(provenance.styleRevision, acknowledged.styleRevision) < visualRevision` (the A §4.4 wording was inverted); imported versions never get style changed; undo of a style edit restores the revision exactly; placements aren't rewritten on page-setup change (focal point/zoom re-clamped at draw, so reverting restores the crop); fold rule; rotation centre.

**For Session B:** no live checks. Hand checks need a book with placed images (use fixture/imported images; imported versions have no provenance, so "style changed" needs a generated version — check what the hand-check driver can do offline, or note it for the user). Check undo for every Style-tab and page-setup field. Style references are stored but not sent to the provider yet (Phase 8 follow-up) — confirm Version details doesn't claim otherwise.

**Session B (2026-11-08):** `scripts/test.sh all` green; secret scan clean; no live checks ($0.00).
- Review round 1 (`a1ba052`): `visualRevision` is now monotonic through `StyleGuide.visualRevisionHighWater` (tolerant decode, defaults to `visualRevision`; A §4.1/§4.4 updated). Undo restores the fields and the revision but never lowers the high-water mark. `.chooseVersion` of the placed version is a no-op. The Style tab text editors follow model changes, so ⌘Z isn't reversed on blur. Re-review: no must-fix.
- Hand-check round 2 (`d7a12b8`): `CommitField` (margins, bleed, custom size, box inspector) shows the committed value and ends editing on Return, so Edit > Undo works. Confirmed in the app.
- Driven hand checks (placed versions written into a throwaway package's JSON, because there is no image import UI yet): checks 1–3 passed; undo passed for every Style/page-setup field; Version details doesn't claim references are sent. The title-box B follow-up wasn't reachable (the box opens Book Settings; B is disabled), so it stays open.
