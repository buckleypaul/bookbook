# BookBook: Notes for the Architecture Session

These ideas came up while writing `product-description.md` but are about *how*, not *what*, so they were moved here. They are **non-binding suggestions**. The architecture session should feel free to accept, change or reject any of them. `product-description.md` is the source of truth for requirements.

## Suggestions

- **UI:** SwiftUI.
- **Provider abstraction:** put each AI capability (image generation/editing, layout generation, vision consistency check) behind a protocol, with OpenAI and Gemini implementations, so more providers can be added later.
- **Templates as structured data:** e.g. a JSON schema for templates. The text model fills it using structured output, and it can be copied between books and diffed.
- **Book storage:** each book as a self-contained folder package (e.g. `MyBook.bookbook/`) with a manifest (metadata, style, templates, pages, assets) plus image files and session logs. Default library location `~/Library/Application Support/BookBook/`. Use atomic writes for crash safety.
- **Secrets:** API keys in the Keychain.
- **Homebrew cask:** `auto_updates false`, since updates come only through `brew upgrade`.

## Things the architecture should explicitly address

- How session context (style, assets, sheet images, conversation history, selected version) is put together for each provider, given that their image APIs differ in multi-image input, editing and conversation support.
- How the "most relevant sheet images" are chosen for a request (§8.3).
- Mapping image box shapes to the aspect ratios each model supports, and how crop/pan/zoom is stored.
- Text layout and PDF rendering pipeline (fonts, embedding, page numbers, spreads, 300 DPI images).
- Undo/redo model across windows (§8.10).
- Cost estimation and tracking data.
- Error and refusal classification for plain-language messages (§5).
- Signing, notarization and release automation for the cask.
