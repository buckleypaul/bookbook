# Local spikes SL-1, SL-2, SL-3 (implementation-plan.md §4.3)

Run on 2026-11-07: macOS 27 (Darwin 27.0.0), Xcode 27.2, Swift 6.4.2, Apple Silicon, logged-in GUI session.
These spikes are local only. They make no network calls, use no keys, and cost $0.

How to rerun:

- SL-1 and SL-2 (in-process parts): `cd Spikes && swift test --filter LocalSpikeTests`. This needs a GUI session for SL-2; the suite skips itself without one.
- SL-2 (marker check in a real app): `Spikes/scripts/sl2-run.sh [--control]`
- SL-3: `Spikes/scripts/sl3-run.sh --auto` (automated), or `Spikes/scripts/sl3-run.sh` (by hand)

Every finding is printed as a `SPIKE-RESULT SL-n <key>: <value>` line.

---

## SL-1: TextKit 2 fragments drawn into a CGPDFContext

**Question.** Does drawing `NSTextLayoutFragment`s into a `CGPDFContext` keep the text real and selectable, embed font subsets, and match the on-screen layout exactly?

**What was done.** `Tests/LocalSpikeTests/SL1TextKitPDFTests.swift`:

- **Layout.** Four paragraphs in a fixed 324 × 300 pt `NSTextContainer` (`lineFragmentPadding = 0`) on a 432 × 432 pt page, using `NSTextContentStorage` and `NSTextLayoutManager`. Fonts: Georgia 22 (from `/System/Library/Fonts/Supplemental`, which ships with the OS), the system font 13, and AvenirNext-DemiBold 15. One paragraph is centred, and the text includes "fluffy" and "waffle" to test ligatures.
- **Drawing.** Each fragment is drawn with `draw(at:in:)` into (a) a 2× bitmap `CGContext` and (b) a `CGPDFContext` that writes to memory. Both use the same code: flip the CTM once, then set `NSGraphicsContext(cgContext:flipped: true)` as current. This is the PageRenderer path in §8.3.
- **PDFKit checks.** `PDFDocument.string`, `findString`, and `PDFPage.selection(for:)`. For all 223 non-space characters, the test compares the one-character selection's bounds with TextKit's `NSTextLineFragment.locationForCharacter(at:)` and the baseline (`layoutFragmentFrame` + `typographicBounds` + `glyphOrigin`).
- **Raster check.** The PDF page is drawn back into a 2× bitmap and compared pixel by pixel with the direct render.
- **Font check.** `CGPDFDictionary` walks the page `/Resources /Font` entries (and any Form XObjects), reading `BaseFont` and `FontDescriptor` / `FontFile{,2,3}`.

**Observed answer: yes, on all three points.**

| Check | Result |
|---|---|
| Text extractable | All paragraphs are in `PDFDocument.string` once whitespace is normalised. Exact paragraph matching fails only because PDFKit puts a `\n` at each soft line wrap, which is expected. |
| Searchable / selectable | `findString` finds phrases ("Once upon a time"; "fluffy" and "waffle" too). The selection bounds (54, 347, 172 × 26) fall inside the text box. A whole-page selection returns all 278 characters. No ligature code points (U+FB00–FB06) appear in the extracted text. |
| Positions vs TextKit | 223 of 223 characters matched in order. **Max x delta 0.126 pt, max baseline delta 0.005 pt** (limit 0.5 pt). |
| PDF raster vs direct bitmap (2×) | Identical ink bounding boxes. Mean channel difference 0.033/255. 248 pixels (0.033 %) differ by more than 32/255, all of them antialiasing at glyph edges. |
| Fonts | 3 fonts, all `TrueType` with `FontFile2`, all subsets: `AAAAAB+Georgia`, `AAAAAC+.SFNS-Regular_wdth_opsz110000_GRAD_wght`, `AAAAAD+AvenirNext-DemiBold`. |

Things worth knowing:

- **Subset prefixes are deterministic.** Core Graphics names them `AAAAAB`, `AAAAAC` and so on, not random. They're still valid subset tags.
- **The system font (SF) is a variable font.** CG embeds the instance actually used, as a TrueType subset with a dotted name (`.SFNS-…`). That's fine for viewing and printing, but the name is ugly in preflight and font lists. If print shops complain, the product could show the user a real family name. This isn't a blocker.
- **PDFKit quirk.** `PDFPage.characterBounds(at:)` returns tight ink boxes, and on macOS 27 its index runs one character ahead of `page.string` after every soft line break that PDFKit inserts (198 of 223 characters were off). `PDFPage.selection(for: NSRange)` + `bounds(for:)` lines up correctly and gives the advance box (descender to ascender). Any future PDF snapshot or position test should use selections, not `characterBounds(at:)`.
- **"Matches the on-screen layout".** This spike proves that the bitmap path and the PDF path agree, because both draw the same `NSTextLayoutFragment`s. It doesn't compare against a live `NSTextView` editing session: `NSTextView`'s own container defaults to `lineFragmentPadding = 5`, and its frame and inset geometry differ from `TextBoxLayout`.

**What changes in architecture.md.**

- **§8.3: no change to the approach.** The rendering claim holds.
- **§8.3, suggested addition.** `TextBoxLayout` and the inline editor `NSTextView` must use the same container settings: `lineFragmentPadding` (0 here), `textContainerInset = .zero`, the same width, and the same paragraph and hyphenation settings. Otherwise the editor and the rendered page will wrap differently.
- **§12 (testing), suggested note.** PDF text-position tests should use `PDFPage.selection(for:)` bounds, because `characterBounds(at:)` is ink-tight and has the off-by-one quirk above.

**Confidence: high.** The numbers are deterministic from run to run.

---

## SL-2: TextKit 2 NSTextView over a layer-backed canvas, continuous spelling and grammar checking

**Question.** Can a TextKit 2 `NSTextView` laid over a layer-backed canvas run continuous spelling and grammar checking with `allowsUndo = false`, without falling back to TextKit 1?

**What was done.**

- **Test setup.** `Tests/LocalSpikeTests/SL2SpellCheckTextKit2Tests.swift` builds an `NSWindow` programmatically. Its layer-backed content view holds a layer-backed canvas view with a `CALayer` "page", and an `NSTextView(usingTextLayoutManager: true)` sits on top as a subview. The text view has `drawsBackground = false`, `allowsUndo = false`, `isContinuousSpellCheckingEnabled` and `isGrammarCheckingEnabled` on, and auto-correction and replacement off.
- **Fallback assertion.** The test observes `NSTextView.willSwitchToNSLayoutManagerNotification` with `object: textView`. It types text containing misspellings with `insertText(_:replacementRange:)`, pumps AppKit events, edits and restyles the text, and asserts that no notification was posted and `textLayoutManager != nil`.
- **Control test.** A clearly labelled CONTROL test, on its own view, reads `textView.layoutManager` to prove that the observer catches a fallback. Nothing else touches `.layoutManager`.
- **Real-app check.** `scripts/sl2-run.sh` compiles `scripts/sl2-app/main.swift` with the same setup into a minimal `.app` (`app.bookbook.spike.sl2`) and launches it with `open`. It types the sample a word at a time, waits for markers, corrects one word, restyles a range, and reports. `--control` repeats the run after forcing TextKit 1, for comparison.
- **Reading markers without touching `layoutManager`.** On TextKit 2, `NSTextView` stores spelling and grammar markers as **rendering attributes on the `NSTextLayoutManager`**: key `.spellingState`, with values made of `NSAttributedString.SpellingState` bits. They're read with `textLayoutManager.enumerateRenderingAttributes(from:reverse:using:)`. The markers are not in the text storage, which was checked and found empty. In TextKit 1 they're `NSLayoutManager` temporary attributes, and that path was used only in the control run.

**Observed answer: yes.**

| | Real `.app` (TextKit 2) | Real `.app`, TextKit 1 control | Inside `swift test` |
|---|---|---|---|
| `willSwitchToNSLayoutManagerNotification` | **0** | 1 (control) | **0** (control test: 1) |
| `textLayoutManager` at end | **present** | nil | **present** |
| Spelling markers | `brwon`, `jumpd`, `lazzy`; same as `NSSpellChecker`, after about 1.4 s | same | **none** |
| Grammar markers | `go`, `was` (from "She go … they was happy.") | `go`, `was`, `is` | none |
| After correcting "brwon" | `jumpd`, `lazzy` (marker removed) | same | — |
| `allowsUndo` / `undoManager.canUndo` | false / false | false / false | false / false |

Things worth knowing:

- **Markers don't appear inside the `swift test` host.** This is true for TextKit 2 and TextKit 1 alike (a TextKit 1 probe was tried too), even after `NSApp.activate()` made the window key, and even after calling `checkTextInDocument(_:)`. `NSSpellChecker.check(…)` itself works in-process. The test host never runs `NSApplication.run()`, and the delayed checking that `NSTextView` schedules apparently depends on that. So the in-process test asserts the fallback facts, which hold, and the marker check lives in `sl2-run.sh`. Phase 4 tests of the inline editor should do the same: assert no fallback in unit tests, and check markers in a UI test or app-hosted test.
- **Grammar checking isn't deterministic.** `NSSpellChecker`'s grammar verdicts on the same text varied between runs: one run flagged "Me and him is going home.", another didn't. Tests should require spelling markers but only record grammar markers.
- **Undo goes to the document.** With `allowsUndo = false`, the view registers no undo, which fits §6.3 (every undoable edit is a `BookCommand`).
- **Canvas layering doesn't matter.** Putting the text view on a layer-backed canvas has no effect on checking or on the TextKit 2 path.

**What changes in architecture.md.**

- **§8.3: no change to the approach.** The "TextKit 1 trap" bullet holds: reading `.layoutManager` switches the view at once (one notification, then `textLayoutManager` becomes nil), and nothing else does.
- **§8.3, suggested addition.** Spelling and grammar markers live in the `NSTextLayoutManager`'s rendering attributes (`.spellingState`), and code must not look for them in the text storage or temporary attributes. Continuous checking needs a running `NSApplication`, so it can't be tested in a plain `swift test` host.

**Confidence: high** for the no-fallback result and for spelling. **Medium** for grammar, because the checker itself varies.

---

## SL-3: `WindowGroup(for: BookID.self)`, bring to front and restoration

**Question.** Does `WindowGroup(for: BookID.self)` bring an already-open book to the front, so that opening the same value twice gives one window? And does it restore windows at relaunch, on macOS 27?

**What was done.**

- **The app.** `Sources/SL3WindowGroupApp/SL3App.swift` has the same shape as §6.1: a `Window("Library", id: "library")` plus a `WindowGroup(for: BookID.self)`. `BookID` is a `Codable`, `Hashable` struct that wraps a `UUID`, with fixed IDs for books A and B. The Library window and each Book window have buttons that open A or B with `openWindow(value:)`.
- **The script.** `scripts/sl3-run.sh` builds the product with `swift build --product SL3WindowGroupApp`. It wraps the result in `Spikes/.build/sl3/SL3WindowGroupApp.app`: an Info.plist with `CFBundleIdentifier` `app.bookbook.spike.sl3`, an ad-hoc signature, and registration with LaunchServices. It then launches the app with `open -n -W --stdout`, using `--auto` scenarios that count visible windows by title through `NSApp.windows` and `NSApp.orderedWindows` and quit through `NSApp.terminate` (the same path as Cmd-Q).
- **The user's setting.** `defaults read NSGlobalDomain NSQuitAlwaysKeepsWindows` reports the key as **unset** on this Mac. That's the system default: "Close windows when quitting an application" is ON. To simulate the setting being OFF without changing the user's settings, one scenario passes `-NSQuitAlwaysKeepsWindows YES` as a launch argument, which sets the argument domain for that process only.

**Observed answer.**

*Bring to front: yes.* Open A, open B, then open A again:

- After A, B: 1 window for A, 1 for B. Front to back: B, A, Library. Key window: B.
- After A again: **still 1 window for A**. Front to back: **A**, B, Library. Key window: **A**.
- After B again: 1 window for each book. B is in front and key.

*Restoration: yes, but only when the user's macOS setting allows it.*

| Scenario | Windows after relaunch |
|---|---|
| System default ("close windows when quitting" ON): open A + B, quit, relaunch | Library only. The book windows are **not** restored. |
| `NSQuitAlwaysKeepsWindows = YES` (setting OFF): open A + B, quit, relaunch | **Library, Book A, Book B**. Each book appears once, with its `BookID` decoded. |
| Saved state from the previous row, relaunched under the system default | Library, Book A, Book B. The setting decides whether state is **saved at quit**; once state exists, a later launch restores it. |

Things worth knowing:

- **No duplicates.** Restoration and `openWindow(value:)` share the same identity. After a restore, opening A still focuses the restored window. (This is a hand check, see below. The automated runs never produced a duplicate.)
- **Where the saved state lives.** On macOS 27 it isn't in `~/Library/Saved Application State/<bundle-id>.savedState`. That folder holds no entry for the spike, and the state lives in a protected container, so the script can't delete it. Instead the script orders its runs so that each starts clean (a quit under the default setting throws the saved windows away), and its final run leaves the state clean. A follow-up launch confirmed that only the Library window came back.
- **What the Preferences plist holds.** `~/Library/Preferences/app.bookbook.spike.sl3.plist` holds only window frames, including `NSWindow Frame SwiftUI.WindowGroup<…BookID…>-1-AppWindow-1`. That's a by-product of the spike, which can be removed with `defaults delete app.bookbook.spike.sl3`.

**What changes in architecture.md.**

- **§6.1, first bullet.** The bring-to-front claim is confirmed. The restoration claim should be qualified: "SwiftUI restores book windows at relaunch **when the user's macOS setting 'Close windows when quitting an application' is off** (or after Quit and Keep Windows, ⌥⌘Q). With the default setting, the app relaunches to the Library window only." That's an accurate description and doesn't change the product.
- **Product question for the user.** If BookBook should *always* reopen the books that were open, the smallest choice is an app-level "reopen last books" list: `AppModel` stores the open `BookID`s, and the app reopens them at launch with `openWindow(value:)`, which can't create duplicates (see above). Alternatively the app could register `NSQuitAlwaysKeepsWindows = YES` in its own defaults domain. Both choices change product behaviour, so they're for the user to decide. Nothing in Phase 0 depends on this.

**Confidence: high** for bring-to-front and for both restoration modes. Each was observed directly, twice.

**Hand checks (only the user can do these, about 3 minutes):**

1. Run `Spikes/scripts/sl3-run.sh`. Click "Open Book A", then "Open Book B", then "Open Book A" again in the Library window. Expect exactly one "Book A" window, and expect it to come to the front.
2. Minimise Book A to the Dock, then click "Open Book A" in Book B's window. Expect A to un-minimise and come to the front, with no second window. *(This wasn't automated.)*
3. Press **⌥⌘Q** (Quit and Keep Windows), then run `open Spikes/.build/sl3/SL3WindowGroupApp.app`. Expect Library, Book A and Book B to come back. Click "Open Book A" and expect the restored window to come to the front, with no duplicate.
4. Optional: in System Settings → Desktop & Dock, turn **off** "Close windows when quitting an application". Quit with ⌘Q, relaunch, and expect the book windows to come back. Turn the setting back on afterwards.
5. Clean up: quit once with plain ⌘Q under the default setting, then run `defaults delete app.bookbook.spike.sl3`.

---

## Package / build notes

- No `Package.swift` change was needed. `SL3WindowGroupApp` now uses `@main` in `SL3App.swift`, and `main.swift` has been removed.
- The SL-2 probe app is compiled by `sl2-run.sh` with plain `swiftc -swift-version 6 -enable-upcoming-feature ExistentialAny`, outside the package, because adding a target would need a `Package.swift` edit. If you'd rather have it as a package executable (`SL2SpellCheckApp`), it's a one-line target addition.
- `swift build --build-tests` prints no warnings or errors. `swift test --filter LocalSpikeTests` runs 7 tests in 2 suites, and all pass in about 6.5 s.
