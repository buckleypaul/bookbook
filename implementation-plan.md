# BookBook — Implementation Plan

**Status:** Draft v1, for review
**Date:** 2026-11-07
**Inputs:** `product-description.md` v4 (cited as **PD §n**) and `architecture.md` v1.1 (cited as **A §n**). `architecture-notes.md` was background only (since removed). A §15–§16 now live in `architecture-decisions.md`.
**Next step:** carry out the plan, one phase at a time. The phase specs live in `plan/` (one file per phase; finished phases in `plan/done/`). A phase session reads this core file (§0–§3) plus its own phase file. This document sets the order of work. It does not change the design. Where the plan needed a design detail, it's flagged as a **plan decision** so you can overrule it.

---

## 0. Decisions recorded before planning (2026-11-07)

| Topic | Decision | Where it's recorded |
|---|---|---|
| A §15 product changes | Already applied to PD v3. Nothing outstanding. | PD header |
| A §16 decisions made without asking | All 8 accepted as written. | `architecture-decisions.md` §16 |
| Minimum OS | **macOS 27.** macOS 26 is no longer supported. | PD §3, A §2 |
| Toolchain | Xcode 27.x (Swift 6.4), locally and in CI. CI uses GitHub's `xcode-27` runner label (macOS 27, Apple Silicon). | A §2, D13, §13.2 |
| Repository | Public on GitHub at **`buckleypaul/bookbook`** (personal account), created 2026-11-07 with the planning docs as the first commit. Commits use the repo-local identity `Paul Buckley <paul@paulbuckley.me>`. The Homebrew tap will be `buckleypaul/homebrew-tap`. | A §13.2, §13.3 |
| Signing | A Developer ID Application certificate is available. | A §13.2 |
| Bundle ID | `app.bookbook.BookBook` (kept). | A §13.1 |
| Live-API spend cap | **$10 in total** for the spikes plus routine live tests during development. This doesn't cover content you make yourself in the app (see the content note in Phase 16). | §2.4 |

**Plan decisions** (made here; easy to overrule):

- **P-1: one local package.** All modules are library targets in a single local Swift package, `BookBookKit/`, rather than one package per module. The module boundaries in A §3 stay the same, and they're enforced by target dependencies. This keeps `swift test --filter LiveProviderTests` a single command run from one folder, and cuts the boilerplate.
- **P-2: the crash-safe journal comes in the first slice.** It's small, and adding it after other code already writes files would be riskier. Fault-injection tests come in Phase 3.
- **P-3: the command and undo layer comes in the first slice.** Every edit goes through `BookDocument.perform` from the start (A §6.3), so later phases never have to move mutations over to it.
- **P-4: `GenerationQueue` exists from the first slice**, as a serial in-memory actor. Persistence, reordering, retries and the queue window come in Phase 9. That way the slice's single generation already follows the real path.
- **P-5: OpenAI text and vision calls use Chat Completions with `store: false`**, not the Responses API. This keeps A §7.6's "no Responses API in v1" true for every OpenAI call. If SP-7 shows that structured output or vision only works through Responses for the chosen models, that's raised with you as an architecture change, not decided in the plan.
- **P-6: Phase 1 starts with a short bootstrap step (1a)**: `.gitignore`, the secret-scan pre-commit hook, `scripts/live-tests.sh` and `scripts/record-fixtures.sh`. Phase 0 depends on 1a, so the key-safety tooling exists before the first live call. The rest of Phase 1 (1b) runs alongside Phase 0.

---

## 1. Phase overview

Sizes: **S** is a few focused days, **M** about a week, **L** about two weeks (agent-assisted, with you reviewing). They're relative, not promises.

| # | Phase | Size | Ends with something you can use |
|---|---|---|---|
| 0 | Live-API spikes and fixtures | S | A spike report and recorded fixtures. The catalog and price list are seeded from real responses. |
| 1 | Project setup and CI | M | The app launches to an empty Library window. CI is green on `xcode-27`. |
| 2 | **Thin vertical slice** | L | Open a book, type text, generate an image with OpenAI, place it, export a PDF. |
| 3 | Storage and library | M | A library grid with thumbnails. Books survive crashes. Several book windows can be open. |
| 4 | Text and typography | M | Rich story text in real fonts, with spelling, overflow and text undo. |
| 5 | Pages tab, ordering and cover | L | A whole book's structure: spreads, reordering, story import, cover, page numbers. |
| 6 | Template editor | L | Your own layouts, made in a visual editor. |
| 7 | Style guide and page setup | M | Style tab, page sizes, bleed, and the style changed / layout changed flags. |
| 8 | Sessions and versions | L | A full chat, version strip and refinement workflow for each image box. |
| 9 | Queue, cost, errors and settings | L | A real queue, cost estimates and totals, plain-language errors, "Draft all empty boxes". |
| 10 | Assets and character sheets | L | Consistent characters: references, `@mentions`, sheets, where-used. |
| 11 | Region editing | M | Brush or lasso an area and change only that area (OpenAI). |
| 12 | Consistency check and AI templates | M | Drift warnings with a one-click fix. Describe a layout and get a template. |
| 13 | Gemini provider *(floating)* | L | A second provider, with "Retry with Gemini". |
| 14 | Export and print, complete | L | Print-shop PDF with bleed and crop marks, booklets, preflight, Print, PNG/JPEG export. |
| 15 | Release pipeline | M | `brew install --cask buckleypaul/tap/bookbook` installs a notarized build. |
| 16 | Library import, book settings, onboarding, sample | M | First-run setup, the new-book wizard, the sample book, clean-up, import from another book. |
| 17 | Hardening and v1.0 | M | Tagged v1.0.0, installed through the tap. |

**Milestones**

- **M1, the slice (end of Phase 2):** the end-to-end path works.
- **M2, write and draft a whole book (Phases 3–9):** your household can start using local builds for real books.
- **M3, consistent illustration (Phases 10–12):** characters stay the same from page to page.
- **M4, print-ready and installable (Phases 14–15):** printed copies, installed with brew.
- **M5, v1.0 (Phases 16–17).**

---

## 2. Working rules for every phase

### 2.1 Definition of done (applies to every phase)

1. `scripts/test.sh all` passes locally (the same steps as CI): unit and snapshot tests, the app build, and the secret scan. CI isn't a gate (no PRs).
2. The phase's **hand acceptance checks** have been run by you on macOS 27, in a Debug build launched from Xcode, or from the release build once Phase 15 is done.
3. Every new edit that PD §8.10 says is undoable goes through a `BookCommand`, and its undo/redo has been checked by hand.
4. Anything new that's sent to a provider is visible in Version details. That's the privacy rule in A §11.
5. Any design change found while building is written back into `architecture.md` in the same change. Product-level changes go into `product-description.md`, after asking you.

### 2.2 API key hygiene (applies to everyone, including subagents)

The OpenAI dev key lives in the macOS Keychain (service `openai-api-key`, account `$USER`). A Gemini key will be added later as `gemini-api-key` in the same way.

- **The only allowed way to use it** is to inline it into the test process's environment:
  ```sh
  OPENAI_API_KEY="$(security find-generic-password -a "$USER" -s openai-api-key -w)" \
    BOOKBOOK_LIVE_TESTS=1 swift test --filter LiveProviderTests
  ```
  This is run from `BookBookKit/`. Only two scripts may use the key: `scripts/live-tests.sh [openai|gemini] [filter]` and `scripts/record-fixtures.sh` (which runs the same tests in record mode). Both use exactly this pattern, with no `set -x`, no `env` dumps and no echoing. To keep the key away from the compiler and build tools, they first run `swift build --build-tests` *without* the key, then run `swift test --skip-build --filter …` with the key inlined. Live tests never start child processes.
- **Remaining risk you accept:** while a live test runs, other processes running as your user can read its environment (e.g. `ps -E`). Runs are short, and nothing else gets the key.
- **Never** print, log, `echo`, write to a file, put in a fixture, commit, or paste the key into chat. Never run `security … -w` on its own, outside `$(…)`.
- Tests read the key only from `ProcessInfo.environment`. It's passed straight to the HTTP client and goes into nothing that can appear in a failure message.
- `BBNet` always redacts `Authorization` and `x-goog-api-key` in its own diagnostics. Request and response bodies are never logged (A §7.12).
- **The fixture recorder** saves only response bodies plus an allowlist of response headers (`content-type`, `retry-after`, rate-limit headers, `x-request-id`). Request headers are never saved. Before writing a file, it checks in memory that the file's bytes don't contain the key, and refuses to write if they do. Organisation and project IDs are replaced with placeholders.
- **Live tests never use snapshot assertions**, so nothing is written to `__Snapshots__` from a live run. The only files a live run writes are fixtures (through the recorder) and the spend log.
- **Secret scanning:** a pre-commit hook and a CI step (covering every tracked file, including `__Snapshots__` and fixtures) grep for `sk-[A-Za-z0-9_-]{20,}`, `sk-proj-…` and `AIza[0-9A-Za-z_-]{35}`. GitHub push protection is turned on (free for public repos).
- **Live tests never run in CI.** They skip themselves unless `BOOKBOOK_LIVE_TESTS=1` is set and a key is present.
- The in-app key, added in Phase 2, is separate. You paste it into the app's Settings, and the app stores it under its own Keychain item (`app.bookbook.api-key` / `openai`, A §5.5). The app never reads the dev item. The Settings field is a `SecureField`, and the key goes only into the Keychain: never into `UserDefaults`, `@SceneStorage` or `@AppStorage`, window restoration state, the queue file or logs. The field is cleared once the key is saved.

### 2.3 Live test structure

- `LiveProviderTests` sits in the `BBOpenAITests` and `BBGeminiTests` test targets, with one suite per provider. Test names start with the spike ID (e.g. `SP4_maskPolarity`) so they can be filtered one at a time.
- **`LiveSpendGuard`** writes the estimated cost of each live call, priced from reported `usage` with the bundled price list, to `~/Library/Caches/BookBook-dev/live-spend.jsonl`. The file holds no key or prompt text. Live tests skip, with a message, once the running total passes `BOOKBOOK_LIVE_BUDGET`, which defaults to **$10**. These are estimates, so check against the provider dashboards after Phase 0.
- Live tests use **Draft/low** quality and small sizes unless the question needs something else.

### 2.4 Live spend budget ($10 total)

| Use | Allotted |
|---|---|
| Phase 0 OpenAI spikes | $3 |
| Phase 0 Gemini spikes (once the key exists) | $2 |
| Phase-end live passes (Phases 2, 8, 9, 11, 12, 13, 17: about $0.30 each) | $2.50 |
| Re-runs and contingency | $2.50 |

### 2.5 Parallel work with subagents

- **Contracts first.** At the start of each phase, the main thread lands the public types and protocols that the phase's lanes share (e.g. `BookCommand` cases, `ImageRequest`, `QueueItem`). Lanes then build against them.
- **One git worktree per lane.** The main thread merges lanes and runs the hand checks.
- **File ownership** prevents conflicts. Two lanes never edit the same file at once. Known hot spots: `CanvasView` (Phases 4, 6, 7 and 11), `BookDocument` (every phase), and `ModelCatalog.json` / `PriceList.json` (Phases 0, 9 and 13). Changes to a hot spot are made by the main thread, or by one lane at a time.
- **Good lane splits:** model plus tests / UI / provider adapter / fixtures. Bad lane splits: two lanes inside the canvas at once.
- A repo `CLAUDE.md`, created in Phase 1, holds the key-hygiene rules (§2.2), the module map and the ownership rules, so every subagent starts from them.

### 2.6 Phase workflow and progress tracking

- **`PROGRESS.md`** at the repo root is the single record of where the build is. It has one row per phase (in the order 1a, 0, 1b, 2, 3 … 17), with a status, branch, PR (none from Phase 5 on), live spend and notes. Each phase session updates it. It also holds the open follow-ups (grouped by target phase) and the current phase's log. When a phase is `done`, its log moves to `progress/phase-<id>-<slug>.md` and its spec to `plan/done/`, so PROGRESS.md stays small.
- **Statuses:** `not started` → `in progress` → `awaiting hand checks` (code is done, local tests are green, merged into main and pushed) → `done` (you've confirmed the hand checks). `blocked` and `skipped (floating)` are also allowed.
- **One phase per pair of sessions.** Session A (build: contracts, lanes, merge) and Session B (verify: tests, hand checks, review) work on a branch called `phase-<id>-<slug>`, with git worktrees for parallel lanes. A **Stage** line in the current phase log tells the next session where to resume. **No PRs or CI waits:** every session ends by merging the phase branch into `main` (`--no-ff`) and pushing `main` directly to `origin`, so main always has the latest work. Session B stops at `awaiting hand checks`. The **next** session starts by asking whether the previous phase's hand checks passed. If they did, it marks the phase `done`, merges into main again and deletes the phase branch before starting the next one.
- **Which phase is next:** the first phase in `PROGRESS.md` order that isn't `done` and whose solid dependencies (§3) are all `done`. Phase 13 is skipped while no `gemini-api-key` Keychain item exists. To check, run `security find-generic-password -s gemini-api-key >/dev/null 2>&1`; this checks the item exists without reading the key.
- **Git identity** is set in the repo config (`Paul Buckley <paul@paulbuckley.me>`). Don't override it.

---

## 3. Dependencies and parallel lanes

Solid arrows mean "must be merged before this phase starts". Dashed arrows mean "work can start without it, but it's needed for the hand checks or for one part of the phase", and the label says which.

```mermaid
graph TD
  P1a[1a Bootstrap: git, hooks, scripts] --> P0[0 Spikes]
  P1a --> P1b[1b Setup + CI]
  P0 -.fixtures.-> P2
  P1b --> P2[2 Thin slice]
  P2 --> P3[3 Storage + library]
  P2 --> P4[4 Text + typography]
  P4 --> P5[5 Pages + cover]
  P4 --> P6[6 Template editor]
  P5 --> P6
  P2 --> P8[8 Sessions + versions]
  P5 -.hand checks: spreads.-> P8
  P6 -.hand checks: two image boxes.-> P8
  P4 --> P7[7 Style + page setup]
  P6 --> P7
  P8 --> P9[9 Queue, cost, errors, settings]
  P3 --> P9
  P0 -.fixtures.-> P9
  P9 --> P10[10 Assets + sheets]
  P5 --> P10
  P7 --> P10
  P9 --> P11[11 Region editing]
  P0 -.SP4 mask polarity.-> P11
  P10 --> P12[12 Consistency + AI templates]
  P6 --> P12
  P0 -.SP7 fixtures.-> P12
  P9 --> P13[13 Gemini - floating]
  GK([Gemini key added]) -.-> P13
  P12 -.layout + vision parts.-> P13
  P11 -.hand check: region tool off.-> P13
  P4 --> P14[14 Export + print]
  P5 --> P14
  P7 --> P14
  P8 --> P14
  P1b --> P15[15 Release pipeline]
  P14 --> P15
  P3 --> P16[16 Import, book settings, onboarding, sample]
  P10 --> P16
  P14 --> P16
  P15 --> P17[17 Hardening + v1.0]
  P16 --> P17
  P12 --> P17
  P11 --> P17
  P13 -.if key available.-> P17
```

**Preflight items** (Phase 14) for the asset-changed and consistency flags are added by whichever lands later: Phase 14, or the phase that adds the flag (10 or 12).

**What can run at the same time**

| Window | In parallel |
|---|---|
| Start | **1a** first (an hour or so). Then **Phase 0** (spikes, in a standalone `Spikes/` package) alongside **1b** (project and CI). |
| After M1 (Phase 2) | Three lanes: **A** = Phase 3 (storage); **B** = Phase 4 → Phase 5 → Phase 6 → Phase 7 (canvas and text; one lane, because they share `CanvasView`); **C** = Phase 8 → Phase 9 (AI). Phase 8's build work starts at once, and its hand checks wait for Phases 5 and 6. Phase 9 needs Phase 3 merged. |
| After Phase 9 | Phase 10 (assets, once Phase 7 is in) ∥ Phase 11 (region editing) ∥ Phase 13 image part (Gemini, if the key exists) ∥ Phase 14 (export, once Phases 4, 5, 7 and 8 are done). |
| After Phases 10 and 14 | Phase 12 (consistency, AI templates) ∥ **Phase 15 (release)** ∥ Phase 16 (onboarding etc.) |
| End | Phase 17 |

Phase 15 only *needs* Phase 1 and a working app. It's placed after Phase 14 so the first brew install is a printable app, but it can start earlier as a side lane if you want brew installs for household testing sooner.

**Critical path:** 1 → 2 → 4 → 5 → 6 → 7 → 10 → 12 → 17. The AI lane (8 → 9) runs alongside it and must finish before Phase 10.

---

## 4–8. Moved to `plan/`

Old citations such as "implementation-plan.md §4.3" or Phase 2 "Risks" resolve through this table. Phase 0 and Phases 1–3 are done and live in `plan/done/`.

| Old reference | Now in |
|---|---|
| §4, §4.1, §4.3 (Phase 0 spikes) | `plan/done/phase-00-spikes.md` |
| §4.2 (Gemini spikes, SG-n) | `plan/phase-13-gemini.md` |
| §5 Phase 1 | `plan/done/phase-01-setup-ci.md` |
| §5 Phase 2 | `plan/done/phase-02-thin-slice.md` |
| §5 Phase 3 | `plan/done/phase-03-storage-library.md` |
| §5 Phase 4 | `plan/done/phase-04-text-typography.md` |
| §5 Phase 5 | `plan/phase-05-pages-cover.md` |
| §5 Phase 6 | `plan/phase-06-template-editor.md` |
| §5 Phase 7 | `plan/phase-07-style-guide.md` |
| §5 Phase 8 | `plan/phase-08-sessions-versions.md` |
| §5 Phase 9 | `plan/phase-09-queue-cost-settings.md` |
| §5 Phase 10 | `plan/phase-10-assets-characters.md` |
| §5 Phase 11 | `plan/phase-11-region-editing.md` |
| §5 Phase 12 | `plan/phase-12-consistency-ai-templates.md` |
| §5 Phase 13 | `plan/phase-13-gemini.md` |
| §5 Phase 14 | `plan/phase-14-export-print.md` |
| §5 Phase 15 | `plan/phase-15-release.md` |
| §5 Phase 16 | `plan/phase-16-import-onboarding.md` |
| §5 Phase 17 | `plan/phase-17-hardening.md` |
| §6 Coverage check | `plan/coverage-and-deferred.md` |
| §7 Deferred / not in v1 | `plan/coverage-and-deferred.md` |
| §8 Open items | `plan/coverage-and-deferred.md` |
