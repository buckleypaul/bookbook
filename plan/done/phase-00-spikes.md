# Phase 0 — Live-API spikes and fixtures (S)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** answer the "verify during implementation" items in A §14 against the live APIs before code depends on them, and record fixtures for the offline tests.

**Depends on:** Phase 1a (P-6), so the pre-commit hook and both key scripts exist before any live call.

**Scope:** A §7.1 (catalog), §7.5 (sizes), §7.6 (adapters, masks, history), §7.7–7.8 (structured output, vision), §7.9 (cancel, timing), §7.10 (usage and cost), §7.11 (errors), §14. A throwaway `Spikes/` SwiftPM package, with a small `URLSession` client and the fixture recorder, including its in-memory key check (§2.2), from the first commit. The recorder and redaction code move into `BBNet`'s test support in Phase 2.

**Method:** each spike is a live test (`SPn_…`) run through `scripts/live-tests.sh`. Results go into `spikes/REPORT.md` (question, what was sent, the observed answer, and what changes in the architecture or catalog). Fixtures go into `Spikes/Fixtures/<provider>/<spike>/`. Image payloads are shrunk to a 64 px placeholder PNG, except for one real image per endpoint.

Costs are estimated from the A §7.10 price list (image output about $30 per 1M tokens: low 1024² ≈ $0.006, medium ≈ $0.013, high ≈ $0.053; about $0.006 per reference image in). SP-2 checks these prices.

## 4.1 OpenAI spikes (now)

| ID | Question | Method | Est. cost |
|---|---|---|---|
| SP-1 | Which catalog models does this key see? Is the organisation verified for GPT Image? | `GET /v1/models`; compare with the catalog seed (`gpt-image-2.5-sunburst`, `2.6-sunburst`/`-flare`, `gpt-image-2`, `gpt-6-luna`, `gpt-6.1-terra`). One tiny generation shows whether a 403 verification error comes back. Record the error body if it does. | $0.01 |
| SP-2 | Which **usage/cost fields** come back, and do they match the estimator? Are free sizes accepted? | `/images/generations` at low 1024×1024, low 1024×1536, low with a computed free size (e.g. 1232×816, multiples of 16), one medium and one high 1024². Record `usage` (input/output, text/image token details), latency and returned pixel size. Also try one size below `minPixels` and one above the 2560×1440 "experimental" line, and record the response. | $0.15 |
| SP-3 | How do `/images/edits` with a base image plus references behave? | Multipart `image[]` with a base and 3 references, low. Check: the order is respected (prompt says "image 1 is the base"); usage counts input images; the output keeps the base's size; `output_format: png`, `moderation: auto`, `n: 1` accepted. One request with 16 images to confirm the cap, and one with 17 to record the error. | $0.30 |
| SP-4 | **Mask polarity:** is the edit area the *transparent* or the *opaque* part of the mask? | Base: a synthetic 1024² image of four solid-colour quadrants. Mask A: top-left quadrant transparent, the rest opaque. Mask B: the inverse. Prompt: "Fill the editable area with bright magenta; leave everything else unchanged." Measure, in code, which quadrant changed. Also record the error for a mask whose size doesn't match the base, and how far the changed area spills past the mask edge (this sets the feather default in A §7.6). | $0.10 |
| SP-5 | What do **refusals** look like (shape, `moderation_details`, billing)? | At most **2** requests with a prompt that should clearly be blocked (graphic violence; nothing involving real people or minors), to record the `moderation_blocked` / `image_content_policy_violation` body. Plus free error cases: a bogus key (401), an unknown model (404), an invalid size (400), and an oversized image upload. Kept small because repeated policy hits can flag an account. | $0.02 |
| SP-6 | What happens when a request is **cancelled**, and how long do requests take? | Start a high 1024×1536 generation and cancel the `URLSessionTask` after 5 s. Write down the UTC time, then check the OpenAI usage dashboard the next day (by hand) for a charge in that minute, with no other activity on the key around it. Record typical durations for low, medium and high, which seed the catalog's `typicalDuration`. | $0.10 |
| SP-7 | Do **structured output** (template) and **vision** (consistency) work with the planned models and schema? | Through Chat Completions with `store: false` (P-5): send the `TemplateDraft` JSON Schema (A §7.7, strict-mode intersection) to `gpt-6-luna` and validate the result. Send one consistency request to `gpt-6.1-terra` with a reference and a mismatching image at low detail, and validate it against the A §7.8 output schema. Record usage, and the `refusal` content shape if there is one. If either fails on Chat Completions, stop and raise it with you (P-5). | $0.05 |

**Expected OpenAI total: about $0.75.** $3 is allotted to cover re-runs.

## 4.2 Gemini spikes: moved to Phase 13

The Gemini spikes (old §4.2) now live in `plan/phase-13-gemini.md`, under "Gemini spikes (moved from Phase 0 §4.2)".

## 4.3 Local (no-cost) spikes

These remove risk from Phase 2 and run alongside the live spikes.

| ID | Question | Method |
|---|---|---|
| SL-1 | Does drawing `NSTextLayoutFragment`s into a `CGPDFContext` keep text real and selectable, embed font subsets, and match the on-screen layout exactly? | A small test that renders the same text box to a bitmap and a PDF, then parses the PDF with PDFKit to check the text and fonts. |
| SL-2 | Can a TextKit 2 `NSTextView` laid over a layer-backed canvas run continuous spelling and grammar checking with `allowsUndo = false`, without falling back to TextKit 1? | A throwaway AppKit window with the fallback-notification assertion turned on. |
| SL-3 | Does `WindowGroup(for: BookID.self)` bring an already-open book to the front, and restore windows at relaunch, on macOS 27? | A throwaway SwiftUI app. |

**Deliverables:** `spikes/REPORT.md`; fixtures; corrections to `architecture.md` (§7.6 mask polarity, §7.9 cancel billing, §14 rows marked resolved); first real values for `ModelCatalog.json` and `PriceList.json`.

**Acceptance (by hand):** read `REPORT.md`. Every A §14 row that a live API can answer has an answer or an explicit "couldn't determine, because…". The OpenAI dashboard spend matches the `LiveSpendGuard` total within about 20%. `git grep` for key patterns finds nothing.

**Tests added:** none yet in the product. The fixtures become the input for the Phase 2 and Phase 9 adapter tests.

**Risks:** the account isn't verified for GPT Image (SP-1 finds out on day one; verification can take time, so start it at once if needed). Refusal spikes could flag the account (capped at 2 requests). Cancellation billing may not be visible in the dashboard at all, in which case the product keeps assuming it's billed.
