# Phase 9 — Queue, cost, errors and settings (L) · completes **M2**

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** you can draft a whole book safely: queued work, known costs, understandable failures.

**Scope:** A §7.1 (catalog availability, successors, custom model ID), §7.9 in full, §7.10, §7.11, §6.4 (closed-book deliveries), §5.5. PD §5 (queue, cancel, costs, budget, refusals, reference limits), §8.11 (image parts), §8.5 "Draft all empty boxes", §8.12 cost display and budget (minimal). Modules: `BBAI`, `BBOpenAI`, `BBStore` (ledger), `BBUI`. **Depends on Phase 3**, for the ledger primitive, headless `BookStore` and several open books.

**Deliverables**
- `GenerationQueue`: persistence (restored paused, with a banner), reorder, remove, cancel running (with a billing notice and an estimated ledger entry), automatic retry with backoff and `Retry-After`, a 300 s timeout, offline pause through `NWPathMonitor`.
- Queue window, plus a sidebar badge showing book, page, box, estimate and progress (elapsed time against typical duration).
- `CostEstimator` and `CostCalculator`, the ledger, the cost shown next to Generate, a confirmation threshold, and budget warnings.
- `PriceList` with a user override, an editor, its as-of date and "reset to built-in".
- `ProviderError` mapping from the Phase 0 fixtures. `RefusalAdvisor` rules (A §7.11) with **Details**. Failed items stay in the queue.
- Settings: API key **Test connection**, list-models availability, a prompt when a model has disappeared, default model and quality, threshold, custom model ID.
- **Draft all empty boxes**, with the total estimate first.
- Book running total, recent requests, and the optional **budget** field, added to the minimal Book Settings sheet from Phase 5. The full Book Settings cost view is Phase 16.
- Deliveries into closed books (`BookWriter`, headless).

**Acceptance (by hand)**
- In a 12-page book, choose Draft all empty boxes. It shows "12 requests, about $0.07" and asks for confirmation if that's above your threshold. While it runs, keep editing text in another book. Reorder two waiting items, and cancel the running one: the notice says it may be billed.
- Quit halfway through. Relaunch: the banner reads "Resume N queued requests" and the queue is paused. Resume it.
- Close the book while items are queued: they still land, and reopening shows them.
- Set a $0.05 budget: a warning appears before the next generation, and it still runs if you confirm.
- Change the key to garbage: you get "Your OpenAI key was rejected" with steps, and Details shows the raw body with no key in it.
- Book total equals the sum in Recent Requests, with actual-cost entries marked as such.

**Tests added:** queue state machine (enqueue, run, cancel, fail, retry, persist and restore, offline); estimator against the published calculator figures and SP-2 actuals; error mapping for every fixture; advisor rule ordering; CostPolicy thresholds; headless delivery into a closed book; ledger totals. Phase-end live pass: a two-item queue plus one cancel (about $0.10).

**Risks:** queue and book write races (all writes go through `BookStore` actors; tests with an injected slow provider). Estimator drift (calibrate with SP-2 data).
