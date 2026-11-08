# Phase 9 — Queue, cost, errors and settings (2026-11-08)

**Status:** done (merged 2026-11-08) · branch `phase-9-queue-cost-settings` · no PR (merged into main directly) · live spend **$0.04** (`SP9_twoRequestsAndCancel`: $0.006 generate + $0.018 edit + $0.02 estimated cancel).

**Hand checks:** the user said to assume they passed (2026-11-08). An automated pass without a real key confirmed the items marked *(auto)*.
- [x] 12-page book, Draft all empty boxes: shows the count and estimate, and confirms above the threshold. *(auto: "13 requests, about $0.08", because the cover's image box counts too)* Keep editing another book while it runs; reorder two waiting items; cancel the running one, and the notice says it may be billed.
- [x] Quit halfway, relaunch: "Resume N queued requests" banner, queue paused; resume. *(auto: banner and paused state)*
- [x] Close the book while items are queued: they still land and show on reopen.
- [x] $0.05 budget: a warning before the next generation, and it still runs on confirm. (It fires once the book's total passes the budget, per PD §5.)
- [x] Garbage key: "Your OpenAI key was rejected" with steps. *(auto: wording and steps)* Details shows the raw body with no key. (Automation couldn't expand Details.)
- [x] Book total equals the sum in Recent Requests, with actual-cost entries marked.


**Contracts (main thread, 2026-11-08):** `BBModel/Cost.swift` (`CostRecord`, `LedgerSummary`); `BBAI/CostContracts.swift` (`PriceList`, `CostEstimate`, `ImageEstimateInput`, `CostPricing`, `CostDecision`); `BBAI/Contracts.swift` queue types (`QueueItem` now Codable with `estimate`/`display`/`enqueuedAt`, `QueueFailure`, `.retrying`, `QueuePause`, `QueuePosition`, `DeliveryResult`, `GenerationHost.recordCost`, `QueuePersistence`, `PersistedQueue`; `AssemblyReport` Codable with `storyText`); `BBAI/AdvisorContracts.swift` (`FailureAdvice`, `AdviceContext`, `CustomModelSpec`, `ModelAvailability`); BBAICore `ProviderError` Codable, `ModelLister`, `CatalogModel.copiesFrom`; `BBStore/AppSupportFiles.swift`; `Resources/SensitiveTerms.json`.

**Assumptions (plan defaults; overrule if wrong):**
- Confirmation threshold default **$0.50** per request or batch.
- Money is `Decimal` USD throughout (matches `Book.budget`).
- One ledger line per provider request, including automatic retries. $0 for HTTP 4xx/5xx failures; the estimate for cancels, timeouts and transport errors (they may be billed).
- Custom model IDs and the default model/quality/threshold are stored in `UserDefaults` (A §5.5 put catalog overrides in `pricelist.json`; recorded in architecture.md).
- Template and consistency default-model settings wait for Phase 12 (nothing uses them yet).
- "Retry with <other provider>" is computed but hidden until Phase 13 (only OpenAI is configured).
- A delivery to a book locked by another process is kept in memory by the queue and retried; it's lost if the app quits first.
- Prices checked against OpenAI's pricing page on 2026-11-08: image models unchanged; `gpt-6-luna` $0.10/$0.50 and `gpt-6.1-terra` $1.00/$5.00 per 1M (no longer placeholders); the other four image models got entries reusing the 2.5-sunburst output-token table (unmeasured).

**Session A lanes (all merged into the phase branch):**
- Cost (sonnet): `PriceList` loading/override, `CostEstimator` (+ `estimateInput` via `ContextAssembler.plan`), `CostCalculator`, `CostPolicy`. 12 Draft 1024² ≈ $0.072.
- Queue (opus): full A §7.9 queue: retries/backoff/`Retry-After`, 300 s timeout, pause reasons, persistence and restore, ledger per request, redelivery for locked books. `QueueRetryPolicy.swift`.
- OpenAI (sonnet): `OpenAIModelLister`, error mapping tests for every fixture plus synthetic bodies, shared transport mapping, cancellation test, live test `SP9_twoRequestsAndCancel` (written, **not run**).
- Advisor/catalog (sonnet): `RefusalAdvisor` (ordered rules), `SensitiveTerms`, `ModelCatalog.adding/resolve/imageModels/availability`, `AssemblyReport.storyText`.
- Views (sonnet): Queue window, sidebar badge, resume/offline banners, cost next to Generate + confirm/budget alert, cancel notice, `FailureAdviceView`, Draft All Empty Boxes…, Book Settings cost + budget, Version details cost, Settings (Test Connection, Models tab, Cost tab with price list editor).
- Wiring (opus): AppModel on the new queue (restore-gated op chain), `QueueFileStore`, `NetworkMonitor`, ledger writes open/closed, `DeliveryResult`, Draft all planner, list-models at launch, custom-model catalog and pricing pushes.

**State at end of Session A:** `swift build --build-tests` clean (no warnings); all package tests pass; `scripts/test.sh app` passes. `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` failed once again and passed on re-run (known flaky, Later).


**Session B (2026-11-08):**
- Live pass `SP9_twoRequestsAndCancel` passed. A 1536×1024 reference measured **1536** input-image tokens (the patch rule predicted 704). Added to `PriceList.json` for every image model; estimator tests now use 2048² for the unmeasured patch-rule case.
- `scripts/test.sh all` green (318 package tests, no compiler warnings). `FaultInjectionTests.concurrentSavesAndOpensDoNotRaceOnJournalFolder` flaked once in the fix lane and passed on re-run (known, Later).
- Review must-fixes, fixed in one round (re-review clean): Regenerate with Same Settings skipped the cost confirmation and budget warning (now shares Generate's path, via `AppModel.regenerateEstimate`); `CostCalculator` charged cached tokens on top of input (now a subset at the cached rate, attributed to text first, then image).
- Hand-check fixes: the Settings → Models custom model ID field was squeezed to a few characters; Regenerate is now disabled offline, like Generate.
- Secret scan clean over the whole tree.
