# Phase 8 — Sessions and versions (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-8-sessions-versions` · no PR (merged into main directly) · live spend **$0.02** (`SP8_refinementLowQuality`).

**Hand checks (user, 2026-11-08):** all passed.
- [x] On a page with two image boxes, generate in each. The two chats and version strips are independent.
- [x] Refine v1 three times (v2–v4), then select v1 and refine again. A new v5 appears, v2–v4 remain, and Version details for v5 shows only the v1 lineage in its prompt.
- [x] Drag in a scanned drawing and refine it ("make the sky blue").
- [x] Reset with "keep versions": the chat clears and the versions remain.
- [x] Pan and zoom the crop, undo it, then export: the PDF crop matches the screen.
- [x] On a spread whose image crosses the fold, the prompt in Details contains the fold instruction.

**Follow-ups filed:** see PROGRESS.md "Open follow-ups" (Later, tagged "from Phase 8").

**Decisions (2026-11-08, asked):** clicking a version places it (undoable `chooseVersion`) and makes it the panel's selected version, which is the base for Details and refining; this closes the Phase 2 "separate inspect from place" follow-up as "keep combined" (PD §8.6 as written). Starring and deleting a version are not undoable; delete asks for confirmation, and deleting the placed version empties the box.

**Contracts (main thread):** `BBModel/Session+Lineage.swift` (`visibleMessages`, `lineage(of:)`, `lineageInstructions(of:)`, `versionNumber`, `BookContent.session(containing:)`); `ImagePayload.pixelSize`; `GenerationHost.imageData(for:in:)` (implemented by `BookWriter`, with a nil default for fakes).

**Lanes:** L1 BBAI assembly and queue (sonnet); L2 OpenAI `/images/edits` (sonnet); L3 session panel, strip, details, import, normalizer (sonnet); L4 crop command and canvas, canvas drop, BookDocument follow-ups (opus).

**Session A result (all lanes merged; `swift test --parallel` and `scripts/test.sh app` green):**
- L1: `ContextAssembler.plan(...)` lists the images needed; the queue loads them through `host.imageData`; then `assemble(...)` (now `throws(AssemblyError)`). The base image comes first, then style references (closes the Phase 7 follow-up), then attached references, within the model's limits; the overflow goes to `referencesOmitted`. Fold, safe-area, history (the lineage only) and legend prompt sections are new resource files in `Prompts/image-v1/`. Refinements send the base version's size. The session is resolved by message ID.
- L2: OpenAI `/images/edits` multipart (`image[]` with the base first, explicit `size`, a 16-image cap, a 50 MB pre-check, HEIC rejected). A golden multipart body test. Live test `SP8_refinementLowQuality` (about $0.02, **not run yet**).
- L3: session panel (thread with "refined version N" tags, quality picker, Include story text toggle, Reset Session… with keep/discard), `VersionStrip` (star, delete with confirmation, Export Image…), Version details (version, refined-from, cost "—", Regenerate with Same Settings), `BBStore/ImageImportNormalizer` (EXIF → pixels, HEIC/TIFF → PNG), `BookDocument.importImage(from:page:box:)`, panel drop and Choose Image…. Delivery resolves by message ID.
- L4: `setCrop` plus canvas pan/zoom gestures, canvas image drop (main thread wired it to `importImage` in BookWindow), session owner rewrite on slot moves, lazy slots on undoing a page delete, and targeted undo for `setPageDone`/`setPageTemplate`. architecture.md §6.3 updated.
- Phase 8 follow-ups closed: style references in requests; lazy slots; moved-slot owners; whole-page undo snapshots; edits/references in the adapter (masks stay with Phase 11); "separate inspect from place" (decided: keep combined).

**For Session B:** run the live check `scripts/live-tests.sh openai SP8_refinementLowQuality` (budget about $0.02). Hand checks need a two-image-box template and a spread. Check the trackpad feel (two-finger scroll over the selected placed image zooms rather than pans) and the canvas drop by hand. Lane notes for the review: the safe area uses `box.bleedEdges` without checking that the box reaches the trim; refining a version whose base was deleted fails with `baseVersionGone` (the UI could prevent this); deleting a mid-lineage version leaves its children's `parent` dangling, so their lineage stops at the gap; the selected version is panel `@State`, reset by `.id(box)`.

**Session B (2026-11-08):** `scripts/test.sh all` green before and after fixes; secret scan clean; no compiler warnings. Live check `SP8_refinementLowQuality` passed ($0.020: generate $0.006 + edit $0.014; confirms `/images/edits` accepts `moderation: auto`). Review must-fixes fixed (merged from `phase-8-fixes`, re-review clean): refinement edit `size` is now snapped to the model's catalog limits via new `AspectFitter.snap` (imported scans/photos sent raw sizes → 400); `ContextAssembler.resolve` now finds the page/box through the slot holding the message's session (a slot moved to a new box ID while queued failed as `.unknown`); duplicate Cost row removed. Should-fix items went to Open follow-ups → Later. Automated hand checks (no in-app key, local PNGs): two boxes have independent sessions/strips; Reset → Keep Versions keeps versions (epoch bumps); crop pan/zoom, undo and PDF crop match; star, Export Image…, delete with confirmation work. Not checked automatically: generate/refine and the v1 lineage in Details, refining a dropped drawing (Finder drag, HEIC/EXIF), the fold instruction in Details, trackpad feel.
