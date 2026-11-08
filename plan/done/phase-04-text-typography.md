# Phase 4 — Text and typography (M)

Part of implementation-plan.md; read the core file (§0–§3) first.

**Goal:** story text looks and behaves like real typesetting.

**Scope:** A §4.2 `RichText` in full, §6.3 (text undo coalescing), §8.3. PD §8.2 typography, §8.6 canvas text, rich text and spelling. Modules: `BBModel` (RichText), `BBLayout` (`RichTextBridge`, `TextBoxLayout`, fonts), `BBUI` (formatting controls, the text overlay).

**Deliverables**
- Bold, italic and underline. Per-run font, size and colour. Paragraph alignment. Checking that spelling and grammar (turned on in Phase 2) still work with rich text.
- A format bar and the Format menu, with the standard shortcuts.
- `RichTextBridge` resolving style-guide defaults, so runs without an override follow the style when it changes.
- Typography fields in the style guide (body and title font, size, colour, line spacing, alignment). A minimal Style tab form for them; the full tab is Phase 7.
- Font import into `fonts/` with `.process` registration, a `fsType` embedding check, and missing-font fallback with a warning.
- A red "+" overflow badge.
- Coalesced `SetRichText` undo (1 s pause, box switch, or formatting change).
- A debug assertion for TextKit 1 fallback.

**Acceptance (by hand)**
- Type a paragraph, make "BOOM!" 48 pt red bold in a different font, and export a PDF: it matches the screen, and the text is selectable.
- Change the style's body font: unformatted text changes, and "BOOM!" keeps its own font.
- Import a `.ttf`. Use it, export, then remove the font file from your system: the PDF still shows the font.
- Type until the text overflows: the badge appears. Type, pause, type again, then undo twice: the text comes back in two steps.
- Switch pages and come back: undo still works without a crash.

**Tests added:** RichText ↔ NSAttributedString round-trips (property-based over random runs). Snapshot tests: render the same box on screen and in a PDF, then compare. Font embedding: parse PDF font dictionaries. Overflow edge cases. Undo coalescing timing (with an injected clock).

**Risks:** the TextKit 2 overlay and the rendered layout drifting apart (one layout path, plus snapshot tests). Font licensing flags on some system fonts.
