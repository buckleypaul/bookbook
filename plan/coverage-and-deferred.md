# Coverage check, deferred items and open items (old §6–§8)

Part of implementation-plan.md; read the core file (§0–§3) first.

## 6. Coverage check: product sections to phases

| PD section | Phase(s) |
|---|---|
| §3 constraints (macOS 27, BYOK, local, privacy notice, distribution) | 1, 2, 10, 15 |
| §5 AI usage: quality, cost, budget, queue, cancel, refusals, reference limits | 2, 8, 9, 10, 12, 13 |
| §7 app structure (sidebar, switcher, queue indicator, windows) | 2, 3, 9 |
| §8.1 library, import | 3, 16 |
| §8.2 style tab | 4, 5 (page numbers), 7, 16 (preset samples) |
| §8.3 assets | 10 |
| §8.4 layouts | 5 (presets), 6, 12 (AI) |
| §8.5 pages | 5, 7 (flags), 9 (draft all) |
| §8.6 page editor and sessions | 2, 4, 8, 10, 11 |
| §8.7 cover | 5 |
| §8.8 export and print | 2, 14 |
| §8.9 consistency | 12 |
| §8.10 undo | 2 (layer), every phase |
| §8.11 settings | 2, 3, 9, 12, 13, 16 |
| §8.12 book settings | 5, 9, 16 |
| §8.13 first run, wizard, sample | 16 |

---

## 7. Deferred / not in v1

**From the product description (non-goals and §9 "Later")**

- DMG download and a "new version available" notice.
- Screen/share PDF (low resolution).
- Read mode.
- AI-written story text.
- Print-on-demand specs: KDP/Lulu, spines, wraparound and back covers.
- Cloud sync, collaboration and accounts.
- Providers other than OpenAI and Gemini.
- Windows, iPad and web.
- Languages other than English, non-Latin scripts and right-to-left text.

**From the architecture and this plan**

- macOS 26 support (dropped 2026-11-07).
- Submission to the official homebrew-cask repo (needs notability; personal tap only).
- App Sandbox and the Mac App Store.
- OpenAI Responses API, server-side conversation state, background mode and server-side cancel.
- Partial-image streaming, and progress beyond elapsed time.
- Region edits for Gemini (outline plus local composite).
- Gemini Files API.
- OpenAI `xhigh`/`max` quality levels (in the catalog, not exposed).
- A Core ML upscaler (the protocol is ready).
- AI-ranked reference selection.
- Copying session history when importing assets from another book.
- Telemetry, crash reporting and update checks of any kind.

---

## 8. Open items to settle later (not blocking Phase 0 or 1)

| Item | Needed by |
|---|---|
| Apple team ID and the release secrets listed in Phase 15 | Phase 15 |
| When the Gemini key arrives | Phase 13 start |
| Homebrew `depends_on macos:` symbol for macOS 27 | Phase 15 |
| Whether to bring Phase 15 forward for household brew installs | After M2 |
