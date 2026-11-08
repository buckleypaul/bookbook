import BBAI
import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBUI

@MainActor
struct BookMutationsTests {
    /// A book with one pending message in page 1's image box.
    private func pendingBook() -> (BookContent, Message, QueueItem, PageID, SessionID) {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let (message, item) = BookMutations.makeGeneration(
            prompt: "a fox", refines: nil, defaults: GenerationDefaults(), bookID: content.book.id,
            page: page, box: Fixtures.imageBox.id, now: Fixtures.date)
        let dirty = BookMutations.appendPendingMessage(message, page: page, box: Fixtures.imageBox.id, to: &content)
        let sessionID = content.pages[page]!.images[Fixtures.imageBox.id]!.sessionID
        #expect(dirty.sessions == [sessionID])
        return (content, message, item, page, sessionID)
    }

    @Test func makeGeneration_usesSliceDefaultsAndLinksMessageToItem() {
        let page = PageID(), box = BoxID(), book = BookID(), refines = VersionID()
        let (message, item) = BookMutations.makeGeneration(prompt: "a fox", refines: refines,
                                                           defaults: GenerationDefaults(), bookID: book,
                                                           page: page, box: box, now: Fixtures.date)
        #expect(message.role == .user)
        #expect(message.queueItemID == item.id)
        #expect(message.refines == refines)
        #expect(item.messageID == message.id)
        #expect(item.bookID == book)
        #expect(item.target == .pageBox(page, box))
        #expect(item.intent.provider == .openai)
        #expect(item.intent.model == "gpt-image-2.5-sunburst")
        #expect(item.intent.quality == .standard)
        #expect(item.intent.includeStoryText)
        #expect(item.intent.refines == refines)
    }

    @Test func appendPendingMessage_missingBox_changesNothing() {
        var content = Fixtures.book()
        let before = content
        let message = Message(role: .user, text: "x", createdAt: Fixtures.date)
        let dirty = BookMutations.appendPendingMessage(message, page: Fixtures.firstPage(content), box: BoxID(),
                                                       to: &content)
        #expect(dirty.isEmpty)
        #expect(content == before)
    }

    @Test func success_addsVersion_setsProducedVersion_clearsPending_andPlacesInEmptyBox() throws {
        var (content, message, item, page, sessionID) = pendingBook()
        let versionID = VersionID()
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                         provenance: Fixtures.provenance()))
        let dirty = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content,
                                                versionID: versionID, now: Fixtures.date)

        let session = try #require(content.sessions[sessionID])
        let version = try #require(session.version(versionID))
        #expect(version.source == .generated)
        #expect(version.image == Fixtures.ref)
        #expect(version.pixelSize == PixelSize(width: 1024, height: 1536))
        #expect(version.provenance == Fixtures.provenance())
        let updated = try #require(session.messages.first { $0.id == message.id })
        #expect(updated.producedVersion == versionID)
        #expect(updated.queueItemID == nil)

        let placement = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.placement)
        #expect(placement.versionID == versionID)
        #expect(placement.zoom == 1)
        #expect(placement.center == .center)
        // 0.8 × 612 / (0.5 × 792)
        #expect(abs(placement.boxAspectWhenPlaced - (0.8 * 612) / (0.5 * 792)) < 1e-9)
        #expect(dirty.sessions == [sessionID])
        #expect(dirty.pages == [page])
    }

    @Test func success_doesNotReplaceAPlacedVersion() throws {
        var (content, _, item, page, sessionID) = pendingBook()
        let first = VersionID()
        _ = BookMutations.applyDelivery(
            GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(), provenance: Fixtures.provenance())),
            storedImage: Fixtures.ref, to: &content, versionID: first, now: Fixtures.date)

        let (message2, item2) = BookMutations.makeGeneration(prompt: "again", refines: first, defaults: GenerationDefaults(),
                                                             bookID: content.book.id, page: page,
                                                             box: Fixtures.imageBox.id, now: Fixtures.date)
        _ = BookMutations.appendPendingMessage(message2, page: page, box: Fixtures.imageBox.id, to: &content)
        let second = VersionID()
        let dirty = BookMutations.applyDelivery(
            GenerationDelivery(item: item2, outcome: .success(result: Fixtures.result(),
                                                              provenance: Fixtures.provenance(refines: first))),
            storedImage: Fixtures.ref, to: &content, versionID: second, now: Fixtures.date)

        #expect(content.pages[page]?.images[Fixtures.imageBox.id]?.placement?.versionID == first)
        #expect(content.sessions[sessionID]?.versions.map(\.id) == [first, second])
        #expect(content.sessions[sessionID]?.version(second)?.parent == first)
        #expect(dirty.pages.isEmpty)
        #expect(dirty.sessions == [sessionID])
    }

    @Test func failure_clearsPendingOnly() throws {
        var (content, message, item, page, sessionID) = pendingBook()
        let dirty = BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .failure(.offline)),
                                                storedImage: nil, to: &content, now: Fixtures.date)
        let session = try #require(content.sessions[sessionID])
        #expect(session.versions.isEmpty)
        let updated = try #require(session.messages.first { $0.id == message.id })
        #expect(updated.queueItemID == nil)
        #expect(updated.producedVersion == nil)
        #expect(content.pages[page]?.images[Fixtures.imageBox.id]?.placement == nil)
        #expect(dirty.sessions == [sessionID])
        #expect(dirty.pages.isEmpty)
    }

    @Test func successWithoutStoredImage_actsLikeFailure() throws {
        var (content, _, item, _, sessionID) = pendingBook()
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                         provenance: Fixtures.provenance()))
        _ = BookMutations.applyDelivery(delivery, storedImage: nil, to: &content, now: Fixtures.date)
        let session = try #require(content.sessions[sessionID])
        #expect(session.versions.isEmpty)
        #expect(session.messages.allSatisfy { $0.queueItemID == nil })
    }

    @Test func delivery_forDeletedPage_changesNothing() {
        var (content, _, item, page, _) = pendingBook()
        content.pages[page] = nil
        let before = content
        let dirty = BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .failure(.timeout)),
                                                storedImage: nil, to: &content, now: Fixtures.date)
        #expect(dirty.isEmpty)
        #expect(content == before)
    }
}
