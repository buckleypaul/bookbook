# Phase 16 — Library import, book settings, onboarding, sample

**Stage:** done (hand checks deferred), merged 2026-11-09

- 2026-11-08: Phase 15 deferred at your request; Phase 16 started (its dependencies 3, 10 and 14 are done).
- Contracts: `BBStore/Phase16/Phase16Contracts.swift` (import, clean-up plan, `NewBookSpec`).
- Lanes, all merged:
  - **L1 store:** `BookImporter` (clashes, build with ID remapping, image copy deduplicated by hash), `CleanUp` (plan, apply, immediate file delete), `BookStore.sizeOnDisk`, and duplicate `Book.id` resolution on library refresh (Phase 3 follow-up).
  - **L2 onboarding:** a "Guided Setup" window scene that opens on first launch (flag `onboardingCompleted`; not under XCTest or when a key is saved), with typical costs from the price list. It can be reopened from Settings › API Keys and the Help menu.
  - **L3 wizard and sample:** a five-step `NewBookWizard` (each step skippable), `NewBookSpec.apply`, `Library.createBook(spec:)`, `StylePreset.sampleImage` (optional; none bundled yet), the bundled placeholder sample book "Pip and the Missing Moon" (text only), and Open Sample Book in the library toolbar, the empty state and the File menu.
  - **L4 import and clean-up UI:** the `.importFromBook` command, `ImportFromBookSheet` (book menu and File › Import from Book…), and Book Settings › Storage (size on disk, Clean Up… with confirmation). Book Settings cost labels now read images / consistency checks / templates.
- Assumptions:
  - The real sample book and the preset sample images are content you make in the app, per the content note. The bundled sample is a text-only placeholder made by `SampleBookGenerator` (`BOOKBOOK_GENERATE_SAMPLE=1`). To add the real ones, see the READMEs in `Resources/SampleBook/` and `Resources/Presets/Samples/`.
  - Read-only open of an older-schema book (Phase 16/17 follow-up) is left for Phase 17.
- **For Session B:**
  - Run the full `scripts/test.sh all`.
  - Check that Guided Setup's OpenAI billing and organization URLs are current.
  - Check undo of import, and that Clean up handles dangling `parent`/`refines` lineage (L1 noted it doesn't check `Session+Lineage`).
  - Check that the sample opens with no key, and that the onboarding window doesn't pop up in automated app runs.

## Session B (2026-11-09)

- `scripts/test.sh all` green before and after the fixes (no warnings in project code). Secret scan clean. No live checks listed; spend $0.00.
- App pass (throwaway library, `-onboardingCompleted NO`, no API calls): Guided Setup shows, skips and reopens from Help and Settings, OpenAI only; the sample book opens with no key; the wizard applies size, style, character and the story-import offer; Import from Book with a rename clash makes independent copies, and ⌘Z removes the import; Book Settings shows size on disk, and Clean Up is disabled on an empty book.
- Review fixes (two rounds):
  - Clean Up keeps the full `parent` lineage of every kept version (placed, chosen, starred, reference, sheet).
  - Clean Up ends the typing step and clears the window's undo history straight after the in-memory removal, before the save (PD §8.12: it can't be undone).
  - Duplicate `Book.id` resolution: `LibraryIndex` tracks which package owned each ID before a scan, so the original keeps the ID (on a fresh index: earliest creation date, then the shorter name). Packages open in this process are never rewritten (`resolveDuplicateBookIDs(open:)`, fed by `AppModel` via `setOpenPackages`).
- Deviations: none from the product description. The sample book and preset sample images are still placeholders until you make them in the app (content note).

