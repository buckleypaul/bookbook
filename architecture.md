# BookBook — Architecture

**Status:** Draft v1.1, reviewed (2026-11-07: decisions in `architecture-decisions.md` accepted; minimum OS raised to macOS 27; toolchain Xcode 27; public repo)
**Date:** 2026-11-07
**Inputs:** `product-description.md` (the source of truth for requirements, cited as §n), `architecture-notes.md` (non-binding suggestions; since removed, see git history), plus research on the current OpenAI, Gemini, macOS and Homebrew documentation, done on 2026-11-07.

> **Gemini is post-MVP (decided 2026-11-08):** v1.0 ships with OpenAI as the only provider. Everything about Gemini in this document describes a later release. It stays here so the design keeps room for a second provider. `BBGemini` and the provider-neutral protocols stay in the design, but no v1.0 phase builds the Gemini adapter (see `implementation-plan.md` §1 and `plan/post-mvp/phase-13-gemini.md`).
**Next document:** `implementation-plan.md`. This document covers *how* BookBook is built. It does not set the order of work.

---

## 0. Key decisions at a glance

| # | Area | Decision | Main alternative rejected |
|---|---|---|---|
| D1 | UI | SwiftUI for app structure, forms, panels and lists. AppKit for the page/template **canvas** and **text editing** (NSTextView on TextKit 2). | Pure SwiftUI. Its `TextEditor` has no layout geometry for overflow and unreliable spell checking. |
| D2 | Book format | A folder package `Name.bookbook/` holding **several small JSON files**, content-addressed image files and embedded fonts. *(Your choice.)* | SQLite, SwiftData |
| D3 | Crash safety | Atomic per-file replacement, plus a **write-ahead staging journal** for saves that touch several files. Images are written before the JSON that refers to them. | Single-file manifest |
| D4 | Dependencies | Apple SDKs first; **a few vetted packages** allowed (swift-collections, plus swift-snapshot-testing in tests only). **No vendor AI SDKs.** *(Your choice.)* | Community OpenAI/Gemini SDKs |
| D5 | AI abstraction | Three capability protocols (`ImageProvider`, `LayoutProvider`, `VisionProvider`) with a provider-neutral request model, a **data-driven model catalog** and a separate **price list**. | One protocol per provider |
| D6 | Session context | **The app owns the conversation.** Requests are rebuilt from local state every time. Gemini (post-MVP) gets native multi-turn history when it's safe; otherwise requests are stateless "edit this image" calls. OpenAI always uses the stateless Images API. | OpenAI Responses API with `previous_response_id`. It keeps state on the server and makes branching from older versions harder. |
| D7 | Text layout | **TextKit 2 for both editing and final rendering.** The same `NSTextLayoutManager` layout is drawn on screen, in thumbnails, in PDFs and in print. | Core Text for output and TextKit for editing. Small layout differences would break WYSIWYG. |
| D8 | Rendering | A single `PageRenderer` that draws into any `CGContext`: screen, bitmap, PDF or print. | Separate on-screen and export paths |
| D9 | Undo | One `UndoManager` per book window (from SwiftUI). All undoable edits go through a command layer that captures value-type snapshots. NSTextView's own undo is **disabled**, and text undo is coalesced at the model level. | NSTextView-native undo. It breaks when the view goes away. |
| D10 | Queue | One app-wide `GenerationQueue` actor that runs one request at a time. The user's intent is captured when an item is queued; context is resolved when it runs. The queue persists across relaunches (restored paused). | One queue per book |
| D11 | Upscaling | Core Image (Lanczos plus mild luminance sharpening) behind an `Upscaler` protocol. *(Your choice.)* | Bundled Core ML model |
| D12 | Sandbox | **Not sandboxed** in v1. Hardened runtime is on (required for notarization). See §13.3. | App Sandbox |
| D13 | Release | GitHub Actions on `xcode-27` (macOS 27, arm64) runners: sign → notarize (`notarytool`, API key) → staple → zip → GitHub Release → bump the cask in a personal tap. | Local release script |

---

## 1. Principles

1. **The local model is the truth.** Providers are stateless functions as far as the app is concerned. Everything needed to rebuild, audit ("Version details") or regenerate a request lives in the book package.
2. **Value types throughout the model.** Books are trees of `Codable`, `Sendable`, `Equatable` structs. This makes undo snapshots, background export, diffing and copying between books cheap and safe.
3. **One renderer, one text engine.** What's on screen is exactly what prints.
4. **Data-driven provider knowledge.** Models, capabilities and prices change monthly. In the last six weeks, `gpt-image-1` was shut down and two new OpenAI and Gemini image models shipped. That knowledge lives in bundled JSON resources rather than in code branches.
5. **Derived state is computed, not stored.** Status flags, "where used", totals and page positions are computed from the model, so they can't go stale.
6. **Nothing leaves the Mac except provider requests.** The only network hosts are `api.openai.com` and `generativelanguage.googleapis.com`.

---

## 2. Platform and technology stack

| Concern | Choice |
|---|---|
| Language | Swift 6 language mode, strict concurrency checking on. |
| Toolchain | Xcode 27.x (Swift 6.4), locally and in CI. GitHub-hosted images are now named by Xcode version; CI uses the `xcode-27` label, which runs macOS 27 on Apple Silicon. |
| Deployment target | macOS 27.0. macOS 26 is not supported (decided 2026-11-07). macOS 27 is the current release, which also satisfies Homebrew's "works on the latest macOS" rule. When macOS 28 ships, test on it before claiming support. |
| UI | SwiftUI (`NavigationSplitView`, `WindowGroup(for:)`, `Settings` scene), Observation (`@Observable`), and AppKit via `NSViewRepresentable` for the canvas and text. |
| Text | TextKit 2 (`NSTextLayoutManager`, `NSTextContentStorage`) and `NSSpellChecker` for checking. |
| Graphics | Core Graphics (PDF contexts), Core Image (upscaling, mask feathering, compositing), ImageIO (decoding, thumbnails, metadata). |
| PDF and print | `CGContext` PDF output; PDFKit for preview and `PDFDocument.printOperation`. |
| Fonts | Core Text font manager. Imported fonts are registered with `.process` scope. |
| Networking | `URLSession`, ephemeral configuration (no cookies or cache). |
| Secrets | Security framework Keychain (generic password items). |
| Persistence | `JSONEncoder` / `JSONDecoder` and `FileManager`. |
| Testing | Swift Testing, plus `swift-snapshot-testing` (test-only) for prompts, layouts and rendered pages. |
| Third-party (runtime) | `swift-collections` (`OrderedDictionary`, `Deque`). Nothing else without a decision-log entry. |

---

## 3. Module structure

The Xcode app target stays thin, and the code lives in local Swift packages so that most of it can be tested without the UI.

```
                    ┌──────────────────────┐
                    │  BookBook (app)      │  @main, scenes, Info.plist, entitlements
                    └─────────┬────────────┘
                              │
                    ┌─────────▼────────────┐
                    │  BBUI                │  SwiftUI features, AppKit canvas, view models
                    └──┬───────┬───────┬───┘
         ┌─────────────┘       │       └──────────────┐
┌────────▼───────┐   ┌─────────▼────────┐   ┌──────────▼────────┐
│ BBExport       │   │ BBAI             │   │ BBStore           │
│ PDF, booklet,  │   │ queue, context   │   │ package I/O,      │
│ upscale,       │   │ assembly, cost,  │   │ journal, library, │
│ preflight      │   │ errors, catalog  │   │ migrations, image │
└──────┬─────────┘   └──┬──────────┬────┘   │ store, keychain   │
       │                │          │        └─────────┬─────────┘
┌──────▼─────────┐  ┌───▼──────┐ ┌─▼────────┐         │
│ BBLayout       │  │ BBOpenAI │ │ BBGemini │         │
│ geometry, page │  └───┬──────┘ └─┬────────┘         │
│ order, TextKit │      └────┬─────┘                  │
│ layout,        │      ┌────▼──────┐                 │
│ PageRenderer   │      │ BBNet     │ HTTP client,    │
└──────┬─────────┘      │           │ multipart, SSE  │
       │                └────┬──────┘                 │
       └──────────┬──────────┴────────────────────────┘
           ┌──────▼───────┐
           │ BBModel      │  value types, IDs, schema versions, derived queries
           └──────────────┘
```

- `BBModel` imports Foundation only. It contains no I/O.
- `BBOpenAI` and `BBGemini` depend on `BBAI`'s protocol and request types (shown in a separate small target, `BBAICore`, if the dependency graph needs it), not the other way round. The app wires up the concrete providers.
- `BBLayout` depends on AppKit only for TextKit 2 and font types. It has no views.
- **As-built dependencies (Phase 1b, `BookBookKit/Package.swift`; this list wins where the diagram is looser):** BBModel → swift-collections · BBStore → BBModel · BBLayout → BBModel · BBNet → nothing (it needs no model types) · BBAICore → BBModel · BBAI → BBAICore, BBModel · BBOpenAI and BBGemini → BBAICore, BBNet · BBExport → BBLayout, BBModel · BBUI → BBExport, BBAI, BBAICore (added Phase 2: the UI shows `ProviderError`s), BBStore, BBLayout, BBModel · app → BBUI, BBOpenAI, BBGemini. BBAI does **not** depend on the provider adapters; the diagram's BBAI → BBOpenAI/BBGemini arrows mean "uses through BBAICore's protocols".
- **As built (Phase 1b):** every module is a library target in one local package, `BookBookKit/` (plan P-1), and `BBAICore` exists as its own target from the start. A test-only target, `BBTestSupport` (the live-test gate and the bundled test font, Atkinson Hyperlegible, OFL), is depended on only by test targets and never linked into the app.
- **Bundled resources:** `BBAI` holds `ModelCatalog.json`, `PriceList.json` and `Prompts/`. `BBStore` holds `Presets/StylePresets.json` and `Presets/TemplatePresets.json` (§10), because `BBModel` does no I/O and both the UI and the layout requests need the presets. The app passes presets to the providers; providers never load them.

---

## 4. Domain model (BBModel)

### 4.1 Identity, units, revisions

- **IDs:** typed wrappers around `UUID` (`BookID`, `PageID`, `BoxID`, `AssetID`, `SessionID`, `VersionID`, `TemplateID`, …) for type safety.
- **ImageRef:** the lowercase hex SHA-256 of an image file's bytes, plus its UTType. Files are content-addressed, so copying between books de-duplicates automatically.
- **Geometry:** page setup is stored in **points** (1/72 in). Box frames are stored **normalized to the trim area of the template's coordinate space** (0…1 on each axis; a spread's x range covers both pages). That's what lets "boxes keep their position and size relative to the page" (§8.2) work when page setup changes. **Origin (Phase 2):** normalized rects and points have their origin at the trim's **top-left**, y increasing downward; BBLayout uses the same convention in points, and `PageRenderer` expects a context already set up that way (PDF contexts are flipped once by the caller).
- **Money:** `Decimal` in USD.
- **Revisions:** monotonic `Int` counters on things whose changes cause flags:
  - `StyleGuide.visualRevision` goes up (to `visualRevisionHighWater + 1`, never reusing a number) when the visual description, style references or negative guidance change. Typography and page setup don't count.
  - `Asset.revision` goes up when the description or primary reference changes.

### 4.2 Core types (abridged)

```swift
struct Book {                       // book.json
    var id: BookID
    var schemaVersion: Int
    var title: String
    var author: String
    var createdAt, modifiedAt: Date
    var pageOrder: [PageID]          // reading order, excluding the cover
    var coverPageID: PageID
    var budget: Decimal?
    var acknowledgements: Acknowledgements   // e.g. real-person-photo notice per provider
}

struct StyleGuide {                 // style.json
    var presetID: String?
    var visualDescription: String
    var styleReferences: [ImageRef]
    var negativeGuidance: String     // default: "no text, letters or words in the image"
    var visualRevision: Int
    var typography: Typography       // body/title font, size, colour, line spacing, alignment
    var pageSetup: PageSetup         // size, orientation, margins, bleed (on/off, amount)
    var pageNumbers: PageNumberStyle // on/off, position, font, start, skip rules
}

struct Template {                   // templates/<id>.json
    var id: TemplateID
    var name: String
    var kind: TemplateKind           // .single, .spread, .cover
    var boxes: [Box]                 // array order = layer order
}

struct Box {
    var id: BoxID
    var frame: NormalizedRect
    var rotationDegrees: Double
    var cornerRadius: Double          // points
    var bleedEdges: EdgeSet           // edges that extend into the bleed (full-bleed = .all)
    var content: BoxContentKind       // .image | .text(TextBoxStyle overrides)
    var role: BoxRole?                // .title, .author, .pageNumberSlot … (cover/title templates)
}

struct Page {                       // pages/<id>.json  (the cover is a Page with kind .cover)
    var id: PageID
    var kind: PageKind               // .story, .cover
    var templateID: TemplateID
    var text: [BoxID: RichText]
    var images: [BoxID: ImageSlot]
    var assetChecklist: [AssetID]
    var isDone: Bool
}

struct ImageSlot {
    var sessionID: SessionID
    var placement: ImagePlacement?   // nil = empty box
    var acknowledged: FlagBaseline   // revisions/aspect the user accepted ("mark as OK")
}

struct ImagePlacement {
    var versionID: VersionID
    var zoom: Double                 // ≥ 1.0; 1.0 = aspect-fill of the box
    var center: CGPoint              // focal point in image-normalized coordinates (0…1)
    var boxAspectWhenPlaced: Double  // used for the "layout changed" flag
}

struct Asset {                      // assets/<id>.json
    var id: AssetID
    var type: AssetType              // .character, .place, .object
    var name: String
    var description: String
    var tags: [String]
    var references: [ReferenceSlot]  // exactly one with isPrimary == true
    var sheet: CharacterSheet?       // characters only
    var revision: Int
}

struct ReferenceSlot {
    var id: UUID
    var label: String
    var isPrimary: Bool
    var sessionID: SessionID
    var chosen: VersionID?
}

struct CharacterSheet {
    var items: [SheetItem]
}

struct SheetItem {
    var id: UUID
    var kind: SheetItemKind          // .view(.front/.threeQuarter/.side/.back), .expression(name)
    var sessionID: SessionID
    var chosen: VersionID?
    var locked: Bool
}
```

**As built (Phase 10):** `Asset` also stores `revisionHighWater` (like `StyleGuide.visualRevisionHighWater`). Only a description change or a change of the primary reference's chosen image (or which slot is primary) bumps `revision` to `highWater + 1`; undo restores the old revision, and numbers are never reused. Renames, tags and sheet edits don't bump. A new character's sheet has 8 items: three-quarter, side and back views plus happy, sad, surprised, angry and sleepy (the primary reference serves as the front view; decided 2026-11-08). `Version.depictsRealPerson: Bool?` holds the import answer (§11). Asset edits are `BookCommand.addAsset` / `updateAsset` (wholesale replace) / `setAssetChecklist`; deletion is irreversible (`BookDocument.deleteAsset`).

**RichText** is BookBook's own `Codable` attributed-run model. It isn't RTF and it isn't an archived `NSAttributedString`, so it stays diffable, version-proof and limited to the formatting the product supports:

```swift
struct RichText {
    var paragraphs: [Paragraph]
}

struct Paragraph {
    var runs: [Run]
    var alignment: Alignment?
}

struct Run {
    var text: String
    var bold, italic, underline: Bool
    var fontFamily: String?          // overrides the style default
    var size: Double?
    var color: RGBA?
}
```

`TextBoxStyle` (Phase 6) also carries optional `fontSize`, `alignment` and `color` overrides. Precedence is run/paragraph override > box style > style guide, applied by `Typography.applying(_:)` before layout.

Converting between this model and `NSAttributedString` is done in one place (`BBLayout.RichTextBridge`). The style guide's defaults are resolved there, so "layered on the style guide defaults" (§8.6) falls out naturally: a run with no override follows the style guide when it changes.

`bold` and `italic` are relative to the run's base face (its `fontFamily`, else the role's style font from `Typography.resolved(for:)`): `true` means "the opposite of the base face". With a regular base face that's ordinary bold/italic. With a bold base face (the default title font, `AvenirNext-Bold`) an unformatted run is drawn bold but stored as `bold: false`, so it follows a later change of the title font, and `bold: true` draws the family's regular weight. The format bar and the B/I toggles work on what is drawn, not on the stored flags: B is on over unformatted title text, and pressing it sets each run's flag so the run draws the other weight (fix round 1, Phase 4).

### 4.3 Sessions and versions

```swift
struct Session {                    // sessions/<id>.json
    var id: SessionID
    var owner: SessionOwner          // .pageBox(PageID, BoxID) | .assetReference(AssetID, slotID) | .sheetItem(AssetID, itemID)
    var messages: [Message]          // a single linear thread (§8.6 "stays a single conversation")
    var versions: [Version]          // version strip order
    var resetEpoch: Int              // bumped on reset; messages from earlier epochs are hidden
}

struct Message {
    var id: UUID
    var epoch: Int
    var role: Role                   // .user, .assistant (status notes), .system (e.g. "consistency fix")
    var text: String                 // mentions encoded as tokens: ⟦asset:<uuid>⟧
    var refines: VersionID?          // the version that was selected when this was sent
    var attachedReferences: [VersionRef]
    var producedVersion: VersionID?
    var queueItemID: QueueItemID?
}

struct Version {
    var id: VersionID
    var image: ImageRef
    var source: VersionSource        // .generated, .imported, .regionEdit, .consistencyFix
    var parent: VersionID?           // the version that was refined, if any
    var createdAt: Date
    var starred: Bool
    var provenance: Provenance?      // nil for imported
    var consistency: ConsistencyResult?
}

struct Provenance {
    var provider: ProviderID
    var model: String
    var quality: QualityLevel
    var outputSize: PixelSize
    var promptSent: String           // the exact composed text sent
    var referencesSent: [SentReference]   // ImageRef + role + label, in the order sent
    var referencesOmitted: [SentReference]
    var styleRevision: Int
    var assetRevisions: [AssetID: Int]
    var storyTextIncluded: Bool
    var intent: GenerationIntent     // the replayable user intent ("Regenerate with same settings")
    var cost: CostRecordID
    var providerTurn: ProviderTurn?  // opaque, provider-specific continuation data (§7.6)
}
```

- **As built (Phase 2):** IDs are one generic `TypedID<Tag>` (encoded as a bare UUID string, and as a string key in dictionaries, so `[BoxID: RichText]` is a JSON object). `ImageRef` stores the UTType identifier as `contentType`. `Version` also stores its `pixelSize`; `Message` has `createdAt`. `Provenance` adds `usage` (`TokenUsage`, when reported), `revisedPrompt`, and `parametersSent` (every wire parameter other than the prompt and images, e.g. `size`, `quality`, `output_format`, `moderation`, `n`), so Version details can show everything sent (§11). `cost` is optional until the ledger lands (Phase 9). The whole book in memory is `BookContent` (book, style, templates, pages, sessions).
- **Mentions** are stored as asset-ID tokens, so renaming an asset updates every prompt automatically. When an asset is deleted, a single pass rewrites its tokens to the asset's name as plain text (§8.3).
- **Reset** (§8.6) increments `resetEpoch`. Earlier messages are hidden and stop contributing context. Versions are either kept (the default) or deleted, as the user chooses.

### 4.4 Derived state (computed, never stored)

| Derived value | How it's computed |
|---|---|
| Page **status** | *Empty* when there is no text and no placement. *Done* when `isDone`. Otherwise *in progress*. |
| **Style changed** | `max(placedVersion.provenance.styleRevision, acknowledged.styleRevision) < currentVisualRevision`. Imported versions (no provenance) are never flagged (Phase 7). |
| **Asset changed** | For any asset in the placed version's `assetRevisions`, the recorded revision is below the current one, and that hasn't been acknowledged. |
| **Layout changed** | `abs(log(currentBoxAspect / (acknowledged.boxAspect ?? placement.boxAspectWhenPlaced))) > 0.05` (about a 5% change in shape). `currentBoxAspect` is the render rect's aspect, so bleed counts. Placing a new version clears `acknowledged.boxAspect` (Phase 7). |
| **Consistency warning** | The placed version has an undismissed warning. |
| **Where used** (§8.3) | An in-memory index `[AssetID: Set<UsageSite>]`, rebuilt incrementally from checklists, mentions and version provenance. |
| **Physical page positions** | `PageSequencer` (§8.1) |
| **Cost totals** | Summed from the cost ledger (§7.10). |

Flags clear on their own when the box gets a newer version. "Mark as OK" (a small addition to §8.5) writes the current revisions into `acknowledged`.

**Phase 7 decisions.** Undoing a style edit restores the previous fields *and* `visualRevision`, so flags it raised disappear on undo, but `StyleGuide.visualRevisionHighWater` (decoded as `visualRevision` when missing, so no schema bump) never goes down: every bump sets `visualRevision = highWater + 1`, so a number is never reused and an image generated at a since-undone revision is still flagged after a different edit. Choosing the version that is already placed is a no-op (no undo step, `acknowledged.boxAspect` kept). Page-setup changes don't rewrite placements: box frames are already trim-normalized, and `PageGeometry.imageRect` re-clamps the stored focal point and zoom at draw time, so reverting a size change restores the original crop ("crops are kept where possible").

---

## 5. Storage (BBStore)

### 5.1 Package layout

```
MyBook.bookbook/                 UTType app.bookbook.book, conforms to com.apple.package
├── book.json                    Book
├── style.json                   StyleGuide
├── templates/<uuid>.json        Template
├── pages/<uuid>.json            Page (story pages and the cover)
├── assets/<uuid>.json           Asset
├── sessions/<uuid>.json         Session (+ versions + provenance)
├── costs.jsonl                  append-only cost ledger, one JSON object per line
├── images/<sha256>.<ext>        every image: versions, references, imported files
├── fonts/<sha256>.<ext>         imported font files
├── thumbnail.png                cover thumbnail for the library grid
└── .journal/                    present only while a save is in flight
```

- The JSON is written with `.sortedKeys` and `.prettyPrinted`, with dates in ISO 8601. That makes it diffable and easy to read for debugging. **As built (Phase 2):** dates are ISO 8601 UTC with nine fractional digits, so any `Date` round-trips exactly; decoding also accepts dates without a fraction.
- `book.json` carries a `schemaVersion`. `BBStore.Migrator` runs ordered, pure `(old JSON) → (new JSON)` steps when a book is opened. It copies the book to `<name>.bookbook.backup-v<N>` in the Trash first, so the pre-migration book can be recovered.
- Imported images keep their original bytes, apart from EXIF orientation being normalized and HEIC being converted to PNG. Generated images are stored exactly as the provider returned them.
- Thumbnails and downsampled renditions are **not** stored in the package. They go to `~/Library/Caches/BookBook/<bookID>/` and are rebuilt from scratch when missing.
- `Info.plist`: `UTExportedTypeDeclarations` declares the type (conforming to `com.apple.package` and `public.content`, extension `bookbook`), and `CFBundleDocumentTypes` gives it `LSTypeIsPackage = YES`, so Finder shows a single file.

### 5.2 Write path and crash safety

The in-memory model tracks dirty entities. Each save is one **transaction**:

1. Write any new image and font files first (write to a temp file, then `rename`). Content addressing makes this idempotent.
2. Encode every dirty entity and write it to `.journal/<txid>/` together with `manifest.json`, which lists target paths and deletions.
3. `fsync`, then write `.journal/<txid>/COMMIT` (empty) and `fsync` again.
4. Move each staged file into place with `rename(2)` (atomic per file), and apply the deletions.
5. Remove `.journal/<txid>/`.

**When a book is opened:** a transaction with a `COMMIT` file is replayed (roll forward). One without it is discarded. The book on disk therefore always reflects either the state before a save or the state after it.

**As built (Phase 2):** the journal is `.journal/<txid>/{staged/<relative path>, manifest.json, COMMIT}`, with `manifest.json` = `{targets, deletions}`. Because a book can come from someone else, roll-forward validates the transaction first: the txid must be a UUID, every path must be exactly `book.json`, `style.json` or `(templates|pages|sessions)/<uuid>.json`, and every source and destination must stay inside the package after resolving symlinks. If any entry fails, the whole transaction is discarded and the book opens as it was. `create` stages the whole package in a sibling folder and renames it into place.

Image files that no JSON refers to are swept only when the book is opened, and only if they are more than 24 hours old, so a generation that is still being delivered never loses its file. Ledger lines are appended with `O_APPEND`. A truncated last line is ignored and repaired.

### 5.3 Autosave

- `BookStore` is an actor (one per open book) that serializes all I/O for that book.
- A save is triggered 1 s after the last edit (debounced), and also when the window closes, the app quits or the app is hidden.
- Encoding happens on the actor from a value snapshot, so the UI never blocks.
- **Single writer:** an open book holds `.lock`, which records the process ID and host. If another live lock is found (for example a library on a shared drive), the app warns and offers to open the book read-only.
  - `.lock` is created atomically with `link(2)`. A stale lock (dead PID on this host, or unreadable) is taken over only while holding `flock(2)` on the package folder, re-reading the lock through one file descriptor first; a lock that vanished counts as missing, never stale. Release takes the same `flock`.
  - Within one process the lock is re-entrant and counted per book across `BookStore`s; only the last release removes `.lock`.
  - Headless opens (closed-book deliveries, snapshots, renames) run in `OpenBooks`' per-book queue and take the lock; if another process holds it, deliveries write nothing and report the book as locked, and snapshots load read-only (no recovery, migration, ledger repair or sweep). (Phase 3)

### 5.4 Library

- **Default location:** `~/Library/Application Support/BookBook/Library/`. It can be changed in Settings (§8.11). Changing it offers to move the existing books. The library window has a **Show in Finder** command so books are easy to back up.
- `LibraryIndex` scans the folder for `*.bookbook`, reads `book.json` and `thumbnail.png`, and caches the results in `~/Library/Application Support/BookBook/library-index.json`. It refreshes through an `FSEvents`-backed `DispatchSource`, so books copied in through Finder appear.
- **Delete** uses `FileManager.trashItem` (§8.1). **Duplicate** is a recursive copy with a new `Book.id`. Internal IDs can stay the same because they are scoped to the book.
- **Import from another book** (§8.1) is done by `BookImporter`:
  - Templates and the style guide are deep-copied with new IDs.
  - Assets are copied with their reference and sheet slots. Each chosen image is copied in as a single **imported** version in a new session. Sessions aren't copied, so history stays in the source book and the copies are independent.
  - Image files are copied by hash, so duplicates are skipped.
  - Name clashes go through a rename prompt before anything is written.
- The **sample book** is a bundled read-only `.bookbook` in the app resources. "Open sample" copies it into the library on first use.
- **As built (Phase 16):**
  - An imported style guide keeps the target book's page setup; only the visual style and typography come across. Importing is one undoable `BookCommand` (`.importFromBook`). Undo removes the assets and templates and restores the style guide, but leaves the new sessions behind as orphans, as for any new session.
  - Duplicate `Book.id`s (a Finder copy) are resolved on library refresh. The package already indexed keeps its ID. Otherwise the earliest-created folder keeps it. The other package gets a new ID through a locked, journaled save.
  - Clean up deletes the freed image files at once, not through the 24-hour orphan sweep.
  - The sample book is bundled at `BBStore/Resources/SampleBook/Sample.bookbook`. The ID of its library copy is kept in `UserDefaults` (`sampleBookCopyID`). The bundled one is a text-only placeholder until the real one is made in the app (see its README).

### 5.5 App-level files

| Data | Location |
|---|---|
| Preferences | `UserDefaults` (providers, models, quality, threshold, custom model IDs, consistency switch, library path). **As built (Phase 9):** custom model IDs live here (`customModels`), not in `pricelist.json`. |
| API keys | Keychain, service `app.bookbook.api-key`, account `openai` or `gemini`; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; not synchronizable |
| Model catalog overrides and the user's price list | `~/Library/Application Support/BookBook/pricelist.json` (when missing, the bundled defaults are used) |
| Queue | `~/Library/Application Support/BookBook/queue.json` |
| Caches | `~/Library/Caches/BookBook/` |

---

## 6. Application architecture (BBUI and the app)

### 6.1 Scenes and windows

```swift
@main
struct BookBookApp: App {
    @State var app = AppModel()                  // @MainActor @Observable

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
        }
        WindowGroup(for: BookID.self) { $bookID in
            BookWindow(bookID: bookID)
        }
        Window("Queue", id: "queue") {
            QueueView()
        }
        Settings {
            SettingsView()
        }
    }
}
```

- `openWindow(value: bookID)` brings an existing window for that book to the front if there is one, so "one window per open book" is enforced by the system. SwiftUI also restores book windows when the app relaunches, **but only when the user's macOS setting "Close windows when quitting an application" is off, or after Quit and Keep Windows (⌥⌘Q)**. With the macOS default, the app relaunches to the Library window only (SL-3, `Spikes/REPORT.md`).
- **Reopening books at relaunch (decided 2026-11-07, PD §8.1):** BookBook always reopens the books that were open when it quit. `OpenBooks` keeps an ordered list of open `BookID`s in `UserDefaults` (`openBookIDs`; IDs only, nothing else), updated as book windows open and close. While the app is quitting, closing windows doesn't remove entries. At launch, `AppModel` calls `openWindow(value:)` for each ID that `LibraryIndex` still resolves, and silently drops the rest. Because `openWindow(value:)` brings an existing window to the front, this never duplicates a window that SwiftUI's own restoration already reopened. `NSQuitAlwaysKeepsWindows` is not used, since it would change behaviour for every window rather than only books.
- `AppModel` owns everything app-wide: `Settings`, `ModelCatalog`, `PriceList`, `KeychainStore`, `LibraryIndex`, `GenerationQueue`, and `OpenBooks`, a registry of `BookID → BookDocument`.
- `BookDocument` is `@MainActor @Observable`, one per window. It holds the in-memory `BookState` (a value tree), its `BookStore` actor, the derived indexes, and the command layer (§6.3).

### 6.2 Book window composition

| Area | Implementation |
|---|---|
| Sidebar (Pages, Assets, Style, Layouts, queue indicator, book switcher) | SwiftUI `NavigationSplitView` |
| Spread overview, asset editor, style form, template list, settings, wizard, queue | SwiftUI |
| **Page canvas and template editor** | `CanvasView` (AppKit `NSView`, layer-backed) inside `NSViewRepresentable`. It draws with `PageRenderer` and handles hit-testing, selection handles, snapping guides, pan/zoom of placed images, and the in-place text editor. |
| In-place text editing | One `NSTextView` (TextKit 2) placed over the active text box, configured from `TextBoxLayout`. Continuous spelling and grammar checking are on. `allowsUndo = false` (§6.3). |
| Session panel | SwiftUI: chat thread, prompt field with `@mention` autocomplete, asset checklist, version strip, version details. |
| Region editor | An AppKit overlay over a large view of the selected version, with brush and lasso tools. It produces an 8-bit mask at the version's pixel size. |

The canvas draws downsampled images from the cache; export uses the full-resolution files.

**As built (Phase 6):** `CanvasView` only draws, fits to the view and forwards events to a mode controller: `PlacementController` (page canvas: selection, clicks, overflow badges; owns a `TextEditingController` for the in-place editor) or `LayoutEditingController` (template editor, hosted by `TemplateCanvas`). Drag maths lives in pure functions (`LayoutEditingMath`); hit-testing, handles, snapping and align/distribute are in `BBLayout/TemplateEditing.swift`. The editor manipulates *trim* rects (normalized frame × trim, no bleed push-out). The Layouts tab's state is `TemplateEditorModel` (one per window); selecting a bundled preset only opens it; the first edit copies it into the book under its own ID, folded into that edit's undo step (Session B change).

### 6.3 Commands and undo/redo (§8.10)

- Every undoable mutation is a `BookCommand`, a value describing the edit, such as `MoveBox`, `SetRichText`, `ChooseVersion`, `ReorderPages` or `ImportStoryText`. It is applied through `BookDocument.perform(_:)`. `perform` captures a **before snapshot** of the affected entities (cheap, because they are value types), applies the edit, marks the entities dirty, and registers the inverse with the window's `UndoManager` (`@Environment(\.undoManager)`, passed into `BookDocument`).
- Drags and resizes open an undo group on mouse-down and close it on mouse-up. Story text import is one group (§8.10).
- **Text typing:** NSTextView's own undo is off, because its undo entries point at a text storage that is thrown away when the user moves to another page. The text bridge sends `SetRichText` commands. Consecutive edits to the same box are **coalesced** into one undo step until the user pauses for 1 s, switches box, or changes formatting. That matches how the Mac usually groups typing undo.
- **Undo closures look up entities by ID** when they run, and do nothing if the target has gone. A version deleted from the strip, or an asset deleted (both non-undoable), can therefore never be "resurrected" by undo, and the stack never crashes.
- **Edits that aren't undoable** (§8.10) go through `BookDocument.performIrreversible(_:)`, which never registers undo. That covers AI results arriving, session reset, asset deletion, version deletion, clean-up and book deletion. Each UI entry point shows its own confirmation.
- AI results write only to sessions and the ledger. Undo never touches those, except for `ChooseVersion`. That keeps the undo history consistent while results come in. **Phase 8:** a template change that moves an image slot to a new box ID also rewrites its session's `owner` in the same edit, and undo restores it; that is the only other place undo touches a session. Queue items and deliveries resolve their session by message ID (`BookContent.session(containing:)`), never by box ID.
- Undo history lasts until the window closes (§8.10). It isn't persisted.
- **Undo groups (Phase 6):** `BookDocument.beginUndoGroup()` / `endUndoGroup(actionName:)` bracket a drag: edits inside apply and save live, their inverses are collected, and one compound undo step is registered at the end (nothing if no edit happened). Template edits are `addTemplate`, `updateTemplate(_, actionName:)` (whole-template replace; new image boxes get empty sessions on using pages, irreversibly) and `deleteTemplate` (refused while any page uses it); `DirtySet.deletedTemplates` removes the file in the same journal transaction.
- **As built (Phase 2):** `perform` translates each `BookCommand` into primitive edits (set a box's text, set a box's placement, insert a page, remove a page), each of which returns its own inverse; undo and redo replay those inverses by ID and do nothing if the target is gone. Page commands never touch sessions: deleting a page keeps its session files, and undoing an add leaves the new page's empty sessions behind (swept by clean-up, Phase 16).
- **As built (Phase 8):** `setCrop(page:box:zoom:center:)` ("Adjust Crop") clamps zoom to 1…8 and the centre so the image covers the box; its undo applies only while the same version is still placed. Canvas drag pans and pinch/scroll zooms, one undo step per gesture (a phaseless mouse wheel closes its step after a 0.5 s pause). `setPageDone` and `setPageTemplate` use targeted inverses instead of whole-page snapshots, so undo keeps a version an AI delivery placed in between. Undoing a page deletion gives image boxes the template gained since then new empty slots, irreversibly. Starring, deleting and session reset are `performIrreversible`; deleting the placed version clears the placement.

### 6.4 Writing to books from the background

Queue results have to reach a book whether or not it's open. `BookWriter.apply(_ delivery:, to bookID:)` handles this:

- If the book is open, it calls `BookDocument.performIrreversible` on the main actor, and the UI updates live.
- If the book is closed, it opens a headless `BookStore`, loads only the affected session and ledger, applies the delivery, saves (one transaction) and closes.
- If the book has been deleted or moved to the Trash, the delivery is dropped and the queue item says so.

The image file is always written before the session JSON (§5.2).

### 6.5 Concurrency model

| Isolation | Types |
|---|---|
| `@MainActor` | `AppModel`, `BookDocument`, all views and view models |
| `actor` | `BookStore` (per book), `GenerationQueue` (app-wide), `ThumbnailCache` |
| `Sendable` value types and stateless clients | Model snapshots, `ImageRequest`, provider clients, `PageRenderer` inputs |
| Detached tasks with progress | Export, preflight, story-text spelling scans, upscaling |

**As built (Phase 2):** `TextBoxLayout`, `RichTextBridge`, `PageRenderer` and `PDFExporter` are `@MainActor` (TextKit 2 objects and `NSAttributedString` aren't `Sendable`); a slice-sized export on the main actor is acceptable. Phase 14 moves export and preflight off the main actor. `BookDocument` chains its autosave hand-offs to `BookStore` in one task chain so snapshots arrive in order, and `BookStore.scheduleSave` also keeps the highest generation number.

---

## 7. AI subsystem (BBAI, BBOpenAI, BBGemini, BBNet)

*Gemini parts of this section (`BBGemini`, Gemini quality mapping, fixed ratios, native history, signals) are post-MVP. v1.0 implements only the OpenAI paths.*

### 7.1 Model catalog (data-driven)

The bundled `ModelCatalog.json` describes every model the app knows about. Each entry has:

```jsonc
{
  "provider": "openai",
  "id": "gpt-image-2.5-sunburst",
  "displayName": "GPT Image 2.5 Sunburst",
  "kind": "image",                         // image | text | vision
  "status": "current",                     // current | deprecated | retired
  "retiresOn": null,
  "image": {
    "maxReferenceImages": 16,
    "maxRequestBytes": 20000000,
    "supportsMask": true,
    "nativeMultiTurn": false,               // as used by BookBook (Images API)
    "aspect": { "mode": "free", "minRatio": 0.3333, "maxRatio": 3.0,
                "multipleOf": 16, "minPixels": 655360, "maxPixels": 8294400 },
    "quality": {
      "draft":    { "param": "low",    "targetPixels": 1048576 },
      "standard": { "param": "medium", "targetPixels": 1572864 },
      "high":     { "param": "high",   "targetPixels": 3686400 }
    }
  }
}
```

Gemini image entries use `"aspect": { "mode": "fixed", "ratios": ["1:1","2:3",…] }` and quality mappings such as `{ "imageSize": "2K", "thinkingLevel": "medium" }`.

**Defaults when the catalog is seeded** (from the 2026-11-07 research; re-verify during implementation):

| Purpose | OpenAI | Gemini |
|---|---|---|
| Image | `gpt-image-2.5-sunburst` (the guide's recommended default). Also listed: `gpt-image-2.6-sunburst`/`-flare` and `gpt-image-2`. | `gemini-nano-banana-2.1` (stable). Also listed: `gemini-3-pro-image`. `gemini-3.1-flash-lite-image` is listed but marked "weak with multiple references". |
| Template (structured output) | `gpt-6-luna` | `gemini-3.1-flash-lite` |
| Consistency (vision) | `gpt-6.1-terra` (visual matching); `gpt-6-luna` offered as cheaper | `gemini-3.1-flash-lite` |

**How quality maps to each provider:**

- **OpenAI:** Draft = `low`, Standard = `medium`, High = `high`. GPT Image 2.5 and 2.6 also offer `xhigh` and `max`. Those are listed in the catalog but not exposed in v1, because the product defines three levels.
- **Gemini:** there's no native quality setting. Draft = 1K and `thinkingLevel: minimal`, Standard = 2K and `medium`, High = 4K and `medium`.

The settings UI says that a quality level means different things for each provider.

**Keeping up with model churn without contacting any non-provider server (§3):**
1. "Test connection" and opening Settings call the provider's own list-models endpoint with the user's key. Models missing from that list are marked unavailable, and a chosen model that has disappeared triggers a prompt to switch.
2. Retired models fall back to a `successor` named in the catalog.
3. An **advanced "custom model ID"** entry lets the user try a new model by copying the capabilities and prices of a named catalog family.
4. Catalog and prices are refreshed in each app release, which arrives through `brew upgrade`.

### 7.2 Provider protocols

```swift
protocol ImageProvider: Sendable {
    var id: ProviderID { get }
    func generate(_ request: ImageRequest,
                  progress: @Sendable (GenerationProgress) -> Void) async throws(ProviderError) -> ImageResult
}

protocol LayoutProvider: Sendable {
    func generateLayout(_ request: LayoutRequest) async throws(ProviderError) -> LayoutResult
}

protocol VisionProvider: Sendable {
    func checkConsistency(_ request: ConsistencyRequest) async throws(ProviderError) -> ConsistencyResult
}

protocol ProviderAccount: Sendable {
    func testConnection() async -> ConnectionStatus
    func availableModels() async throws(ProviderError) -> Set<String>
}
```

`ImageRequest` is provider-neutral:

```swift
struct ImageRequest: Sendable {
    var model: CatalogModel
    var quality: QualityLevel
    var output: OutputShape            // the box aspect; the provider adapter picks the concrete size
    var instruction: ComposedPrompt    // structured sections (§7.3), rendered per provider
    var baseImage: ImagePayload?       // the version being refined, if any
    var mask: MaskPayload?             // region edit only
    var references: [ReferenceImage]   // priority-ordered, already trimmed to limits
    var history: [HistoryTurn]         // lineage turns (§7.6); the adapter decides if it can use them
}

struct ImageResult: Sendable {
    var imageData: Data
    var mime: UTType
    var pixelSize: PixelSize
    var usage: Usage?
    var providerTurn: ProviderTurn?
    var revisedPrompt: String?
}
```

The provider adapters are the only code that knows wire formats. `BBNet.HTTPClient` is a protocol, so tests can inject recorded fixtures.

### 7.3 Context assembly (§8.6 "Context included with each request")

`ContextAssembler.assemble(intent:book:session:catalogModel:)` → `(ImageRequest, AssemblyReport)`. It's a pure function over a book snapshot, and is snapshot-tested.

1. **Resolve the assets in play.** These are the page's checklist, plus mentions in the current message, plus mentions in earlier messages in the current epoch along the lineage of the refined version (§7.6). For an asset session (reference or sheet item), the owning asset is always included.
2. **Select the reference images** (§7.4), up to the model's `maxReferenceImages` and a byte budget. The selection sets the image order, which the prompt legend depends on.
3. **Compose the prompt** from versioned templates, kept as resource text files so they can be tuned without code changes. The sections, in order:
   - **Role and medium:** "Illustration for a children's picture book."
   - **Style:** the visual description, plus "Images N–M are style references."
   - **Avoid:** the negative guidance.
   - **Cast and setting:** for each asset, its name, type, description and "Image K shows <name> (<view/expression>)".
   - **Composition:**
     - The box aspect and orientation.
     - Calm areas: any text boxes that overlap this image box are turned into region guidance, e.g. "leave the bottom third calm and low-detail for text".
     - On spreads where the image crosses the fold: "a vertical fold sits at 50% of the width; keep faces and key details away from it."
     - The bleed and safe area, phrased as "keep important content inside the central N%".
   - **Story text:** the page's text, as plain text. Optional, on by default.
   - **Conversation so far:** the user instructions along this version's lineage, condensed (used in stateless mode only; see §7.6).
   - **Request:** the current message, with mention tokens turned back into names.
   - **Reference legend:** "Image 1: … Image 2: …"
4. **Report:** the omitted references (shown to the user, per §5 "Reference limits"), the estimated input size, and the exact text that will be sent.

### 7.4 Choosing "the most relevant sheet images" (§8.3)

This is deterministic, with no AI call, so it adds no cost or latency and its decisions can be explained in Version details.

- **Priority tiers.** Earlier tiers fill first, and the tier order sets the image order:
  1. The base image (when refining or doing a region edit).
  2. References the user explicitly attached ("same kitchen as page 4").
  3. Primary references of **mentioned** assets.
  4. Primary references of **checklist-only** assets.
  5. Style reference images (at most 2; more only if there's spare capacity).
  6. Matching sheet items (see below).
  7. Other reference slots of the assets in play.
- **Matching sheet items:**
  - **Expressions:** the current message, plus the story text when it's included, is tokenized and matched against expression names and a bundled synonym table (e.g. *grin, giggle, beaming* → happy; *tears, crying* → sad; *yawn* → sleepy). User-defined expressions match on their own name and its simple inflections.
  - **Views:** *from behind, walking away* → back; *profile, side-on* → side; *turning, over her shoulder* → three-quarter. With no match, the default is three-quarter.
  - **Per-asset caps:** a character gets primary + 1 expression + 1 view; a place gets primary + 1; an object gets the primary only.
  - Unchosen sheet items are skipped. **Phase 10 decision:** locked items are *not* skipped; "lock" means "don't regenerate" (Generate whole sheet skips it), and a locked, chosen item is still sent.
- **Budget.** Selection stops when the model's reference limit or byte budget is reached. Whatever is cut gets listed: "Left out: Granny Oak – sleepy expression; style reference 3."
- **Payload prep.** References are downscaled to a 1536 px long edge and sent as JPEG (quality 0.9), or PNG when they have alpha. The base image is sent at its native size, because a mask has to match it.

### 7.5 Fitting image boxes to model sizes (§8.6)

- **Fixed-ratio models (Gemini):** pick the supported ratio that minimizes `|log(r_box) − log(r_model)|`.
- **Free-size models (OpenAI 2/2.5/2.6):**
  1. Clamp the box ratio to the 1:3–3:1 range.
  2. Solve `w·h ≈ targetPixels(quality)` with `w/h = r`.
  3. Round both sides to multiples of 16, then clamp to the model's minimum and maximum pixel counts.
  4. Don't go above 2560×1440-equivalent pixels, where OpenAI marks results "experimental".
- **Placing the result:** a new version is placed with `zoom = 1`, centred, aspect-filling the box. `ImagePlacement` stores a zoom and a focal point that are independent of box size, so resizing a box, changing page setup or turning bleed on (§8.2) keeps the crop's intent. The focal point is re-clamped so the image always covers the box.
- `boxAspectWhenPlaced` is recorded at placement time for the "layout changed" flag (§4.4).

### 7.6 Sessions, refinement and provider differences

The thread is linear in the UI (§8.6), but versions form a **lineage tree** through `Version.parent`. Refining a version uses only that version's lineage: the chain of messages and versions from the root to the selected version. This is how "refining an older version never removes later ones" works without any special handling.

**Two request modes:**

| Mode | When | What is sent |
|---|---|---|
| **Native history** (Gemini only) | Every turn on the lineage was made by the same provider and model, has a stored `ProviderTurn` (including `thoughtSignature`s), is in the current epoch, and the resent inline images fit the budget (≤ 15 MB of inline data and ≤ 6 turns) | `contents` = the lineage turns as originally exchanged: user parts, then the model's parts *as returned*, with their signatures echoed back exactly, then the new user turn |
| **Stateless edit** (OpenAI always, and Gemini otherwise) | Everything else: imported versions, provider switches, budget exceeded, a missing signature | The base image as image 1, the references after it, and a prompt that includes the condensed lineage of instructions ("Earlier requests: …; now: …") |

`ProviderTurn` for Gemini stores the model's response parts, with image bytes **replaced by a reference to the version's `ImageRef`** so images aren't duplicated, plus the opaque `thoughtSignature` strings. If Gemini returns `MISSING_THOUGHT_SIGNATURE`, the request is retried once automatically in stateless mode.

**OpenAI adapter (Images API):**
- A new image with no references uses `POST /v1/images/generations`. Anything with references or a base image uses `POST /v1/images/edits` (multipart, `image[]` up to 16, base image first).
- Parameters: `size` from §7.5, `quality` from the catalog, `output_format: png`, `n: 1`, `moderation: auto`. **`size` is always explicit.** On `/images/edits`, `size: auto` returned 1254×1254 for a 1024² base (SP-3), so refinements and region edits send the base image's size.
- Uploads are limited to 50 MB per image (`file_above_max_size`), which the adapter checks before sending (SP-5).
- The response image is in `data[0].b64_json`. `usage` (input and output image and text tokens) feeds the actual cost.
- **The Responses API isn't used in v1.** Server-side conversation state needs `store=true`, with at least 30 days of retention, and the app's own lineage model already gives the same refinement behaviour. Background mode (which supports server-side cancel) is noted as a future option (§7.9).

**Gemini adapter (`generateContent`):**
- `responseModalities: ["IMAGE"]` (TEXT is added only to get refusal explanations), `imageConfig.aspectRatio` and `imageConfig.imageSize` from the catalog, and `thinkingConfig.thinkingLevel`.
- **Send `store: false` on every request.** New paid projects store `generateContent` requests by default since 26 Oct 2026, and this matches §3's privacy stance. If the field is rejected by an older API version, it is dropped, which the catalog flags.
- Inline data only (base64 `inlineData`), with a total request budget of 20 MB. The Files API isn't used, because it keeps files on Google's side for 48 hours.
- Blocks come back as HTTP 200 with `promptFeedback.blockReason` or `candidates[].finishReason`. Those go to the error classifier (§7.11).

**Region editing (§8.6):**
- Available only when `supportsMask` is true, which today means OpenAI's GPT Image models. Every current Gemini image model edits by prompt only, so the region tool is disabled for Gemini with the explanation the product requires.
- The mask is sent as a PNG with alpha, the same size as the base image (a mismatch gives 400 `invalid_mask_image_format`), with the edit area transparent. **SP-4: the API replaces the transparent area**, so the encoding is right. But with flat test images the area often came back solid black, and the requested change landed outside the mask. The original pixels never survived under the mask, whatever RGB the mask held. **Settled in Phase 11 (SP11 live re-check, 2026-11-08):** on a real 1024² illustration, two masked edits and one unmasked edit returned no black fill (near-black fraction 0.0 under the mask), with the change concentrated in the mask (mean change 26–34 inside vs about 2.1 outside, the same drift as the unmasked edit). So v1 uses the **masked edit**, plus the mandatory local composite below, plus **black-fill detection as a safety net**: if more than 60% of the mask area comes back near-black, no version is made and the item fails as `.noImage` with advice to retry or select a larger area (the call is still charged).
- OpenAI documents mask edits as "prompt-based, not pixel-exact", and SP-4 saw the model repaint whole opaque (protected) quadrants. So BookBook **always composites the result locally**; this is mandatory, not a safeguard: the provider's output is blended into the original through the user's mask, feathered by about 8 px, using Core Image. This guarantees "only that area is altered". The composited result is stored as a `.regionEdit` version, and the raw provider output is kept in provenance for Details. As built (Phase 11): the user's 8-bit mask (white = edit) is stored in the book's `images/` and referenced by `GenerationIntent.regionMask`, so queue items stay small and Regenerate with Same Settings replays it; `ImageOps` (BBAI) rasterises the drawing, encodes the wire mask (alpha 0 = edit), composites with a box-blur feather (pixels beyond the feather band are byte-identical) and detects black fills; `Provenance.maskSent`, `rawOutput` and `featherPixels` feed Version details. The raw output travels to the host in `GenerationDelivery.additionalImages`, stored before the session JSON; the image sweep treats mask and raw-output refs as in use.
- (Later, the same local composite could enable region edits for Gemini too, by sending an image with the region outlined. That's out of scope for v1, per §8.6.)

**Importing your own image (§8.6):** the file is stored as a `.imported` version with no provenance. Refining it always uses stateless mode.

### 7.7 Template generation (§8.4)

- The `LayoutProvider` sends the description, page setup (size, orientation, margins, bleed, single or spread) and two built-in presets as few-shot examples. It requests **structured output** using one shared JSON Schema, `TemplateDraft`.
- The schema is written to the **intersection** of OpenAI strict-mode rules and Gemini's supported keywords:
  - Every property is `required`.
  - `additionalProperties: false`.
  - Nullable fields use `type: ["number", "null"]`.
  - No `allOf`, `not` or `if/then`.
  - Enums for box kinds and alignments.
  - Coordinates as numbers in 0…1.
- The response is validated and normalized locally:
  - Clamp to 0…1.
  - Snap edges within 2% of a margin or the trim edge to it.
  - Mark boxes that touch the trim edge as bleed boxes.
  - Drop degenerate boxes.
  - Ensure at least one box.
- The result is a new `Template`, opened in the visual editor. Provider refusals (`refusal` content on OpenAI, block reasons on Gemini) use the normal error path.

**As built (Phase 12):** template generation runs directly from the Layouts tab, not through the generation queue (§7.9): it's one short request that the user waits for in a sheet, and its result opens in the editor rather than landing in a session. The sheet shows the estimate first and a "What was sent" disclosure (model, prompts, parameters). Each request writes a `template` ledger line. Draft coordinates are fractions of the trim area (both pages for a spread), origin top-left; text boxes may carry an alignment, a corner radius in points and a `#RRGGBB` background panel.

### 7.8 Consistency check (§8.9)

- **Trigger:** after each successful image generation (page, cover or sheet item), when the global switch is on. The check is queued as a **follow-up item that runs straight after its parent**, ahead of other waiting items, and its cost is included in the parent's estimate.
- **Input:**
  - the new image;
  - for each asset used, its primary reference plus the sheet images picked by the same §7.4 selector;
  - the style description and up to 2 style references.
  
  Images are downscaled to a 1024 px long edge, with `detail: low` or the equivalent Gemini media resolution, to keep the cost down.
- **Output schema:**

  ```
  { consistent: bool,
    differences: [ { asset: string | null,
                     aspect: string,
                     observed: string,
                     expected: string,
                     severity: "minor" | "major" } ] }
  ```

  A warning badge appears when there's at least one `major` difference, or three or more `minor` ones. Those thresholds live in the catalog, so they can be tuned.
- **One-click fix:** turns the differences into a correction message ("Keep everything the same, but: make Pip's scarf red as in the reference; give the castle three towers"). It's sent in the same session as a refinement of that version (`source: .consistencyFix`), and the cost estimate is shown first.
- **On demand:** any version, including imported ones, can be checked.

**As built (Phase 12):**
- Queue items carry a kind (image or consistency check) and a `parent`; `queue.json` is schema 2 (schema 1 files still load; older builds ignore schema 2 files). The queue assigns the new version's ID before delivery, and the follow-up is inserted ahead of every waiting item once that delivery lands, including a later redelivery to a locked book. A second check of a version already queued is skipped.
- Follow-ups and on-demand checks need a wired `VisionProvider` and a catalog vision model; without them nothing is queued or estimated. The switch and the vision model are captured at enqueue time.
- `ConsistencyAssembler` leaves out the checked image itself from the references and leaves out real-person photos unless the book has acknowledged that provider's notice (§11).
- A failed check fails like any item and leaves the version untouched; a check whose version (or page box) is gone is dropped quietly. Checks write a `consistency` ledger line; the parent's line prices only its own request.

### 7.9 Generation queue (§5)

```swift
actor GenerationQueue {
    private(set) var items: [QueueItem]        // waiting + running + failed
    func enqueue(_ items: [QueueItem], position: Position) -> [QueueItemID]
    func move(_ id: QueueItemID, to index: Int)
    func remove(_ id: QueueItemID)             // waiting or failed only
    func cancelRunning()
    func retry(_ id: QueueItemID, on provider: ProviderID?)
    var updates: AsyncStream<QueueSnapshot>    // drives the queue UI and sidebar badge
}

struct QueueItem {
    var id: QueueItemID
    var bookID: BookID
    var target: GenerationTarget    // page box / cover box / reference slot / sheet item / template / consistency(versionID)
    var intent: GenerationIntent    // message text + mentions, refines, attached refs, mask ref,
                                    // provider, model, quality, includeStoryText
    var estimate: CostEstimate
    var state: State                // .waiting, .running(progress), .failed(ProviderError, advice)
    var parent: QueueItemID?        // for consistency follow-ups
}
```

- **Serial execution:** one item at a time across the app, in a long-lived task on the actor.
- **Intent captured when queued; context resolved when run.** The user's intent is fixed at enqueue time. Style, asset descriptions and references are assembled when the item starts, so a queued "Draft all empty boxes" picks up a style edit made while it waits. The version records exactly what was sent.
- **Pending state in the UI:** enqueueing appends the user's message to the session immediately, with `queueItemID` set. The session shows it as pending until the result arrives.
- **Progress:** neither provider reports real progress for a non-streamed image. The UI shows elapsed time against a typical duration for each model, kept in the catalog. OpenAI partial-image streaming is possible later, but each partial adds output tokens.
- **Cancelling the running item:** this cancels the `URLSessionTask`. Neither provider documents whether a cancelled request is billed, so the app assumes it is (§5). A ledger entry is written with status `cancelled` and the estimate marked as an estimate.
- **Failures:** the item stays in the queue as failed (§5) and the queue carries on. Transient errors (429, 500, 503 and 504; network loss) are retried automatically up to 3 times with exponential backoff and jitter, honouring `Retry-After`, before the item is marked failed.
- **Timeouts:** 300 s per request. Image generation can take up to about 2 minutes.
- **Persistence:** `queue.json` is rewritten whenever the queue changes. When the app relaunches, waiting and failed items come back with the queue **paused**, and a banner offers "Resume N queued requests". An item that was running when the app quit is recorded as cancelled.
- **Batch actions** ("Generate whole sheet", "Draft all empty boxes") build all their items, show the combined estimate (§7.10), and enqueue them in one call.
- **Offline:** when `NWPathMonitor` reports no network, the queue pauses and AI actions show "Offline". Everything else keeps working (§3).

**As built (Phase 9):**
- Automatic retries cover `.rateLimited`, `.transient` and `.offline`: up to 3 retries, base 2 s doubling plus jitter, or `Retry-After` capped at 120 s. `.noImage` retries once. While waiting, the item is `.retrying(attempt:resumesAt:lastError:)`. `.timeout` isn't retried, since the request may have been billed.
- Pause reasons rank offline, then restored, then user. Restore pauses only if at least one waiting item came back, so there's never a "Resume 0" banner. An item interrupted before its request was sent comes back as waiting.
- `remove` on a waiting or retrying item delivers `.failure(.cancelled)` so the host clears the pending message. A failed item's message was already cleared when it failed.
- `GenerationHost.deliver` returns a `DeliveryResult`. When a book is locked by another process, the result is kept in memory and redelivered every 30 s and on every queue change. It's lost if the app quits first.
- The app calls `restore()` before any enqueue, so the first save can't overwrite the previous `queue.json`.

### 7.10 Cost estimation and tracking (§5, §8.12)

**Price list** (`PriceList.json` is bundled; a user-edited copy takes precedence). Each entry is keyed by provider and model:

```jsonc
{ "provider": "openai", "model": "gpt-image-2.5-sunburst", "currency": "USD", "asOf": "2026-11-07",
  "perMillionTokens": { "textIn": 5.00, "imageIn": 8.00, "imageOut": 30.00, "cachedImageIn": 2.00 },
  "estimation": {
    "outputImageTokens": { "low@1024x1024": 200, "medium@1024x1024": 433, "high@1024x1024": 1767, "...": 0 },
    "inputImageTokens": { "1024x1024": 1024, "256x256": 256, "128x128": 64 },   // measured (SP-3); other sizes: see below
    "textTokensPerPromptChar": 0.27 } }
```

Gemini image entries carry `perImage` prices (e.g. `{ "1K": 0.0336, "2K": 0.0504, "4K": 0.113 }` for Nano Banana 2.1), plus input and thinking token rates and a typical thinking-token count per thinking level. Thinking can't be turned off and is always billed.

**Estimator:** `CostEstimator.estimate(_ request: ImageRequest | LayoutRequest | ConsistencyRequest) -> CostEstimate`. It's a pure function, so it can be unit-tested against the official calculator figures. Output tokens are **not** proportional to pixel count (SP-2: low 1024×1536 = 158 tokens, below low 1024² = 196), so the table holds measured entries per quality and size. For sizes not in the table, it uses the nearest measured entry of the same quality, rounded up, and labels the result an estimate. Input-image tokens use the measured per-size table; for other sizes the estimate assumes "downscale to ≤ 512 px a side, then 1 token per 16×16 patch", which fits SP-3 but is unconfirmed (Phase 9 measures a 1536×1024 reference). Text and vision estimates count reasoning tokens as output (SP-7). A generation's estimate includes its consistency follow-up when the switch is on.

**Actual cost:** when a response has `usage` or `usageMetadata`, `CostCalculator` prices the reported tokens with the same price list, broken down by modality, and the ledger entry is marked `actual`. Otherwise the estimate is recorded and marked `estimated`. Requests that fail with a 4xx or 5xx are recorded at $0, since neither provider bills those.

**Ledger:** `costs.jsonl` holds one line per request:

```
{id, at, kind: image|consistency|template, provider, model, quality, target, status: completed|failed|cancelled,
 estimated, actual?, basis: actual|estimate, priceListAsOf}
```

The book's running total, the breakdown by type and the list of recent requests (§8.12) are all computed from it.

**As built (Phase 9):** there's one ledger line per provider request, including automatic retries. HTTP-mapped failures (a raw 4xx or 5xx, refusals, key and billing errors) are $0 with basis `actual`. Cancels, timeouts, transport errors (`.transient(nil)`), `.offline` and unmapped errors without a status are recorded at the estimate, since they may be billed. A failure before any request is sent, such as a missing key, writes no line. Amounts are USD `Decimal`. `CostRecord` and `LedgerSummary` live in BBModel.

**Policies:** `CostPolicy` decides, before enqueueing, whether the app asks for confirmation (the estimate is above the Settings threshold, for a single request or a batch total) and whether it warns (the book's total is above its budget; it warns and never blocks).

Prices change often, so the Settings price list shows its "as of" date and has a "reset to built-in" command.

### 7.11 Errors, refusals and plain-language advice (§5)

Each provider's mapper turns HTTP status, error body and finish reasons into a single `ProviderError`:

| `ProviderError` | OpenAI signals | Gemini signals | Retry? |
|---|---|---|---|
| `.invalidKey` | 401 | 401, 403 `permission_denied` (key) | no |
| `.verificationRequired` | 403 for unverified org (GPT Image) | — | no |
| `.regionUnsupported` | 403 unsupported country | 400 `FAILED_PRECONDITION` (region/billing) | no |
| `.billing` | 429 `insufficient_quota`, `credit_balance_exhausted`, `*_spend_limit_exceeded` (switch on `error.code`) | 402, 429 `quota_exceeded` (daily) | no |
| `.rateLimited(retryAfter)` | 429 `rate_limit_error` / `slow_down` | 429 `rate_limit_exceeded` | auto |
| `.refused(stage, categories, raw)` | 400 `code: moderation_blocked` (+ `moderation_details.{categories, moderation_stage}`), `image_content_policy_violation` | `blockReason` *, `finishReason` ∈ SAFETY, PROHIBITED_CONTENT, IMAGE_SAFETY, IMAGE_PROHIBITED_CONTENT, SPII, BLOCKLIST | no |
| `.recitation` | — | RECITATION, IMAGE_RECITATION | no |
| `.noImage` | empty `data` | NO_IMAGE, IMAGE_OTHER, OTHER | once |
| `.invalidRequest(param)` | 400 `invalid_value` (with `param`, e.g. `size`), `invalid_image*`, `invalid_mask_image_format`, `file_above_max_size`, `image_too_large` | 400 `INVALID_ARGUMENT` | no |
| `.continuityLost` | — | MISSING_THOUGHT_SIGNATURE | once, stateless |
| `.modelUnavailable` | 404; 400 `invalid_value` with `param: model` (SP-5); deprecated or shut-down model | 404 `model_not_found` | no |
| `.transient` | 500, 503 `server_is_overloaded` | 500, 503, 504 | auto |
| `.offline`, `.timeout`, `.cancelled` | URLError | URLError, 499 | per case |

The raw status and body are kept in `raw`, with the API key never included, for the **Details** disclosure.

`RefusalAdvisor` turns an error and its `AssemblyReport` into a headline, an explanation and suggested fixes, using an ordered rules table. Each rule has a predicate and a piece of advice:

1. A refusal where the references include a **real-person photo** (flagged when imported; see §11): "Describe the child in words instead of uploading a photo."
2. A refusal where a word from a bundled **sensitive-terms list** (story-context words that often trigger filters, e.g. *naked, bath, blood, gun, kill*) appears in the prompt or the included story text: "Try removing the word '<X>'." If the term is only in the story text: "Or turn off 'include story text' for this request."
3. A refusal at the output stage: "The picture the model made was blocked. Try rephrasing the scene."
4. `.billing`, `.invalidKey` or `.verificationRequired`: specific steps with a link to the provider's console page.
5. Generic refusal: a rephrasing tip.

If the other provider is configured, every non-auth failure gets **"Retry with <other provider>"**. That rebuilds the request through `ContextAssembler` for the other model. The prompt is the same, but limits and sizes are recomputed.

Provider wording isn't parsed for advice. It's shown only under Details.

The OpenAI mapper switches on `error.code` (and `param`), not `error.type`: many 400s carry the newer `type: image_generation_user_error` (SP-5). A 401 body echoes a masked form of the key with some characters visible, so that fragment is redacted before `raw` is stored or shown. **As built (Phase 2):** SP-5's echo had no `sk-` prefix (`bookbook****…-key`), so `Redaction.redactMaskedKeys` replaces any key-like token containing four or more asterisks.

### 7.12 Networking (BBNet)

- `URLSessionConfiguration.ephemeral`, with `timeoutIntervalForRequest = 300` and `waitsForConnectivity = false`. HTTP/2 is the default.
- A multipart encoder for OpenAI `/images/edits`, and JSON encoding throughout.
- The API key is read from the Keychain for each request and set only in the `Authorization` header (OpenAI) or the `x-goog-api-key` header (Gemini, never as a query parameter, so it can't end up in URL logs).
- Logging uses `os.Logger`. Request and response bodies are never logged. Hosts, status codes, durations and token counts are logged with `privacy: .public`; everything else is private.
- Tests use `FixtureHTTPClient`, which replays recorded, redacted JSON. A separate `LiveProviderTests` suite runs only when `BOOKBOOK_LIVE_TESTS=1` and keys are present.

---

## 8. Layout, text and rendering (BBLayout)

### 8.1 Page sequencing (§8.5)

`PageSequencer` maps `Book.pageOrder` to physical positions:

- The cover stands alone, in position 0.
- Story page 1 is a **right-hand** page. After it, pages pair up as (2, 3), (4, 5), and so on.
- A page using a spread template takes two consecutive positions and must start on an **even** (left) position.

For any reorder, insert or delete, the sequencer works out the resulting layout before the command runs. If a spread would end up split across sheets, the UI warns and offers a variant of the command that inserts a blank page (using the built-in text-only template) in the right place. Both variants are single undoable commands.

Page numbers come from physical positions, the style's starting number, and its skip rules: cover, front-matter roles, and specific pages.

### 8.2 Geometry

- `PageGeometry` takes `PageSetup` and returns:
  - the trim size;
  - the bleed amount (0 when bleed is off);
  - the margins and safe area (trim inset by margins, and by at least 0.125 in when bleed is on);
  - for spreads, the fold position.
- A box's **render rect** is its normalized frame times the trim size, with each edge in `bleedEdges` pushed out by the bleed. That's how turning bleed on "slightly enlarges full-bleed boxes" (§8.2) without changing the stored data.
- Rotation and corner radius are applied as transforms and clip paths at draw time. Hit-testing uses the inverse transform.
- **Fold rule (Phase 7):** on a spread, a box edge lying on the fold (within 0.5 pt) gets no bleed even if it's in `bleedEdges`, so a half-spread full-bleed box never spills onto the facing page (`PageGeometry.pushedBleedEdges`; `BookContent.boxAspect` uses the same rule).
- **Rotation centre (Phase 7):** rotation is about the *render rect's* centre (bleed-extended when bleed is on) in `PageRenderer`, the page canvas and the template editor alike.
- **Guides (Phase 7):** `PageRenderer.drawGuides` (screen only) draws the trim line when bleed is on, one safe area per page half, and box outlines; both editors use it. With bleed on, the page canvas shows the bleed area around the trim.

### 8.3 Text layout

- `TextBoxLayout` holds an `NSTextContentStorage` and an `NSTextLayoutManager` with a fixed-size `NSTextContainer`. The size comes from the box's render rect, minus the padding of its background panel.
- **Overflow:** the box overflows if `usageBoundsForTextContainer` is taller than the container, or if the last layout fragment doesn't reach the end of the document. The canvas shows a red "+" badge, and preflight lists the box.
- **Rendering:** each `NSTextLayoutFragment` is drawn with `draw(at:in:)` into the target `CGContext`, wrapped in an `NSGraphicsContext`. In a PDF context, glyphs stay real text and fonts are embedded as subsets by Core Graphics.
- **The TextKit 1 trap:** code must never touch `NSTextView.layoutManager`, because doing so permanently switches that view to TextKit 1 and breaks the shared layout path. A debug assertion watches for the switch notification.
- **As built (Phase 2):** `RichTextBridge` uses a family's real bold/italic faces when they exist and otherwise fakes them (stroke width for bold; for italic a sheared font matrix, since TextKit 2 ignores the `.obliqueness` attribute when drawing, fixed in Phase 4), so the flags survive a round trip. As of Phase 4 the flags toggle relative to the run's base face (§4.2): reading back, a run is bold/italic only if its drawn trait differs from the base face's, and writing, a flag on a bold/italic base face removes the trait (a family with no such face draws its base face). A missing font falls back to the system font, and the requested PostScript name is kept in a private attribute so it round-trips. When text overflows, lines that don't fully fit aren't drawn (no half-cut lines).
- **Fonts:**
  - Installed fonts are referenced by PostScript name.
  - Imported fonts are copied into `fonts/` and registered with `CTFontManagerRegisterFontURLs(…, .process, …)` when the book opens.
  - A missing font falls back to the system font, with a book-level warning and a preflight issue.
  - Fonts whose OS/2 `fsType` forbids embedding are flagged when they're imported.
- **Editor and renderer share container settings:** the inline `NSTextView` uses the same `lineFragmentPadding` (0), `textContainerInset` (zero), width, and paragraph and hyphenation settings as `TextBoxLayout`. `NSTextView` defaults to a padding of 5, which would make the editor wrap differently from the page (SL-1).
- **Spelling and grammar:** `NSTextView`'s continuous checking covers live editing. On TextKit 2 the markers are rendering attributes on the `NSTextLayoutManager` (`.spellingState`), not in the text storage. Continuous checking needs a running `NSApplication`, so tests of it are app-hosted (SL-2). Preflight runs `NSSpellChecker.check(_:range:types:options:…)` over every text box in the background (§8.8 "spelling").

### 8.4 PageRenderer

```swift
struct PageRenderer {
    func draw(_ spreadOrPage: RenderUnit,       // page, spread, or one half of a spread
              into ctx: CGContext,
              options: RenderOptions)           // .screen / .thumbnail / .pdf(trim|bleed) / .print;
                                                // guides, image source (downsampled|full), marks
}
```

Each page is drawn in this order:

1. The background.
2. Image boxes, in layer order. Each one is clipped to its rect and corner radius, and has the image drawn with its placement transform.
3. Text boxes, with background panels first and then the text.
4. The page number.
5. Overlays, on screen only: trim line, safe area, fold and guides.

Hit-testing follows this draw order: text boxes (topmost last in layer order) are hit before any image box, then image boxes in reverse layer order (`BoxHitTesting.box`).

For export, the renderer fetches pre-processed bitmaps from `ExportImagePreparer` (§9.2), so the renderer itself never resamples.

---

## 9. Export and print (BBExport)

### 9.1 Pipeline

```
Book snapshot ─▶ PageSequencer ─▶ Imposition (standard | printShop | booklet)
             ─▶ ExportImagePreparer (crop → required px @300 DPI → upscale if needed → JPEG/PNG encode, cached)
             ─▶ PageRenderer into CGPDFContext ─▶ .pdf  (or PDFDocument.printOperation for Print)
```

- The export works from a `Sendable` `BookContent` snapshot, with progress reporting and cancellation. The UI stays usable. Image preparation (decode, crop, upscale, encode) runs off the main actor in the `ExportImagePreparer` actor. Page drawing stays on the main actor because TextKit 2 layout is `@MainActor` (§8.3): `BookExporter` draws one page per step and suspends in between, so the UI keeps responding (Phase 14 decision).
- For export, the renderer draws each box's prepared bitmap (`PreparedImageSource`, keyed by `BoxImageKey`) filling the box's render rect, rather than resampling the source image itself.
- **Standard:** the media box is the trim size. No bleed.
- **Print shop** (bleed must be on):
  - The media box is the trim plus the bleed plus a 0.25 in mark area. `TrimBox` and `BleedBox` are set as PDF box attributes.
  - Crop marks are drawn in the mark area, offset from the bleed.
- **Spreads:** either exported as single pages (the default; each half is rendered with a clip and offset) or as double-width pages (§8.8 options).
- **Single-page or image export (PNG/JPEG):** the same renderer draws into a `CGBitmapContext` at 300 DPI.

### 9.2 Image preparation for 300 DPI (§8.8)

For each placed image:

1. Work out the **required pixels**: the box's render-rect size in inches × 300.
2. Work out the **available pixels**: the crop of the source after zoom.
3. If available < required, upscale the crop with `CoreImageUpscaler` (`CILanczosScaleTransform`, then `CISharpenLuminance` at about 0.4). Otherwise downsample with Lanczos.
4. **Softness warning** when the upscale factor is above 2.5×, or the source crop is under 600 px on its short side. These thresholds are tunable constants. Preflight lists the image, and "Preview upscaled" shows the result at 100%.
5. Encode as JPEG at quality 0.92, or PNG when the image has alpha. The result is cached in `~/Library/Caches/BookBook/<bookID>/export/<hash>-<px>.jpg`.

```swift
protocol Upscaler: Sendable {
    func upscale(_ image: CGImage, to size: CGSize) async throws -> CGImage
}
```

A Core ML implementation can be added later without changes elsewhere (D11).

### 9.3 Booklet imposition

- Pages, including the cover unless it's excluded, are padded with blanks to a multiple of 4. The number added is reported to the user.
- Story pages keep `PageSequencer`'s side (odd position = right = odd booklet page): a blank inside front cover follows the cover, or a leading blank precedes a range that starts on an even position. These count in the reported blanks.
- For `n` pages and sheet side `s`, pages are paired as (n − 2s, 1 + 2s) on the front and (2 + 2s, n − 1 − 2s) on the back, for s = 0…n/4 − 1, using 1-based page numbers.
- Each half-sheet slot holds one page, scaled to fit and centred when the page size doesn't fit two-up exactly (§8.8, with a notice). 5.5×8.5 in on Letter and A5 on A4 fit at 100%.
- Sheet sizes: Letter, A4, Tabloid, A3. The output dialog shows printing instructions, "Print double-sided, flip on short edge" for both orientations (the fold is always parallel to the sheet's short edge).
- When the cover is excluded, it can be exported separately as a single page for printing on card.

### 9.4 Preflight (§8.8 "Before export")

`Preflight.run(snapshot) -> [Issue]` checks for:

- empty image boxes;
- text overflow (via `TextBoxLayout`);
- spelling (via `NSSpellChecker`);
- images that will look soft (via §9.2);
- style, asset or layout changed flags;
- consistency warnings;
- missing fonts.

Each issue carries a navigation target (page, box). The export sheet lists them grouped, with "Export anyway".

---

## 10. Features mapped to components

| Product section | Main components |
|---|---|
| §8.1 Library, import between books | `LibraryIndex`, `BookStore`, `BookImporter`, `LibraryView` |
| §8.2 Style tab, presets, page setup changes | `StyleGuide`, bundled `StylePresets.json` (with sample images), `PageGeometry`, derived flags |
| §8.3 Assets, character sheet, where-used | `Asset`, `CharacterSheet`, `ReferenceSelector` (§7.4), `UsageIndex`, sessions |
| §8.4 Layouts, AI templates, visual editor | `Template`, bundled `TemplatePresets.json`, `LayoutProvider`, `CanvasView` editing mode |
| §8.5 Pages, order, story import, draft-all | `PageSequencer`, `StoryTextImporter` (plain/RTF via `NSAttributedString(url:)` → split at blank lines or a marker → preview), `GenerationQueue` batch |
| §8.6 Page editor, sessions | `CanvasView`, `TextBoxLayout`, session panel, `ContextAssembler`, provider adapters, region editor |
| §8.7 Cover | A `Page` with kind `.cover`, a cover template whose title and author boxes (`BoxRole`) are bound to book settings |
| §8.8 Export and print | BBExport (§9) |
| §8.9 Consistency | `VisionProvider`, a follow-up `QueueItem`, `ConsistencyResult` on `Version` |
| §8.10 Undo | §6.3 |
| §8.11 Settings | SwiftUI `Settings` scene, `KeychainStore`, `ModelCatalog`, `PriceList` |
| §8.12 Book settings, clean-up | Ledger aggregation; `CleanUp` computes the deletable set (unstarred versions not referenced by any placement, reference slot or sheet item) and the bytes freed, from the image files only those versions use |
| §8.13 First run, wizard, sample | `OnboardingFlow` (keys → test → typical costs from the price list), `NewBookWizard`, bundled sample |

---

## 11. Security and privacy

- **Keys:** stored only in the Keychain (§5.5). They never appear in book files, the queue file, logs or error Details. Removing a provider deletes its item.
- **Network surface:** the only hosts contacted are `api.openai.com` and `generativelanguage.googleapis.com`. There is no telemetry, crash reporting or update checking. Crash reports go only to Apple's system crash reporter, if the user has it turned on in macOS.
- **What gets sent** is exactly what `ContextAssembler` builds (§7.3), and it's shown in Version details. Gemini requests carry `store: false` (§7.6).
- **Real-person photos (§3):**
  - The import dialog for a reference asks "Is this a photo of a real person?" (on by default for camera-originated images, detected from EXIF). The answer is stored on the version as `depictsRealPerson`.
  - The first time such an image would be sent to a provider, the app shows the notice with that provider's data-policy link and records the acknowledgement for each provider.
  - The flag also drives refusal advice (§7.11).
- **Hardened runtime:** no JIT, no unsigned executable memory, no `disable-library-validation`.
- **Entitlements:** none beyond the hardened-runtime defaults, because the app isn't sandboxed (§13.3).

---

## 12. Testing strategy

| Layer | Approach |
|---|---|
| BBModel | Unit tests for derived flags, the usage index, mention rewriting and RichText round-trips |
| BBStore | Round-trip encode/decode; migration fixtures (one per schema version); **fault injection** that "crashes" at every step of a save and checks that reopening gives either the old or the new state; lock handling; importer de-duplication and name clashes |
| BBLayout | Geometry and bleed maths; `PageSequencer` cases (spread splits, blank insertion); TextKit overflow; snapshot-rendered pages (PNG, with per-pixel tolerance) |
| BBAI | `ContextAssembler` **prompt snapshots**; `ReferenceSelector` tables; aspect fitting for each catalog model; cost estimator against the official calculator figures; error mapping from recorded fixtures; queue state machine (cancel, retry, persist/restore, follow-ups) |
| Providers | Recorded fixtures for success, refusal, rate-limit, billing and malformed responses; opt-in live tests (`BOOKBOOK_LIVE_TESTS=1`) for each model, including **mask polarity** and **Gemini thought-signature continuity** |
| BBExport | Booklet ordering for n = 4…32; PDF box attributes; font embedding (parsing the output PDF); upscaler thresholds |
| UI | A small XCUITest smoke suite: open the sample book, edit text, undo, export a PDF. Most behaviour is tested below the UI. |

CI runs everything except the live tests on each push.

---

## 13. Build, signing, release and distribution

### 13.1 Project

- The Xcode project uses `.xcconfig` files (Debug, Release).
- `BookBook.xcodeproj` is generated by XcodeGen (2.46.0, pinned) from `project.yml` at the repo root. Both are committed, so a fresh clone opens in Xcode without XcodeGen; CI regenerates the project and fails if it differs from the committed one (Phase 1b).
- Bundle ID `app.bookbook.BookBook` (placeholder; it needs your Developer ID team).
- `MARKETING_VERSION` comes from the git tag `vX.Y.Z`. `CURRENT_PROJECT_VERSION` is the CI run number.

### 13.2 Release workflow (GitHub Actions, `xcode-27` runner, triggered by a `v*` tag)

The repository is **public** (decided 2026-11-07): macOS Actions minutes are free, and the cask can download release zips without a token. A Developer ID Application certificate is available.

1. Check out the code and select Xcode 27.x.
2. Create a temporary keychain and import the Developer ID Application certificate from repository secrets (GitHub's documented flow).
3. `xcodebuild archive`, then `-exportArchive` with Developer ID signing and the hardened runtime.
4. `ditto -c -k --keepParent BookBook.app BookBook.zip`
5. `xcrun notarytool submit BookBook.zip --key AuthKey.p8 --key-id … --issuer … --wait`. On failure, fetch `notarytool log`.
6. `xcrun stapler staple BookBook.app`, then **zip again** (a zip can't be stapled; the app inside it can).
7. `shasum -a 256` the final zip, then create the GitHub Release (with release notes from the tag) and upload the zip.
8. Bump the cask in the personal tap (a `homebrew-tap` repo with `Casks/bookbook.rb`) by editing `version` and `sha256` and committing with a fine-grained PAT. As an alternative or backstop, run `Homebrew/actions/bump-packages` on a schedule with a `livecheck` block.
9. Delete the temporary keychain (`if: always()`).

### 13.3 Cask and sandbox notes

```ruby
cask "bookbook" do
  version "1.0.0"
  sha256 "…"
  url "https://github.com/buckleypaul/bookbook/releases/download/v#{version}/BookBook.zip"
  name "BookBook"
  desc "Make illustrated children's books with AI image generation"
  homepage "https://github.com/buckleypaul/bookbook"
  livecheck do
    url :url
    strategy :github_latest
  end
  depends_on macos: :<macos-27-symbol>   # bare-symbol form means "this or newer"; the ">= :x" string form is deprecated. Check the macOS 27 symbol in current Homebrew
  app "BookBook.app"
  zap trash: [
    "~/Library/Preferences/app.bookbook.BookBook.plist",
    "~/Library/Caches/BookBook",
    "~/Library/Application Support/BookBook/library-index.json",
    "~/Library/Application Support/BookBook/queue.json",
    "~/Library/Application Support/BookBook/pricelist.json",
  ]
end
```

- `auto_updates` is **left out**, which is the same as false. Updates come only through `brew upgrade` (§3).
- **The zap list deliberately leaves out `…/BookBook/Library/`**, so `brew uninstall --zap` never deletes the user's books. The same reasoning is behind D12. A sandboxed app's container (`~/Library/Containers/<id>`) is normally zapped whole, and it would also put the library somewhere hard to find for "back up by copying" (§8.1). Being unsandboxed also makes it simpler to choose a library location, trash books, register fonts and print. Hardened runtime and notarization still apply.
- **Getting into homebrew-cask** (later, §4) needs notarization (already done) plus notability: for a self-submitted app, 225 stars, 90 forks or 90 watchers, and a repo at least 30 days old. The app must also work on the latest macOS (27 today).

---

## 14. Risks and things to verify during implementation

| Risk | Mitigation |
|---|---|
| Model churn: OpenAI retired `gpt-image-1` on 2026-10-23 and removes 1.5/mini on 2026-12-01; Gemini deprecated two image models in 2026 | Data-driven catalog with successors, list-models availability checks, the custom-model escape hatch (§7.1). SP-1: all seed models are listed, and list-models returns `shutdown_date`, which the check can use to mark models deprecated early |
| Prices drift | A dated price list the user can edit, actual-cost-from-usage where it's available, and "estimate" labels |
| OpenAI mask polarity isn't documented | **Partly resolved (SP-4):** the API replaces the transparent area, but the result is often black and edits land outside the mask. Local compositing (§7.6) is mandatory, and the approach is **open and blocking for Phase 11** |
| Gemini thought-signature requirements are documented inconsistently | Always echo signatures; fall back once to stateless on `MISSING_THOUGHT_SIGNATURE` |
| Gemini inline request limit: the docs say both 20 MB and 100 MB | Design for 20 MB |
| Cancellation billing is undocumented for both providers | Assume it's billed (§7.9), as the product already tells the user. OpenAI: SP-6 cancelled a request at 2026-11-07 23:39 UTC, and the dashboard check is a Phase 0 hand check |
| OpenAI organization verification can block GPT Image with a 403 | A dedicated `.verificationRequired` error with steps |
| TextKit 2 silently falling back to TextKit 1 | Never touch `layoutManager`; debug assertion (§8.3). SL-2: no fallback with continuous spelling and grammar, and the notification observer is proven to work |
| Brief differences between on-screen and PDF text layout | One TextKit 2 layout path; PDF snapshot tests. SL-1: PDF positions are within 0.13 pt of TextKit's, and fonts are embedded as subsets. Tests use `PDFPage.selection(for:)`, not `characterBounds(at:)` |
| `depends_on macos:` symbol for macOS 27 | Use the bare-symbol form; check the macOS 27 symbol against current Homebrew when the cask is written |
| Long Gemini histories with 4K images exceed the budget | Native history caps (§7.6), with automatic stateless mode |

---

## 15–16. Moved

The findings for `product-description.md` (§15) and the decision log (§16) now live in `architecture-decisions.md`.
