import BBAICore
import BBLayout
import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 16b lane L4: BookDocument fixes (style import, mark OK, choose version, split warning,
/// font notifications, coalesced typing, style-revision undo/redo).
@MainActor
struct Phase16bBookDocumentTests {
    let story = try! Presets.storyTemplate()
    let cover = try! Presets.coverTemplate()

    func makeDocument(content: BookContent? = nil, pages: Int = 1) throws -> (BookDocument, UndoManager) {
        let content = content ?? BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                                     storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory.appending(path: "P16bDoc-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    @discardableResult
    func perform(_ doc: BookDocument, _ undo: UndoManager, _ command: BookCommand) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return doc.perform(command)
    }

    /// Adds a generated version to the first page's image session (irreversibly) and returns its ID.
    func addVersion(_ doc: BookDocument, styleRevision: Int = 0, consistency: ConsistencyReport? = nil) -> VersionID {
        let page = doc.content.book.pageOrder[0]
        let box = story.imageBoxes[0].id
        var provenance = Fixtures.provenance()
        provenance.styleRevision = styleRevision
        var version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024), source: .generated,
                              createdAt: Fixtures.date, provenance: provenance)
        version.consistency = consistency
        let sessionID = doc.content.pages[page]!.images[box]!.sessionID
        let added = version
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(added)
            return DirtySet(sessions: [sessionID])
        }
        return version.id
    }

    func warning() -> ConsistencyReport {
        ConsistencyReport(checkedAt: Fixtures.date, provider: .openai, model: "m", consistent: false, differences: [],
                          warns: true, sent: ConsistencySent(promptSent: "p", imagesSent: []))
    }

    // MARK: #3h

    @Test func importFromBook_keepsTargetPageNumbers() throws {
        let (doc, undo) = try makeDocument()
        var target = doc.content.style.pageNumbers
        target.enabled.toggle()
        #expect(perform(doc, undo, .setPageNumberStyle(target)))
        var guide = doc.content.style
        guide.pageNumbers.enabled.toggle()
        guide.visualDescription = "Imported look"
        let item = BookImport(assets: [], sessions: [], templates: [], styleGuide: guide, images: [])
        #expect(perform(doc, undo, .importFromBook(item)))
        #expect(doc.content.style.visualDescription == "Imported look")
        #expect(doc.content.style.pageNumbers == target)
    }

    // MARK: #19

    @Test func markFlagsOK_clearsConsistencyWarning_andUndoRestoresIt() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        let box = story.imageBoxes[0].id
        let version = addVersion(doc, consistency: warning())
        #expect(perform(doc, undo, .chooseVersion(page: page, box: box, version: version)))
        #expect(doc.content.imageFlags(page: page, box: box).contains(.consistencyWarning))
        #expect(perform(doc, undo, .markFlagsOK(page: page, box: box)))
        #expect(!doc.content.imageFlags(page: page, box: box).contains(.consistencyWarning))
        undo.undo()
        #expect(doc.content.imageFlags(page: page, box: box).contains(.consistencyWarning))
        undo.redo()
        #expect(!doc.content.imageFlags(page: page, box: box).contains(.consistencyWarning))
    }

    // MARK: #59

    @Test func chooseVersion_resetsAcknowledged_andUndoRestoresIt() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        let box = story.imageBoxes[0].id
        let first = addVersion(doc, styleRevision: 5)
        let second = addVersion(doc, styleRevision: 0)
        #expect(perform(doc, undo, .chooseVersion(page: page, box: box, version: first)))
        doc.performIrreversible { content in
            content.pages[page]?.images[box]?.acknowledged.styleRevision = 7
            return DirtySet(pages: [page])
        }
        #expect(perform(doc, undo, .chooseVersion(page: page, box: box, version: second)))
        #expect(doc.content.pages[page]?.images[box]?.acknowledged == FlagBaseline())
        undo.undo()
        #expect(doc.content.pages[page]?.images[box]?.acknowledged.styleRevision == 7)
    }

    // MARK: #69

    @Test func wouldSplitSpread_warnsOnlyForNewSplits() throws {
        let (doc, undo) = try makeDocument(pages: 2)
        let spread = Presets.spreadImageTemplateID
        // A spread at position 1 is split; accept it.
        #expect(doc.wouldSplitSpread(.addPage(index: 0, templateID: spread)))
        #expect(perform(doc, undo, .addPage(index: 0, templateID: spread)))
        // A later structural command that doesn't create a split no longer warns.
        let count = doc.content.book.pageOrder.count
        #expect(!doc.wouldSplitSpread(.addPage(index: count, templateID: Presets.textOnlyTemplateID)))
    }

    // MARK: #77

    @Test func fontsRegisteredNotification_refreshesOtherDocuments() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        content.pages[page]?.text[Fixtures.textBox.id] = RichText(paragraphs: [
            Paragraph(runs: [Run(text: "x", fontFamily: "NoSuchFont-Regular")]),
        ])
        let (a, _) = try makeDocument(content: content)
        let (b, _) = try makeDocument(content: content)
        let beforeA = a.fontsRevision
        let beforeB = b.fontsRevision
        NotificationCenter.default.post(name: BookDocument.fontsRegisteredNotification, object: nil)
        #expect(a.fontsRevision > beforeA)
        #expect(b.fontsRevision > beforeB)
        #expect(b.missingFonts == ["NoSuchFont-Regular"])
    }

    // MARK: #79a

    @Test func coalescedTyping_addsMissingFontFromEditedBox() throws {
        let (doc, undo) = try makeDocument()
        let page = doc.content.book.pageOrder[0]
        let box = story.textBoxes[0].id
        #expect(doc.missingFonts.isEmpty)
        perform(doc, undo, .setRichText(page: page, box: box, text: RichText(plain: "a"), coalescing: false))
        // The second edit joins the open typing step.
        undo.beginUndoGrouping()
        let pasted = RichText(paragraphs: [Paragraph(runs: [Run(text: "ab", fontFamily: "PastedMissing-Regular")])])
        #expect(doc.perform(.setRichText(page: page, box: box, text: pasted)))
        undo.endUndoGrouping()
        #expect(doc.missingFonts == ["PastedMissing-Regular"])
    }

    // MARK: #58b

    @Test func undoRedoThenDifferentStyleEdit_neverReusesARevision() throws {
        let (doc, undo) = try makeDocument()
        var visual = doc.content.style.visual
        visual.visualDescription = "A"
        perform(doc, undo, .setStyleVisual(visual))
        #expect(doc.content.style.visualRevision == 1)
        undo.undo()
        #expect(doc.content.style.visualRevision == 0)
        undo.redo()
        #expect(doc.content.style.visualRevision == 1)
        undo.undo()
        visual.visualDescription = "B"
        perform(doc, undo, .setStyleVisual(visual))
        #expect(doc.content.style.visualRevision == 2, "revision 1 was used by the undone edit")
        // An image made at revision 1 is flagged now.
        let page = doc.content.book.pageOrder[0]
        let box = story.imageBoxes[0].id
        let old = addVersion(doc, styleRevision: 1)
        #expect(perform(doc, undo, .chooseVersion(page: page, box: box, version: old)))
        #expect(doc.content.imageFlags(page: page, box: box).contains(.styleChanged))
    }
}
