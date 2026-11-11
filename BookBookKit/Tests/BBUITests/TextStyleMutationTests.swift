import BBAI
import BBAICore
import BBLayout
import BBModel
import BBStore
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

/// AI text styling (A §7.13): the styling slot and session, delivery of a decoration, the
/// typography-only path, choosing and removing a style (undoable), and the renderer's resolved
/// look.
@MainActor
struct TextStyleMutationTests {
    let textBox = Fixtures.textBox.id

    func styleIntent(_ text: String = "gold frame", decoration: String? = "a gold frame",
                     refines: VersionID? = nil) -> GenerationIntent {
        let call = TextStyleCall(provider: .openai, model: "gpt-6-luna", system: "SYSTEM", user: "USER",
                                 parametersSent: ["model": "gpt-6-luna"], cost: CostRecordID())
        let style = TextStyleIntent(styling: TextStyling(font: FontRef(postScriptName: "Georgia"), fontSize: 30,
                                                         color: RGBA(red: 0.5, green: 0.2, blue: 0),
                                                         alignment: .center, insetFraction: 0.15),
                                    decorationPrompt: decoration, summary: "A gold frame.", call: call)
        return GenerationIntent(messageText: text, refines: refines, provider: .openai,
                                model: "gpt-image-2.5-sunburst", quality: .draft, includeStoryText: false,
                                checkConsistency: false, textStyle: style)
    }

    /// A book whose first page's text box has a styling slot.
    func styledBook() -> (BookContent, PageID, SessionID) {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let dirty = BookMutations.ensureTextStyleSlot(page: page, box: textBox, to: &content)
        let sessionID = content.pages[page]!.textStyles[textBox]!.sessionID
        #expect(dirty.pages == [page])
        #expect(dirty.sessions == [sessionID])
        #expect(content.sessions[sessionID]?.owner == .textBox(page, textBox))
        return (content, page, sessionID)
    }

    func deliver(_ intent: GenerationIntent, page: PageID, to content: inout BookContent) -> VersionID {
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: content.book.id,
                                                           target: .textBox(page, textBox), now: Fixtures.date)
        _ = BookMutations.appendPendingMessage(message, target: item.target, to: &content)
        var provenance = Fixtures.provenance()
        provenance.intent = intent
        let id = VersionID()
        _ = BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                                        provenance: provenance)),
                                        storedImage: Fixtures.ref, to: &content, versionID: id, now: Fixtures.date)
        return id
    }

    @Test func ensureSlot_onlyForTextBoxes_once() {
        var (content, page, _) = styledBook()
        #expect(BookMutations.ensureTextStyleSlot(page: page, box: textBox, to: &content).isEmpty)
        #expect(BookMutations.ensureTextStyleSlot(page: page, box: Fixtures.imageBox.id, to: &content).isEmpty)
        #expect(content.pages[page]?.textStyles[Fixtures.imageBox.id] == nil)
    }

    @Test func delivery_addsVersionAndShowsTheNewestStyle() throws {
        var (content, page, sessionID) = styledBook()
        let first = deliver(styleIntent(), page: page, to: &content)
        #expect(content.pages[page]?.textStyles[textBox]?.versionID == first)
        let second = deliver(styleIntent("blue", refines: first), page: page, to: &content)
        #expect(content.pages[page]?.textStyles[textBox]?.versionID == second)
        let session = try #require(content.sessions[sessionID])
        #expect(session.versions.map(\.id) == [first, second])
        #expect(session.messages.allSatisfy { $0.queueItemID == nil })
        let applied = try #require(content.appliedTextStyle(page: page, box: textBox))
        #expect(applied.decoration == Fixtures.ref)
        #expect(applied.styling.fontSize == 30)
        // Picture boxes are untouched.
        #expect(content.pages[page]?.images[Fixtures.imageBox.id]?.placement == nil)
    }

    @Test func typographyOnly_makesAVersionWithNoDecoration() throws {
        var (content, page, sessionID) = styledBook()
        let message = Message(role: .user, text: "playful font", createdAt: Fixtures.date)
        let intent = styleIntent("playful font", decoration: nil)
        let dirty = BookMutations.appendTypographyOnlyStyle(message: message, intent: intent,
                                                            placeholder: Fixtures.ref, page: page, box: textBox,
                                                            to: &content, now: Fixtures.date)
        #expect(dirty.sessions == [sessionID])
        #expect(dirty.pages == [page])
        let session = try #require(content.sessions[sessionID])
        #expect(session.versions.count == 1)
        #expect(session.messages.first?.producedVersion == session.versions.first?.id)
        let applied = try #require(content.appliedTextStyle(page: page, box: textBox))
        #expect(applied.decoration == nil)
        // The version's cost is the design request (there was no image request).
        #expect(session.versions.first?.provenance?.cost == intent.textStyle?.call.cost)
    }

    @Test func deleteAndReset_removeTheShownStyle() {
        var (content, page, sessionID) = styledBook()
        let id = deliver(styleIntent(), page: page, to: &content)
        let dirty = BookMutations.deleteVersion(id, in: sessionID, to: &content)
        #expect(dirty.pages == [page])
        #expect(content.pages[page]?.textStyles[textBox]?.versionID == nil)

        _ = deliver(styleIntent(), page: page, to: &content)
        _ = BookMutations.resetSession(sessionID, keepVersions: false, to: &content)
        #expect(content.pages[page]?.textStyles[textBox]?.versionID == nil)
    }

    @Test func pageCoding_omitsEmptyStylesAndReadsOldFiles() throws {
        let page = Page(kind: .story, templateID: TemplateID())
        let data = try JSONEncoder().encode(page)
        #expect(!(String(decoding: data, as: UTF8.self).contains("textStyles")))
        #expect(try JSONDecoder().decode(Page.self, from: data) == page)

        var styled = page
        styled.textStyles[BoxID()] = TextStyleSlot(sessionID: SessionID(), versionID: VersionID())
        #expect(try JSONDecoder().decode(Page.self, from: JSONEncoder().encode(styled)) == styled)

        let owner = SessionOwner.textBox(PageID(), BoxID())
        #expect(try JSONDecoder().decode(SessionOwner.self, from: JSONEncoder().encode(owner)) == owner)
    }

    // MARK: Commands

    func makeDocument() throws -> (BookDocument, UndoManager, PageID, SessionID, VersionID, VersionID) {
        var (content, page, sessionID) = styledBook()
        let first = deliver(styleIntent(), page: page, to: &content)
        let second = deliver(styleIntent("blue"), page: page, to: &content)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "TextStyleMutationTests-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return (document, undo, page, sessionID, first, second)
    }

    func perform(_ doc: BookDocument, _ undo: UndoManager, _ command: BookCommand) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return doc.perform(command)
    }

    @Test func chooseAndRemoveStyle_areUndoable() throws {
        let (doc, undo, page, _, first, second) = try makeDocument()
        #expect(doc.content.pages[page]?.textStyles[textBox]?.versionID == second)

        #expect(perform(doc, undo, .chooseTextStyle(page: page, box: textBox, version: first)))
        #expect(doc.content.pages[page]?.textStyles[textBox]?.versionID == first)
        #expect(undo.undoMenuItemTitle == "Undo Choose Text Style")

        #expect(perform(doc, undo, .chooseTextStyle(page: page, box: textBox, version: nil)))
        #expect(doc.content.pages[page]?.textStyles[textBox]?.versionID == nil)
        #expect(undo.undoMenuItemTitle == "Undo Remove Text Style")

        undo.undo()
        #expect(doc.content.pages[page]?.textStyles[textBox]?.versionID == first)
        undo.undo()
        #expect(doc.content.pages[page]?.textStyles[textBox]?.versionID == second)

        // No-ops: the shown version again, or a version that isn't a text style.
        #expect(!perform(doc, undo, .chooseTextStyle(page: page, box: textBox, version: second)))
        #expect(!perform(doc, undo, .chooseTextStyle(page: page, box: textBox, version: VersionID())))
    }

    @Test func duplicatePage_copiesTheStyleSession() throws {
        let (doc, undo, page, sessionID, _, second) = try makeDocument()
        #expect(perform(doc, undo, .duplicatePage(page)))
        let copyID = try #require(doc.content.book.pageOrder.last)
        #expect(copyID != page)
        let slot = try #require(doc.content.pages[copyID]?.textStyles[textBox])
        #expect(slot.sessionID != sessionID)
        #expect(slot.versionID == second)
        #expect(doc.content.sessions[slot.sessionID]?.owner == .textBox(copyID, textBox))
        #expect(doc.content.appliedTextStyle(page: copyID, box: textBox) != nil)
    }

    // MARK: Appearance

    @Test func appearance_layersThePageStyleOverTheTemplate() throws {
        var (content, page, _) = styledBook()
        guard case let .text(style) = Fixtures.textBox.content else { Issue.record("not a text box"); return }
        let size = CGSize(width: 200, height: 100)
        let plain = TextBoxAppearance.resolve(box: Fixtures.textBox, style: style, pageID: page, content: content,
                                              renderSize: size)
        #expect(plain.padding == 4)
        #expect(plain.decoration == nil)

        _ = deliver(styleIntent(), page: page, to: &content)
        let styled = TextBoxAppearance.resolve(box: Fixtures.textBox, style: style, pageID: page, content: content,
                                               renderSize: size)
        #expect(styled.typography.bodyFont.postScriptName == "Georgia")
        #expect(styled.typography.bodySize == 30)
        #expect(styled.typography.alignment == .center)
        #expect(styled.padding == 15)                         // 0.15 × the 100 pt short side
        #expect(styled.decoration == Fixtures.ref)

        // Layout previews (no page) never show a page's style.
        let preview = TextBoxAppearance.resolve(box: Fixtures.textBox, style: style, pageID: nil, content: content,
                                                renderSize: size)
        #expect(preview == plain)
    }

    @Test func boxLabels() {
        let content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        #expect(TextStyleLabels.boxLabel(page: page, box: textBox, in: content) == "Text")
        #expect(DraftAllPlanner.textStyleDisplay(page: page, box: textBox, in: content).boxLabel == "Text Style")
    }
}
