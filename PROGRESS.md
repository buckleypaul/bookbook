# BookBook — Build Progress

Updated by each phase session (see `implementation-plan.md` §2.6). Phases are listed in execution order.

**Statuses:** `not started` · `in progress` · `awaiting hand checks` · `done` · `blocked` · `skipped (floating)`

**Live API spend so far:** $0.45 of the $10.00 cap (`LiveSpendGuard` estimate; check it against the provider dashboards).

| Phase | Name | Status | Branch | PR | Live spend | Notes |
|---|---|---|---|---|---|---|
| 1a | Bootstrap (gitignore, hooks, key scripts) | done | `phase-1a-bootstrap` | [#1](https://github.com/buckleypaul/bookbook/pull/1) | $0.00 | Repo and remote were created on 2026-11-07. [Log](progress/phase-1a-bootstrap.md) |
| 0 | Live-API spikes and fixtures | done | `phase-0-spikes` | [#2](https://github.com/buckleypaul/bookbook/pull/2) | $0.44 | OpenAI + local spikes; Gemini spikes (§4.2) moved to Phase 13. [Log](progress/phase-0-spikes.md) |
| 1b | Project setup and CI | done | `phase-1b-setup-ci` | [#3](https://github.com/buckleypaul/bookbook/pull/3) | $0.00 | XcodeGen project; CI on `xcode-27`. [Log](progress/phase-1b-setup-ci.md) |
| 2 | Thin vertical slice (M1) | done | `phase-2-thin-slice` | [#4](https://github.com/buckleypaul/bookbook/pull/4) | $0.006 | [Log](progress/phase-2-thin-slice.md) |
| 3 | Storage and library | in progress | `phase-3-storage-library` | | | |
| 4 | Text and typography | not started | | | | |
| 5 | Pages tab, ordering and cover | not started | | | | |
| 6 | Template editor | not started | | | | |
| 7 | Style guide and page setup | not started | | | | |
| 8 | Sessions and versions | not started | | | | |
| 9 | Queue, cost, errors and settings (M2) | not started | | | | |
| 10 | Assets and character sheets | not started | | | | |
| 11 | Region editing | not started | | | | |
| 12 | Consistency check and AI templates (M3) | not started | | | | |
| 13 | Gemini provider (floating) | not started | | | | Needs the `gemini-api-key` Keychain item |
| 14 | Export and print | not started | | | | |
| 15 | Release pipeline (M4) | not started | | | | |
| 16 | Import, book settings, onboarding, sample | not started | | | | |
| 17 | Hardening and v1.0 (M5) | not started | | | | |

## Standing decisions

Facts later phases depend on. Detail is in the logs under `progress/`.

- The cover page is created with every book (`Book.coverPageID` is valid) but is hidden, not edited and not exported until Phase 5 ([Phase 2](progress/phase-2-thin-slice.md)).
- The app accepts a `-BookBookLibraryRoot <path>` launch argument (argument domain only, never saved) for throwaway libraries in automated runs ([Phase 2](progress/phase-2-thin-slice.md)).
- BBAITests prompt snapshots live in `Tests/BBAISnapshots/`; BBLayoutTests excludes `__Snapshots__` ([Phase 2](progress/phase-2-thin-slice.md)).
- Page commands never touch sessions; TextKit 2 layout, rendering and export are `@MainActor` for now ([Phase 2](progress/phase-2-thin-slice.md)).
- Gemini spikes (SG-1...SG-8) moved to the start of Phase 13; there is no `gemini-api-key` yet ([Phase 0](progress/phase-0-spikes.md)).
- Books always reopen at relaunch (decided 2026-11-07; PD §8.1, A §6.1, Phase 3) ([Phase 0](progress/phase-0-spikes.md)).
- OpenAI masked edits are unreliable; the region-edit approach is chosen in Phase 11 ([Phase 0](progress/phase-0-spikes.md)).

## Open follow-ups

Collected from the finished phase logs. Remove an item when it is done; add new ones from the running phase.

### Phase 3
- Reopen books at relaunch (from Phase 2).
- `.lock` (from Phase 2).
- Image sweep (from Phase 2).
- Thumbnails (from Phase 2).
- The library index (from Phase 2).

### Phase 4
- Coalesce typing undo (today each keystroke is one undo step) (from Phase 2).
- The overflow badge (from Phase 2).
- Title-role typography (from Phase 2).
- A missing-font warning (from Phase 2).
- Cache `TextBoxLayout` (it's rebuilt every draw) (from Phase 2).

### Phase 5
- Cover editing/export and page numbers (from Phase 2).

### Phase 8
- Edits/references/masks in the OpenAI adapter (from Phase 2).
- Separate "inspect" from "place" in the version strip (from Phase 2).

### Phase 9
- Retries and `Retry-After` (from Phase 2).
- The queue window (`QueueView` is still the stub) (from Phase 2).
- Queue persistence (from Phase 2). A failed generation's error lives only in the in-memory queue, so after relaunch the message shows no error; persist it with the queue (from Phase 2, listed there under Phase 3).
- Check the transient mapping of `HTTPClientError.transport` (from Phase 2).
- Unclassified 403s map to `.unknown` (from Phase 2).
- Measure the input tokens for a 1536×1024 reference (from Phase 0).
- Check the `gpt-6-luna` / `gpt-6.1-terra` per-token prices (placeholders in the seed) (from Phase 0).
- Transport errors, such as timeouts on long generations, may still be billed, so record them as estimates, not $0 (from Phase 0).
- Add an offline test for cancellation mapping (from Phase 0, listed there under Phase 2 / BBNet; Phase 2 does not record it as done).
- A delivery to a book locked by another process (or open read-only here) stores nothing: the image is reported but lost unless the queue keeps it. Failed generations delivered there are only logged (`report()` skips non-success outcomes) (from Phase 3).
- A brief lock held by a delivery/snapshot makes a concurrent open in another process see "locked"; snapshots now queue behind opens/deliveries of the same book (from Phase 3).

### Phase 11
- **Blocking:** re-check OpenAI masked edits on a real illustration, and choose the region-edit approach (masked edit / unmasked edit plus composite / black-fill detection plus fallback) (from Phase 0).

### Phase 13
- Run SG-1...SG-8 first (from Phase 0).

### Phase 14
- Export off the main actor (from Phase 2).

### Phase 16
- A Finder copy of a package keeps the same `Book.id`; give one a new ID on detection (from Phase 3).
- A read-only open of an older-schema book has no in-memory migration (from Phase 3; or Phase 17).

### Later
- **CI flake:** `ReviewFixTests` (`autosaveHandlerReportsSuccessAndFailureAndKeepsPending`, `scheduledSaveCompletesAfterStoreReferenceIsDropped`) failed once on the CI runner, then passed on a re-run and 5/5 locally. They're timing-sensitive; wait on a condition instead of a fixed delay. (from Phase 2 merge, 2026-11-08)
- The canvas loads images synchronously on the main thread (move to an actor `ThumbnailCache`) (from Phase 2).
- Calm-area guidance only for overlapping text boxes, not adjacent ones (from Phase 2).
- A test that every prompt template key exists (from Phase 2).
- Versions dropped as invalid on load can leave dangling placements, which resolve to nil (from Phase 2).
- Hand check 6 wording: it should name where macOS 27 keeps saved state, since the `Saved Application State` path doesn't exist (from Phase 2).
- `live-tests.sh` exits 0 when no test matches the filter (SwiftPM prints "No matching test cases were run"); make the spend guard or the suite report counts (from Phase 1a, 0 and 1b).
- The secret scan doesn't decode UTF-16 files (e.g. `Localizable.strings`); revisit if the app ever stores such files with secrets nearby. GitHub push protection is the backstop (from Phase 1a).
- App icon and `UTTypeIcons` for `.bookbook` documents are placeholders (Finder shows a generic package icon) (from Phase 1b).
- The `xcode-27` runner image is "preview", and Xcode 27.2 is an RC there; the `xcode-select` path may change (from Phase 1b).
- `actions/checkout` v4.2.2 / `actions/cache` v4.2.0 are Node 20 actions; bump them when GitHub retires Node 20 (from Phase 1b).

## Current phase log

The running phase writes its log here; when it is marked done, move the entry to `progress/phase-<id>-<slug>.md`.
- Library actions have no menu-bar items (`BookBookCommands.swift`) (from Phase 3).
- A restored window for a deleted book may flash briefly after ⌥⌘Q (from Phase 3).
- `LibraryIndex` FSEvents context uses `passUnretained` with no retain/release; an in-flight callback during `stop()` could touch a freed box (from Phase 3 review).
- The app's own autosaves trigger full library rescans (the "filter own writes" risk isn't really handled) (from Phase 3 review).
- Lock liveness: a reused PID keeps a stale lock "live" forever, and foreign-host locks can never be taken over; compare process start time with `acquiredAt` (from Phase 3 review).
- `storeImage` returns early on an existing file without touching its mtime, so a just-stored image identical to a >24 h orphan can be swept before its JSON is saved (from Phase 3 review).
- Read-only `load()` skips recovery, so it can show a half-applied save from the writer; read staged files of a committed transaction or retry (from Phase 3 review).
- Rename racing a closing window falls back to a background rename outside OpenBooks' per-book ordering; the closing flush can overwrite the new title (from Phase 3 review).
- `Library.trash`/`duplicate`/`moveBooks` ignore a foreign `.lock`; duplicate can copy mid-save and drops `.journal` (from Phase 3 review).
- Moving the library closes only books already in `documents`; a book mid-open reopens at the old URL (from Phase 3 review).
- Library grid thumbnails are blank white for empty books (check once books have content) (from Phase 3 hand checks).

### Phase 3 — Storage and library

**Stage:** B

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

**For Session B:**
- The xcodebuild app build/test passed in L4's worktree, but not yet on the merged branch.
- The lock/read-only UI was written against the stub. It's only truly exercised now that L1 has landed, so check it by hand: open the same library from a second app instance with `-BookBookLibraryRoot`, or plant a `.lock` with a live foreign PID/host.
- The worktrees `.claude/worktrees/agent-*` and branches `worktree-agent-*` / `worktree-l5-thumbnails` are merged; remove them when the phase is done.
- Candidate follow-ups from the lanes, to file in Session B:
  - Library actions have no menu-bar items (`BookBookCommands.swift`).
  - A Finder copy of a package keeps the same `Book.id`, so give one of them a new ID on detection (Phase 16 import?).
  - A read-only open of an older-schema book has no in-memory migration (Phase 16/17).
  - A restored window for a deleted book may flash briefly after ⌥⌘Q.
