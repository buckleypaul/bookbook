# Phase 3 — Storage and library (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-3-storage-library` · PR [#7](https://github.com/buckleypaul/bookbook/pull/7) · live spend **$0.00**.

Started 2026-11-08.

**Contracts (main thread, committed before the lanes):** `StoreError.locked/.readOnly`, `LockOwner`, `LockAcquisition`, `LibraryEntry.thumbnailURL` (+ Codable); stubs for the `BookStore` lock / read-only / thumbnail / sweep API, `Migrator`, `CostLedger`, `LibraryIndex`, the `Library` ops (duplicate, trash, rename, moveBooks), `ThumbnailCache` and `BookThumbnail`. BBStoreTests gets a `Fixtures/` resource folder.

**Assumptions (plan defaults):**
- Rename changes `Book.title` only; the package folder keeps its name. A closed book is renamed through a headless `BookStore`, an open one through its `BookDocument` (not undoable: it isn't in PD §8.10's list).
- The library location is saved in `UserDefaults` key `libraryPath` (A §5.5). The `-BookBookLibraryRoot` launch argument still wins. Moving the books needs every book window closed first (the app closes them after flushing).
- A book held by another live process opens read-only: editing is disabled and nothing is written (no journal replay, migration, sweep or ledger repair).
- The library thumbnail is the first story page while the cover is hidden (until Phase 5).

**Session A (2026-11-08): all lanes merged, the package builds and every package test passes (5 runs in a row).**
- **L1 store durability (opus):**
  - Fault injection at each of the 5 save steps × 3 entity mixes.
  - `.lock` (`BookLock.swift`: `link(2)` create, stale-PID takeover, re-entrant in-process) and read-only mode.
  - Orphan image sweep (`ImageSweep.swift`), `writeThumbnail`, and `load()` wiring (recover → migrate → ledger repair → decode → sweep).
  - **Fixed a Phase 2 bug:** a committed transaction that crashed partway through its renames was discarded on reopen.
  - The empty `.journal` folder is now removed after saves. That opened a race; it's fixed by making `recover()` tolerate a missing folder and skip this process's in-flight transactions.
  - ReviewFixTests' fixed sleeps became polling (the "CI flake" follow-up).
  - A test-only `PackageCoding.fullSync` task-local swaps `F_FULLFSYNC` for `fsync` in the crash suites.
- **L2 Migrator + CostLedger (sonnet):** `Fixtures/SchemaV1.bookbook`.
- **L3 LibraryIndex + Library ops (sonnet):** FSEvents uses `realpath` because FSEvents reports `/private/var/...`. `Library.rename` is `async` (contract change, main thread).
- **L4 app/UI (opus):**
  - Library grid, rename/duplicate/trash/Show in Finder.
  - `OpenBooks` keeps `openBookIDs` and reopens them at launch.
  - Lock alert with read-only banner; sidebar `BookSwitcher`; Settings ▸ General library location with a move offer (`LibraryLocation.resolve`).
  - Thumbnails written at most every 3 s and on close.
- **L5 ThumbnailCache + BookThumbnail (sonnet).**

**Session B (2026-11-08):**
- CI-equivalent run green on the merged branch (secret scan, bootstrap, kit tests, spikes, xcodegen check, app Debug build+test, Release build); no concurrency warnings.
- Review (opus) found 2 must-fix, fixed in two rounds (opus), each re-reviewed: background deliveries/snapshots/closed-book renames now take `.lock` inside `OpenBooks`' per-book queue (deliveries to a foreign-locked book write nothing and report "locked"; snapshots load read-only); stale-lock takeover serialized with `flock(2)` on the package folder, `.lock` read through one fd, release under the same `flock`, in-process lock refcounted per book. New `LockTakeoverTests` + `OpenBooksDeliveryTests` cases. `architecture.md` §5.3 updated.
- Contract change: `OpenBooks.rename` (AppModel routes renames through it); `BookLock.acquire(as:)` for tests.
- Hand checks driven by an agent (pre-fix build): 3 books, duplicate, trash, folder copy appears live, double-open → one window, ⌘Q/⌥⌘Q reopen without duplicates, deleted-while-closed book dropped, lock alert + read-only banner — all pass. Not driven: rename, Put Back, edit-then-force-quit (typing didn't reach the page), library-location move.
- Should-fix items from the review are filed under Open follow-ups (Phase 9, 16, Later).
- No live spend.

**Hand checks (2026-11-08, all driven by agents):**
- [x] Three books; duplicate, rename, delete to Trash, Put Back restores to the grid.
- [x] Finder copy into the library folder appears without relaunch.
- [x] Force-quit (`kill -9`) within ~0.4 s of an edit, 3×: the before-state reopened intact each time, lock taken over silently.
- [x] Double-open: one window comes to the front.
- [x] ⌘Q / ⌥⌘Q reopen both books, one window each; a book deleted while closed is dropped without error.
- [x] Library location move: books moved on disk and shown in the grid at the new path.

Driving note: System Events `click at` doesn't focus the canvas text box; a real CGEvent click does.
