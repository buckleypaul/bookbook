# BookBook — Architecture decisions and findings

History split out of architecture.md to save context. The current design lives in architecture.md.

## 15. Findings that may affect `product-description.md`

> **Applied** to `product-description.md` v3 on 2026-11-07: items 1–2 in §3 and §8.13, item 3 in §8.6, item 4 in §5, item 5 in §5, item 6 in §8.5, and item 7 in §5.

The research turned up a few things outside the architecture that you may want reflected in the product description:

1. **OpenAI and photos of children.** OpenAI's under-18 guidance says not to process *personal data of children under 13* without zero data retention, which individual users won't normally have. The real-person photo notice (§3) should probably say this explicitly and steer users towards describing the child in words, or towards a drawing.
2. **Gemini API terms.** Users must be 18 or older, and apps "directed towards or likely to be accessed by" under-18s aren't allowed. BookBook is aimed at parents, which fits, but the guided setup should mention it. In the EEA, Switzerland and the UK, only the paid tier may be used (and Gemini's image models have no free tier anyway). Every Gemini image carries an invisible SynthID watermark.
3. **Region editing is OpenAI-only today.** No current Gemini image model accepts a mask, so §8.6's "unavailable, with a short explanation" applies to every Gemini model.
4. **Quality levels differ between providers.** Gemini has no low/medium/high setting, so BookBook maps levels to resolution and thinking depth (§7.1). The cost estimate and Version details already show the level.
5. **"Remove the word X" is a best guess.** Neither provider says which word triggered a refusal, so the advice comes from a local list (§7.11).
6. **Small addition:** a "Mark as OK" action to clear style, asset or layout changed flags without regenerating (§4.4). Without it, a flag stays until the image is redone.
7. **The queue survives relaunch, restored paused** (§7.9). The product description doesn't say what happens to queued items when the app quits.

---

## 16. Decision log for review

These were decided in this document, without being raised as questions. **All accepted as written on 2026-11-07.**

- Not sandboxed (D12, §13.3).
- OpenAI Images API rather than the Responses API (§7.6).
- Deterministic reference selection rather than an AI-ranked one (§7.4).
- NSTextView's undo is disabled in favour of coalesced model-level undo (§6.3).
- Region-edit results are composited locally (§7.6).
- Asset sessions aren't copied when importing from another book; only the chosen images are (§5.4).
- Context is resolved when a queued item runs, not when it's queued (§7.9).
- Consistency-check follow-ups jump the queue so they run straight after their parent (§7.8).
