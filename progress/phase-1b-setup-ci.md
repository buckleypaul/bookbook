# Phase 1b — Project setup and CI (2026-11-07)

**Status:** done (hand checks passed, PR #3 squash-merged 2026-11-08) · branch `phase-1b-setup-ci` · PR [#3](https://github.com/buckleypaul/bookbook/pull/3) · live spend **$0.00** (`scripts/live-tests.sh openai` with no live tests: exit 0, "No matching test cases were run", nothing key-shaped printed).

**Built:**
- `BookBookKit/Package.swift` (P-1): `BBModel`, `BBStore`, `BBLayout`, `BBNet`, `BBAICore`, `BBAI`, `BBOpenAI`, `BBGemini`, `BBExport`, `BBUI`, each with a test target and a smoke test. Swift 6 mode, `ExistentialAny`, warnings as errors. Pinned `swift-collections` 1.7.5 and `swift-snapshot-testing` 1.19.7 (tests only); `Package.resolved` committed.
- `BBTestSupport` (test-only): `LiveTestGate` (live tests need `BOOKBOOK_LIVE_TESTS=1` and a key; never exposes the key) with tests, and `TestFonts` with the bundled Atkinson Hyperlegible Regular/Bold (OFL 1.1, google/fonts @95f4904) and tests.
- Resources: `BBAI/Resources/ModelCatalog.json`, `PriceList.json` (moved from `Spikes/Seeds/`), `Prompts/` (placeholder); `BBStore/Resources/Presets/StylePresets.json`, `TemplatePresets.json` (empty placeholders).
- App: `project.yml` → generated `BookBook.xcodeproj` (XcodeGen 2.46.0, both committed). `App/BookBook`: `@main` with the A §6.1 scenes stubbed (Library, `WindowGroup(for: BookID.self)`, Queue, Settings); Info.plist with the `app.bookbook.book` UTType and document type; hardened runtime, not sandboxed; xcconfigs for Debug/Release (deployment 27.0, Swift 6, strict concurrency complete, warnings as errors, ad-hoc signing with no team). BBUI stub views and `AppModel`; `BBModel.BookID`. `App/BookBookTests`: bundle ID and Info.plist type checks.
- `scripts/test.sh [all|secrets|bootstrap|kit|spikes|xcodeproj|app|release]` mirrors CI; never touches keys and unsets the live-test variables.
- `.github/workflows/ci.yml`: job `test` on `xcode-27` (Xcode 27.2), push-triggered; XcodeGen 2.46.0 from the release zip with a SHA-256 check; SwiftPM cache keyed on the Xcode version; runs every `test.sh` step.
- `README.md`; `CLAUDE.md` module map and file-ownership sections.
- GitHub: branch protection on `main` (PR required, status check `test`, not enforced on admins). Secret scanning and push protection were already on.

**Decisions / deviations:**
- XcodeGen, with the generated project committed and a CI drift check (your choice). Branch protection not enforced on admins (your choice). Atkinson Hyperlegible as the test font (your choice).
- New test-only target `BBTestSupport`; presets bundled in `BBStore`; as-built dependency list added to A §3 (BBNet has no BBModel dependency). All in `architecture.md` §3 and §13.1.
- CI triggers on push only (required checks match by SHA, so the PR is covered without double runs).
- `PHASE_PROMPT.md` step 3 now marks a phase `done` on its branch **before** squash-merging, so the status reaches main (1a's `done` had only been recorded on the Phase 0 branch).

**Review:** fresh opus review, no code must-fixes. Fixed: branch protection (was pending), `test.sh` steps could pass despite a failing command (errexit off inside `if`), unverified XcodeGen download, stale-prone cache key, A §3 graph mismatch, test target Release config including Debug settings, duplicate push/PR runs and cancelled runs on main, no test for the Info.plist type, stale `Spikes/Seeds` references here.

**Hand checks:**
- [x] Clone fresh, build and run: the app launches to an empty "Library" window, and ⌘, opens Settings. *(2026-11-08: fresh clone of the branch built with `xcodebuild` (same build as Xcode), launched from that build: "No Books Yet" in Library, ⌘, opened General. You waived the Xcode GUI run.)*
- [x] Push a branch and CI goes green. *(Confirmed: CI green on this branch.)*
- [x] On a scratch branch, commit a fake `sk-…` string: the pre-commit hook blocks it, and CI or push protection would too. *(Covered offline by `scripts/tests/test-bootstrap.sh`; you waived the by-hand try, trusting push protection.)*
- [x] `scripts/live-tests.sh openai` with no live tests runs, reports zero tests and prints nothing secret. *(Confirmed: see above.)*

**Follow-ups:**
- App icon and `UTTypeIcons` for `.bookbook` documents are placeholders (Finder shows a generic package icon).
- `BookWindow` shows the book UUID as placeholder text (Phase 2 replaces it).
- The `xcode-27` runner image is "preview", and Xcode 27.2 is an RC there; the `xcode-select` path may change.
- `actions/checkout` v4.2.2 / `actions/cache` v4.2.0 are Node 20 actions; bump them when GitHub retires Node 20.
- Product decision recorded on this branch (2026-11-07): BookBook always reopens the books that were open at quit. PD §8.1, A §6.1, plan Phase 3, `Spikes/REPORT.md`.
- From 1a, still open: `live-tests.sh` exits 0 when no test matches (SwiftPM prints a warning); fine for this phase's check.

