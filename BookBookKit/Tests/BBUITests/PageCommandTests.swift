import BBLayout
import BBModel
import BBStore
import CryptoKit
import Foundation
import Testing
@testable import BBUI

/// Phase 5 page commands (A §6.3, §8.1; PD §8.5, §8.10): each one is a single undo step,
/// including the blank pages that fix a split spread.
@MainActor
struct PageCommandTests {
    let story = try! Presets.storyTemplate()                        // image (top), text
    let cover = try! Presets.coverTemplate()
    let spreadID = Presets.spreadImageTemplateID
    let textLeftID = Presets.textLeftImageRightTemplateID
    let textOnlyID = Presets.textOnlyTemplateID

    var storyImage: BoxID { story.imageBoxes[0].id }
    var storyText: BoxID { story.textBoxes[0].id }

    func makeDocument(pages: Int = 1, readOnly: Bool = false) throws -> (BookDocument, UndoManager) {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: pages, now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PageCommandTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url), readOnly: readOnly)
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo)
    }

    /// Performs `command` in its own undo group, as one user action.
    @discardableResult
    func perform(_ doc: BookDocument, _ undo: UndoManager, _ command: BookCommand) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return doc.perform(command)
    }

    func order(_ doc: BookDocument) -> [PageID] { doc.content.book.pageOrder }
    func templateID(_ doc: BookDocument, _ page: PageID) -> TemplateID? { doc.content.pages[page]?.templateID }

    /// Pages, order and style: the undoable parts of the content (sessions and templates gain
    /// irreversible orphans).
    @MainActor struct Snapshot: Equatable {
        var order: [PageID]
        var pages: [PageID: Page]
        var style: StyleGuide
        init(_ doc: BookDocument) {
            order = doc.content.book.pageOrder
            pages = doc.content.pages
            style = doc.content.style
        }
    }

    // MARK: addPage

    @Test func addPage_spreadCopiesPresetIn_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        #expect(doc.content.templates[spreadID] == nil)
        let before = Snapshot(doc)
        #expect(!doc.wouldSplitSpread(.addPage(index: 1, templateID: spreadID)), "positions 2–3: not split")
        #expect(perform(doc, undo, .addPage(index: 1, templateID: spreadID)))
        let added = order(doc)[1]
        #expect(templateID(doc, added) == spreadID)
        #expect(doc.content.templates[spreadID] != nil, "the preset was copied into the book")
        let after = Snapshot(doc)

        undo.undo()
        #expect(Snapshot(doc) == before)
        #expect(doc.content.templates[spreadID] != nil, "copy-in is irreversible (harmless orphan)")
        undo.redo()
        #expect(Snapshot(doc) == after)
    }

    @Test func addPage_atSplitPosition_fixSplitsInsertsBlank_undoRemovesBoth() throws {
        let (doc, undo) = try makeDocument()
        let original = order(doc)[0]
        #expect(doc.wouldSplitSpread(.addPage(index: 0, templateID: spreadID)), "a spread at position 1 is split")
        #expect(doc.content.templates[textOnlyID] == nil)
        let before = Snapshot(doc)

        #expect(perform(doc, undo, .addPage(index: 0, templateID: spreadID, fixSplits: true)))
        #expect(order(doc).count == 3)
        #expect(templateID(doc, order(doc)[0]) == textOnlyID, "blank text-only page before the spread")
        #expect(templateID(doc, order(doc)[1]) == spreadID)
        #expect(order(doc)[2] == original)
        #expect(!PageSequencer.layout(sequence(doc), cover: doc.content.book.coverPageID).hasSplitSpread)
        #expect(undo.undoActionName == "Add Page")

        undo.undo()
        #expect(Snapshot(doc) == before, "one undo removes the spread and the blank")
        #expect(!undo.canUndo)
    }

    @Test func addPage_rejectsUnknownAndCoverTemplates() throws {
        let (doc, undo) = try makeDocument()
        #expect(!doc.perform(.addPage(index: 0, templateID: cover.id)))
        #expect(!doc.perform(.addPage(index: 0, templateID: TemplateID())))
        #expect(!undo.canUndo)
    }

    // MARK: duplicatePage

    @Test func duplicatePage_copiesTextAndPlacementsUnderNewSessions() throws {
        let (doc, undo) = try makeDocument(pages: 2)
        let source = order(doc)[0]
        perform(doc, undo, .setRichText(page: source, box: storyText, text: RichText(plain: "Once"), coalescing: false))
        let version = addVersion(to: doc, page: source, box: storyImage)
        perform(doc, undo, .chooseVersion(page: source, box: storyImage, version: version))
        let before = Snapshot(doc)

        #expect(perform(doc, undo, .duplicatePage(source)))
        #expect(undo.undoActionName == "Duplicate Page")
        #expect(order(doc).count == 3)
        let copyID = order(doc)[1]
        #expect(copyID != source)
        let original = try #require(doc.content.pages[source])
        let copy = try #require(doc.content.pages[copyID])
        #expect(copy.templateID == original.templateID)
        #expect(copy.text == original.text)
        let originalSlot = try #require(original.images[storyImage])
        let copySlot = try #require(copy.images[storyImage])
        #expect(copySlot.placement == originalSlot.placement)
        #expect(copySlot.sessionID != originalSlot.sessionID)
        let copiedSession = try #require(doc.content.sessions[copySlot.sessionID])
        #expect(copiedSession.owner == .pageBox(copyID, storyImage))
        #expect(copiedSession.version(version)?.image == doc.content.sessions[originalSlot.sessionID]?.version(version)?.image,
                "content-addressed image shared, no file copy")
        #expect(doc.content.placedVersion(page: copyID, box: storyImage)?.id == version)
        let after = Snapshot(doc)

        undo.undo()
        #expect(Snapshot(doc) == before)
        undo.redo()
        #expect(Snapshot(doc) == after)
    }

    @Test func duplicatePage_ofCoverIsRejected() throws {
        let (doc, _) = try makeDocument()
        #expect(!doc.perform(.duplicatePage(doc.content.book.coverPageID)))
    }

    // MARK: deletePage

    @Test func deletePage_withFixSplits_insertsBlank_undoRestores() throws {
        let (doc, undo) = try makeDocument()
        let first = order(doc)[0]
        perform(doc, undo, .addPage(index: 1, templateID: spreadID))
        let before = Snapshot(doc)
        #expect(doc.wouldSplitSpread(.deletePage(first)))
        #expect(perform(doc, undo, .deletePage(first, fixSplits: true)))
        #expect(doc.content.pages[first] == nil)
        #expect(order(doc).map { templateID(doc, $0) } == [textOnlyID, spreadID])
        undo.undo()
        #expect(Snapshot(doc) == before)
    }

    // MARK: reorderPages

    @Test func reorderPages_withFixSplits_insertsBlank_undoRemovesBoth() throws {
        let (doc, undo) = try makeDocument()
        let first = order(doc)[0]
        perform(doc, undo, .addPage(index: 1, templateID: spreadID))
        let spread = order(doc)[1]
        let before = Snapshot(doc)

        #expect(doc.wouldSplitSpread(.reorderPages([spread, first])))
        #expect(doc.wouldSplitSpread(.reorderPages([spread, first], fixSplits: true)),
                "answers for the unfixed variant")
        #expect(perform(doc, undo, .reorderPages([spread, first], fixSplits: true)))
        #expect(undo.undoActionName == "Move Page")
        #expect(order(doc).count == 3)
        #expect(templateID(doc, order(doc)[0]) == textOnlyID)
        #expect(Array(order(doc)[1...]) == [spread, first])
        let after = Snapshot(doc)

        undo.undo()
        #expect(Snapshot(doc) == before, "one undo restores the order and removes the blank")
        undo.redo()
        #expect(Snapshot(doc) == after)
    }

    @Test func reorderPages_withoutFix_leavesTheSplit_andRejectsNonPermutations() throws {
        let (doc, undo) = try makeDocument(pages: 3)
        let (a, b, c) = (order(doc)[0], order(doc)[1], order(doc)[2])
        #expect(!doc.wouldSplitSpread(.reorderPages([c, a, b])))
        #expect(perform(doc, undo, .reorderPages([c, a, b])))
        #expect(order(doc) == [c, a, b])
        undo.undo()
        #expect(order(doc) == [a, b, c])

        #expect(!doc.perform(.reorderPages([a, b, c])), "unchanged order is a no-op")
        #expect(!doc.perform(.reorderPages([a, b])))
        #expect(!doc.perform(.reorderPages([a, a, b])))
        #expect(!doc.perform(.reorderPages([a, b, PageID()])))
        #expect(order(doc) == [a, b, c])
    }

    // MARK: wouldSplitSpread

    @Test func wouldSplitSpread_falseCases_andMutatesNothing() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        let before = doc.content
        #expect(!doc.wouldSplitSpread(.addPage(index: 1, templateID: story.id)))
        #expect(!doc.wouldSplitSpread(.setPageDone(page, true)))
        #expect(!doc.wouldSplitSpread(.setRichText(page: page, box: storyText, text: RichText(plain: "x"))))
        #expect(!doc.wouldSplitSpread(.deletePage(PageID())), "unknown target")
        #expect(doc.wouldSplitSpread(.setPageTemplate(page: page, templateID: spreadID)))
        #expect(doc.wouldSplitSpread(.importStoryText([RichText(plain: "a")], templateID: spreadID, index: 0)))
        #expect(doc.content == before, "simulation copies nothing in")
        #expect(!undo.canUndo)
    }

    // MARK: setPageTemplate

    @Test func setPageTemplate_movesTextAndImage_undoRestores() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        perform(doc, undo, .setRichText(page: page, box: storyText, text: RichText(plain: "Hello"), coalescing: false))
        let version = addVersion(to: doc, page: page, box: storyImage)
        perform(doc, undo, .chooseVersion(page: page, box: storyImage, version: version))
        let oldSlot = try #require(doc.content.pages[page]?.images[storyImage])
        let before = Snapshot(doc)

        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: textLeftID)))
        #expect(undo.undoActionName == "Change Layout")
        let textLeft = try #require(doc.content.templates[textLeftID])
        let changed = try #require(doc.content.pages[page])
        #expect(changed.templateID == textLeftID)
        #expect(changed.text[textLeft.textBoxes[0].id]?.plainText == "Hello")
        #expect(changed.images[textLeft.imageBoxes[0].id] == oldSlot, "same session and placement")
        let after = Snapshot(doc)

        undo.undo()
        #expect(Snapshot(doc) == before)
        undo.redo()
        #expect(Snapshot(doc) == after)
    }

    @Test func setPageTemplate_createsSessionsForUnassignedImageBoxes() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        perform(doc, undo, .setPageTemplate(page: page, templateID: textOnlyID))
        #expect(doc.content.pages[page]?.images.isEmpty == true)
        perform(doc, undo, .setPageTemplate(page: page, templateID: textLeftID))
        let textLeft = try #require(doc.content.templates[textLeftID])
        let slot = try #require(doc.content.pages[page]?.images[textLeft.imageBoxes[0].id])
        #expect(doc.content.sessions[slot.sessionID]?.owner == .pageBox(page, textLeft.imageBoxes[0].id))
    }

    @Test func setPageTemplate_kindRules() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        let coverPage = doc.content.book.coverPageID
        #expect(!doc.perform(.setPageTemplate(page: page, templateID: cover.id)), "story page can't take a cover template")
        #expect(!doc.perform(.setPageTemplate(page: coverPage, templateID: story.id)), "cover takes only cover templates")
        #expect(!doc.perform(.setPageTemplate(page: page, templateID: story.id)), "same template is a no-op")
        #expect(!undo.canUndo)
    }

    @Test func setPageTemplate_toSpread_withFixSplits() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        let before = Snapshot(doc)
        #expect(perform(doc, undo, .setPageTemplate(page: page, templateID: spreadID, fixSplits: true)))
        #expect(order(doc).map { templateID(doc, $0) } == [textOnlyID, spreadID])
        undo.undo()
        #expect(Snapshot(doc) == before)
    }

    // MARK: importStoryText

    @Test func importStoryText_twelvePages_isOneUndoStep() throws {
        let (doc, undo) = try makeDocument()
        let first = order(doc)[0]
        let texts = (1...12).map { RichText(plain: "Paragraph \($0)") }
        let before = Snapshot(doc)

        #expect(perform(doc, undo, .importStoryText(texts, templateID: textLeftID, index: 1)))
        #expect(undo.undoActionName == "Import Story Text")
        #expect(order(doc).count == 13)
        #expect(order(doc)[0] == first)
        let textLeft = try #require(doc.content.templates[textLeftID])
        let imported = order(doc)[1...].map { doc.content.pages[$0]?.text[textLeft.textBoxes[0].id]?.plainText }
        #expect(imported == texts.map(\.plainText))
        for id in order(doc)[1...] {
            let slot = try #require(doc.content.pages[id]?.images[textLeft.imageBoxes[0].id])
            #expect(doc.content.sessions[slot.sessionID] != nil)
        }
        let after = Snapshot(doc)

        undo.undo()
        #expect(Snapshot(doc) == before, "⌘Z removes all 12 at once")
        #expect(!undo.canUndo)
        undo.redo()
        #expect(Snapshot(doc) == after)
    }

    @Test func importStoryText_usesFirstTextBoxInReadingOrder() throws {
        let (doc, undo) = try makeDocument()
        // The lower box comes first in layer order, so this checks reading order is by frame.
        let lower = Box(frame: NormalizedRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3), content: .text(TextBoxStyle()))
        let upper = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3), content: .text(TextBoxStyle()))
        let twoText = Template(name: "Two text", kind: .single, boxes: [lower, upper])
        doc.performIrreversible { content in
            content.templates[twoText.id] = twoText
            return DirtySet(templates: [twoText.id])
        }
        #expect(perform(doc, undo, .importStoryText([RichText(plain: "A")], templateID: twoText.id, index: 0)))
        let page = try #require(doc.content.pages[order(doc)[0]])
        #expect(page.text == [upper.id: RichText(plain: "A")])
    }

    @Test func importStoryText_emptyIsNoOp() throws {
        let (doc, undo) = try makeDocument()
        #expect(!doc.perform(.importStoryText([], templateID: story.id, index: 0)))
        #expect(!undo.canUndo)
    }

    // MARK: setPageDone / setPageNumberStyle

    @Test func setPageDone_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        #expect(perform(doc, undo, .setPageDone(page, true)))
        #expect(undo.undoActionName == "Mark as Done")
        #expect(doc.content.pages[page]?.isDone == true)
        #expect(doc.content.status(of: doc.content.pages[page]!) == .done)
        #expect(!doc.perform(.setPageDone(page, true)), "unchanged")
        undo.undo()
        #expect(doc.content.pages[page]?.isDone == false)
        undo.redo()
        #expect(doc.content.pages[page]?.isDone == true)
    }

    @Test func setPageNumberStyle_undoRedo() throws {
        let (doc, undo) = try makeDocument()
        let page = order(doc)[0]
        let style = PageNumberStyle(enabled: true, position: .bottomOuter, startNumber: 3, skippedPages: [page])
        #expect(perform(doc, undo, .setPageNumberStyle(style)))
        #expect(undo.undoActionName == "Change Page Numbers")
        #expect(doc.content.style.pageNumbers == style)
        #expect(!doc.perform(.setPageNumberStyle(style)), "unchanged")
        undo.undo()
        #expect(doc.content.style.pageNumbers == PageNumberStyle())
        undo.redo()
        #expect(doc.content.style.pageNumbers == style)
    }

    // MARK: Typing coalescing

    @Test func pageCommands_endTheTypingStep() throws {
        let content = BookContent.makeNew(title: "Test", storyTemplate: story, coverTemplate: cover,
                                          now: Date(timeIntervalSince1970: 0))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PageCommandTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let fixed = Date(timeIntervalSince1970: 1_000)
        let doc = BookDocument(content: content, store: BookStore(packageURL: url), now: { fixed })
        let undo = UndoManager()
        undo.groupsByEvent = false
        doc.undoManager = undo
        let page = content.book.pageOrder[0]
        perform(doc, undo, .setRichText(page: page, box: storyText, text: RichText(plain: "a")))
        perform(doc, undo, .setPageDone(page, true))
        perform(doc, undo, .setRichText(page: page, box: storyText, text: RichText(plain: "ab")))
        undo.undo()
        #expect(doc.content.pages[page]?.text[storyText]?.plainText == "a", "typing after a page command is a new step")
        undo.undo()
        #expect(doc.content.pages[page]?.isDone == false)
    }

    // MARK: Read-only

    @Test func readOnly_rejectsEveryPageCommand() throws {
        let (doc, undo) = try makeDocument(readOnly: true)
        let page = order(doc)[0]
        let before = doc.content
        let commands: [BookCommand] = [
            .addPage(index: 0, templateID: story.id), .addPage(index: 0, templateID: spreadID, fixSplits: true),
            .duplicatePage(page), .deletePage(page), .reorderPages([page]),
            .setPageTemplate(page: page, templateID: textLeftID),
            .importStoryText([RichText(plain: "x")], templateID: story.id, index: 0),
            .setPageDone(page, true), .setPageNumberStyle(PageNumberStyle(enabled: true)),
        ]
        for command in commands { #expect(!doc.perform(command), "\(command.actionName)") }
        #expect(!doc.setAuthor("Someone"))
        #expect(doc.content == before)
        #expect(!undo.canUndo)
    }

    // MARK: setAuthor

    @Test func setAuthor_trims_andIsNotUndoable() async throws {
        let (doc, undo) = try makeDocument()
        #expect(doc.setAuthor("  Ada Lovelace \n"))
        #expect(doc.content.book.author == "Ada Lovelace")
        #expect(!undo.canUndo)
        #expect(doc.setAuthor(""), "clearing the author is allowed")
        #expect(doc.content.book.author == "")
        await doc.close()
        #expect(!doc.setAuthor("Late"))
    }

    // MARK: Persistence

    @Test func pageCommands_roundTripThroughSaveAndReload() async throws {
        let (doc, undo) = try makeDocument(pages: 2)
        let (a, b) = (order(doc)[0], order(doc)[1])
        perform(doc, undo, .setRichText(page: a, box: storyText, text: RichText(plain: "One"), coalescing: false))
        perform(doc, undo, .importStoryText((1...3).map { RichText(plain: "T\($0)") }, templateID: textLeftID, index: 2))
        perform(doc, undo, .duplicatePage(a))
        perform(doc, undo, .addPage(index: 0, templateID: spreadID, fixSplits: true))
        perform(doc, undo, .setPageTemplate(page: b, templateID: textOnlyID))
        perform(doc, undo, .setPageDone(a, true))
        perform(doc, undo, .setPageNumberStyle(PageNumberStyle(enabled: true, startNumber: 5)))
        perform(doc, undo, .deletePage(b, fixSplits: true))
        #expect(doc.setAuthor("Author"))
        var reversed = order(doc)
        reversed.reverse()
        perform(doc, undo, .reorderPages(reversed, fixSplits: true))
        await doc.flush()
        #expect(doc.lastSaveError == nil)
        let reloaded = try await BookStore(packageURL: doc.store.packageURL).load()
        #expect(reloaded == doc.content)

        // Undo everything (pages added then removed, template copies left behind) and save again.
        while undo.canUndo { undo.undo() }
        await doc.flush()
        #expect(doc.lastSaveError == nil)
        let afterUndo = try await BookStore(packageURL: doc.store.packageURL).load()
        #expect(afterUndo == doc.content)
        #expect(afterUndo.book.pageOrder == [a, b])
    }

    // MARK: Helpers

    func sequence(_ doc: BookDocument) -> [SequenceEntry] {
        order(doc).map { SequenceEntry(id: $0, isSpread: templateID(doc, $0) == spreadID) }
    }

    @discardableResult
    func addVersion(to doc: BookDocument, page: PageID, box: BoxID) -> VersionID {
        let sha = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        let version = Version(image: ImageRef(sha256: sha, contentType: "public.png"),
                              pixelSize: PixelSize(width: 1024, height: 1024), source: .generated,
                              createdAt: Date(timeIntervalSince1970: 1))
        let sessionID = doc.content.pages[page]!.images[box]!.sessionID
        doc.performIrreversible { content in
            content.sessions[sessionID]?.versions.append(version)
            return DirtySet(sessions: [sessionID])
        }
        return version.id
    }
}
