import BBAI
import BBAICore
import BBModel
import BBStore
import CryptoKit
import Foundation
import Testing
@testable import BBUI

/// Phase 11 (A §7.6): `generateRegionEdit`, replay, delivery as `.regionEdit` and Version details.
@MainActor
struct RegionEditTests {
    static let size = PixelSize(width: 64, height: 48)
    static let drawing = RegionMaskDrawing(pixelSize: size, operations: [
        .brush(points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 20)], diameter: 8, erase: false),
    ])

    private struct Setup {
        var h: Phase9Harness
        var app: AppModel
        var document: BookDocument
        var page: PageID
        var base: Version
        var target: GenerationTarget { .pageBox(page, Fixtures.imageBox.id) }
    }

    private func setup() throws -> Setup {
        let h = try Phase9Harness()
        var content = Fixtures.book(pages: 1)
        let page = Fixtures.firstPage(content)
        let sessionID = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        let base = Version(image: Fixtures.ref, pixelSize: Self.size, source: .generated, createdAt: Fixtures.date)
        content.sessions[sessionID]?.versions = [base]
        let url = h.dir.appending(path: "Region.bookbook", directoryHint: .isDirectory)
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))
        let app = h.makeApp()
        app.pauseQueue()
        return Setup(h: h, app: app, document: document, page: page, base: base)
    }

    private func messages(_ s: Setup) -> [Message] {
        let id = s.document.content.pages[s.page]?.images[Fixtures.imageBox.id]?.sessionID
        return id.flatMap { s.document.content.sessions[$0]?.messages } ?? []
    }

    private static func expectedMaskRef() throws -> ImageRef {
        let png = try ImageOps.grayscalePNG(ImageOps.rasterize(drawing))
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        return ImageRef(sha256: hash, contentType: "public.png")
    }

    @Test func generateRegionEdit_storesTheMaskAndQueuesTheIntent() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let id = try await s.app.generateRegionEdit(prompt: " make the scarf yellow ", quality: .draft,
                                                    includeStoryText: false, refines: s.base.id,
                                                    drawing: Self.drawing, target: s.target, in: s.document)
        let mask = try Self.expectedMaskRef()
        #expect(FileManager.default.fileExists(atPath: s.document.store.imageURL(for: mask).path))
        let message = try #require(messages(s).first)
        #expect(message.text == "make the scarf yellow")
        #expect(message.refines == s.base.id)
        #expect(message.queueItemID == id)
        await s.app.queueOperationsSettled()
        await until("snapshot") { s.app.queueSnapshot.entries.count == 1 }
        let entry = try #require(s.app.queueSnapshot.entries.first)
        #expect(entry.item.intent.regionMask == mask)
        #expect(entry.item.intent.refines == s.base.id)
        #expect(entry.item.intent.model == s.app.defaults.model)
    }

    @Test func generateRegionEdit_refusesWithoutQueueing() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        func refusal(_ drawing: RegionMaskDrawing, prompt: String = "yellow") async -> RegionEditRefusal? {
            do {
                _ = try await s.app.generateRegionEdit(prompt: prompt, quality: .draft, includeStoryText: false,
                                                       refines: s.base.id, drawing: drawing, target: s.target,
                                                       in: s.document)
                return nil
            } catch {
                return error
            }
        }
        // Nothing drawn, and a drawing that erases everything it paints.
        #expect(await refusal(RegionMaskDrawing(pixelSize: Self.size)) == .emptyMask)
        let erased = RegionMaskDrawing(pixelSize: Self.size, operations: [
            .lasso(points: [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 0), CGPoint(x: 64, y: 48)], erase: false),
            .lasso(points: [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 0), CGPoint(x: 64, y: 48)], erase: true),
        ])
        #expect(await refusal(erased) == .emptyMask)
        // Not at the base version's pixel size.
        let other = RegionMaskDrawing(pixelSize: PixelSize(width: 32, height: 24), operations: [.invert])
        #expect(await refusal(other) == .sizeMismatch(expected: Self.size, actual: PixelSize(width: 32, height: 24)))
        #expect(await refusal(Self.drawing, prompt: "  ") == .emptyPrompt)
        // A model without `supportsMask` (or unknown to the catalog).
        s.app.preferences.defaultImageModelID = "no-such-model"
        #expect(await refusal(Self.drawing) == .maskUnsupported(model: "no-such-model"))
        #expect(s.app.regionEditUnavailableReason(refines: s.base.id, target: s.target, in: s.document)
            == .maskUnsupported(model: "no-such-model"))
        #expect(messages(s).isEmpty)
        // Nothing was stored either.
        let images = s.document.store.packageURL.appending(path: "images")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func regionEditUnavailableReason_nilForTheDefaultModel() throws {
        let s = try setup()
        defer { s.h.tearDown() }
        #expect(s.app.regionEditUnavailableReason(refines: s.base.id, target: s.target, in: s.document) == nil)
        #expect(s.app.regionEditUnavailableReason(refines: VersionID(), target: s.target, in: s.document)
            == .baseVersionGone)
    }

    @Test func regenerateWithSameSettings_replaysTheMask() async throws {
        let s = try setup()
        defer { s.h.tearDown() }
        let mask = try Self.expectedMaskRef()
        let intent = GenerationIntent(messageText: "make the scarf yellow", refines: s.base.id, provider: .openai,
                                      model: "gpt-image-2.5-sunburst", quality: .draft, regionMask: mask)
        var provenance = Fixtures.provenance(refines: s.base.id)
        provenance.intent = intent
        provenance.maskSent = mask
        let edit = Version(image: Fixtures.ref, pixelSize: Self.size, source: .regionEdit, parent: s.base.id,
                           createdAt: Fixtures.date, provenance: provenance)
        #expect(s.app.regenerate(edit, target: s.target, in: s.document))
        await s.app.queueOperationsSettled()
        await until("snapshot") { s.app.queueSnapshot.entries.count == 1 }
        // Unchanged, except the consistency follow-up follows today's Settings switch (Phase 12).
        var replayed = intent
        replayed.checkConsistency = s.app.preferences.consistencyCheckEnabled
        #expect(s.app.queueSnapshot.entries.first?.item.intent == replayed)
    }

    // MARK: Delivery

    private func regionDelivery(target: GenerationTarget, messageID: MessageID, refines: VersionID,
                                raw: ImageRef) -> GenerationDelivery {
        let mask = ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")
        let intent = GenerationIntent(messageText: "yellow", refines: refines, provider: .openai,
                                      model: "gpt-image-2.5-sunburst", quality: .draft, regionMask: mask)
        var provenance = Fixtures.provenance(refines: refines)
        provenance.intent = intent
        provenance.maskSent = mask
        provenance.rawOutput = raw
        provenance.featherPixels = 8
        let item = QueueItem(bookID: BookID(), target: target, messageID: messageID, intent: intent)
        let result = ImageResult(imageData: Data([9]), contentType: "public.png", pixelSize: Self.size)
        return GenerationDelivery(item: item, outcome: .success(result: result, provenance: provenance),
                                  additionalImages: [raw: Data([8])])
    }

    @Test func applyDelivery_makesARegionEditVersion_pageAndAsset() throws {
        var content = Fixtures.book(pages: 1)
        let page = Fixtures.firstPage(content)
        let sessionID = try #require(content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        let base = Version(image: Fixtures.ref, pixelSize: Self.size, source: .generated, createdAt: Fixtures.date)
        content.sessions[sessionID]?.versions = [base]
        let message = Message(role: .user, text: "yellow", refines: base.id, queueItemID: QueueItemID(),
                              createdAt: Fixtures.date)
        content.sessions[sessionID]?.messages = [message]
        let raw = ImageRef(sha256: String(repeating: "ef", count: 32), contentType: "public.png")
        let delivery = regionDelivery(target: .pageBox(page, Fixtures.imageBox.id), messageID: message.id,
                                      refines: base.id, raw: raw)
        _ = BookMutations.applyDelivery(delivery, storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        let made = try #require(content.sessions[sessionID]?.versions.last)
        #expect(made.source == .regionEdit)
        #expect(made.parent == base.id)
        #expect(made.pixelSize == Self.size)
        #expect(made.provenance?.rawOutput == raw)

        // Asset path.
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner)
        content.sessions[pip.sessionID]?.versions = [base]
        let assetMessage = Message(role: .user, text: "yellow", refines: base.id, queueItemID: QueueItemID(),
                                   createdAt: Fixtures.date)
        content.sessions[pip.sessionID]?.messages = [assetMessage]
        let assetDelivery = regionDelivery(target: .asset(pip.id), messageID: assetMessage.id,
                                           refines: base.id, raw: raw)
        _ = BookMutations.applyDelivery(assetDelivery, storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        let assetMade = try #require(content.sessions[pip.sessionID]?.versions.last)
        #expect(assetMade.source == .regionEdit)
        #expect(assetMade.parent == base.id)
    }

    @Test func closedBookDelivery_storesTheRawOutputToo() async throws {
        let h = try Phase9Harness()
        defer { h.tearDown() }
        let entry = try h.createBook()
        let store = BookStore(packageURL: entry.url)
        var content = try await store.load()
        let (page, box) = try Phase9Harness.firstImageBox(content)
        let sessionID = try #require(content.pages[page]?.images[box]?.sessionID)
        let base = Version(image: Fixtures.ref, pixelSize: Self.size, source: .generated, createdAt: Fixtures.date)
        content.sessions[sessionID]?.versions = [base]
        let message = Message(role: .user, text: "yellow", refines: base.id, queueItemID: QueueItemID(),
                              createdAt: Fixtures.date)
        content.sessions[sessionID]?.messages = [message]
        try await store.save(content, dirty: DirtySet(sessions: [sessionID]))

        let rawData = Data([8])
        let rawHash = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let raw = ImageRef(sha256: rawHash, contentType: "public.png")
        var delivery = regionDelivery(target: .pageBox(page, box), messageID: message.id, refines: base.id, raw: raw)
        delivery.item.bookID = content.book.id
        let books = OpenBooks(library: Library(root: h.libraryRoot))
        books.remember([entry])
        #expect(await books.deliver(delivery, now: { Fixtures.date }) == .delivered)
        let saved = try await BookStore(packageURL: entry.url).load()
        let made = try #require(saved.sessions[sessionID]?.versions.last)
        #expect(made.source == .regionEdit)
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: raw).path))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(for: made.image).path))
    }

    // MARK: Version details

    @Test func versionDetails_showMaskRawOutputAndFeather() {
        let mask = ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")
        var provenance = Fixtures.provenance()
        provenance.intent.regionMask = mask
        provenance.maskSent = mask
        provenance.rawOutput = Fixtures.ref
        provenance.featherPixels = 8
        provenance.parametersSent["mask"] = "64x48 png"
        let version = Version(image: Fixtures.ref, pixelSize: Self.size, source: .regionEdit, createdAt: Fixtures.date,
                              provenance: provenance)
        let rows = Dictionary(VersionDetailsContent.rows(for: version).map { ($0.label, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        #expect(rows["Source"] == "Region edit")
        #expect(rows["Mask sent"] == "64x48 mask (transparent = edit area)")
        #expect(rows["Raw provider output"] == "1024x1536 image, before blending into the original")
        #expect(rows["Feather"] == "8 px")
        #expect(rows["Parameter mask"] == "64x48 png")

        // A plain generated version has none of these.
        let plain = Version(image: Fixtures.ref, pixelSize: Self.size, source: .generated, createdAt: Fixtures.date,
                            provenance: Fixtures.provenance())
        let labels = VersionDetailsContent.rows(for: plain).map(\.label)
        #expect(!labels.contains("Mask sent") && !labels.contains("Feather") && !labels.contains("Source"))
    }

    @Test func blankAreaStatusText() {
        let error = ProviderError.noImage(ProviderErrorRaw(status: nil, code: RegionEditFailure.blankAreaCode, body: ""))
        #expect(ProviderErrorText.message(for: error)
            == "The model returned a blank area instead of an edit. Try again, or select a slightly larger area.")
    }
}
