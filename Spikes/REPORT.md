# Phase 0 spike report

**Date:** 2026-11-07 · **Branch:** `phase-0-spikes` · **Toolchain:** macOS 27, Xcode 27.2, Swift 6.4.2
**Live spend:** about **$0.40** (LiveSpendGuard estimate from reported `usage`), against an estimate of $0.75 and an allotment of $3.
**Not run:** the Gemini spikes SG-1…SG-8 (§4.2). There is no `gemini-api-key` Keychain item yet, so they move to the start of Phase 13.

How to rerun: `scripts/record-fixtures.sh --package Spikes openai SP4` (or `live-tests.sh` to run without recording). Each test prints `SPIKE-RESULT <id> <key>: <value>` lines, and those lines are where the numbers below come from. Fixtures are in `Fixtures/openai/SP-n/`. Each endpoint has one real image (the SP-2 low 1024² generation, the SP-3 edit, and the SP-4 mask C edit); every other image is the 64 px placeholder. The local spikes are written up in full in [`notes/local-spikes.md`](notes/local-spikes.md) and summarised here.

## Summary of answers

| # | Question | Answer | Changes |
|---|---|---|---|
| SP-1 | Which catalog models does the key see? Is the org verified? | All six seed IDs are listed, plus `gpt-image-2.5-flare`. A generation works, so the org is verified. | Catalog: add 2.5 Flare. List-models returns `shutdown_date`, which can feed `status`/`retiresOn`. |
| SP-2 | Usage fields; estimator accuracy; free sizes | Usage gives text and image token details for input and output. The 1024² numbers match §7.10 within 2%. Free sizes work. **Output tokens don't scale with pixels.** | §7.10 estimator: use measured per-size entries. |
| SP-3 | Edits with a base plus references | Works. `size: auto` **does not** keep the base size, and an explicit size does. 17 images were accepted. Input images cost about 1 token per 1024 px. | §7.6: always send an explicit size. §7.10: reference input cost scales with pixels. |
| SP-4 | Mask polarity | **The transparent area is the edit area.** The model **can't see the original pixels** under it, and it **may change pixels outside it**. | §7.6: polarity confirmed; local compositing is required, not optional; region-edit prompts must describe the whole area. |
| SP-5 | Refusal and error shapes | Refusals come back as `400 image_generation_user_error / moderation_blocked` with `moderation_details`. An unknown model gives **400**, not 404. | §7.11 mapping table. |
| SP-6 | Cancel billing; durations | Cancelling works locally. **Billing must be checked by hand on the dashboard** (see hand checks). Durations: low ~10 s, medium ~13 s, high ~29 s. | Catalog `typicalDuration`. §7.9 keeps assuming cancelled requests are billed until the dashboard shows otherwise. |
| SP-7 | Structured output and vision through Chat Completions | **Both work** with `store: false` and strict `json_schema`. | None (P-5 holds). |
| SL-1 | TextKit 2 fragments into a PDF: real text, subset fonts, same layout | Yes. Character positions match within 0.13 pt, and fonts are embedded as subsets. | §8.3: the editor and the renderer must share container settings. |
| SL-2 | TextKit 2 `NSTextView` with continuous spelling and grammar, no fallback | Yes, in a real app. The markers don't show up inside the `swift test` host. | §8.3 note, §12 note. |
| SL-3 | `WindowGroup(for:)`: one window per book; restoration | Bring-to-front works. Restoration happens **only when the user's macOS setting allows it**. | §6.1 wording. Product question raised (below). |

## OpenAI spikes (§4.1)

### SP-1 Models and verification
- **What was sent:** `GET /v1/models`, then one low 1024² generation with `gpt-image-2.5-sunburst`.
- **Observed:**
  - 96 models are listed. All six seed IDs are present: `gpt-image-2.5-sunburst`, `gpt-image-2.6-sunburst`, `gpt-image-2.6-flare`, `gpt-image-2`, `gpt-6-luna` and `gpt-6.1-terra`.
  - Also listed: `gpt-image-2.5-flare`, dated snapshots (`gpt-image-2-2026-04-21`, `gpt-image-2.5-sunburst-2026-09-08`, `gpt-image-2.5-flare-2026-09-08`), `gpt-image-1.5`, `gpt-image-1-mini`, `chatgpt-image-latest`, `gpt-6-astra`, `gpt-6-sol` and `gpt-6.1-sol`.
  - Model objects carry a `shutdown_date`. For example, `chatgpt-image-latest` has `"shutdown_date": "2026-12-01"`.
  - The generation returned 200, so there was no verification 403. The org is verified for GPT Image.
- **Changes:**
  - Catalog seed: add `gpt-image-2.5-flare`.
  - §7.1: the availability check can also read `shutdown_date` to mark a model deprecated before it disappears.
  - The `.verificationRequired` mapping in §7.11 stays as documented. It wasn't observed, because this org is verified.

### SP-2 Usage, cost and sizes (`/images/generations`, `gpt-image-2.5-sunburst`)

| Request | Status | Output image tokens | Est. cost | Latency | Returned size |
|---|---|---|---|---|---|
| low 1024×1024 | 200 | 196 (table: 200) | $0.0060 | 17.0 s | 1024×1024 |
| low 1024×1536 | 200 | **158** (pixel-scaled guess: 300) | $0.0049 | 12.2 s | 1024×1536 |
| low 1232×816 (free size) | 200 | **133** (guess: 192) | $0.0041 | 11.3 s | 1232×816 |
| medium 1024×1024 | 200 | 439 (table: 433) | $0.0133 | 13.9 s | 1024×1024 |
| high 1024×1024 | 200 | 1756 (table: 1767) | $0.0528 | 29.2 s | 1024×1024 |
| low 512×512 (below min) | 400 `invalid_value`, param `size`: "Requested resolution is below the current minimum pixel budget." | — | $0 | 0.7 s | — |
| low 3840×2160 (above 2560×1440) | **200** | **371** | $0.0113 | 17.3 s | 3840×2160 |

- **Usage shape:**
  ```
  { input_tokens, input_tokens_details: { text_tokens, image_tokens },
    output_tokens, output_tokens_details: { text_tokens, image_tokens },
    total_tokens }
  ```
  A 26-character prompt was counted as 26 text tokens.
- **Response fields:** the body also carries `background`, `output_format`, `quality`, `size` and `safety_identifier`. Nothing in the response marks a 3840×2160 result as "experimental".
- **Changes:**
  - §7.10: the estimator can't interpolate output tokens by pixel count. Low-quality outputs at other aspects and sizes used *fewer* tokens than 1024². The seed `PriceList.json` carries the measured entries. Estimates for unmeasured sizes should use the nearest measured entry of the same quality, rounded up, and stay labelled "estimate". Actual cost from `usage` stays the source of truth.
  - §7.5: no change. Keep the 2560×1440 cap as a quality guard, because the API itself accepts up to `maxPixels`.

### SP-3 Edits with references (`/images/edits`, multipart `image[]`)
- **Base plus 3 references, `size: auto`:**
  - Base is 1024² quadrants; the references are 256² solids. Returned 200.
  - It returned **1254×1254**, not the base's 1024×1024.
  - Usage: 1792 input image tokens, 95 text tokens, 229 output tokens.
  - The prompt was followed: the base colours were kept and the image-2 colour (magenta) was added in the centre, so image order is respected.
- **Same request with `size: 1024x1024`:** returned 1024×1024, with 1792 input and 196 output image tokens.
- **16 images (128² each):** 200, 1024 input image tokens.
- **17 images:** also **200**, with 1088 input image tokens. The 17th image was counted, so a 16-image cap isn't enforced for this model.
- **Input token cost:** input images are billed at about **1 token per 1024 pixels**: 1024² gives 1024 tokens, 256² gives 256, and 128² gives 64. The fields `output_format: png`, `moderation: auto` and `n: 1` were all accepted.
- **Changes:**
  - §7.6: the adapter must always send an explicit `size`, and for refinements and region edits that's the base image's size. `auto` changes the size and would break masks and local compositing.
  - §7.10: `inputTokensPerReferenceImage: 765` is replaced by pixel-based pricing. A reference downscaled to a 1536 px long edge (1536×1024) costs about 1536 tokens, or about $0.012.
  - Keep `maxReferenceImages: 16`, the documented figure, because the API's actual limit isn't known.

### SP-4 Mask polarity (`/images/edits` with `mask`)

| Mask | Transparent quadrant(s) | Result |
|---|---|---|
| A | top-left | Top-left became **magenta**. The other quadrants were unchanged (colour distance ≤ 4.4). Spill past the mask edge: **0 px**. |
| B | top-right, bottom-left, bottom-right | The three transparent quadrants came back **black**, and top-left (opaque) became **magenta**. |
| C | bottom-right | Bottom-right came back **black**, and bottom-left (opaque) became **magenta**. Reproduced twice, with an alpha of 255 everywhere in the output. |
| C, prompt "keep the area's colour, add a white star" | bottom-right | Bottom-right came back black with a star. The other quadrants were unchanged. |
| Mask 512² on a 1024² base | — | 400 `invalid_mask_image_format`: "mask size does not match image size". |

Conclusions:
1. **The transparent pixels mark the edit area.** Every result changed the transparent region, and none kept the original there.
2. **The model doesn't see the original pixels under the mask.** The region comes back as if it had been erased: the masks have black RGB under alpha 0, and the original yellow never survives even when the prompt says to keep it. Region-edit prompts therefore have to describe everything that should appear in the area, not just the change.
3. **The model isn't confined to the mask.** In B and C it painted magenta onto an opaque quadrant. The documentation's "prompt-based, not pixel-exact" understates this.

**Changes:**
- §7.6: record the confirmed polarity, and make the Core Image composite through the user's mask **mandatory** for every region edit, so pixels outside the mask always come from the original.
- **Phase 11 decision to settle:** give the composite a small feather (the seed of 8 px stays a UI default; the clean case showed 0 px spill), and change the region-edit prompt template so it describes the masked area's intended content.
- **Phase 11 live check to add:** does filling the transparent pixels' RGB with the original image's colours, instead of black, change what the model sees? This wasn't tested, because the spike's mask generator writes premultiplied zeros.

### SP-5 Refusals and errors

| Case | Status | `type` / `code` / `param` | Notes |
|---|---|---|---|
| Blockable prompt ×2 | 400 | `image_generation_user_error` / `moderation_blocked` / null | `moderation_details: {"categories": ["other"], "moderation_stage": "input"}`. The message includes a request ID. No usage was returned, so nothing was billed. |
| Invalid key | 401 | `invalid_request_error` / `invalid_api_key` | The message echoes a masked key with its last 4 characters showing. SpikeKit now redacts that from output and fixtures, and BBNet must do the same (follow-up). |
| Unknown model | **400** (not 404) | `image_generation_user_error` / `invalid_value` / `model` | "The model '…' does not exist." |
| 1000×1000, 1023×1023 | 400 | `image_generation_user_error` / `invalid_value` / `size` | "Width and height must both be divisible by 16." |
| 58 MB upload | 400 | `invalid_request_error` / `file_above_max_size` / `image[0]` | The limit is **50 MB per image**. The rejection took 12.9 s because the whole upload is sent first. |

**Changes (§7.11):**
- OpenAI `.modelUnavailable` should also match `400 invalid_value` with `param == "model"`.
- `.refused` matches `code == "moderation_blocked"` under either `type`, and `moderation_details.moderation_stage` gives the `stage`.
- `.invalidRequest(param)` reads `param`, which is reliably present.
- The new `type` value `image_generation_user_error` appears on many 400s, so the mapper must switch on `code`, not `type`.
- Add `maxImageBytes: 50 MB` to the catalog. The app should check it before uploading rather than spend 13 s finding out.

### SP-6 Cancellation and timing
- **Cancel test:** a high 1024×1536 generation started at **2026-11-07T23:38:59Z**, and its task was cancelled at **23:39:04Z**. `URLSession` threw a cancellation error at once, which was mapped to `HTTPClientError.cancelled`. It's recorded as a $0.08 estimate, on the assumption that it was billed.
- **Is it billed?** That's for the hand check: look at the OpenAI usage dashboard for a charge in the 23:38–23:40 UTC minutes on 2026-11-07 that isn't accounted for. Other spike calls ran within minutes of it, so compare the per-request list rather than the totals. Until then, §7.9 stays as it is ("assume billed").
- **Durations:** low 1024² took 9.7 s (other runs 7.7–17.0 s), medium 1024² 12.8 s (13.9 s), and high 1024² 28.2 s (29.2 s). Edits at low quality took 7.4–11.4 s. These become the catalog's `typicalDurationSeconds`: draft 10, standard 14, high 29.

### SP-7 Structured output and vision (Chat Completions, `store: false`)
- **Template:** `gpt-6-luna` with a strict `json_schema` `TemplateDraft` (see `Tests/OpenAISpikeTests/SP7_StructuredOutputAndVision.swift`). Returned 200 with `finish_reason: stop` and no refusal. It produced two boxes (an image box at 0.059/0.059 sized 0.882×0.58, and a centred text box below), and the result validated. Usage: 224 prompt tokens and 253 completion tokens, **154 of them reasoning tokens**, which are billed as output. Took 4.6 s.
- **Vision:** `gpt-6.1-terra` with two `image_url` data URLs at `detail: low`, against the §7.8 schema. Returned 200 and a valid result: `{consistent: false, differences: [{asset: "Pip's scarf", aspect: "colour", observed: "Solid blue", expected: "Solid red", severity: "major"}]}`. Usage: 306 prompt tokens (images are counted inside `prompt_tokens`, with no separate image field) and 71 completion tokens, 22 of them reasoning. Took 1.9 s.
- **Changes:** none. P-5 (Chat Completions with `store: false`) holds for both. The estimator must count reasoning tokens as output, and `Usage.openAI` already does, via `completion_tokens`.

## Local spikes (§4.3)

Full detail is in [`notes/local-spikes.md`](notes/local-spikes.md).

- **SL-1, yes:**
  - The PDF text can be extracted, searched and selected, with no ligature code points.
  - All 223 characters sit within 0.126 pt of TextKit's positions.
  - The PDF and the bitmap rasters have identical ink bounds.
  - Georgia, SF and Avenir Next are embedded as TrueType subsets.
  - Watch out for `PDFPage.characterBounds(at:)`: it's ink-tight and its index runs one ahead after soft line breaks. Use `selection(for:)` in tests.
- **SL-2, yes, in a real app:**
  - Continuous spelling and grammar work on a TextKit 2 `NSTextView` over a layer-backed canvas with `allowsUndo = false`.
  - There's no TextKit 1 fallback (the notification observer was proven by a control test).
  - Markers live in the `NSTextLayoutManager` rendering attributes (`.spellingState`).
  - Markers never appear inside the `swift test` host, because it doesn't run `NSApplication.run()`. Grammar results vary from run to run.
- **SL-3:**
  - Opening the same `BookID` again focuses the existing window.
  - Book windows are restored at relaunch only if "Close windows when quitting an application" is off, or after ⌥⌘Q. With the macOS default, the app reopens to the Library only.

## architecture.md §14 rows

| Risk | Status after Phase 0 |
|---|---|
| Model churn | Resolved for now: all seed models are present (SP-1). List-models returns `shutdown_date`, which the availability check can use. |
| Prices drift | Partly resolved: the 1024² token counts match the table, and per-size counts are now measured (SP-2). The dashboard-vs-estimate comparison is a hand check. Text-model prices are placeholders, to be checked in Phase 9. |
| OpenAI mask polarity | **Resolved: transparent = edit area** (SP-4). New finding: the content under the mask is invisible to the model, and the model changes pixels outside the mask, so local compositing is mandatory. |
| Gemini thought signatures | Not answered: there's no Gemini key (SG-4, Phase 13). |
| Gemini inline request limit | Not answered: there's no Gemini key (SG-5, Phase 13). |
| Cancellation billing | **Pending the hand check** of the dashboard for 2026-11-07 23:39 UTC (SP-6). Until then, assume it's billed. |
| OpenAI organization verification | Not hit: this org is verified (SP-1). The mapping stays as designed. |
| TextKit 2 falling back to TextKit 1 | Resolved: no fallback with spelling and grammar on. The control test proves the detector works (SL-2). |
| On-screen vs PDF text layout | Resolved for the shared fragment-drawing path (SL-1). The editor's `NSTextView` must use the same container settings (§8.3 note). |
| `depends_on macos:` symbol | Not in scope (Phase 15). |
| Long Gemini histories | Not answered: there's no Gemini key (Phase 13). |

## Product question raised (needs your decision; nothing in Phase 0 depends on it)

**Should BookBook always reopen the books that were open when it quit?** With the macOS default setting, SwiftUI doesn't restore them (SL-3). The options:
- (a) Accept the macOS behaviour, which is the current product text once §6.1 is qualified.
- (b) An app-level "reopen last books" list, opened with `openWindow(value:)`. That can't create duplicates.
- (c) Set `NSQuitAlwaysKeepsWindows` in the app's own defaults domain.

This is recorded under Follow-ups in `PROGRESS.md`.
