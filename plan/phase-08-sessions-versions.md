# Phase 8 — Sessions and versions (L)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** the full per-box AI workflow: chat, versions, refinement, your own images.

**Scope:** A §4.3, §6.2 session panel, §7.3 (full assembly without assets: calm areas, fold, safe area, lineage), §7.5 (placement), §7.6 (lineage tree, stateless edit mode, OpenAI `/images/edits`). PD §8.6 (except region editing and asset parts). Modules: `BBAI`, `BBOpenAI`, `BBUI`. Build work starts after Phase 2. The hand checks need Phase 5 (spreads) and Phase 6 (a template with two image boxes).

**Deliverables**
- Session panel: the chat thread with "refined version N" tags, and pending messages.
- Version strip: choose, star, delete, export as an image file.
- Version details: prompt, references sent and left out, provider, model, quality, cost (filled in Phase 9), date. **Regenerate with same settings.**
- Refinement through `/images/edits` with the base image, using the lineage only (refining an old version keeps later ones).
- Reset session (keep or discard versions, with confirmation; not undoable).
- **Use your own image** by drag or file picker, with EXIF normalization and HEIC → PNG.
- Pan and zoom crop on the canvas (undoable).
- Calm-area, fold and safe-area composition guidance in prompts.
- Quality picker (Draft, Standard, High).
- An **Include story text** toggle for each request (on by default), recorded in provenance (PD §8.6, A §7.3).
- Separate sessions for each image box.

**Acceptance (by hand)**
- On a page with two image boxes, generate in each. The two chats and version strips are independent.
- Refine v1 three times (v2–v4), then select v1 and refine again. A new v5 appears, v2–v4 remain, and Version details for v5 shows only the v1 lineage in its prompt.
- Drag in a scanned drawing and refine it ("make the sky blue").
- Reset with "keep versions": the chat clears and the versions remain.
- Pan and zoom the crop, undo it, then export: the PDF crop matches the screen.
- On a spread whose image crosses the fold, the prompt in Details contains the fold instruction.

**Tests added:** lineage resolution (branching trees), prompt snapshots (single, spread, overlapping text box, bleed), stateless-mode condensation, edits adapter multipart encoding (snapshot of the encoded body without the key), import normalization, and epoch hiding. Phase-end live check: one refinement at low quality.

**Risks:** prompt quality for refinements (the prompt templates are resource files, so they can be tuned without code changes).
