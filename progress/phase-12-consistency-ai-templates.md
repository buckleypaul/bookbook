# Phase 12 — Consistency check and AI templates

**Stage:** done (hand checks deferred), merged 2026-11-08

**Session A note:** five lanes merged: L1 BBAI (normalizer, layout/consistency prompts, text estimates, catalog text models, flag), L2 `OpenAIChatProvider` (layout + vision, SP-7 fixtures, live test `SP12_templateAndConsistency` written, not run), L3 consistency follow-ups (queue kind/parent, `queue.json` schema 2, `ConsistencyAssembler`, delivery, estimates incl. follow-ups, `AppModel+Consistency`), L5 AI template sheet (Layouts tab sparkles button, `TemplateGenerationFlow`), L4 consistency UI (strip badge, panel section with Fix/Dismiss/Check, Version details rows, thumbnail flag, Settings ▸ Models "AI helpers", queue row wording). App wires `OpenAIChatProvider` as vision and layout provider. `scripts/test.sh all` was green before L4; L4 reported BBUITests (412) and the app build green. Nothing was looked at in the running app.

**For Session B:** run the live check `SP12_templateAndConsistency` (est. ~$0.02). Known items to look at: the confirm-cost alert button says "Generate" for a check; chat `refusal` maps to stage `.output` (a guess); the SP12 live test hardcodes model IDs; L4 edited `QueueView.swift` (one line) outside its list.

**Contracts (main thread):** `BBModel/Consistency.swift` (`ConsistencyDifference`, `ConsistencyReport`, `ConsistencySent`); `Version.consistency`; `GenerationIntent.checkConsistency` / `.versionSource`; `BBAICore/TextContracts.swift` (`CatalogTextModel`, `ConsistencyThresholds`, `TemplateDraft`, `StructuredSchemas`, `LayoutRequest/Result`, `ConsistencyRequest/Result`, `LayoutProvider`, `VisionProvider`); BBAI stubs `TemplateNormalizer`, `LayoutPrompt`, `ConsistencyPrompt`, `CostEstimator+Text`, `ModelCatalog.textModels`; `AppPreferences` consistency switch and template/consistency default models; `AppModel.layoutProvider`.

**Assumptions:**
- Template generation runs directly from the Layouts tab (a short request with a progress sheet), not through the generation queue; it writes a `.template` ledger line. Recorded in architecture.md §7.7.
- Phase 14 isn't merged, so the consistency preflight item is Phase 14's (plan §3).
- Dismissing a warning isn't undoable (PD §8.10 doesn't list it); "Show Warning Again" reverses it. It's written with `setConsistencyWarningDismissed`, not a `BookCommand`.

**Session B (2026-11-08):**
- `scripts/test.sh all` green (about 1,090 Swift Testing tests, app and release builds); no project warnings; secret scan clean.
- Live check `SP12_templateAndConsistency` passed: layout $0.0033 (gpt-6-luna) + consistency $0.0039 (gpt-6.1-terra), about $0.007.
- Review fixes: an on-demand check of a real-person photo now shows the real-person notice first, and `ConsistencyAssembler.plan` refuses an unacknowledged real-person checked image, so the automatic follow-up can't send it either (`2299184`, `3c5056b`). Settings ▸ Models no longer clips: the custom-model row is stacked and the footers wrap (`7d1b025`).
- Automated app pass confirmed: Layouts tab AI template sheet (description, page/spread, model, estimate); Settings ▸ Models "AI helpers" (template and consistency model pickers, switch on by default); disabled "Check Consistency" with a missing-key note.
- Deviations: none beyond the Session A assumptions above. Dismissing a warning is not a `BookCommand` (PD §8.10 doesn't list it as undoable).
