import AppKit
import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// The inline editor's format actions (TextFormatTarget), its FormatState and its undo
/// behaviour, tested on the NSTextView directly (no window).
@MainActor
struct InlineTextEditorFormatTests {
    final class Sent {
        var changes: [(RichText, Bool)] = []
        var stepEnds = 0
    }

    let typography = Typography.default

    func makeEditor(_ text: RichText, formatting: TextFormatController? = nil) -> (InlineTextEditor, Sent) {
        let sent = Sent()
        let editor = InlineTextEditor(pageID: PageID(), boxID: BoxID(), text: text, typography: typography,
                                      formatting: formatting, undoManager: { nil },
                                      onChange: { sent.changes.append(($0, $1)) })
        editor.onEndTypingStep = { sent.stepEnds += 1 }
        editor.place(viewRect: CGRect(x: 0, y: 0, width: 300, height: 200), pageSize: CGSize(width: 300, height: 200))
        return (editor, sent)
    }

    let hello = RichText(plain: "Hello BOOM!")
    let boom = NSRange(location: 6, length: 5)

    func runs(_ text: RichText?) -> [Run] { text?.paragraphs.flatMap(\.runs) ?? [] }

    // MARK: Actions on a selection

    @Test func toggleBold_onSelection_sendsOneNonCoalescingChange() throws {
        let (editor, sent) = makeEditor(hello)
        editor.textView.setSelectedRange(boom)
        editor.apply(.toggleBold)
        #expect(sent.changes.count == 1)
        let (text, coalescing) = try #require(sent.changes.last)
        #expect(!coalescing)
        #expect(runs(text) == [Run(text: "Hello "), Run(text: "BOOM!", bold: true)])
        #expect(editor.shownText == text)

        editor.apply(.toggleBold)
        #expect(runs(sent.changes.last?.0) == [Run(text: "Hello BOOM!")], "toggling again clears it")
    }

    @Test func toggle_onMixedSelection_setsAll() throws {
        let mixed = RichText(paragraphs: [Paragraph(runs: [Run(text: "ab", italic: true), Run(text: "cd")])])
        let (editor, sent) = makeEditor(mixed)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(editor.formatState.italic == nil, "mixed")
        editor.apply(.toggleItalic)
        #expect(runs(sent.changes.last?.0) == [Run(text: "abcd", italic: true)])
    }

    @Test func boomFormatting_sizeColourFontUnderline() throws {
        let (editor, sent) = makeEditor(hello)
        editor.textView.setSelectedRange(boom)
        let red = RGBA(red: 1, green: 0, blue: 0)
        editor.apply(.setSize(48))
        editor.apply(.setColor(red))
        editor.apply(.setFont("Georgia"))
        editor.apply(.toggleUnderline)
        editor.apply(.toggleBold)
        #expect(sent.changes.count == 5)
        #expect(sent.changes.allSatisfy { !$0.1 })
        let last = runs(sent.changes.last?.0)
        #expect(last == [Run(text: "Hello "),
                         Run(text: "BOOM!", bold: true, underline: true, fontFamily: "Georgia", size: 48, color: red)])
        #expect(editor.textView.selectedRange() == boom, "the selection survives")

        let state = editor.formatState
        #expect(state == FormatState(bold: true, italic: false, underline: true, font: "Georgia", size: 48,
                                     color: red, alignment: nil, resolvedSize: 48, resolvedColor: red))

        // nil clears the override: back to the style.
        editor.apply(.setFont(nil))
        editor.apply(.setSize(nil))
        editor.apply(.setColor(nil))
        #expect(runs(sent.changes.last?.0) == [Run(text: "Hello "), Run(text: "BOOM!", bold: true, underline: true)])
    }

    @Test func biggerAndSmaller_stepFromTheEffectiveSize() throws {
        let (editor, sent) = makeEditor(hello)
        editor.textView.setSelectedRange(boom)
        editor.apply(.biggerText)
        #expect(runs(sent.changes.last?.0).last?.size == typography.bodySize + 1)
        editor.apply(.smallerText)
        editor.apply(.smallerText)
        #expect(runs(sent.changes.last?.0).last?.size == typography.bodySize - 1)
    }

    @Test func alignment_appliesToTouchedParagraphs() throws {
        let (editor, sent) = makeEditor(RichText(plain: "one\ntwo\nthree"))
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0)) // caret in "two"
        editor.apply(.setAlignment(.center))
        let text = try #require(sent.changes.last?.0)
        #expect(!sent.changes.last!.1)
        #expect(text.paragraphs.map(\.alignment) == [nil, .center, nil])
        #expect(editor.formatState.alignment == .center)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 9)) // "one\ntwo\nt"
        #expect(editor.formatState.alignment == nil, "mixed")
        editor.apply(.setAlignment(.trailing))
        #expect(sent.changes.last?.0.paragraphs.map(\.alignment) == [.trailing, .trailing, .trailing])
        editor.apply(.setAlignment(nil))
        #expect(sent.changes.last?.0.paragraphs.map(\.alignment) == [nil, nil, nil])
    }

    // MARK: Empty selection: typing attributes

    @Test func emptySelection_changesTypingAttributes_andEndsTheStep() throws {
        let (editor, sent) = makeEditor(hello)
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        editor.apply(.toggleBold)
        editor.apply(.setSize(30))
        #expect(sent.changes.isEmpty, "nothing in the text changed")
        #expect(sent.stepEnds == 2, "but the typing step ends")
        #expect(editor.formatState.bold == true)
        #expect(editor.formatState.size == 30)

        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        let (text, coalescing) = try #require(sent.changes.last)
        #expect(coalescing, "typing coalesces")
        #expect(runs(text) == [Run(text: "Hello BOOM!"), Run(text: "!", bold: true, size: 30)])
    }

    // MARK: FormatState publishing

    @Test func formatState_followsTheSelection_andIsClearedOnTearDown() throws {
        let controller = TextFormatController()
        let bold = RichText(paragraphs: [Paragraph(runs: [Run(text: "plain "), Run(text: "bold", bold: true)])])
        let (editor, _) = makeEditor(bold, formatting: controller)
        editor.beginEditing(in: nil)
        #expect(controller.target === editor)
        #expect(controller.isEditing)

        editor.textView.setSelectedRange(NSRange(location: 7, length: 2))
        #expect(controller.state?.bold == true)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(controller.state?.bold == false)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 10))
        #expect(controller.state?.bold == nil)

        controller.perform(.toggleBold)
        #expect(controller.state?.bold == true)

        editor.tearDown()
        #expect(controller.target == nil)
        #expect(controller.state == nil)
        #expect(!controller.isEditing)
    }

    // MARK: Editor settings

    @Test func editor_keepsTextKit2SpellingAndContainerSettings() throws {
        let (editor, _) = makeEditor(hello)
        let tv = editor.textView
        #expect(tv.textLayoutManager != nil, "TextKit 2")
        #expect(!tv.allowsUndo)
        #expect(tv.isRichText)
        #expect(tv.isContinuousSpellCheckingEnabled)
        #expect(tv.isGrammarCheckingEnabled)
        #expect(tv.textContainerInset == TextContainerSettings.textContainerInset)
        #expect(tv.textContainer?.lineFragmentPadding == TextContainerSettings.lineFragmentPadding)
        editor.textView.setSelectedRange(boom)
        editor.apply(.toggleBold)
        #expect(tv.textLayoutManager != nil, "formatting doesn't switch to TextKit 1")
        #expect(tv.isContinuousSpellCheckingEnabled)
    }

    // MARK: Undo across editor teardown

    @Test func undo_afterEditorIsTornDownAndRecreated() throws {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Editor-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let clock = TestClock()
        let doc = BookDocument(content: content, store: BookStore(packageURL: url), now: { clock.now })
        let undo = UndoManager()
        doc.undoManager = undo
        let page = Fixtures.firstPage(content), box = Fixtures.textBox.id

        func makeEditor() -> InlineTextEditor {
            let editor = InlineTextEditor(
                pageID: page, boxID: box, text: doc.content.pages[page]?.text[box] ?? .empty,
                typography: doc.content.style.typography, undoManager: { undo },
                onChange: { text, coalescing in
                    doc.perform(.setRichText(page: page, box: box, text: text, coalescing: coalescing))
                })
            editor.onEndTypingStep = { doc.endTypingStep() }
            return editor
        }

        var editor = makeEditor()
        for word in ["Once", " upon"] {
            editor.textView.insertText(word, replacementRange: editor.textView.selectedRange())
            TestRunLoop.endEvent()
            clock.advance(2)
        }
        #expect(doc.content.pages[page]?.text[box]?.plainText == "Once upon")
        editor.tearDown() // switch pages: the text storage goes away
        doc.endTypingStep()

        editor = makeEditor() // come back
        #expect(editor.textView.string == "Once upon")
        undo.undo()
        TestRunLoop.endEvent()
        #expect(doc.content.pages[page]?.text[box]?.plainText == "Once")
        editor.reloadIfNeeded(modelText: doc.content.pages[page]?.text[box] ?? .empty,
                              typography: doc.content.style.typography)
        #expect(editor.textView.string == "Once")

        // Typing in the new editor still works and undoes.
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        TestRunLoop.endEvent()
        #expect(doc.content.pages[page]?.text[box]?.plainText == "Once!")
        undo.undo()
        TestRunLoop.endEvent()
        #expect(doc.content.pages[page]?.text[box]?.plainText == "Once")
        editor.tearDown()
    }
}

/// The pure RichText range edits behind the format actions.
@MainActor
struct RichTextFormattingTests {
    let typography = Typography.default

    func runs(_ text: RichText?) -> [Run] { text?.paragraphs.flatMap(\.runs) ?? [] }

    @Test func applying_splitsRunsAtTheRangeEdges_acrossParagraphs() {
        let text = RichText(paragraphs: [
            Paragraph(runs: [Run(text: "abc"), Run(text: "def", italic: true)]),
            Paragraph(runs: [Run(text: "ghi")], alignment: .center),
        ])
        // "abcdef\nghi": select "ef\ngh" (offsets 4..<9).
        let edited = RichTextFormatting.applying({ $0.bold = true }, to: NSRange(location: 4, length: 5), of: text)
        #expect(edited.paragraphs[0].runs == [Run(text: "abc"), Run(text: "d", italic: true),
                                              Run(text: "ef", bold: true, italic: true)])
        #expect(edited.paragraphs[1].runs == [Run(text: "gh", bold: true), Run(text: "i")])
        #expect(edited.paragraphs[1].alignment == .center)
    }

    @Test func applying_handlesUTF16() {
        let text = RichText(plain: "🦊 fox")
        // "🦊" is two UTF-16 units; select " fox".
        let edited = RichTextFormatting.applying({ $0.underline = true }, to: NSRange(location: 2, length: 4), of: text)
        #expect(edited.paragraphs[0].runs == [Run(text: "🦊"), Run(text: " fox", underline: true)])
    }

    @Test func state_reportsCommonValuesOrNil() {
        let red = RGBA(red: 1, green: 0, blue: 0)
        let state = RichTextFormatting.state(of: [Run(text: "a", bold: true, size: 30, color: red),
                                                  Run(text: "b", bold: true, italic: true, color: red)],
                                             typography: typography)
        #expect(state.bold == true)
        #expect(state.italic == nil)
        #expect(state.underline == false)
        #expect(state.size == nil)
        #expect(state.color == red)
        #expect(state.font == nil)
    }

    // MARK: Bold base face (title): B shows and toggles what is drawn (A §4.2)

    var title: Typography { Typography.default.resolved(for: .title) }

    @Test func titleBaseFace_stateShowsDrawnBold() {
        #expect(title.bodyFont.postScriptName == "AvenirNext-Bold")
        // Unformatted title text is drawn bold: B is on.
        #expect(RichTextFormatting.state(of: [Run(text: "The Fox")], typography: title).bold == true)
        // The relative flag draws the regular weight: B is off.
        #expect(RichTextFormatting.state(of: [Run(text: "Fox", bold: true)], typography: title).bold == false)
        #expect(RichTextFormatting.state(of: [Run(text: "a"), Run(text: "b", bold: true)], typography: title).bold == nil)
        // Body text (regular base face): drawn and stored agree.
        #expect(RichTextFormatting.state(of: [Run(text: "a")], typography: typography).bold == false)
        #expect(RichTextFormatting.state(of: [Run(text: "a", bold: true)], typography: typography).bold == true)
    }

    @Test func titleBaseFace_toggleBoldFlipsDrawnWeight() throws {
        let toggle = try #require(RichTextFormatting.transform(for: .toggleBold, current: [Run(text: "Fox")],
                                                                typography: title))
        var run = Run(text: "Fox")
        toggle(&run)
        #expect(run.bold) // stored relative: draws regular
        #expect(RichTextFormatting.state(of: [run], typography: title).bold == false)
        // Mixed (one drawn bold, one not): everything becomes drawn bold.
        let mixed = [Run(text: "a"), Run(text: "b", bold: true)]
        let toBold = try #require(RichTextFormatting.transform(for: .toggleBold, current: mixed, typography: title))
        let edited = mixed.map { var r = $0; toBold(&r); return r }
        #expect(edited.allSatisfy { !$0.bold })
        #expect(RichTextFormatting.state(of: edited, typography: title).bold == true)
    }

    @Test func titleEditor_formatStateMatchesDrawnText() {
        let sent = InlineTextEditorFormatTests.Sent()
        let editor = InlineTextEditor(pageID: PageID(), boxID: BoxID(), text: RichText(plain: "The Fox"),
                                      typography: title, formatting: nil, undoManager: { nil },
                                      onChange: { sent.changes.append(($0, $1)) })
        editor.place(viewRect: CGRect(x: 0, y: 0, width: 300, height: 200), pageSize: CGSize(width: 300, height: 200))
        editor.textView.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(editor.formatState.bold == true)
        editor.apply(.toggleBold)
        #expect(editor.formatState.bold == false)
        #expect(runs(sent.changes.last?.0) == [Run(text: "The "), Run(text: "Fox", bold: true)])
    }
}
