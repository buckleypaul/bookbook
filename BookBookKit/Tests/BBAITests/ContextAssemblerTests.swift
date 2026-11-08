import BBAICore
import BBModel
import Foundation
import SnapshotTesting
import Testing
@testable import BBAI

@Suite struct ContextAssemblerTests {
    @Test func promptWithStoryText() throws {
        let book = SliceBook.make()
        let (request, report) = try #require(ContextAssembler.assemble(
            intent: intent(), target: book.target, content: book.content, model: testModel()))
        assertPromptSnapshot(request.instruction.rendered)
        #expect(report.promptText == request.instruction.rendered)
        #expect(report.storyTextIncluded)
        #expect(report.styleRevision == 3)
        #expect(report.estimatedInputBytes == request.instruction.rendered.utf8.count)
        #expect(request.quality == .draft)
        let single = try #require(book.content.templates.values.first { $0.kind == .single })
        #expect(abs(request.output.boxAspect - book.content.boxAspect(try #require(single.box(book.imageBox)), in: single)) < 1e-9)
    }

    @Test func promptWithoutStoryText() throws {
        let book = SliceBook.make()
        let (request, report) = try #require(ContextAssembler.assemble(
            intent: intent(story: false), target: book.target, content: book.content, model: testModel()))
        assertPromptSnapshot(request.instruction.rendered)
        #expect(!report.storyTextIncluded)
        #expect(request.instruction.sections.map(\.key) == ["role", "style", "avoid", "composition", "request"])
    }

    @Test func overlappingTextBoxAsksForCalmArea() throws {
        let book = SliceBook.make(overlappingText: true)
        let (request, _) = try #require(ContextAssembler.assemble(
            intent: intent(), target: book.target, content: book.content, model: testModel()))
        assertPromptSnapshot(request.instruction.rendered)
    }

    @Test func emptyInputsOmitSections() throws {
        let book = SliceBook.make(text: "  ", style: "")
        var content = book.content
        content.style.negativeGuidance = ""
        let (request, report) = try #require(ContextAssembler.assemble(
            intent: intent(""), target: book.target, content: content, model: testModel()))
        #expect(request.instruction.sections.map(\.key) == ["role", "composition"])
        #expect(!report.storyTextIncluded)
    }

    @Test func missingTargetsReturnNil() throws {
        let book = SliceBook.make()
        let model = try testModel()
        func run(_ target: GenerationTarget, _ content: BookContent) -> Bool {
            ContextAssembler.assemble(intent: intent(), target: target, content: content, model: model) != nil
        }
        #expect(run(book.target, book.content))
        #expect(!run(.pageBox(PageID(), book.imageBox), book.content))
        #expect(!run(.pageBox(book.pageID, BoxID()), book.content))
        // The text box is not an image box.
        #expect(!run(.pageBox(book.pageID, book.textBox), book.content))
        var noSession = book.content
        noSession.sessions = [:]
        #expect(!run(book.target, noSession))
        var noTemplate = book.content
        noTemplate.templates = [:]
        #expect(!run(book.target, noTemplate))
    }

    @Test func aspectWording() {
        #expect(ContextAssembler.describeAspect(1.5) == "landscape, about 3:2")
        #expect(ContextAssembler.describeAspect(1.0) == "square, about 1:1")
        #expect(ContextAssembler.describeAspect(0.66) == "portrait, about 2:3")
    }
}
