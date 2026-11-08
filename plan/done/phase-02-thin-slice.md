# Phase 2 — Thin vertical slice (L) · **M1**

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** open a book → type text on a page → generate one image with OpenAI → place it → export a PDF. Every layer exists in a thin form, on its real architecture.

**Scope**
- `BBModel`: `Book`, `StyleGuide` (visual description, page setup for a fixed Letter portrait, no bleed), `Template`/`Box` (one built-in "image on top, text below" preset), `Page`, `ImageSlot`, `ImagePlacement`, `Session`, `Message`, `Version`, `Provenance`, and a plain-paragraph `RichText`. (A §4.1–4.3)
- `BBStore`: the package layout (A §5.1), content-addressed images, the transaction journal (A §5.2, P-2), 1 s debounced autosave (A §5.3), and a minimal library: a folder scan plus create.
- `BBLayout`: `PageGeometry` (no bleed), `TextBoxLayout` on TextKit 2, and `PageRenderer` for `.screen` and `.pdf(trim)` (A §8.2–8.4).
- `BBNet`: `HTTPClient` protocol, the URLSession client (A §7.12), `FixtureHTTPClient`, and the recorder moved over from `Spikes/`.
- `BBAICore`/`BBAI`: `ImageProvider`, `ImageRequest`/`ImageResult`, a minimal `ContextAssembler` (role, style text, avoid, composition aspect, story text, request), aspect fitting for free-size models (A §7.5), a `ModelCatalog` loader, and the `GenerationQueue` v0 (P-4).
- `BBOpenAI`: `/images/generations` only, with basic error mapping (invalid key, refusal, transient).
- `BBUI` and the app: a Library window ("New Book", a list of books), a book window with a page list of N pages using the one template, `CanvasView` showing the page, an NSTextView overlay for the text box, a minimal session panel (prompt field, Generate, a spinner with elapsed time, the latest version shown), continuous spelling and grammar checking turned on in the text overlay (SL-2), a Settings tab for the OpenAI key (`SecureField`, Keychain only, A §5.5 and §2.2), **File ▸ Export PDF…** (Standard), the `BookCommand` layer with undo for `SetRichText` (not coalesced yet), `ChooseVersion` and add/delete page (P-3), and a minimal `BookWriter` for open books.

**Deliverables:** the slice described above, plus the `Provenance` record for each generation (the exact prompt sent, model, quality, size, and usage when reported). The ledger isn't built until Phase 9.

**Acceptance (by hand)**
1. Launch, choose New Book "Test", and it opens in its own window with page 1.
2. Click the text box and type two sentences. Misspellings are underlined. ⌘Z undoes the typing.
3. Settings ▸ API Keys: paste your OpenAI key and save it. (It's stored in the app's own Keychain item; check in Keychain Access that it's there and not in the book folder.)
4. Click the image box, type "a fox in a red scarf at a castle gate, watercolour", and press Generate. Within about 2 minutes the image fills the box, cropped to aspect-fill.
5. Export PDF. In Preview, the page shows the image and the text. The text is selectable, and Preview ▸ Inspector shows embedded fonts.
6. Quit, relaunch and reopen "Test": the text, image and placement are all still there. Open the package in Finder (Show Package Contents): `book.json`, `pages/`, `sessions/` and `images/<sha256>.png` are there. No key appears anywhere: `grep -r "sk-" Test.bookbook`, `defaults read app.bookbook.BookBook | grep sk-` and `grep -r "sk-" ~/Library/Saved\ Application\ State/app.bookbook.BookBook.savedState` all find nothing.
7. Turn off Wi-Fi and press Generate: you get a plain-language "Offline" error. Editing text still works.

**Tests added:** Codable round-trips for every type. Journal roll-forward and discard (basic). `PageGeometry`. A `TextBoxLayout` overflow test. A rendered-page snapshot (PNG). A PDF test: parse it, check the text is there and fonts are embedded. A `ContextAssembler` prompt snapshot. Aspect fitting for the OpenAI catalog entries. OpenAI adapter tests against the Phase 0 fixtures (success, refusal, 401). One live test, `LiveProviderTests.slice_generateLow` (about $0.01).

**Risks:** TextKit 2 overlay quirks (reduced by SL-2). The model types in `BBModel` will churn as later phases land; keep the schema at version 1 until Phase 3 and allow breaking changes until then.
