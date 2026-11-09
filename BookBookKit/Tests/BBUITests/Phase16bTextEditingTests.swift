import AppKit
import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 16b: colour-panel bursts are one undo step (#76a); pasted rich text shows only what
/// the model keeps (#78a).
@MainActor
struct Phase16bTextEditingTests {
    @MainActor final class Harness {
        let doc: BookDocument
        let undo: UndoManager
        let page: PageID
        let box: BoxID
        var editor: InlineTextEditor!

        init() throws {
            let content = Fixtures.book()
            let url = FileManager.default.temporaryDirectory.appending(path: "Editor16b-\(UUID().uuidString).bookbook")
            try BookStore.create(content, at: url)
            doc = BookDocument(content: content, store: BookStore(packageURL: url))
            undo = UndoManager()
            doc.undoManager = undo
            page = Fixtures.firstPage(content)
            box = Fixtures.textBox.id
            let (doc, undo, page, box) = (doc, undo, page, box)
            step { doc.perform(.setRichText(page: page, box: box, text: RichText(plain: "Hello BOOM!"), coalescing: false)) }
            undo.removeAllActions()
            let editor = InlineTextEditor(
                pageID: page, boxID: box, text: doc.content.pages[page]?.text[box] ?? .empty,
                typography: doc.content.style.typography, undoManager: { undo },
                onChange: { text, coalescing in
                    doc.perform(.setRichText(page: page, box: box, text: text, coalescing: coalescing))
                })
            editor.onEndTypingStep = { doc.endTypingStep() }
            editor.onBeginUndoGroup = { name, closed in doc.beginUndoGroup(actionName: name, onClosedByReplay: closed) }
            editor.onEndUndoGroup = { doc.endUndoGroup(actionName: $0) }
            editor.place(viewRect: CGRect(x: 0, y: 0, width: 300, height: 200), pageSize: CGSize(width: 300, height: 200))
            self.editor = editor
        }

        /// One user event: the run loop closes its undo group (if anything registered).
        func step(_ body: () -> Void) {
            body()
            TestRunLoop.endEvent()
        }

        var text: RichText? { doc.content.pages[page]?.text[box] }
        var runs: [Run] { text?.paragraphs.flatMap(\.runs) ?? [] }
    }

    let boom = NSRange(location: 6, length: 5)
    let red = RGBA(red: 1, green: 0, blue: 0)
    let blue = RGBA(red: 0, green: 0, blue: 1)

    // MARK: #76a

    @Test func twoColourChanges_oneUndo() throws {
        let h = try Harness()
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(red)) }
        h.step { h.editor.apply(.setColor(blue)) }
        #expect(h.runs.last == Run(text: "BOOM!", color: blue))
        h.editor.finishColorBurst()
        #expect(h.undo.undoActionName == InlineTextEditor.colorActionName)
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello BOOM!")], "one undo removes both changes")
        #expect(!h.undo.canUndo)
        h.editor.tearDown()
    }

    @Test func burstClosesAfterIdle_nextChangeIsItsOwnStep() async throws {
        let h = try Harness()
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(red)) }
        #expect(h.editor.isColorBurstOpen)
        // The idle timer closes the burst (wait for it, however busy the machine is).
        // Counted polls, not a deadline: a main thread blocked by another test can't use them up.
        var polls = 0
        while h.editor.isColorBurstOpen, polls < 400 {
            polls += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!h.editor.isColorBurstOpen)
        h.step { h.editor.apply(.setColor(blue)) }
        h.editor.finishColorBurst()
        h.undo.undo()
        #expect(h.runs.last == Run(text: "BOOM!", color: red))
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello BOOM!")])
        h.editor.tearDown()
    }

    @Test func otherFormatActionEndsTheBurst() throws {
        let h = try Harness()
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(red)) }
        h.step { h.editor.apply(.toggleBold) }
        h.undo.undo()
        #expect(h.runs.last == Run(text: "BOOM!", color: red), "bold is its own step")
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello BOOM!")])
        h.editor.tearDown()
    }

    @Test func newSelectionStartsANewBurst() throws {
        let h = try Harness()
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(red)) }
        h.editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        h.step { h.editor.apply(.setColor(blue)) }
        h.editor.finishColorBurst()
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello "), Run(text: "BOOM!", color: red)])
        h.editor.tearDown()
    }

    @Test func undoDuringBurst_closesIt() throws {
        let h = try Harness()
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(red)) }
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello BOOM!")])
        h.editor.reloadIfNeeded(modelText: h.text ?? .empty, typography: h.doc.content.style.typography)
        // A new change after the undo is a fresh step that undoes on its own.
        h.editor.textView.setSelectedRange(boom)
        h.step { h.editor.apply(.setColor(blue)) }
        h.editor.finishColorBurst()
        #expect(h.runs.last == Run(text: "BOOM!", color: blue))
        h.undo.undo()
        #expect(h.runs == [Run(text: "Hello BOOM!")])
        h.editor.tearDown()
    }

    // MARK: #78a

    @Test func pastedKerningLinkAndSpacing_areDroppedFromTheView() throws {
        let h = try Harness()
        let tv = h.editor.textView
        let spacing = NSMutableParagraphStyle()
        spacing.paragraphSpacing = 24
        spacing.paragraphSpacingBefore = 12
        let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 40), toHaveTrait: .boldFontMask)
        let pasted = NSAttributedString(string: "Linked", attributes: [
            .font: bold, .kern: 5.0, .link: URL(string: "https://example.com")!, .paragraphStyle: spacing,
        ])
        let board = NSPasteboard(name: NSPasteboard.Name("Phase16bPaste-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([pasted])

        tv.setSelectedRange(NSRange(location: 5, length: 0))
        h.step { _ = tv.readSelection(from: board, type: .rtf) }
        let storage = try #require(tv.textStorage)
        #expect(storage.string == "HelloLinked BOOM!")
        let all = NSRange(location: 0, length: storage.length)
        var leaked: [NSAttributedString.Key] = []
        storage.enumerateAttributes(in: all, options: []) { attributes, _, _ in
            for key in [NSAttributedString.Key.kern, .link] where attributes[key] != nil { leaked.append(key) }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               style.paragraphSpacing != 0 || style.paragraphSpacingBefore != 0 { leaked.append(.paragraphStyle) }
        }
        #expect(leaked.isEmpty, "the view shows only what the model keeps")

        // The view is what the model renders, and keeps the formatting the model does hold.
        let model = try #require(h.text)
        #expect(model.plainText == "HelloLinked BOOM!")
        let rendered = RichTextBridge.attributedString(from: model, typography: h.doc.content.style.typography)
        #expect(storage.isEqual(to: rendered))
        #expect(h.runs.contains { $0.text == "Linked" && $0.bold && $0.size == 40 })
        // Typing right after the paste doesn't pick up the pasted link or kerning.
        #expect(tv.typingAttributes[.link] == nil)
        #expect(tv.typingAttributes[.kern] == nil)
        h.editor.tearDown()
    }

    @Test func matchesNeighbour_onlyForAnInsertionLikeTheTextBesideIt() {
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let s = NSMutableAttributedString(string: "abcd", attributes: plain)
        #expect(InlineTextEditor.matchesNeighbour(NSRange(location: 2, length: 1), in: s))
        #expect(InlineTextEditor.matchesNeighbour(NSRange(location: 0, length: 1), in: s), "at the start: the next character")
        s.addAttribute(.kern, value: 5.0, range: NSRange(location: 2, length: 1))
        #expect(!InlineTextEditor.matchesNeighbour(NSRange(location: 2, length: 1), in: s))
        #expect(!InlineTextEditor.matchesNeighbour(NSRange(location: 1, length: 2), in: s), "mixed insertion")
        #expect(!InlineTextEditor.matchesNeighbour(NSRange(location: 0, length: 4), in: s), "no neighbour")
    }

    @Test func plainTyping_leavesTheStorageAlone() throws {
        let h = try Harness()
        let tv = h.editor.textView
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        h.step { tv.insertText("!", replacementRange: tv.selectedRange()) }
        #expect(h.text?.plainText == "Hello BOOM!!")
        let rendered = RichTextBridge.attributedString(from: h.text ?? .empty, typography: h.doc.content.style.typography)
        #expect(tv.textStorage?.isEqual(to: rendered) == true)
        h.editor.tearDown()
    }
}
