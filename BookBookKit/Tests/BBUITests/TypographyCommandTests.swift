import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// `.setTypography` (Style tab form): undoable, saved with the style.
@MainActor
struct TypographyCommandTests {
    func makeDocument() throws -> (BookDocument, UndoManager) {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Typography-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    var georgia: Typography {
        var typography = Typography.default
        typography.bodyFont = FontRef(postScriptName: "Georgia")
        typography.bodySize = 24
        typography.color = RGBA(red: 0.2, green: 0.1, blue: 0.5)
        typography.lineSpacing = 1.5
        typography.alignment = .center
        return typography
    }

    @Test func setTypography_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        let original = doc.content.style.typography
        undo.beginUndoGrouping()
        #expect(doc.perform(.setTypography(georgia)))
        undo.endUndoGrouping()
        #expect(doc.content.style.typography == georgia)
        #expect(undo.undoActionName == "Change Typography")

        undo.undo()
        #expect(doc.content.style.typography == original)
        undo.redo()
        #expect(doc.content.style.typography == georgia)
    }

    @Test func setTypography_isSavedWithTheStyle() async throws {
        let (doc, _) = try makeDocument()
        doc.undoManager = nil
        #expect(doc.perform(.setTypography(georgia)))
        await doc.flush()
        let reloaded = try await BookStore(packageURL: doc.store.packageURL).load()
        #expect(reloaded.style.typography == georgia)
    }

    @Test func setTypography_endsTheTypingStep() throws {
        let (doc, undo) = try makeDocument()
        let page = Fixtures.firstPage(doc.content)
        let box = Fixtures.textBox.id
        for (text, command) in [("a", nil), (nil, BookCommand.setTypography(georgia)), ("ab", nil)] as [(String?, BookCommand?)] {
            undo.beginUndoGrouping()
            if let text { #expect(doc.perform(.setRichText(page: page, box: box, text: RichText(plain: text)))) }
            if let command { #expect(doc.perform(command)) }
            undo.endUndoGrouping()
        }
        undo.undo()
        #expect(doc.content.pages[page]?.text[box]?.plainText == "a")
        undo.undo()
        #expect(doc.content.style.typography == .default)
    }

    @Test func readOnly_rejectsTypography() throws {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Typography-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let doc = BookDocument(content: content, store: BookStore(packageURL: url), readOnly: true)
        #expect(!doc.perform(.setTypography(georgia)))
        #expect(doc.content.style.typography == .default)
    }
}
