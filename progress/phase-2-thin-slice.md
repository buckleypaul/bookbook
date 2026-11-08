# Phase 2 — Thin vertical slice (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-2-thin-slice` · PR [#4](https://github.com/buckleypaul/bookbook/pull/4) · live spend **$0.006**.

**Decisions taken at the start (your answers, 2026-11-08):** Generate uses **Standard** quality (OpenAI `medium`); the default body font is **Avenir Next** (`AvenirNext-Regular`, title `AvenirNext-Bold`); a new book starts with **1 story page**.

**Assumptions (plan defaults, easy to overrule):**
- The cover page is created with every book (so `Book.coverPageID` is valid) but isn't shown, edited or exported until Phase 5.
- A new result is placed automatically only when its box is empty; otherwise it joins the version strip and the user clicks it to place it (`ChooseVersion`, undoable).
- Page commands never touch sessions. Deleting a page keeps its session files; undoing an add leaves the new page's empty sessions behind (clean-up is Phase 16).
- TextKit 2 layout, `PageRenderer` and PDF export are `@MainActor` in the slice; Phase 14 revisits background export.

**Live runs:** 2026-11-08 `scripts/live-tests.sh openai slice` → `LiveProviderTests.slice_generateLow` passed (Draft/low 1024×1024), **$0.006** (LiveSpendGuard).

**Built:** shared contracts first (main thread), then five parallel lanes in worktrees:
- **Store** (sonnet): `BookStore`, `Journal`, `Library`, `Presets`, `KeychainStore`.
- **Layout+Export** (opus): `PageGeometry`, `RichTextBridge`, `TextBoxLayout`, `PageRenderer`, `PDFExporter`.
- **Net+OpenAI** (sonnet): HTTP clients, recorder, redaction, `OpenAIImageProvider`, `LiveSpendGuard` in BBTestSupport.
- **AI** (sonnet): `ModelCatalog`, `ContextAssembler` with `Prompts/image-v1/`, `GenerationQueue` v0.
- **UI+app** (opus): `AppModel`, `OpenBooks`, `BookWriter`, Library, book window, `CanvasView` + inline editor, session panel, Settings ▸ API Keys, Export PDF, app wiring.

The main thread wrote the BBModel types, `BookCommand` and `BookDocument` (undo layer, ordered autosave chain, autosave error reporting).

**Deviations / decisions:**
- **Not shown yet:** the cover page exists but isn't shown or exported (Phase 5).
- **Auto-placing:** a new result is placed only into an empty box.
- **Page commands and sessions:** page commands never touch sessions. A result for a deleted page still lands in its session, so undoing the delete shows it.
- **Main actor:** TextKit 2 layout, rendering and export are `@MainActor`.
- **Snapshots:** BBAITests prompt snapshots live in `Tests/BBAISnapshots/`. BBLayoutTests excludes `__Snapshots__`.
- **Throwaway library:** the app accepts a `-BookBookLibraryRoot <path>` launch argument (argument domain only, never saved), used for automated runs.
- **Reopening books at relaunch** stays in Phase 3.

**Docs changed:**
- `architecture.md` §3: BBUI depends on BBAICore.
- §4.1: the top-left origin.
- §4.3: as-built model fields.
- §5.1/§5.2: date format; journal layout, validation and ordering.
- §6.3: primitive edits.
- §6.5: isolation.
- §7.11: masked-key redaction.
- §8.3: the text bridge.
- `CLAUDE.md`: module map.

**Review (fresh opus), all fixed with tests:**
- **Must-fix:**
  - a result for a deleted page was dropped;
  - deliveries could race open/close and be lost. Every delivery now goes through `OpenBooks`, one operation at a time per book, and the debounce timer holds the store strongly.
- **Should-fix:**
  - silent autosave failures;
  - a failed image store dropped the result silently;
  - an untrusted `ImageRef.sha256` / symlinked `images/` could reach outside the package;
  - journal replay order was random;
  - the aspect fit could exceed 3:1.
- **Nits:** undo during IME composition, the CLAUDE.md module map, `@unchecked Sendable` in the live test, and live spend not logged without usage.
- **Earlier security finding:** journal manifest path traversal, fixed.

**Checked by the agents in the running app** (throwaway library):
- 1 (New Book opens its own window on page 1);
- 2 (misspellings underlined; ⌘Z/⇧⌘Z; no undo-manager mismatch, no TextKit 1 switch);
- 5 without an image (AvenirNext subset embedded, text present);
- 6 (text persists; package layout; no `sk-` in the package or defaults; the Saved Application State folder doesn't exist on macOS 27, see SL-3);
- the Settings key flow with a dummy value;
- Generate disabled without a key;
- page add/delete undo;
- close flushes.

**Hand checks:**
- [x] 1. New Book "Test" opens in its own window with page 1.
- [x] 2. Typing; misspellings underlined; ⌘Z undoes typing.
- [x] 3. Settings ▸ API Keys: save your OpenAI key; it's in Keychain Access, not in the book.
- [x] 4. Generate "a fox in a red scarf at a castle gate, watercolour": the image fills the box within ~2 min (aspect-fill).
- [x] 5. Export PDF: image + selectable text; Preview ▸ Inspector shows embedded fonts.
- [x] 6. Quit/relaunch/reopen: text, image, placement persist; package contents; no `sk-` anywhere.
- [x] 7. Wi-Fi off → Generate shows "Offline"; editing still works.

**Follow-ups:**
- **Phase 3:**
  - reopen books at relaunch;
  - `.lock`;
  - image sweep;
  - thumbnails;
  - the library index.
  - A failed generation's error lives only in the in-memory queue, so after relaunch the message shows no error. Persist it with the queue in Phase 9.
- **Phase 4:**
  - coalesce typing undo (today each keystroke is one undo step);
  - the overflow badge;
  - title-role typography;
  - a missing-font warning;
  - cache `TextBoxLayout` (it's rebuilt every draw).
- **Phase 5:** cover editing/export and page numbers.
- **Phase 8:**
  - edits/references/masks in the OpenAI adapter;
  - separate "inspect" from "place" in the version strip.
- **Phase 9:**
  - retries and `Retry-After`;
  - the queue window (`QueueView` is still the stub);
  - queue persistence;
  - check the transient mapping of `HTTPClientError.transport`;
  - unclassified 403s map to `.unknown`.
- **Later:**
  - the canvas loads images synchronously on the main thread (move to an actor `ThumbnailCache`);
  - calm-area guidance only for overlapping text boxes, not adjacent ones;
  - a test that every prompt template key exists;
  - export off the main actor (Phase 14);
  - versions dropped as invalid on load can leave dangling placements, which resolve to nil.
- **Hand check 6 wording:** it should name where macOS 27 keeps saved state, since the `Saved Application State` path doesn't exist.

