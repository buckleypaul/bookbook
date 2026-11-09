# Phase 10 — Assets and character sheets (L) · **M3** begins

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** characters, places and objects that stay consistent because their references travel with every request.

**Scope:** A §4.2 `Asset`/`ReferenceSlot`/`CharacterSheet`, §4.3 mention tokens, §4.4 asset changed and where-used, §7.3 step 1 (assets in play), §7.4 (the `ReferenceSelector` in full, with the synonym table), §11 (real-person photos). PD §8.3, §8.6 (asset checklist, `@mentions`, reference another image), §3 (photo notice). Modules: `BBModel`, `BBAI`, `BBUI`. **Depends on Phase 7**, for the thumbnail flag framework and Mark as OK.

**Deliverables**
- Assets tab: create and edit assets of each type, with name, description and tags. Reference slots with one primary. A session for each slot.
- Character sheet: turnaround views and expressions (including custom ones). Lock items. **Generate whole sheet** (batch, with the estimate first).
- `@mention` autocomplete stored as tokens (renaming updates prompts).
- Page asset checklist.
- "Reference another image" picker.
- `ReferenceSelector` tiers and caps, with the "Left out: …" report.
- Where-used list with links.
- Asset changed flag.
- Delete with a where-used confirmation, which turns mentions into plain text.
- Real-person photo question on import (EXIF default), with a notice for each provider on first send. Acknowledgements stored in `Book`.

**Acceptance (by hand)**
- Make "Pip" (a fox). Generate a primary reference, then Generate whole sheet (8 items): the estimate is shown first.
- On page 3, write "@Pip yawning by the fire". Version details lists Pip's primary reference plus the *sleepy* expression and three-quarter view, in that order.
- Rename Pip to "Pippa": the page 3 prompt shows "Pippa". Change Pippa's description: pages using her show "asset changed".
- Import a phone photo as a reference: the real-person question defaults to yes. On first generation, the notice appears with OpenAI's policy link and the advice about photos of children.
- Delete an asset that's in use: the confirmation lists where it's used, and afterwards its mentions are plain text.

**Tests added:** `ReferenceSelector` table tests (tiers, caps, budgets, synonyms, inflections), mention token rewriting, the usage index under edits, asset-changed derivation, sheet batch construction, and a prompt snapshot with a cast.

**Risks:** sheet quality depends on the models (the prompts are resource files, tuned during household use).
