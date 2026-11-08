import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// `BookDocument.importFont(from:)` and font registration on open (A §8.3). These need lane B's
/// `FontInspector`/`FontRegistry`/`FontAvailability` and lane C's `storeFont`/`fontFileURLs`; on
/// a branch with only the Phase 4 contract stubs, the import tests fail.
@MainActor
struct FontImportTests {
    static let systemFont = URL(filePath: "/System/Library/Fonts/Supplemental/Courier New.ttf")

    func makeDocument(readOnly: Bool = false, content: BookContent = Fixtures.book()) throws -> BookDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "Fonts-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        return BookDocument(content: content, store: BookStore(packageURL: url), readOnly: readOnly)
    }

    /// A copy of a font file in a temporary folder (what the import panel hands over).
    func fontCopy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FontSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "Courier New.TTF")
        try FileManager.default.copyItem(at: Self.systemFont, to: copy)
        return copy
    }

    @Test func importFont_storesInspectsAndRegisters() async throws {
        let doc = try makeDocument()
        let revision = doc.fontsRevision
        let info = try await doc.importFont(from: try fontCopy())
        #expect(info.postScriptNames.contains("CourierNewPSMT"))
        #expect(info.embeddingAllowed)
        let stored = doc.store.fontFileURLs()
        #expect(stored.count == 1)
        #expect(stored.first?.pathExtension == "ttf")
        #expect(doc.fontsRevision > revision, "the canvas drops its cached layouts")

        // Same bytes again: still one file.
        _ = try await doc.importFont(from: try fontCopy())
        #expect(doc.store.fontFileURLs().count == 1)
    }

    @Test func importFont_unreadableFileThrows_andStoresNothing() async throws {
        let doc = try makeDocument()
        let bogus = FileManager.default.temporaryDirectory.appending(path: "NotAFont-\(UUID().uuidString).ttf")
        try Data("not a font".utf8).write(to: bogus)
        await #expect(throws: (any Error).self) { try await doc.importFont(from: bogus) }
        #expect(doc.store.fontFileURLs().isEmpty)
    }

    @Test func importFont_readOnlyThrows() async throws {
        let doc = try makeDocument(readOnly: true)
        await #expect(throws: (any Error).self) { try await doc.importFont(from: try fontCopy()) }
    }

    @Test func missingFonts_listsUnresolvedNames_andRefreshesOnTypography() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        content.pages[page]?.text[Fixtures.textBox.id] = RichText(paragraphs: [
            Paragraph(runs: [Run(text: "x", fontFamily: "NoSuchFont-Regular")]),
        ])
        let doc = try makeDocument(content: content)
        #expect(doc.missingFonts == ["NoSuchFont-Regular"])

        var typography = doc.content.style.typography
        typography.titleFont = FontRef(postScriptName: "AlsoMissing-Bold")
        doc.undoManager = nil
        #expect(doc.perform(.setTypography(typography)))
        #expect(doc.missingFonts == ["AlsoMissing-Bold", "NoSuchFont-Regular"])
    }
}
