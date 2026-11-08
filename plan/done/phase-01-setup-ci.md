# Phase 1 — Project setup and CI (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** a repo, app and package structure that every later phase builds into, with CI and key hygiene in place from the first commit.

**Scope:** A §2, §3, §12 (CI), §13.1. Modules: an empty skeleton of every target.

**1a, bootstrap (first, about an hour):** the repo already exists (`git init` and the remote were done on 2026-11-07). 1a adds the full `.gitignore` (DerivedData, `.build`, `*.p8`, `*.p12`, `.env*`), the pre-commit secret-scan hook plus `install-hooks.sh`, `scripts/live-tests.sh` and `scripts/record-fixtures.sh` (§2.2), and the repo `CLAUDE.md` with the key rules. Then Phase 0 can start.

**Deliverables (1b)**
- On `buckleypaul/bookbook`: branch protection on `main` (PR required, CI must pass). Check that secret scanning and push protection are on.
- `BookBook.xcodeproj`: a thin app target (`@main`, scenes stubbed per A §6.1), `.xcconfig` files for Debug and Release, deployment target **macOS 27.0**, Swift 6 language mode with strict concurrency, hardened runtime on, bundle ID `app.bookbook.BookBook`, and an Info.plist with the `app.bookbook.book` UTType and document type (A §5.1).
- `BookBookKit/Package.swift` (P-1) with targets `BBModel`, `BBStore`, `BBLayout`, `BBNet`, `BBAICore`, `BBAI`, `BBOpenAI`, `BBGemini`, `BBExport`, `BBUI`, each with a test target. The dependency graph is exactly A §3. Pinned `swift-collections`; `swift-snapshot-testing` for tests only.
- Bundled resource folders: `ModelCatalog.json`, `PriceList.json`, prompt templates, presets (placeholders for now).
- `scripts/test.sh`, alongside the 1a scripts.
- `.github/workflows/ci.yml` on `runs-on: xcode-27`: `swift test` in `BookBookKit` (live tests skip themselves), `xcodebuild build test` for the app, an unsigned Release build, and the secret scan.
- The repo `CLAUDE.md` extended with the module map and ownership rules (§2.5), and a `README.md` with build instructions.
- A test font bundled in the test resources, so snapshot tests don't depend on which system fonts are installed.

**Acceptance (by hand)**
- Clone fresh, open in Xcode 27, and run. The app launches to an empty "Library" window, and Settings opens with ⌘,.
- Push a branch and CI goes green. Push a commit containing a fake `sk-…` string on a scratch branch: the pre-commit hook blocks it, and CI or push protection would too.
- `scripts/live-tests.sh openai` with no tests yet: it runs, reports zero live tests, and prints nothing secret.

**Tests added:** one smoke test per target, so each one builds and links. A test that confirms live tests skip themselves when `BOOKBOOK_LIVE_TESTS` isn't set.

**Risks:** the `xcode-27` runner label or image contents change (check against GitHub's runner-images notes when writing the workflow). SwiftPM tests for AppKit-dependent targets on CI (`BBLayout`) may need a window server; fall back to `xcodebuild test` for those targets if so.
