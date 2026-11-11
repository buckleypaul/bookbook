import BBAI
import BBAICore
import BBModel
import BBStore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

@MainActor
struct SessionMutationsTests {
    private let box = Fixtures.imageBox.id

    private func ref(_ n: Int) -> ImageRef {
        ImageRef(sha256: String(repeating: String(format: "%02x", n), count: 32), contentType: "public.png")
    }

    /// A book whose first page's box has `count` versions; `placed` (1-based, 0 = none) is placed.
    private func book(versions count: Int, placed: Int = 0) -> (BookContent, PageID, SessionID, [VersionID]) {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let sessionID = content.pages[page]!.images[box]!.sessionID
        var ids: [VersionID] = []
        for n in 0..<count {
            let id = VersionID()
            ids.append(id)
            content.sessions[sessionID]!.versions.append(
                Version(id: id, image: ref(n + 1), pixelSize: PixelSize(width: 10, height: 10), source: .generated,
                        createdAt: Fixtures.date))
        }
        if placed > 0 {
            content.pages[page]!.images[box]!.placement = ImagePlacement(versionID: ids[placed - 1],
                                                                          boxAspectWhenPlaced: 1)
        }
        return (content, page, sessionID, ids)
    }

    @Test func setStarred_togglesAndReportsNoChangeWhenSame() {
        var (content, _, sid, ids) = book(versions: 2)
        #expect(BookMutations.setStarred(true, version: ids[1], in: sid, to: &content).sessions == [sid])
        #expect(content.sessions[sid]!.versions[1].starred)
        #expect(!content.sessions[sid]!.versions[0].starred)
        #expect(BookMutations.setStarred(true, version: ids[1], in: sid, to: &content).isEmpty)
        _ = BookMutations.setStarred(false, version: ids[1], in: sid, to: &content)
        #expect(!content.sessions[sid]!.versions[1].starred)
    }

    @Test func deleteVersion_unplaced_keepsPlacement() {
        var (content, page, sid, ids) = book(versions: 3, placed: 1)
        let dirty = BookMutations.deleteVersion(ids[2], in: sid, to: &content)
        #expect(content.sessions[sid]!.versions.map(\.id) == [ids[0], ids[1]])
        #expect(content.pages[page]!.images[box]!.placement?.versionID == ids[0])
        #expect(dirty.sessions == [sid])
        #expect(dirty.pages.isEmpty)
    }

    @Test func deleteVersion_placed_emptiesTheBox() {
        var (content, page, sid, ids) = book(versions: 2, placed: 2)
        let dirty = BookMutations.deleteVersion(ids[1], in: sid, to: &content)
        #expect(content.sessions[sid]!.versions.map(\.id) == [ids[0]])
        #expect(content.pages[page]!.images[box]!.placement == nil)
        #expect(dirty.pages == [page])
    }

    @Test func deleteVersion_unknown_changesNothing() {
        var (content, _, sid, _) = book(versions: 1, placed: 1)
        let before = content
        #expect(BookMutations.deleteVersion(VersionID(), in: sid, to: &content).isEmpty)
        #expect(content == before)
    }

    @Test func resetSession_keep_bumpsEpochAndHidesThreadButKeepsVersionsAndPlacement() {
        var (content, page, sid, ids) = book(versions: 2, placed: 2)
        content.sessions[sid]!.messages.append(Message(role: .user, text: "a fox", createdAt: Fixtures.date))
        let dirty = BookMutations.resetSession(sid, keepVersions: true, to: &content)
        let session = content.sessions[sid]!
        #expect(session.resetEpoch == 1)
        #expect(session.visibleMessages.isEmpty)
        #expect(session.messages.count == 1)
        #expect(session.versions.map(\.id) == ids)
        #expect(content.pages[page]!.images[box]!.placement?.versionID == ids[1])
        #expect(dirty.sessions == [sid])
        #expect(dirty.pages.isEmpty)
    }

    @Test func resetSession_discard_removesVersionsAndClearsPlacement() {
        var (content, page, sid, _) = book(versions: 2, placed: 1)
        let dirty = BookMutations.resetSession(sid, keepVersions: false, to: &content)
        #expect(content.sessions[sid]!.resetEpoch == 1)
        #expect(content.sessions[sid]!.versions.isEmpty)
        #expect(content.pages[page]!.images[box]!.placement == nil)
        #expect(dirty.pages == [page])
    }

    @Test func appendImportedVersion_placesOnlyIntoAnEmptyBox() {
        var (content, page, sid, ids) = book(versions: 0)
        let first = VersionID(), second = VersionID()
        let d1 = BookMutations.appendImportedVersion(image: ref(7), pixelSize: PixelSize(width: 20, height: 40),
                                                     page: page, box: box, to: &content, versionID: first,
                                                     now: Fixtures.date)
        #expect(ids.isEmpty)
        let version = content.sessions[sid]!.version(first)
        #expect(version?.source == .imported)
        #expect(version?.provenance == nil)
        #expect(version?.pixelSize == PixelSize(width: 20, height: 40))
        #expect(content.pages[page]!.images[box]!.placement?.versionID == first)
        #expect(d1.pages == [page])

        let d2 = BookMutations.appendImportedVersion(image: ref(8), pixelSize: PixelSize(width: 1, height: 1),
                                                     page: page, box: box, to: &content, versionID: second,
                                                     now: Fixtures.date)
        #expect(content.sessions[sid]!.versions.map(\.id) == [first, second])
        #expect(content.pages[page]!.images[box]!.placement?.versionID == first)
        #expect(d2.pages.isEmpty)
        #expect(d2.sessions == [sid])
    }

    @Test func appendImportedVersion_missingBox_changesNothing() {
        var (content, page, _, _) = book(versions: 0)
        let before = content
        let dirty = BookMutations.appendImportedVersion(image: ref(1), pixelSize: PixelSize(width: 1, height: 1),
                                                        page: page, box: BoxID(), to: &content, now: Fixtures.date)
        #expect(dirty.isEmpty)
        #expect(content == before)
    }

    @Test func delivery_resolvesSessionByMessage_afterTheBoxMoved() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        let (message, item) = Fixtures.generation("a fox", bookID: content.book.id, page: page, box: box)
        _ = BookMutations.appendPendingMessage(message, target: .pageBox(page, box), to: &content)
        let sessionID = content.pages[page]!.images[box]!.sessionID
        // The slot now lives under another box ID: the item's target no longer names it.
        let slot = content.pages[page]!.images.removeValue(forKey: box)!
        content.pages[page]!.images[BoxID()] = slot

        let versionID = VersionID()
        let delivery = GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                         provenance: Fixtures.provenance()))
        let dirty = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content,
                                                versionID: versionID, now: Fixtures.date)
        let session = try #require(content.sessions[sessionID])
        #expect(session.version(versionID) != nil)
        let updated = try #require(session.messages.first { $0.id == message.id })
        #expect(updated.producedVersion == versionID)
        #expect(updated.queueItemID == nil)
        #expect(dirty.sessions == [sessionID])
    }

    // MARK: Regenerate

    @Test func makeGeneration_fromIntent_repeatsTextAndRefinesUnchanged() {
        let refines = VersionID()
        let intent = GenerationIntent(messageText: "make the sky blue", refines: refines, provider: .openai,
                                      model: "m", quality: .high, includeStoryText: false)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: BookID(),
                                                           target: .pageBox(PageID(), BoxID()), now: Fixtures.date)
        #expect(item.intent == intent)
        #expect(message.text == "make the sky blue")
        #expect(message.refines == refines)
        #expect(message.queueItemID == item.id)
    }

    // MARK: importImage

    private func makeDocument() throws -> BookDocument {
        let content = Fixtures.book()
        let url = FileManager.default.temporaryDirectory.appending(path: "Import-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        return BookDocument(content: content, store: BookStore(packageURL: url))
    }

    private func writeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appending(path: "pic-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        return url
    }

    @Test func importImage_storesNormalizedFile_appendsAndPlacesImportedVersion() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let page = Fixtures.firstPage(document.content)
        let file = try writeJPEG(width: 40, height: 20, orientation: 6)
        defer { try? FileManager.default.removeItem(at: file) }

        let id = try await document.importImage(from: file, page: page, box: box)
        let slot = try #require(document.content.pages[page]?.images[box])
        let version = try #require(document.content.sessions[slot.sessionID]?.version(id))
        #expect(version.source == .imported)
        #expect(version.pixelSize == PixelSize(width: 20, height: 40))
        #expect(slot.placement?.versionID == id)
        #expect(FileManager.default.fileExists(atPath: document.store.imageURL(for: version.image).path(percentEncoded: false)))
    }

    @Test func importImage_rejectsNonImagesAndNonFileURLs() async throws {
        let document = try makeDocument()
        defer { try? FileManager.default.removeItem(at: document.store.packageURL) }
        let page = Fixtures.firstPage(document.content)
        let text = FileManager.default.temporaryDirectory.appending(path: "note-\(UUID().uuidString).txt")
        try Data("not a picture".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }

        await #expect(throws: ImageImportFailure.notAnImage) {
            try await document.importImage(from: text, page: page, box: box)
        }
        await #expect(throws: ImageImportFailure.notAFileURL) {
            try await document.importImage(from: URL(string: "https://example.com/a.png")!, page: page, box: box)
        }
        await #expect(throws: ImageImportFailure.boxGone) {
            try await document.importImage(from: text, page: page, box: BoxID())
        }
    }
}
