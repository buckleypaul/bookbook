# BookBook — Repo Guide for Claude and Subagents

BookBook is a macOS 27 app for writing and illustrating picture books with AI image models. Read these first, as the task needs:

- `product-description.md` (PD): what the product does. It's the source of truth for requirements.
- `architecture.md` (A): how it's built.
- `implementation-plan.md`: the phases, working rules (§2), and dependencies (§3).
- `PROGRESS.md`: where the build is now. `PHASE_PROMPT.md`: how one phase session runs.

## Module map

Targets are defined in `BookBookKit/Package.swift` (architecture.md §3). Dependencies listed are the only ones allowed.

| Target | Folder | Holds | May depend on |
|---|---|---|---|
| BBModel | `BookBookKit/Sources/BBModel` | value types, IDs, schema versions, derived queries. Foundation only, no I/O | swift-collections |
| BBStore | `BookBookKit/Sources/BBStore` | package I/O, journal, library, migrations, image store, keychain. Bundles presets | BBModel |
| BBLayout | `BookBookKit/Sources/BBLayout` | geometry, page order, TextKit 2 layout, PageRenderer. AppKit only for TextKit 2 and fonts; no views | BBModel |
| BBNet | `BookBookKit/Sources/BBNet` | HTTP client, multipart, SSE. Redacts `Authorization` and `x-goog-api-key` | nothing |
| BBAICore | `BookBookKit/Sources/BBAICore` | provider protocols and request/response types shared by BBAI and the adapters | BBModel |
| BBAI | `BookBookKit/Sources/BBAI` | queue, context assembly, cost, errors, catalog. Bundles the catalog, prices and prompts | BBAICore, BBModel, swift-collections |
| BBOpenAI | `BookBookKit/Sources/BBOpenAI` | OpenAI provider adapter | BBAICore, BBNet |
| BBGemini | `BookBookKit/Sources/BBGemini` | Gemini provider adapter | BBAICore, BBNet |
| BBExport | `BookBookKit/Sources/BBExport` | PDF, booklet, upscale, preflight | BBLayout, BBModel |
| BBUI | `BookBookKit/Sources/BBUI` | SwiftUI features, AppKit canvas, view models | BBExport, BBAI, BBAICore, BBStore, BBLayout, BBModel |
| BBTestSupport | `BookBookKit/Sources/BBTestSupport` | live-test gate, bundled test font. Test-only, never linked into the app | nothing |
| BookBook (app) | `App/BookBook` | thin: `@main`, scenes and wiring only | BBUI, BBOpenAI, BBGemini |
| BookBookTests | `App/BookBookTests` | app-level tests | BookBook |

- The app wires up the concrete providers. Providers depend on BBAICore, never the reverse.
- Bundled resources: `BBAI/Resources/ModelCatalog.json`, `PriceList.json`, `Prompts/`; `BBStore/Resources/Presets/` (`StylePresets.json`, `TemplatePresets.json`); `BBTestSupport/Resources/Fonts/` (test font, OFL).

## File ownership (implementation-plan.md §2.5)

- Contracts first: the main thread lands the public types and protocols that a phase's lanes share before any lane starts.
- One git worktree per lane. The main thread merges lanes and runs the hand checks.
- Two lanes never edit the same file at once.
- Hot spots: `CanvasView`, `BookDocument`, `ModelCatalog.json`, `PriceList.json`, `BookBookKit/Package.swift` and `project.yml`. Only the main thread edits these, or one lane at a time.
- `BookBook.xcodeproj` is generated. Never hand-edit it: edit `project.yml` and run `xcodegen generate`, then commit both.
- Subagents edit only the files their brief lists.

## API key hygiene (implementation-plan.md §2.2): mandatory for everyone, including subagents

The OpenAI dev key lives in the macOS Keychain (service `openai-api-key`, account `$USER`). A Gemini key will be added later as `gemini-api-key` the same way.

- **The only allowed way to use a dev key** is through `scripts/live-tests.sh [--package DIR] [openai|gemini] [filter]` or `scripts/record-fixtures.sh` (same arguments; it runs the live tests in record mode). These scripts inline the key into the environment of a single `swift test --skip-build` command, after building without it:
  ```sh
  OPENAI_API_KEY="$(security find-generic-password -a "$USER" -s openai-api-key -w)" \
    BOOKBOOK_LIVE_TESTS=1 swift test --skip-build --filter LiveProviderTests
  ```
  `--package` takes a folder name at the repo root (`BookBookKit` by default, `Spikes` in Phase 0). Live suites must be named `LiveProviderTests`, with test names starting with the spike ID (e.g. `SP4_maskPolarity`), or the filter matches nothing. Don't run the command above by hand, and don't write other scripts that read the key. No `set -x`, no `env` dumps, no echoing. Live tests never start child processes.
- **Never** print, log, `echo`, write to a file, put in a fixture, commit, or paste a key into chat. Never run `security … -w` on its own, outside `$(…)`. To check that an item exists, run `security find-generic-password -a "$USER" -s <service> >/dev/null 2>&1` (no `-w`).
- Tests read the key only from `ProcessInfo.environment`. It goes straight to the HTTP client and into nothing that can appear in a failure message.
- `BBNet` always redacts `Authorization` and `x-goog-api-key` in its own diagnostics. Request and response bodies are never logged.
- **The fixture recorder** saves only response bodies plus an allowlist of response headers (`content-type`, `retry-after`, rate-limit headers, `x-request-id`). Request headers are never saved. It checks in memory that a file's bytes don't contain the key before writing, and refuses if they do. Organisation and project IDs are replaced with placeholders.
- **Live tests never use snapshot assertions.** The only files a live run writes are fixtures (through the recorder) and the spend log `~/Library/Caches/BookBook-dev/live-spend.jsonl` (no key or prompt text).
- **Live tests never run in CI.** They skip themselves unless `BOOKBOOK_LIVE_TESTS=1` is set and a key is present.
- **Spend:** $10 total cap (plan §2.4). `LiveSpendGuard` skips live tests once the running total passes `BOOKBOOK_LIVE_BUDGET` (default 10). Ask the user before any live run that would take the total in `PROGRESS.md` past $8, and record each run's spend there. Only run the live checks the current phase lists. Use Draft/low quality and small sizes unless the question needs more.
- **The in-app key is separate.** The app stores its own key under `app.bookbook.api-key` / `openai`, and never reads the dev item. It's entered in a `SecureField` and goes only to the Keychain: never `UserDefaults`, `@SceneStorage`/`@AppStorage`, window restoration, the queue file or logs.

## Secret scanning

- After cloning, run `scripts/install-hooks.sh` once. It copies `.githooks/pre-commit` into the clone's shared hooks folder as both `pre-commit` and `pre-merge-commit`, so it covers every branch, merge and worktree. It runs `scripts/secret-scan.sh --staged` (the whole index), and it fails closed on a checkout that has no scanner.
- `scripts/secret-scan.sh` (no argument) scans every tracked file, including `__Snapshots__` and fixtures, with binary files read as text. CI runs it. It looks for `sk-[A-Za-z0-9_-]{20,}` (which covers `sk-proj-…`) and `AIza[0-9A-Za-z_-]{35}`, and it reports `file:line` without printing the match.
- Never commit a key-shaped string, even a fake one. Tests that need one build it at runtime (see `scripts/tests/test-bootstrap.sh`).
- `scripts/tests/test-bootstrap.sh` is the offline self-test for the hook and scripts.

## Git and workflow

- One phase per session, on branch `phase-<id>-<slug>`, ending in a PR to `main` (plan §2.6). Update `PROGRESS.md` as you go.
- Small, logical commits with conventional messages. Never force-push `main`, never use `--no-verify`, and never change the repo's git identity (`Paul Buckley <paul@paulbuckley.me>`, set in the repo config).
- Build only what the current phase lists. Put anything else under "Follow-ups" in `PROGRESS.md`.
- If the architecture is wrong or too vague, make the smallest sound choice, update `architecture.md` in the same PR, and log it. Product-level changes need the user's approval.
- Definition of done (plan §2.1): every undoable edit goes through a `BookCommand`; everything sent to a provider is shown in Version details; Swift 6 strict concurrency, with no warnings suppressed.
