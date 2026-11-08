import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// A clock tests move by hand.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

/// Ends the current "event": runs the main run loop once so an `UndoManager` that groups by
/// event closes its group (as AppKit does between keystrokes).
@MainActor
enum TestRunLoop {
    /// A run loop with no sources returns at once without running its observers.
    private static let port: Port = {
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        return port
    }()

    static func endEvent() {
        _ = port
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
}

/// Coalesced typing undo (A §6.3): one undo step per burst of typing in one box, ended by a
/// 1 s pause, a box switch, a formatting change or any other command.
@MainActor
struct TypingCoalescingTests {
    let boxA = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3), content: .text(TextBoxStyle()))
    let boxB = Box(frame: NormalizedRect(x: 0.1, y: 0.5, width: 0.8, height: 0.3), content: .text(TextBoxStyle()))

    // MARK: TypingCoalescer (pure)

    @Test func coalescer_mergesSameBoxWithinOneSecond() {
        let clock = TestClock()
        var coalescer = TypingCoalescer(clock: { clock.now })
        func merges(_ command: BookCommand) -> Bool { coalescer.shouldCoalesce(command) }
        let page = PageID()
        let typing = BookCommand.setRichText(page: page, box: boxA.id, text: .empty)
        #expect(!merges(typing), "the first edit opens a step")
        clock.advance(0.9)
        #expect(merges(typing))
        clock.advance(0.9)
        #expect(merges(typing), "the pause is measured from the previous edit")
        clock.advance(1.0)
        #expect(!merges(typing), "a 1 s pause ends the step")
        #expect(merges(typing))
    }

    @Test func coalescer_boxSwitchFormattingOtherCommandsAndCloseEndTheStep() {
        let clock = TestClock()
        var coalescer = TypingCoalescer(clock: { clock.now })
        func merges(_ command: BookCommand) -> Bool { coalescer.shouldCoalesce(command) }
        let page = PageID()
        let inA = BookCommand.setRichText(page: page, box: boxA.id, text: .empty)
        let inB = BookCommand.setRichText(page: page, box: boxB.id, text: .empty)
        let format = BookCommand.setRichText(page: page, box: boxA.id, text: .empty, coalescing: false)

        _ = coalescer.shouldCoalesce(inA)
        #expect(!merges(inB))
        #expect(!merges(inA))
        #expect(!merges(format))
        #expect(!coalescer.isOpen)
        #expect(!merges(inA))
        #expect(!merges(.deletePage(page)))
        #expect(!merges(inA))
        coalescer.close()
        #expect(!merges(inA))
        #expect(!merges(.setRichText(page: PageID(), box: boxA.id, text: .empty)),
                "same box ID on another page is another box")
    }

    @Test func coalescer_clockGoingBackwardsEndsTheStep() {
        let clock = TestClock()
        var coalescer = TypingCoalescer(clock: { clock.now })
        func merges(_ command: BookCommand) -> Bool { coalescer.shouldCoalesce(command) }
        let typing = BookCommand.setRichText(page: PageID(), box: boxA.id, text: .empty)
        _ = coalescer.shouldCoalesce(typing)
        clock.advance(-5)
        #expect(!merges(typing))
    }

    // MARK: BookDocument

    func makeDocument(clock: TestClock) throws -> (BookDocument, UndoManager, PageID) {
        let story = Template(name: "Two texts", kind: .single, boxes: [boxA, boxB])
        let cover = Template(name: "Cover", kind: .cover,
                             boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])
        let content = BookContent.makeNew(title: "Typing", storyTemplate: story, coverTemplate: cover,
                                          now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appending(path: "Typing-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url), now: { clock.now })
        // Groups by event, like the window's manager: each `keystroke` is one run-loop event.
        let undo = UndoManager()
        document.undoManager = undo
        return (document, undo, content.book.pageOrder[0])
    }

    /// One edit as its own event: performs it, then lets the run loop close the undo group.
    func keystroke(_ document: BookDocument, _ command: BookCommand) {
        #expect(document.perform(command))
        endEvent()
    }

    func endEvent() { TestRunLoop.endEvent() }

    func type(_ document: BookDocument, page: PageID, box: Box, _ text: String) {
        keystroke(document, .setRichText(page: page, box: box.id, text: RichText(plain: text)))
    }

    func text(_ document: BookDocument, _ page: PageID, _ box: Box) -> String? {
        document.content.pages[page]?.text[box.id]?.plainText
    }

    @Test func typePauseTypeUndoTwice_restoresInTwoSteps() throws {
        let clock = TestClock()
        let (doc, undo, page) = try makeDocument(clock: clock)
        for word in ["O", "On", "Onc", "Once"] {
            type(doc, page: page, box: boxA, word)
            clock.advance(0.3)
        }
        clock.advance(1.0)
        for word in ["Once u", "Once up", "Once upon"] {
            type(doc, page: page, box: boxA, word)
            clock.advance(0.3)
        }
        #expect(text(doc, page, boxA) == "Once upon")
        #expect(undo.undoActionName == "Typing")

        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == "Once")
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == nil)
        #expect(!undo.canUndo)

        undo.redo()
        endEvent()
        #expect(text(doc, page, boxA) == "Once")
        undo.redo()
        endEvent()
        #expect(text(doc, page, boxA) == "Once upon", "redo of a coalesced step restores its last text")
    }

    @Test func boxSwitch_splitsTheStep() throws {
        let clock = TestClock()
        let (doc, undo, page) = try makeDocument(clock: clock)
        type(doc, page: page, box: boxA, "A")
        clock.advance(0.1)
        type(doc, page: page, box: boxA, "AA")
        clock.advance(0.1)
        type(doc, page: page, box: boxB, "B")
        clock.advance(0.1)
        type(doc, page: page, box: boxA, "AAA")

        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == "AA")
        #expect(text(doc, page, boxB) == "B")
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxB) == nil)
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == nil)
        #expect(!undo.canUndo)
    }

    @Test func formattingChange_splitsTheStep() throws {
        let clock = TestClock()
        let (doc, undo, page) = try makeDocument(clock: clock)
        type(doc, page: page, box: boxA, "Hi")
        clock.advance(0.1)
        type(doc, page: page, box: boxA, "Hi!")
        clock.advance(0.1)
        let bold = RichText(paragraphs: [Paragraph(runs: [Run(text: "Hi!", bold: true)])])
        keystroke(doc, .setRichText(page: page, box: boxA.id, text: bold, coalescing: false))
        #expect(undo.undoActionName == "Format Text")
        clock.advance(0.1)
        type(doc, page: page, box: boxA, "Hi! there")
        clock.advance(0.1)
        type(doc, page: page, box: boxA, "Hi! there you")

        undo.undo()
        endEvent()
        #expect(doc.content.pages[page]?.text[boxA.id] == bold)
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == "Hi!")
        #expect(doc.content.pages[page]?.text[boxA.id] != bold)
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == nil)
        #expect(!undo.canUndo)
    }

    @Test func otherCommandOrEndingTheStep_splitsIt() throws {
        let clock = TestClock()
        let (doc, undo, page) = try makeDocument(clock: clock)
        type(doc, page: page, box: boxA, "a")
        keystroke(doc, .addPage(index: 1, templateID: doc.content.pages[page]!.templateID))
        type(doc, page: page, box: boxA, "ab")
        doc.endTypingStep() // the editor closed
        type(doc, page: page, box: boxA, "abc")

        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == "ab")
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == "a")
        #expect(doc.content.book.pageOrder.count == 2)
        undo.undo()
        endEvent()
        #expect(doc.content.book.pageOrder.count == 1)
    }

    @Test func typingAfterUndo_startsANewStep() throws {
        let clock = TestClock()
        let (doc, undo, page) = try makeDocument(clock: clock)
        type(doc, page: page, box: boxA, "a")
        type(doc, page: page, box: boxA, "ab")
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == nil)
        type(doc, page: page, box: boxA, "x")
        type(doc, page: page, box: boxA, "xy")
        #expect(text(doc, page, boxA) == "xy")
        undo.undo()
        endEvent()
        #expect(text(doc, page, boxA) == nil)
        #expect(!undo.canUndo)
    }

    @Test func coalescedTyping_isSaved() async throws {
        let clock = TestClock()
        let (doc, _, page) = try makeDocument(clock: clock)
        type(doc, page: page, box: boxA, "a")
        type(doc, page: page, box: boxA, "ab")
        await doc.flush()
        let reloaded = try await BookStore(packageURL: doc.store.packageURL).load()
        #expect(reloaded.pages[page]?.text[boxA.id]?.plainText == "ab")
    }
}
