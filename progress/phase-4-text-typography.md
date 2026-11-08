# Phase 4 — Text and typography (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-4-text-typography` · PR [#8](https://github.com/buckleypaul/bookbook/pull/8) · live spend **$0.00**.

**Hand checks (user, 2026-11-08):** all passed.
- [x] BOOM! 48 pt red bold in another font; the PDF matches the screen and the text is selectable.
- [x] Changing the body font changes unformatted text; BOOM! keeps its font.
- [x] An imported `.ttf` still shows in the exported PDF.
- [x] Overflow badge appears; type, pause, type, then undo twice restores in two steps.
- [x] Switching pages and back keeps undo working, with no crash.


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
