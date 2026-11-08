# Phase 13 — Gemini provider (L, floating)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Starts when** you add a Gemini key and Phase 9 is done. The adapter code can be written earlier against documented shapes, but merges only after SG-1 to SG-8. The **image** part needs only Phase 9. The **layout and vision** parts merge after Phase 12 (they implement its protocols), and the region-tool check needs Phase 11.

**Goal:** a second provider for image, layout and vision, plus cross-provider retry.

**Scope:** A §7.1 Gemini quality mapping, §7.5 fixed ratios, §7.6 native history (thought signatures, budgets, stateless fallback, `store: false`), §7.11 Gemini signals. PD §5 quality levels and retry elsewhere, §8.11 per-provider explanations, §8.13 Gemini requirements text. Modules: `BBGemini`, `BBAI`, `BBUI` (settings).

**Deliverables:** run the Phase 0 Gemini spikes first. Then: the Gemini adapter with all three capabilities; `x-goog-api-key` header only; inline data within the budget; native multi-turn when eligible, with an automatic retry once in stateless mode on `MISSING_THOUGHT_SIGNATURE`; "Retry with <other provider>" for every non-auth failure; Settings text explaining what each quality level means per provider; Gemini key entry and test connection.

**Acceptance (by hand)**
- Set Gemini as the default provider. Generate and refine three times: Details shows "native history". Switch the provider mid-lineage and refine: Details shows "stateless".
- Force a refusal on OpenAI (the SP-5 prompt): "Retry with Gemini" is offered, and the retried request's prompt is the same.
- Region editing is unavailable on Gemini, with an explanation.

**Tests added:** request encoding snapshots, history eligibility rules, signature echo exactness, ratio fitting, finish-reason and block-reason mapping, and cost from `usageMetadata` including thinking tokens. Live: a two-turn refinement.

**Risks:** inconsistent signature docs (always echo, fall back once). `store: false` being rejected (catalog flag).

## Gemini spikes (moved from Phase 0 §4.2)

(Old heading: "4.2 Gemini spikes (once you add a key as `gemini-api-key`)")

These run at the start of Phase 13, or earlier if the key turns up sooner. Prices are from A §7.10 (Nano Banana 2.1: 1K $0.034, 2K $0.050, 4K $0.113).

| ID | Question | Method | Est. cost |
|---|---|---|---|
| SG-1 | Which models are visible to the key? Is the account paid (EEA/UK)? | `GET models` with `x-goog-api-key`, compared against the catalog. | $0 |
| SG-2 | Do `aspectRatio`, `imageSize` and `thinkingLevel` behave as expected, and what's in `usageMetadata`? | Three generations: 1K/minimal, 2K/medium, a non-square ratio. Record thinking-token counts. | $0.15 |
| SG-3 | Does `store: false` get accepted? | Same request with and without it. | $0.07 |
| SG-4 | **Thought signatures:** does native multi-turn work when signatures are echoed back, and what happens without them? | Three-turn refinement with signatures echoed exactly; then the same with signatures removed, to record `MISSING_THOUGHT_SIGNATURE`. | $0.25 |
| SG-5 | Is the **inline request limit** 20 MB or 100 MB? | Requests with about 18 MB and about 25 MB of inline references (generated noise PNGs), at 1K. | $0.15 |
| SG-6 | What do **blocks** look like? | At most 2 clearly blockable prompts; record `promptFeedback.blockReason` and `finishReason`. | $0.05 |
| SG-7 | Cancellation and timing | As in SP-6. | $0.12 |
| SG-8 | Do structured output and vision work with the shared schema? | `gemini-3.1-flash-lite` with `TemplateDraft` and the consistency schema. | $0.02 |

**Expected Gemini total: about $0.80.** $2 is allotted.
