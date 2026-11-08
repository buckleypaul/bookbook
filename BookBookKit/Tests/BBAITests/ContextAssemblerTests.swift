import BBAICore
import BBModel
import Foundation
import SnapshotTesting
import Testing
@testable import BBAI

@Suite struct ContextAssemblerTests {
    @Test func promptWithStoryText() throws {
        let book = SliceBook.make()
        let (request, report) = try assembleBook(book)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(report.promptText == request.instruction.rendered)
        #expect(report.storyTextIncluded)
        #expect(report.storyText?.isEmpty == false)
        #expect(report.styleRevision == 3)
        #expect(report.estimatedInputBytes == request.instruction.rendered.utf8.count)
        #expect(request.quality == .draft)
        #expect(request.baseImage == nil && request.references.isEmpty)
        #expect(request.output.exactSize == nil)
        let single = try #require(book.content.templates.values.first { $0.kind == .single })
        #expect(abs(request.output.boxAspect - book.content.boxAspect(try #require(single.box(book.imageBox)), in: single)) < 1e-9)
    }

    @Test func promptWithoutStoryText() throws {
        let book = SliceBook.make()
        let (request, report) = try assembleBook(book, intent(story: false))
        assertPromptSnapshot(request.instruction.rendered)
        #expect(!report.storyTextIncluded && report.storyText == nil)
        #expect(request.instruction.sections.map(\.key) == ["role", "style", "avoid", "composition", "request"])
    }

    @Test func overlappingTextBoxAsksForCalmArea() throws {
        let book = SliceBook.make(overlappingText: true)
        let (request, _) = try assembleBook(book)
        assertPromptSnapshot(request.instruction.rendered)
    }

    @Test func spreadCrossingFoldStatesFoldPosition() throws {
        let book = SliceBook.makeCustom(kind: .spread, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let (request, _) = try assembleBook(book)
        assertPromptSnapshot(request.instruction.rendered)
        #expect(request.instruction.rendered.contains("about 50% of the way across"))
    }

    @Test func spreadBoxOnOneSideHasNoFoldGuidance() throws {
        let book = SliceBook.makeCustom(kind: .spread, frame: NormalizedRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8))
        let (request, _) = try assembleBook(book)
        #expect(!request.instruction.rendered.contains("fold"))
    }

    @Test func singlePageHasNoFoldGuidance() throws {
        let (request, _) = try assembleBook(SliceBook.make())
        #expect(!request.instruction.rendered.contains("fold"))
        #expect(!request.instruction.rendered.contains("trimmed"))
    }

    @Test func bleedAddsSafeAreaGuidance() throws {
        let book = SliceBook.makeCustom(kind: .single, frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                                        bleed: true, bleedEdges: .all)
        let (request, _) = try assembleBook(book)
        assertPromptSnapshot(request.instruction.rendered)
    }

    @Test func noBleedMeansNoSafeArea() throws {
        let book = SliceBook.makeCustom(kind: .single, frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                                        bleed: false, bleedEdges: .all)
        let (request, _) = try assembleBook(book)
        #expect(!request.instruction.rendered.contains("trimmed"))
    }

    @Test func emptyInputsOmitSections() throws {
        let book = SliceBook.make(text: "  ", style: "")
        var content = book.content
        content.style.negativeGuidance = ""
        let (request, report) = try assembleBook(book, intent(""), content: content)
        #expect(request.instruction.sections.map(\.key) == ["role", "composition"])
        #expect(!report.storyTextIncluded)
    }

    @Test func missingTargetsThrow() throws {
        let book = SliceBook.make()
        let model = try testModel()
        func ok(_ target: GenerationTarget, _ content: BookContent) -> Bool {
            (try? ContextAssembler.assemble(intent: intent(), target: target, content: content, model: model)) != nil
        }
        #expect(ok(book.target, book.content))
        #expect(!ok(.pageBox(PageID(), book.imageBox), book.content))
        #expect(!ok(.pageBox(book.pageID, BoxID()), book.content))
        // The text box is not an image box.
        #expect(!ok(.pageBox(book.pageID, book.textBox), book.content))
        var noSession = book.content
        noSession.sessions = [:]
        #expect(!ok(book.target, noSession))
        var noTemplate = book.content
        noTemplate.templates = [:]
        #expect(!ok(book.target, noTemplate))
    }

    @Test func aspectWording() {
        #expect(ContextAssembler.describeAspect(1.5) == "landscape, about 3:2")
        #expect(ContextAssembler.describeAspect(1.0) == "square, about 1:1")
        #expect(ContextAssembler.describeAspect(0.66) == "portrait, about 2:3")
    }
}
