# Phase 3 — Storage and library (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** books are durable, browsable and manageable, like real documents.

**Scope:** A §5.1–5.3, §5.4 (except `BookImporter` and the sample book, which are Phase 16), §5.5, and §6.1 (several windows, `OpenBooks`). Headless `BookStore` opening is built here; `BookWriter` deliveries into closed books use it in Phase 9. PD §8.1 (except import from another book, which is Phase 16), §7 (book switcher).

**Deliverables**
- Fault-injected save tests at every step. `.lock` single-writer handling with a read-only offer.
- `Migrator` framework with a schema v1 fixture.
- Orphan image sweep (more than 24 h old, at open).
- `costs.jsonl` append and repair primitive (used from Phase 9).
- `LibraryIndex` with `FSEvents` and the cached index.
- Library grid with cover thumbnails and modified dates. Rename, duplicate, delete to Trash, Show in Finder.
- Library location setting, with an offer to move the books.
- One window per book (from SL-3). A sidebar book switcher. Several books open at once.
- Reopen the books that were open at quit, whatever the macOS window setting (PD §8.1, A §6.1: `OpenBooks` list plus `openWindow(value:)`).
- Thumbnail and downsample cache in `~/Library/Caches/BookBook/<bookID>/`.

**Acceptance (by hand)**
- Make three books. Duplicate one, rename one, delete one: it appears in the Trash, and Put Back restores it to the library grid.
- Copy a `.bookbook` into the library folder in Finder: it appears in the grid without a relaunch.
- Type in a book and force-quit (Activity Monitor ▸ Force Quit) within a second of the edit. Reopen: you get either the state before the edit or after it, never a broken book.
- Open the same book twice (double-click it twice): one window comes to the front.
- With the macOS default setting ("Close windows when quitting an application" on), open two books and quit with ⌘Q. Relaunch: both books reopen, each in one window. Repeat with ⌥⌘Q: still one window each, no duplicates. Delete one of them while the app is closed: relaunch opens the other with no error.
- Change the library location and accept moving the books: they all appear in the grid at the new path.

**Tests added:** fault injection (crash after each of the 5 save steps × 3 entity mixes), lock handling, migration from the v1 fixture, ledger truncated-line repair, LibraryIndex refresh, delete going to the Trash, and the open-books list (kept through quit, unresolvable IDs dropped).

**Risks:** FSEvents noise from the app's own saves (filter events during own writes). Lock files left behind by crashes (check whether the recorded PID is still alive).
