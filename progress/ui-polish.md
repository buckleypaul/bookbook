# UI polish pass (2026-11-14)

Not a numbered phase. A sweep for rough edges, poor UI and inconsistencies across the whole app, run as an
orchestrated set of subagents on branch `ui-polish`, merged into `main` the same day. No live API calls ($0.00).

## How it ran

1. **Audit.** Five agents read the UI source by area (shell and settings; Pages editor; sessions and queue;
   Assets, Style, Layouts and sheets; a cross-cutting consistency sweep). A sixth built the app, ran it on a
   throwaway library and screenshotted every screen it could reach, in dark and light. About 150 findings, each
   classed as clear polish or a product call.
2. **Foundations.** One agent added the shared pieces the lanes would need (below), so nine lanes didn't invent
   nine variants.
3. **Fix lanes.** Ten agents, one git worktree each, with disjoint file lists: library/wizard/onboarding;
   Settings; book window, overview and menus; canvas and text editing; box inspector and format sheets; sessions,
   text-style panel and cost/status text; queue and region editor; Assets and Style; Layouts and the
   export/import/settings sheets; the design system's contrast. Then one integration pass for fixes that crossed
   lane boundaries.
4. **Checks.** `scripts/test.sh all`; two independent code reviews of the diff (twelve real bugs found and
   fixed); an agent re-ran the app against a screen-by-screen checklist (nine on-screen problems found and
   fixed), and once more to confirm those fixes.

Only unambiguous polish was fixed. Product calls are listed under Open follow-ups in `PROGRESS.md`.

## What changed

**Design system** (`Theme.swift`, new `CrayonComponents.swift`)
- `CrayonBanner`; `crayonSheet()`, `CrayonSheetFooter`, `CrayonSheetDoneFooter` (Escape closes a Done-only
  sheet); `CrayonInlineMessage` with `Crayon.danger` / `warning` / `success` (readable as text in light mode);
  `crayonComposerField()`; `Crayon.mediumCornerRadius` / `thumbCornerRadius`; `Crayon.onSunflower`.
- Labels on crayon fills are chosen by contrast (`CrayonContrast`). White failed 4.5:1 on every fill in both
  appearances (1.4–3.5:1), so buttons, stickers, selected rows and chips now use dark ink (`Crayon.onFill`).
  `CrayonContrastTests` holds the rule.
- `CrayonButtonStyle`, `StepDots` and the scroll animations respect Reduce Motion.

**Bugs fixed along the way**
- New Book wizard and Style ▸ Page setup: choosing "10 × 8 in" made a portrait 8 × 10 book.
- First click into a text box put the caret at the end; it now lands at the click, and double-click selects a word.
- Opening a page from another tab (Page menu, Export preflight links) didn't switch to the Pages tab: the
  sidebar tab now lives on `PagesController`.
- Read-only books: Generate, Regenerate and the other paid or editing actions in the session panel stayed
  enabled and failed silently.
- The session composer's rows wrapped and truncated at every window size ("Gener-/ate").
- The resume banner's Resume button took Return in every window.
- The text-style version strip offered "Export Image…" (did nothing) and "Edit Region…".
- Layouts chat could be sent with no API key; export options could be changed mid-export.
- @mentions typed in the region editor weren't treated as mentions.
- After Retry, a request's thread status and `isPending` lost track of it, so Draft All could queue the same box
  again (found in review; older than this pass, but the new in-thread Try Again made it easy to hit).
- A locked book asked the same question twice (alert over an empty state); "Couldn't Open the Book" had no way out.

**Consistency**
- Seven sheets moved onto the shared scaffold (Rename, Book Settings, Page Numbers, Typography, Export, upscale
  preview, Edit Region); four banners onto `CrayonBanner`; the box inspector onto the paper background.
- One wording per condition for no key, offline and read-only (`UnavailableText`); the cost alert asks about the
  action being confirmed; paid secondary actions show their estimate first.
- Capitalisation, spelling, ellipses, destructive roles, confirmation wording, tooltips and accessibility labels
  brought to one convention (recorded under Standing decisions).
- Canvas, layout canvas and region editor draw selection and guides in Crayon colours, not the macOS accent.
- Pages overview: two portrait spreads per row at the default window size, status under the page (it hid the
  cover title), keyboard selection, a labelled "Page Labels" chip.
- Settings panes size to their content; Cost shows display names, money formatting and the price unit once.

## Notes for later sessions

- Fix agents can't see the app. Roughly one in ten of their layout changes was wrong on screen (sheets that open
  at their minimum size, an overlay that collided with buttons, a `Form` wider than its sheet). Budget an
  on-screen pass after any batch of UI changes; `make build`, `-BookBookLibraryRoot`, `screencapture -l` and
  System Events worked for driving it, and `-AppleInterfaceStyle Light` switches appearance without touching
  system settings.
- A test that resolved SwiftUI `Color`s off the main thread hung for 15 minutes without failing. Contrast tests
  now work from the palette's hex values and carry a time limit.
- `TextStyleModel`'s keep-decoration edit (committed at the start of the pass) passed `swift build` in some
  configurations but failed `make build` on a non-Sendable closure; `scripts/test.sh all` is the gate, not
  `swift build`.
