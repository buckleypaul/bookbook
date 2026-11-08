# Phase 16 — Library import, book settings, onboarding and sample (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** the app is friendly to start with and manageable over time.

**Scope:** A §5.4 `BookImporter`, sample book, §10 (§8.12, §8.13 rows), `CleanUp`. PD §8.1 import, §8.12, §8.13, §8.2 preset sample images.

**Deliverables**
- Import from another book: assets, templates and/or the style guide as independent copies; deduplication by hash; a rename prompt for name clashes.
- Book Settings in full: title and author, cost breakdown by type, recent requests, budget, size on disk, **Clean up** (count, bytes freed, confirmation).
- First-run guided setup: what a key is, steps for each provider, paste and test, typical costs from the price list, OpenAI verification and Gemini requirements text. It can be skipped and reopened from Settings.
- New-book wizard: title and author, size, style preset, optional main character, then an offer to import story text.
- Style preset sample images and the **sample book**, made by you in the app (see the content note below) and bundled.

**Acceptance (by hand)**
- On a fresh macOS user account: first run shows guided setup. Skip it, open the sample book with no key, and explore it.
- Run the wizard with a main character, and import story text at the end.
- Import Pip and a template from another book: editing the copy doesn't change the original.
- Clean up a book with 30 unused unstarred versions: it reports the count and MB, and afterwards the size on disk drops by that amount.

**Tests added:** importer deduplication, name clashes and ID remapping. The CleanUp deletable set (never placed, starred, reference or sheet versions). Wizard output in the model.

**Content note (outside the $10 live-test cap):** making about 8 preset samples and a 6–8 page sample book at Standard quality is roughly 40–60 generations, about **$1–3** in the app at catalog prices. You do this yourself through the app's own cost display.

**Risks:** the sample book's file size inflating the app (keep its images at Standard and limit its size, e.g. under 15 MB).
