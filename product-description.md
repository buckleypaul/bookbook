# BookBook — Product Description

**Status:** Draft v4, in review (v3 adds findings from the architecture research, `architecture-decisions.md` §15; v4 raises the minimum to macOS 27, 2026-11-07)

> **Gemini is post-MVP (decided 2026-11-08):** v1.0 ships with OpenAI as the only provider. Everything about Gemini in this document describes a later release. It stays here so the design keeps room for a second provider.

> **Scope of this document:** *what* BookBook does and for whom. It deliberately leaves out *how* it's built.
> Documents to follow, each written in its own session:
> 1. `architecture.md`: technical design, based on this document (inputs: `architecture-notes.md`, since removed)
> 2. `implementation-plan.md`: phased build plan, based on the architecture
> 3. Execution of the plan

## 1. Summary

BookBook is a native macOS app for making illustrated children's books with AI image generation. You write the story. BookBook helps you illustrate it consistently by building a library of reusable **assets** (characters, places, objects), a book-wide **style guide**, and **page templates**. Then you make each picture in its own AI **session**. Finished books export to PDF for home printing (as single pages or a fold-and-staple booklet) or for a local print shop.

## 2. Goals and non-goals

**Goals**
- Characters and places look the same from page to page.
- Each picture is made and refined on its own, while the book-wide style guide and shared assets keep it consistent with the rest of the book.
- Story text is laid out properly: real fonts, editable, rich formatting, spell-checked.
- Books are stored locally, and assets, templates and styles can be reused across books.
- Print-ready PDF export for home printing (including booklets) and print shops.
- Good results without expertise: sensible defaults, presets and guided setup.

**Non-goals (v1)**
- AI-written story text. The user writes all text. Text/vision AI is used only for template generation and the consistency check.
- Print-on-demand publishing: KDP/Lulu-specific specs, spines, wraparound covers, back covers. (Simple bleed and crop marks for local print shops *are* in scope, §8.8.)
- Cloud sync, collaboration, accounts.
- AI providers other than OpenAI and Gemini, including Anthropic. Claude has no image generation API. Gemini itself is post-MVP: v1.0 is OpenAI only, and Gemini follows in a later release.
- Windows, iPad, web.
- Languages other than English, for both the app interface and story text. Non-Latin scripts and right-to-left text aren't supported.

## 3. Constraints

- **Platform:** macOS 27 and later only.
- **Technology:** native Swift app.
- **AI access:** bring your own API keys (OpenAI in v1.0; Google Gemini is post-MVP). There is no BookBook server or account.
- **Data:** everything is stored locally on the user's Mac. API keys are stored in the macOS Keychain and never in book files. Everything except AI features works offline.
- **Privacy:** the only data that leaves the Mac is what a request sends to the user's chosen AI provider: the prompt, the style guide, the images of the assets used, and the page's story text (when included). There is no analytics or telemetry. The first time the user imports a photo of a real person for an asset, the app explains that it will be sent to the provider and links to that provider's data policy. The notice also points out that providers restrict photos of children. For example, OpenAI's guidance says personal data of children under 13 shouldn't be sent without a zero-data-retention arrangement, which individual users don't normally have. So the notice recommends describing the child in words, or using a drawing, instead of a photo.
- **Distribution:** signed with an Apple Developer ID, notarized, and published on GitHub Releases. Installed with `brew install --cask bookbook` (a personal tap first; submitted to homebrew-cask once it qualifies). Updates come only through `brew upgrade`. There is no in-app updater. A DMG download may be added later (§9).

## 4. Target user

Parents and hobbyists making personal books to read at home, give as gifts, or print at home or a local print shop. They aren't professional designers or illustrators, so the app should have good defaults and work without prior expertise.

**Initial audience:** the author's own household, where the app will be workshopped through real use over time. Wider release, with a friendlier install (§9), comes later.

## 5. AI usage

| Purpose | Providers (v1) | Behaviour |
|---|---|---|
| Image generation and editing | OpenAI (GPT Image models); Google Gemini image models post-MVP | Default provider chosen in Settings; model and quality level are configurable. |
| Template generation (description → layout) | OpenAI text model (Gemini post-MVP) | Returns a layout that opens in the visual template editor (§8.4). |
| Consistency check (image vs references) | OpenAI vision model (Gemini post-MVP) | Runs automatically after each image generation (§8.9). |

- **Quality levels:** Draft, Standard and High, where the model supports them. Draft is cheap and fast for blocking out the whole book; final images are made at a higher level. The level is shown in the cost estimate and recorded on each version. Providers implement levels differently: OpenAI has native quality settings, while for Gemini (post-MVP) a level means a combination of output resolution and model effort. Settings explains what each level means for the chosen provider.
- **Cost visibility:** an estimated cost is shown next to Generate before every generation (including the consistency check, when it's on). The app asks for confirmation only when a single request or a batch costs more than a threshold set in Settings. Each book keeps a running total that uses the actual cost when the provider reports usage, and the estimate (marked as such) otherwise. Prices come from a built-in price list that the user can edit.
- **Budget (optional, per book):** once a book's total passes its budget, the app warns before each further generation. It never blocks.
- **Generation queue:** AI requests run one at a time across the app, and more can be queued behind them. The queue shows each request's book, page and box, its estimated cost and its progress. Waiting items can be reordered or removed, and the running one can be cancelled. Batch actions (for example "Draft all empty boxes") add many items at once, with the total estimate shown first. While requests run, the rest of the app stays fully usable. The queue survives quitting the app: waiting and failed items come back **paused** at the next launch, with an offer to resume them. A request that was running when the app quit counts as cancelled (see below).
- **Cancelling:** the provider may still charge for a request cancelled partway through. The app says so when you cancel and adds the estimated cost to the total.
- **Refusals and errors:** when a provider refuses a request or it fails, the app explains why in plain language and suggests fixes. For example: "describe the child in words instead of uploading a photo", or "remove the word X". Providers don't say exactly what triggered a refusal, so suggestions like "remove the word X" are best guesses and are worded that way ("Try removing…"). If another provider is set up, it offers to retry there. The raw provider message is available under "Details". A failed queue item stays in the queue, marked as failed, and the rest carry on.
- **Reference limits:** if the selected model can't accept every reference a request would include, the app sends the most important ones (assets the prompt names first) and says which were left out.

## 6. Core concepts

| Concept | Description |
|---|---|
| **Library** | All of the user's books, stored locally. |
| **Book** | One project: book settings, style guide, assets, templates, pages, cover. |
| **Style guide** | Book-wide visual direction and print settings. |
| **Asset** | A reusable named element (character, place, object) with one image. |
| **Template** | A page (or two-page spread) layout made of image boxes and text boxes. |
| **Page** | One instance of a template, with story text and a chosen image per image box. |
| **Session** | The AI conversation and image version history for one image box (on a page, the cover, or an asset). |
| **Version** | One image in a session, either generated or imported, with a record of how it was made. |
| **Cover** | A special front-cover page with its own template and sessions. |
| **Queue** | The app-wide list of waiting and running AI requests. |

## 7. App structure

```
┌──────────────┬──────────────────────────────────────────────┐
│ Sidebar      │ Main area                                    │
│              │                                              │
│ ▸ Pages      │  Pages: spread overview / page editor        │
│ ▸ Assets     │  Assets: list, asset editor + image session  │
│ ▸ Style      │  Style: style guide form + preview           │
│ ▸ Layouts    │  Layouts: template list + visual editor      │
│              │                                              │
│ Queue (2) ●  │                                              │
│ [Book ▾]     │                                              │
└──────────────┴──────────────────────────────────────────────┘
```

- A book switcher in the sidebar: switch, create, duplicate and delete books, and open **Book Settings** (§8.12).
- A queue indicator shows how many requests are waiting and opens the queue (§5).
- One window per open book. Multiple books can be open at once.

## 8. Features

### 8.1 Book library
- Create (using the new-book wizard, §8.13), open, rename, duplicate and delete books. Deleting moves the book to the macOS Trash.
- Grid of books with cover thumbnails and last-modified dates.
- The library location defaults to a standard app folder; the user can choose another location.
- Each book is self-contained, so it can be backed up or moved by copying it.
- Changes save automatically, and a crash never corrupts a book.
- **Reopen at relaunch:** the books that were open when BookBook quit open again when it relaunches, whatever the macOS "Close windows when quitting an application" setting. A book that has since been moved out of the library or deleted is skipped without an error.
- **Import from another book:** choose a source book, then pick assets, templates and/or the style guide to copy in. Imports are **independent copies**: editing one doesn't change the other. Name clashes are resolved with a rename prompt.

### 8.2 Style tab
The style guide applies to the whole book and feeds into every image generation.

- **Start from a preset:** a built-in set of style presets (e.g. watercolour, crayon, cut paper, gouache, ink and wash), each with a description and a sample image. Choosing one fills in the fields below, which can then be edited.
- **Visual style description** (free text): medium, palette, line quality, lighting, mood. Example: "soft watercolour, muted pastels, thick pencil outlines, warm afternoon light".
- **Style reference images** (optional): sample images that define the look (including, say, the child's own drawings), sent along with generation requests.
- **Negative guidance** (optional): things to avoid. Pre-filled with "no text, letters or words in the image" so the model doesn't paint lettering that clashes with the real text. Editable.
- **Typography:** body font, title font, default size, colour, line spacing, alignment. Uses installed macOS fonts; custom font files can be imported and are embedded in the PDF.
- **Page setup:** size presets (US Letter, A4, 5.5×8.5 in, A5, 8×8 in, 8.5×8.5 in, 8×10 in, 10×8 in, custom), orientation (portrait/landscape/square) and margins. 5.5×8.5 in and A5 print as booklets on Letter and A4 paper.
- **Bleed:** off by default; turn it on for print-shop output (default 0.125 in). Full-bleed boxes then extend into the bleed, and the editors show the trim line and a safe area. Turning bleed on later slightly enlarges full-bleed boxes, and their crops adjust automatically.
- **Changing page setup after work has started:** boxes keep their position and size relative to the page, and crops are kept where possible. Images whose box shape changes noticeably are marked "layout changed" so the user can redo them.
- **Page numbers:** on/off, position (bottom centre, bottom outer, bottom inner, top outer…), font/size, starting number, and which pages to skip (cover, front-matter pages, specific pages).
- Changing the visual style **doesn't automatically regenerate** existing images. Pages made under an older style are marked "style changed" so the user can redo them if they want.

### 8.3 Assets tab
Asset types: **Character**, **Place/Scene**, **Object**.

Every asset has:
- Name (used for `@mentions`), type and a text description.
- **Exactly one image.** The user writes the description and presses **Generate** (**Regenerate** once there's an image). Each press makes a fresh picture from the description and the style guide; the current image isn't sent, so editing the description and regenerating fully takes effect. The newest picture always becomes the asset's image, and earlier ones aren't shown. The user can instead import a file as the image (see the privacy notice in §3). There's no chat and no refinement for assets.
- An optional **reference photo** (e.g. a photo of the user's child, a pet or a favourite toy). When there is one, Generate sends it along with the description and the style guide, and draws the asset from it in the book's style, keeping the likeness. The description can be left empty. The photo is kept so Regenerate uses it again, and it can be replaced or removed (undoable). It's sent only with the asset's own Generate requests. Pages and the cover get the illustration it produced, never the photo. Imported photos are scaled down and their metadata (camera, date, location) is removed before they're stored or sent. Importing one asks "Is this a photo of a real person?", and generating from a real person's photo shows the privacy notice (§3).
- A **where used** list of the pages, cover and boxes that use it, each linked.

**Layout**
- Left: the asset list.
- Right: the asset editor: large image; name and type; the reference photo (Add Photo… / Replace… / Remove), the description, with a short note on what it's used for, the quality picker, cost estimate, Import Image… and Generate / Regenerate, and the newest request's status; the image's details (what was sent); where used; delete.

When generating a page, the app sends each mentioned or checked asset's image and description.

**Changes and deletion**
- Changing an asset's description or image doesn't regenerate anything. Pages that use the asset are marked "asset changed" so the user can redo them if they want.
- Deleting an asset that's in use shows where it's used and asks for confirmation. Existing images are kept, the asset is removed from asset checklists, and its `@mentions` become plain text.

### 8.4 Layouts tab (templates)
- A template is either a **single page** or a **two-page spread**, sized to the book's page setup.
- It contains **image boxes** and **text boxes**, with position, size, layer order and optional rotation/corner radius. A box can be full-bleed. Text boxes have style overrides (size, alignment, colour, background panel).
- **Built-in presets:** full-bleed image with text overlay, image on top/text below, text on left/image on right, spread with one image across both pages, text-only page, title page, dedication page, "This book belongs to…" page, "The End" page.
- **AI chat:** the Layouts tab's side panel is a chat thread for the open template. Describe a layout ("big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box") to create it, then keep asking for changes ("make the picture full-bleed"). Each reply changes the template in the visual editor as one undoable step and can be restored later. The thread lasts while the book window is open.
- **Visual editor:** drag, resize, snap to margins and guides, align and distribute, and preview with sample text and placeholder art. The centre fold is shown on spreads, and the trim line and safe area are shown when bleed is on.
- Templates can be duplicated within a book and imported into other books.

### 8.5 Pages tab
- **Overview:** pages shown as facing-page spreads in reading order, the way the printed book will look. The cover appears first on its own.
- **Page order** follows picture-book convention: the cover stands alone, page 1 is a right-hand page, and the pages after it pair up as left/right spreads. A two-page spread template always fills a left and right pair. If adding, removing or moving pages would split a spread across two sheets, the app warns and offers to insert a blank page to fix it.
- Add, insert, duplicate, delete and reorder pages (drag and drop). Choose or change a page's template. Changing it keeps the text and images and reassigns them to the new boxes where possible.
- **Import story text:** paste text or open a plain or rich text file. The text is split into pages at blank lines (or at a chosen marker such as `---`), and a preview shows the resulting pages before anything is created. New pages use a chosen template, with each page's text placed in its first text box. Pages can be imported into a new or existing book (inserted after the selected page).
- **Draft all empty boxes:** queues a Draft-quality generation for every image box that has no image yet, using the page's text and checked assets. It's a quick way to see the whole book before making final images. The total estimate is shown first.
- **Status** on thumbnails: empty, in progress or done, plus flags for style changed, asset changed, layout changed and consistency warning. A page is in progress once it has any text or image. Done is set by the user. A style changed, asset changed or layout changed flag clears by itself when the image is redone. The user can also clear it with **Mark as OK** to keep the current image as it is.
- Double-click a page to open the **page editor**.

### 8.6 Page editor and sessions
The page editor shows the page canvas, with the session panel alongside it.

**Canvas**
- Shows the template with live text and images, at page size. Spreads show the centre fold.
- Click a text box to type the story text. It flows and wraps using the style guide's fonts. Overflow is flagged.
- **Rich text:** bold, italic and underline, plus per-word size, colour and font (for words like "BOOM!"), layered on the style guide defaults.
- **Spelling and grammar** are checked as you type, using macOS checking.
- Click an image box to open that box's session in the panel.
- **Use your own image:** drag in or choose a file (a photo, a scan, the child's drawing) for any image box. It's added as a version like any other and can be refined with AI from there.
- Image fit: images are generated at the **closest aspect ratio the model supports**, fill the box, and can be **panned and zoomed** to adjust the crop.

**Session panel**
- **Each image box has its own session.** A page with two picture boxes has two independent chats and version strips. Boxes don't share conversation context.
- A **chat thread** for the selected image box: "Pip the fox and Granny Oak at the castle gate at dusk" → "make Pip smaller and looking up at Granny".
- **Assets:** `@mention` them in the prompt (with autocomplete) and/or tick them in the page's asset checklist. Selected assets' descriptions and images are included automatically.
- **Reference another image (optional):** attach a version from another box or page (e.g. "same kitchen as page 4"). Only that image is sent; no conversation or other context comes with it.
- **Context included with each request:** style guide (text + reference images), selected assets, any attached image references, image box shape and placement (e.g. "leave the bottom third calm for text"), the centre fold position on spreads (with a request to keep faces and key details away from it), the page's story text (optional, on by default), and the session's conversation so far.
- **Version strip:** every generated or imported image is kept. Click a version to put it on the page. Versions can be starred, deleted, or exported as image files.
- **Version details:** the prompt, the assets and references sent, provider, model, quality level, cost, date and consistency result, with **Regenerate with same settings**.
- **Refining:** follow-up prompts refine the currently selected version. The thread stays a single conversation, and each message shows which version it refined, so refining an older version never removes later ones.
- **Region editing:** select an area of the selected version (brush or lasso) and describe the change. Only that area is altered. If the model doesn't support region edits, the option is unavailable, with a short explanation. In v1 only OpenAI's GPT Image models support it. With Gemini (post-MVP), changes will be made by describing them in a follow-up prompt.
- **Reset session:** clears that box's conversation and starts fresh with the same base context. The user chooses whether to keep or discard existing versions. Reset can't be undone, so it asks for confirmation.
- Sessions are fully **separate**. Nothing from one box or page reaches another unless the user explicitly attaches it as a reference.

### 8.7 Cover
- Front cover only (v1). Uses a cover template (title, author, image box) and the same session workflow as pages.
- Title and author come from book settings (§8.12) and are drawn by the app in the title font.

### 8.8 Export and print
- **Export PDF:** all pages in order with the cover first, at the book's page size. Fonts embedded, text kept as real (selectable, sharp) text.
- **Print resolution:** images target 300 DPI at their printed size. Images below that are **upscaled automatically** on the Mac during export, at no AI cost. The app warns only when the upscaled result is likely to look soft (very small sources), and the upscaled image can be previewed.
- **Output types:**
  - **Standard** (home printing): pages at trim size, no bleed.
  - **Print shop:** adds the bleed from page setup and crop marks. Available when bleed is on; the app offers to turn it on.
  - **Booklet:** pages placed two-up in fold-and-staple order for double-sided printing on a chosen sheet size (Letter, A4, Tabloid, A3). The page count is padded to a multiple of four with blank pages, and the user is told how many were added. If the page size doesn't fit two-up on the sheet, the app scales it to fit and says so. Printing instructions (e.g. "flip on short edge") are shown. The cover is the outer sheet unless it's excluded (for printing separately on card).
- Options: include/exclude cover, page range, and, for Standard and Print shop, spreads exported as single pages (default) or as spread pages.
- **Before export:** a summary of outstanding issues: empty image boxes, text overflow, spelling, images that will look soft, style/asset/layout changed flags, and consistency warnings. Each one links to the page. Export can go ahead regardless.
- **Print:** standard macOS print dialog, for any output type.
- Also: export single pages or images as PNG/JPEG.

### 8.9 Consistency check
- After every image generation (pages, cover and assets), a vision model compares the new image with the image of each asset used, plus the style guide.
- If it finds drift, the version gets a **warning badge** and a short list of differences. Example: "Pip's scarf is blue; reference is red", or "castle has two towers; reference has three".
- **One-click fix:** turns the differences into a correction prompt and sends it in that box's session as a new generation (cost estimate shown first).
- Warnings are advisory. The version can still be chosen, and a warning can be dismissed.
- Imported images aren't checked automatically. A check can be run on demand on any version.
- On by default, with one **global switch** in Settings. Its cost appears in estimates and totals.

### 8.10 Undo / redo
- **Covered:** canvas edits (text, formatting, crop/pan/zoom), template editor edits, style and asset field edits, which version is chosen for a box or an asset, page add/delete/duplicate/reorder/template change, and story text import (as one step).
- **Not covered** (these ask for confirmation instead, or can be fixed another way): AI generations (every result stays in the version strip and can be deleted there), session resets, asset deletion, version clean-up (§8.12), and book deletion (the book goes to the Trash).
- Undo history is kept separately for each open book window and lasts until the book is closed.

### 8.11 Settings (app-wide)
- **API keys:** OpenAI in v1.0 (Gemini post-MVP), with a "test connection" button. The guided setup (§8.13) can be reopened from here.
- **Default providers, models and quality level:** for images, templates and the consistency check.
- **Consistency check:** on/off.
- **Cost:** confirmation threshold, and the price list (view and edit the per-model prices used for estimates).
- **Library location.**

### 8.12 Book settings
- **Title and author:** used on the cover and title page.
- **Cost:** running total, a breakdown by type (images, consistency checks, templates), a list of recent requests, and the optional budget (§5).
- **Storage:** the book's size on disk. **Clean up** deletes unstarred versions that aren't used on any page, the cover, or an asset. It shows how many will go and how much space it will free, and asks for confirmation, because it can't be undone.

### 8.13 First run and new books
- **Guided setup (first run):** explains what an API key is, gives step-by-step instructions for getting an OpenAI key (a Gemini key once Gemini lands, post-MVP), lets the user paste and test it, and shows typical costs (per image and for a whole book) from the price list. It also covers each provider's requirements:
  - **OpenAI** may ask the user to verify their organization before its image models can be used.
  - **Gemini** (post-MVP) requires users to be 18 or over. In the EEA, Switzerland and the UK it needs a paid account (its image models have no free tier anywhere). Every Gemini image carries an invisible SynthID watermark.
  
  It can be skipped.
- **Sample book:** a small bundled example book to open and explore, no API key needed.
- **New-book wizard:** title and author, page size, a style preset, and optionally a main character (name and description). Every step can be skipped and changed later. It ends with an offer to import story text (§8.5).

## 9. Later (after v1)

- **DMG download** on GitHub Releases, with a "new version available" notice, for users without Homebrew.
- **Screen/share PDF:** a smaller, lower-resolution PDF for emailing to family.
- **Read mode:** full-screen page turning, for reviewing the book or reading it on screen.

## 10. Open questions

None at present.
