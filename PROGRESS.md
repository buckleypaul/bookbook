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
| 3 | Storage and library | done | `phase-3-storage-library` | [#7](https://github.com/buckleypaul/bookbook/pull/7) | $0.00 | No live checks. [Log](progress/phase-3-storage-library.md) |
| 4 | Text and typography | awaiting hand checks | `phase-4-text-typography` | [#8](https://github.com/buckleypaul/bookbook/pull/8) | $0.00 | No live checks. |
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

### Phase 5
- Cover editing/export and page numbers (from Phase 2).
- Hand-check the title-box bold state once cover/title boxes are editable: B shows on over the bold title face, and pressing it gives the regular weight (from Phase 4).

### Phase 7
- Typography form: the body-font menu is stale after Import Font… until the sheet reopens; the "Alignment" label wraps; Escape loses a typed size that wasn't committed; a pending colour commit can fire after the sheet closes (from Phase 4).

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
- Format bar: the colour picker adds one undo step per colour-panel change (debounce it like the Typography form); there's no typed size field, only ±1 pt steps (from Phase 4 review).
- Importing a font clears only that window's layout cache and missing-font list; other open books keep stale fallback layouts and banners (from Phase 4 review).
- Pasted rich text keeps attributes the model drops (kerning, paragraph spacing, links) in the editor until reload; pasted text with no requested font still uses the family match (from Phase 4).
- `refreshMissingFonts()` walks every page on each undoable edit, but isn't refreshed on coalesced typing, so a paste that brings in a missing font shows no banner (from Phase 4).
- The `fsType` embedding check runs only on import: a restricted system font picked from the menus isn't flagged, and bitmap-only embedding (bit 9) isn't checked (from Phase 4 review).
- A trailing empty paragraph loses its alignment and formatting on a round trip; a family with only a bold face stores `bold: true` but can't draw it (consider disabling B) (from Phase 4).
- `BookEditorLayoutTests` opens a real `NSWindow` (it needs a GUI session) and depends on the measured 830 pt SwiftUI minimum; it doesn't test widened sidebar or inspector panels with a narrow window (from Phase 4 review).
- The export save panel's default folder carries over from the font-import panel (from Phase 4 hand checks).
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
- `BookLock.acquireHold` holds the process-wide `Mutex` across file I/O and a blocking `flock`; the lock refcount key uses `standardizedFileURL` (no symlink resolution); a `BookStore` dropped without `releaseLock()` leaks its count so `.lock` stays until exit (from Phase 3 review).
- Library grid thumbnails are blank white for empty books (check once books have content) (from Phase 3 hand checks).

## Current phase log

The running phase writes its log here; when it is marked done, move the entry to `progress/phase-<id>-<slug>.md`.

### Phase 4 — Text and typography

**Stage:** B (done; awaiting hand checks)

**Session A (2026-11-08):** contracts on the branch (`TextFormatting.swift`, `Fonts.swift`, `BookStore+Fonts.swift`, `TextBoxLayoutCache`, `Typography.resolved(for:)`, `BookCommand.setRichText(…, coalescing:)` and `.setTypography`). Four lanes merged:
- A (opus): `TypingCoalescer`, coalesced undo in `BookDocument.perform`, `.setTypography`, font registration on open, `importFont`, `missingFonts`, `InlineTextEditor` as `TextFormatTarget`, layout cache and red "+" overflow badge in `CanvasView`, title-role typography.
- B (sonnet): `FontInspector` (fsType), `FontRegistry`, `FontAvailability`, LRU `TextBoxLayoutCache`, `PageRenderer.layouts` and title role; fixed a missing-font + bold/italic round-trip bug; empty text no longer overflows. Property, overflow-edge, screen-vs-PDF and font-embedding tests.
- C (sonnet): `fonts/<sha256>.<ext>` store; orphan sweep never touches `fonts/`.
- D (sonnet): `FormatBar`, Format menu (⌘B/I/U, ⌘+/-, ⌘{ ⌘| ⌘}), `TypographyForm` sheet (toolbar "Typography" button, Format ▸ Typography…) with Import Font…, `MissingFontsBanner`.

At the end of Session A, `swift test` (all targets) is green and the app builds with xcodebuild. Nothing has been checked by hand or reviewed yet.

**For Session B:**
- The typography form is a sheet; the full Style tab is Phase 7.
- `fontFileURLs()` returns `/private/var/...` while `storeFont` returns `/var/...`, so compare font URLs by file name.
- `missingFonts` isn't refreshed on coalesced typing edits.
- A trailing empty paragraph loses its alignment and formatting on a round trip.
- Undo tests spin the run loop once per keystroke (`TestRunLoop`), so watch them for flakiness in CI.
- No live checks this phase.

**Session B (2026-11-08):**
- **CI locally:** `scripts/test.sh all` is green with no Swift warnings, before and after the fixes.
- **Review must-fixes (two rounds, all fixed):**
  - Title runs saved as bold because the title face (`AvenirNext-Bold`) is bold. Bold and italic are now relative to the run's base face, and the format bar shows the drawn traits (`RichTextBridge.drawnTraits`).
  - A title run set to a sibling face of the title family lost its font override on read-back. The family match now applies only to runs with no requested font.
- **Hand-check blocker, fixed:** opening any book crashed the app (SIGABRT, a split-view constraint loop).
  - Cause: the format bar's rigid width (~615 pt) left the detail column no room, and the 760 pt window minimum was below the editor's real 830 pt.
  - Fix: the format bar is in a horizontal scroll view, the window minimum is 840, and new book windows open at 1200×780.
  - `BookEditorLayoutTests` hosts the editor in a real window so CI catches this.
- **Also fixed:** fake italic. TextKit 2 ignores `.obliqueness`, so italic now uses a slanted font.
- **Automated hand checks (sonnet, System Events):**
  - Passed: 1 (BOOM! 48 pt red bold American Typewriter; the PDF matches the screen, has selectable text and embedded fonts), 2, 4, 5, plus ⌘B/I/U, the format bar and spell-check.
  - Check 3: the imported Atkinson font is embedded in the PDF, but it was never installed system-wide, so the "remove it from the system" step wasn't exercised.
  - The title-box bold state couldn't be reached (no cover editing until Phase 5).
- **Docs changed:** architecture.md §4.2 and §8.3 (relative bold/italic, drawn-trait button state).
- **Live spend:** $0.00.
