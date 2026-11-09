# Phase 16b — Bug fixes and edge cases (L)

Part of implementation-plan.md; read the core file (§0–§3) first. Added 2026-11-09 at your request, after Phase 16 and before Phases 15 and 17.

**Goal:** clear the backlog of bugs and edge cases from earlier reviews and app passes before the hardening and release work, so Phase 17 starts from a clean list.

**Inputs:** PROGRESS.md › "Open follow-ups", both the **Phase 17** section and the **Later** section (about 100 items, mostly review should-fixes from Phases 2–16). Out of scope: the "Deferred hand checks" section (you run those at the end of the build), and Phase 17's own deliverables (UI smoke suite, performance pass, accessibility, catalog and price-list refresh, the final live pass, schema freeze, README, release).

**No live checks.** This phase spends $0. A fix that can only be confirmed with a generation gets a code fix plus an offline test (fixtures or a fake provider), and one line under "Deferred hand checks › Phase 16b".

## Session A

1. **Triage (subagents, in parallel).** Split the two lists into 3–4 batches by area and give each batch to a sonnet subagent (opus for store, concurrency, canvas or TextKit items). It checks every item against the current code and returns one row per item: the item, a status, and the files involved.
   - **fix now:** a real bug or edge case that loses data, crashes, gives wrong output or a misleading UI, or is a cheap, safe fix. This is the default for anything a household user could hit.
   - **already fixed / can't reproduce:** drop it, with a note of the evidence.
   - **product call:** needs your decision (e.g. landscape booklet binding, irreversible asset delete, Draft All counting the cover's box, Reset Session → Keep Versions behaviour).
   - **v1.x:** large or risky for little user value, or polish. Give a one-line reason.
   - **Phase 17:** belongs to hardening or release (e.g. Gemini wording cleanup, the catalog refresh). Leave these where they are.
2. **Ask once.** Put every product call into one batched AskUserQuestion, with a recommended default for each. Build the answers as "fix now" items. Log each decision under "Standing decisions" in PROGRESS.md.
3. **Cluster.** Group the "fix now" items into lanes by the files they touch, so no two lanes share a file. Starting clusters (adjust to the triage):
   - **Store:** `BookLock`, journal (including the flaky `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder`), `LibraryIndex`, library trash/duplicate/move/rename, the image-store sweep, read-only load, duplicate-ID gaps, and Clean Up protecting versions used by queued requests.
   - **Queue and cost:** `GenerationQueue`, `QueueFileStore` (including `queue.json` being shared across library roots), `CostLedger`, retry policy and estimates.
   - **AI context and sessions:** `ContextAssembler`, version numbering and lineage, consistency checks, `TemplateNormalizer`, region-edit should-fixes.
   - **Export:** `ExportImagePreparer`, preflight, booklets and crop marks.
   - **Assets:** `RealPersonCheck`, mentions and tokens, `AssetEditor`.
   - **Library and app UI:** menus (Book Settings missing from the File menu), Guided Setup, the wizard, story import, sheets, the overview grid.
   - **Canvas, text and template editor:** contains the `CanvasView` hot spot, so it's one lane at a time or the main thread.
   - **Hot spots** (`CanvasView`, `BookDocument`, `ModelCatalog.json`, `PriceList.json`, `Package.swift`, `project.yml`): only one lane at a time, as in plan §2.5.
4. **Fix: one subagent per cluster.** Each lane gets its own worktree (`isolation: "worktree"`). Launch the lanes whose files don't overlap in parallel, in a single message. Use sonnet for fixes with a known cause, and opus for concurrency, actor, store-journal, canvas and TextKit items, or anything sonnet couldn't fix. Each brief lists the lane's items word for word, the files it owns, and its done check. Each fix gets a regression test where one is feasible. An item that turns out bigger than expected is reported back, not half-done; the main thread moves it to v1.x or a later lane.
5. **Merge** the lanes into the phase branch one at a time, with `swift build` after each. Then run `scripts/test.sh all` once at the end of Session A.

**Batching:** if there are more lanes than you can run comfortably at once, run them in waves. Do the store and queue lanes first, because they carry the data-loss risks.

## PROGRESS.md bookkeeping

- Remove every fixed or dropped item from "Open follow-ups".
- Move "v1.x" items into a new **"### v1.x"** section under "Open follow-ups", one line each with its reason.
- Leave the "Phase 17" items in place.
- The "Later" section should be empty at the end of the phase.

## Session B

As in PHASE_PROMPT.md §4. The review covers the whole phase diff. Its must-fix bar is a regression, data loss or a crash introduced by a fix. The automated app pass re-checks every app-visible fix it can (menus, Guided Setup, the overview grid, sheets).

**Done when:** `scripts/test.sh all` is green with no new warnings. Every item from the two input lists is either fixed (with its test named in the phase log), dropped with a reason, moved to v1.x with a reason, or left for Phase 17. The phase log has a table with the counts for each.

**Risks:** fixes that drift into features (log them as v1.x), and lanes colliding on shared files (cluster strictly by file, and treat the hot spots as serial).
