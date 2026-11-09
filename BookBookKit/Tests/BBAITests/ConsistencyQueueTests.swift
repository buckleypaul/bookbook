import BBAICore
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBAI

// Phase 12 (A §7.8): consistency follow-ups through the queue, request assembly and results.

/// Returns scripted results (then "consistent") and records every request.
actor FakeVision: VisionProvider {
    nonisolated let id = ProviderID.openai
    private var outcomes: [Result<ConsistencyResult, ProviderError>]
    private(set) var requests: [ConsistencyRequest] = []

    init(_ outcomes: [Result<ConsistencyResult, ProviderError>] = []) { self.outcomes = outcomes }

    func checkConsistency(_ request: ConsistencyRequest) async throws(ProviderError) -> ConsistencyResult {
        requests.append(request)
        let outcome = outcomes.isEmpty ? .success(ConsistencyResult(consistent: true, differences: [])) : outcomes.removeFirst()
        return try outcome.get()
    }

    func received() -> [ConsistencyRequest] { requests }
}

/// A host that writes deliveries into its content the way `BookMutations` does (image results
/// become versions with the queue's `versionID`; reports land on their version), so follow-ups
/// find what they check.
actor ApplyingHost: GenerationHost {
    var content: BookContent
    private(set) var deliveries: [GenerationDelivery] = []
    private(set) var costs: [CostRecord] = []
    private var images: [ImageRef: Data]
    private var deliveryResults: [DeliveryResult]

    init(content: BookContent, images: [ImageRef: Data] = [:], deliveryResults: [DeliveryResult] = []) {
        self.content = content
        self.images = images
        self.deliveryResults = deliveryResults
    }

    func content(for bookID: BookID) async -> BookContent? { content }
    func imageData(for ref: ImageRef, in bookID: BookID) async -> Data? { images[ref] }
    func recordCost(_ record: CostRecord, in bookID: BookID) async { costs.append(record) }
    func setContent(_ content: BookContent) { self.content = content }

    func deliver(_ delivery: GenerationDelivery) async -> DeliveryResult {
        if !deliveryResults.isEmpty, deliveryResults.removeFirst() == .bookUnavailable { return .bookUnavailable }
        deliveries.append(delivery)
        switch delivery.outcome {
        case let .success(result, provenance):
            guard case let .pageBox(page, box) = delivery.item.target,
                  let sessionID = content.pages[page]?.images[box]?.sessionID else { break }
            let ref = ImageRef(sha256: "out-\(delivery.versionID.rawValue.uuidString)", contentType: "public.png")
            images[ref] = result.imageData
            content.sessions[sessionID]?.versions.append(
                Version(id: delivery.versionID, image: ref, pixelSize: result.pixelSize,
                        source: provenance.intent.versionSource ?? .generated, createdAt: Date(timeIntervalSince1970: 0),
                        provenance: provenance))
        case let .consistency(report):
            guard let version = delivery.item.kind.checkedVersion else { break }
            for (id, session) in content.sessions {
                if let index = session.versions.firstIndex(where: { $0.id == version }) {
                    content.sessions[id]?.versions[index].consistency = report
                }
            }
        case .failure:
            break
        }
        return .delivered
    }

    func delivered() -> [GenerationDelivery] { deliveries }
    func recorded() -> [CostRecord] { costs }
    func version(_ id: VersionID) -> Version? { content.sessions.values.lazy.compactMap { $0.version(id) }.first }
}

let visionModel = CatalogTextModel(provider: .openai, id: "vision-test", displayName: "Vision Test", kind: .vision,
                                   typicalDurationSeconds: 8, imageDetail: "low",
                                   consistency: ConsistencyThresholds(warnOnMajor: 1, warnOnMinor: 2))

let fakeInstructions: ConsistencyInstructions = { assets, style, labels in
    ("SYS " + assets.map(\.name).joined(separator: ","), "USER " + style + " | " + labels.joined(separator: " | "))
}

func visionCatalog() throws -> ModelCatalog {
    var catalog = try ModelCatalog.bundled()
    catalog.textModels = [visionModel]
    return catalog
}

func minor(_ aspect: String) -> ConsistencyDifference {
    ConsistencyDifference(asset: "Pip", aspect: aspect, observed: "blue", expected: "red", severity: .minor)
}

/// A real PNG of the given size (opaque unless `alpha`).
func pngData(width: Int, height: Int, alpha: Bool = false) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: info))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

@Suite struct ConsistencyQueueTests {
    let book = SliceBook.make()

    func imageItem(_ message: String, check: Bool?, followUp: Decimal? = Decimal(string: "0.002")) -> QueueItem {
        var value = intent(message)
        value.checkConsistency = check
        return QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(), intent: value,
                         estimate: CostEstimate(amount: Decimal(string: "0.01"), priceListAsOf: "2026-11-07"),
                         display: QueueItemDisplay(bookTitle: "T", pageLabel: "Page 1", boxLabel: "Image 1"),
                         consistencyFollowUp: followUp.map {
                             ConsistencyFollowUp(provider: .openai, model: visionModel.id,
                                                 estimate: CostEstimate(amount: $0, priceListAsOf: "2026-11-07"))
                         })
    }

    func checkItem(_ version: VersionID) -> QueueItem {
        QueueItem(bookID: book.content.book.id, target: book.target, messageID: MessageID(),
                  intent: GenerationIntent(messageText: "", refines: version, provider: .openai, model: visionModel.id,
                                           quality: .draft),
                  estimate: CostEstimate(amount: Decimal(string: "0.002")), kind: .consistencyCheck(version))
    }

    func makeQueue(provider: FakeProvider = FakeProvider(outcomes: Array(repeating: .success(okResult()), count: 6),
                                                         gated: false),
                   vision: FakeVision = FakeVision(), host: ApplyingHost? = nil,
                   sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        throws -> (GenerationQueue, ApplyingHost) {
        let host = host ?? ApplyingHost(content: book.content)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try visionCatalog(), host: host,
                                    pricing: FakePricing(prices: ["gpt-image-2.5-sunburst": Decimal(string: "0.012")!,
                                                                  "vision-test": Decimal(string: "0.0015")!]),
                                    now: { Date(timeIntervalSince1970: 100) }, sleep: sleep,
                                    visionProviders: [.openai: vision], consistencyInstructions: fakeInstructions)
        return (queue, host)
    }

    /// "<message>" for image deliveries, "check:<parent message>" for checks, in delivery order.
    func order(_ deliveries: [GenerationDelivery], items: [QueueItem]) -> [String] {
        deliveries.map { delivery in
            switch delivery.item.kind {
            case .image: delivery.item.intent.messageText
            case .consistencyCheck:
                "check:" + (items.first { $0.id == delivery.item.parent }?.intent.messageText ?? "?")
            }
        }
    }

    // MARK: Ordering

    @Test func followUpJumpsAheadOfItemsQueuedEarlier() async throws {
        let provider = FakeProvider(outcomes: Array(repeating: .success(okResult()), count: 3))
        let (queue, host) = try makeQueue(provider: provider)
        let a = imageItem("A", check: true), b = imageItem("B", check: true), c = imageItem("C", check: false)
        await queue.enqueue([a, b, c])
        await provider.release(3)
        await eventually("five deliveries") { await host.delivered().count == 5 }
        #expect(order(await host.delivered(), items: [a, b, c]) == ["A", "check:A", "B", "check:B", "C"])
        let checks = await host.delivered().filter { $0.item.kind != .image }
        #expect(checks.map(\.item.parent) == [a.id, b.id])
        // Each check names the version its parent's delivery created.
        let images = await host.delivered().filter { $0.item.kind == .image }
        #expect(checks.map(\.item.kind.checkedVersion) == [images[0].versionID, images[1].versionID])
        #expect(checks[0].item.display.boxLabel == "Image 1 · Consistency check")
        await eventually("queue empty") { await queue.snapshot().entries.isEmpty }
    }

    @Test func followUpIsInsertedBeforeWaitingItemsWhileTheParentFinishes() async throws {
        let provider = FakeProvider(outcomes: [.success(okResult()), .success(okResult())])
        let (queue, _) = try makeQueue(provider: provider, vision: FakeVision())
        let a = imageItem("A", check: true), b = imageItem("B", check: false)
        await queue.enqueue([a, b])
        await eventually("A running") { await provider.startedPrompts().count == 1 }
        await queue.pause()
        await provider.release(1)
        await eventually("A finished") { await queue.snapshot().entry(for: a.id) == nil }
        let entries = await queue.snapshot().entries
        #expect(entries.count == 2)
        #expect(entries.first?.item.parent == a.id)
        #expect(entries.first?.item.kind.checkedVersion != nil)
        #expect(entries.last?.id == b.id)
    }

    @Test func noFollowUpWhenTheSwitchWasOff() async throws {
        let vision = FakeVision()
        let (queue, host) = try makeQueue(vision: vision)
        await queue.enqueue([imageItem("off", check: false), imageItem("old", check: nil)])
        await eventually("two deliveries") { await host.delivered().count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await host.delivered().count == 2)
        #expect(await vision.received().isEmpty)
        #expect(await queue.snapshot().entries.isEmpty)
    }

    @Test func followUpQueuedWhenARedeliveryLands() async throws {
        let host = ApplyingHost(content: book.content, deliveryResults: [.bookUnavailable])
        let vision = FakeVision()
        let (queue, _) = try makeQueue(vision: vision, host: host, sleep: { _ in })
        await queue.enqueue(imageItem("A", check: true))
        await eventually("check delivered") { await host.delivered().count == 2 }
        #expect(await host.delivered().last?.item.kind.checkedVersion == host.delivered().first?.versionID)
        #expect(await vision.received().count == 1)
    }

    @Test func aVersionIsCheckedOnceAtATime() async throws {
        var content = book.content
        let version = Version(image: ImageRef(sha256: "v", contentType: "public.png"),
                              pixelSize: PixelSize(width: 8, height: 8), source: .imported, createdAt: .distantPast)
        content.sessions[book.sessionID]?.versions = [version]
        let (queue, _) = try makeQueue(host: ApplyingHost(content: content))
        await queue.pause()
        let ids = await queue.enqueue([checkItem(version.id), checkItem(version.id)], position: .front)
        #expect(ids.count == 1)
    }

    // MARK: Results

    @Test(arguments: [(2, true), (1, false)])
    func reportLandsOnTheVersionWithThresholdWarnings(minorCount: Int, warns: Bool) async throws {
        let differences = (0..<minorCount).map { minor("scarf \($0)") }
        let vision = FakeVision([.success(ConsistencyResult(consistent: false, differences: differences,
                                                            usage: TokenUsage(inputTextTokens: 10),
                                                            parametersSent: ["detail": "low"]))])
        let (queue, host) = try makeQueue(vision: vision)
        await queue.enqueue(imageItem("A", check: true))
        await eventually("check delivered") { await host.delivered().count == 2 }
        let parent = try #require(await host.delivered().first)
        let version = try #require(await host.version(parent.versionID))
        let report = try #require(version.consistency)
        #expect(report.warns == warns)
        #expect(report.showsWarning == warns)
        #expect(report.differences == differences)
        #expect(!report.consistent)
        #expect(report.model == "vision-test")
        #expect(report.provider == .openai)
        #expect(report.usage == TokenUsage(inputTextTokens: 10))
        #expect(report.sent.parametersSent == ["detail": "low"])
        #expect(report.sent.imagesSent.first?.role == "checked")
        #expect(report.sent.imagesSent.first?.image == version.image)
        let request = try #require(await vision.received().first)
        #expect(report.sent.promptSent == request.system + "\n\n" + request.user)
        #expect(request.model == visionModel)
        // Ledger: the parent prices only its own request; the check has its own `.consistency` line.
        let costs = await host.recorded()
        #expect(costs.map(\.kind) == [.image, .consistency])
        #expect(costs[0].estimated == Decimal(string: "0.01"))
        #expect(costs[1].estimated == Decimal(string: "0.002"))
        #expect(costs[1].actual == Decimal(string: "0.0015"))
        #expect(costs[1].quality == nil)
        #expect(report.cost == costs[1].id)
        // Not a version: the session still has exactly the generated one.
        #expect(await host.content.sessions[book.sessionID]?.versions.count == 1)
    }

    @Test func standardThresholdsWhenTheCatalogHasNone() {
        #expect(ConsistencyThresholds.standard.warns([minor("a"), minor("b"), minor("c")]))
        #expect(!ConsistencyThresholds.standard.warns([minor("a"), minor("b")]))
        let major = ConsistencyDifference(asset: nil, aspect: "towers", observed: "2", expected: "3", severity: .major)
        #expect(ConsistencyThresholds.standard.warns([major]))
    }

    @Test func failedCheckFailsLikeAnyItemAndDeliversOnlyAFailure() async throws {
        let vision = FakeVision([.failure(.refused(stage: .input, categories: [], nil))])
        let (queue, host) = try makeQueue(vision: vision)
        await queue.enqueue(imageItem("A", check: true))
        await eventually("check failed") { await queue.snapshot().entries.first?.failure != nil }
        let entry = try #require(await queue.snapshot().entries.first)
        #expect(entry.item.kind.checkedVersion != nil)
        #expect(entry.failure?.error == .refused(stage: .input, categories: [], nil))
        guard case .failure = try #require(await host.delivered().last).outcome else {
            Issue.record("expected a failure delivery")
            return
        }
        let parent = try #require(await host.delivered().first)
        #expect(await host.version(parent.versionID)?.consistency == nil)
        #expect(await host.recorded().last?.kind == .consistency)
        #expect(await host.recorded().last?.actual == 0)
    }

    @Test func checkOfADeletedVersionIsDroppedQuietly() async throws {
        let vision = FakeVision()
        let (queue, host) = try makeQueue(vision: vision)
        await queue.enqueue([checkItem(VersionID())], position: .front)
        await eventually("dropped") { await queue.snapshot().entries.isEmpty }
        #expect(await vision.received().isEmpty)
        #expect(await host.recorded().isEmpty)
        #expect(await host.delivered().isEmpty)
    }

    @Test func checkWithNoVisionProviderFailsWithoutTouchingAnything() async throws {
        var content = book.content
        let version = Version(image: ImageRef(sha256: "v", contentType: "public.png"),
                              pixelSize: PixelSize(width: 8, height: 8), source: .imported, createdAt: .distantPast)
        content.sessions[book.sessionID]?.versions = [version]
        let host = ApplyingHost(content: content, images: [version.image: Data([1])])
        let queue = GenerationQueue(providers: [:], catalog: try visionCatalog(), host: host, pricing: FakePricing(),
                                    consistencyInstructions: fakeInstructions)
        await queue.enqueue([checkItem(version.id)], position: .front)
        await eventually("failed") { await queue.snapshot().entries.first?.failure != nil }
        #expect(await host.recorded().isEmpty)
        #expect(await host.version(version.id) == version)
    }

    // MARK: queue.json

    @Test func phase9QueueItemsStillDecode() throws {
        let item = imageItem("old", check: nil, followUp: nil)
        let encoded = try JSONEncoder().encode(item)
        let json = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(json as? [String: Any])
        for key in ["kind", "parent", "consistencyFollowUp"] { object.removeValue(forKey: key) }
        let old = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [["item": object, "wasRunning": false]]])
        let decoded = try JSONDecoder().decode(PersistedQueue.self, from: old)
        #expect(decoded.schemaVersion == 1)
        let restored = try #require(decoded.entries.first?.item)
        #expect(restored.kind == .image)
        #expect(restored.parent == nil)
        #expect(restored.consistencyFollowUp == nil)
        #expect(restored == item)
    }

    @Test func checkItemsRoundTrip() throws {
        var check = checkItem(VersionID())
        check.parent = QueueItemID()
        let queue = PersistedQueue(entries: [.init(item: check), .init(item: imageItem("A", check: true))])
        let decoded = try JSONDecoder().decode(PersistedQueue.self, from: JSONEncoder().encode(queue))
        #expect(decoded == queue)
        #expect(decoded.schemaVersion == 2)
    }

    @Test func estimateIncludingFollowUp() {
        #expect(imageItem("A", check: true).estimateIncludingFollowUp.amount == Decimal(string: "0.012"))
        #expect(imageItem("A", check: false).estimateIncludingFollowUp.amount == Decimal(string: "0.01"))
        #expect(imageItem("A", check: true, followUp: nil).estimateIncludingFollowUp.amount == Decimal(string: "0.01"))
    }
}

// MARK: - Assembly

@Suite struct ConsistencyAssemblerTests {
    /// A page with Pip mentioned (primary + sheet), Oak on the checklist, three style references,
    /// and a generated version to check.
    func makeBook() -> (content: BookContent, version: Version, pip: Asset, oak: Asset) {
        let book = SliceBook.make()
        var content = book.content
        let pip = Cast.add(.character, "Pip", description: "A fox in a red scarf", to: &content)
        let oak = Cast.add(.place, "Granny Oak", to: &content)
        content.pages[book.pageID]?.assetChecklist = [oak.id]
        content.style.styleReferences = (1...3).map { ImageRef(sha256: "style-\($0)", contentType: "public.png") }
        var generating = intent("\(mention(pip)) grinning by the oak", story: false)
        generating.checkConsistency = true
        let version = Version(image: ImageRef(sha256: "checked", contentType: "public.png"),
                              pixelSize: PixelSize(width: 2048, height: 1024), source: .generated,
                              createdAt: .distantPast,
                              provenance: Provenance(provider: .openai, model: "gpt-image-2.5-sunburst", quality: .draft,
                                                     outputSize: PixelSize(width: 2048, height: 1024), promptSent: "",
                                                     styleRevision: 3, storyTextIncluded: false, intent: generating))
        content.sessions[book.sessionID]?.versions.append(version)
        return (content, version, pip, oak)
    }

    @Test func plansAssetReferencesThenTwoStyleReferences() throws {
        let (content, version, _, _) = makeBook()
        let plan = try #require(ConsistencyAssembler.plan(version: version.id, content: content))
        #expect(plan.checked.ref == version.image)
        #expect(plan.references.map(\.label) == [
            "Pip – primary reference", "Granny Oak – primary reference", "Pip – happy expression",
            "Pip – three-quarter view", "Style reference 1", "Style reference 2",
        ])
        #expect(plan.assets.map(\.name) == ["Pip", "Granny Oak"])
        #expect(plan.assets.first?.description == "A fox in a red scarf")
        #expect(plan.styleDescription == "Soft watercolor, warm light.")
        #expect(plan.imageCount == 7)
        // The estimate before generating counts the same images.
        let intent = try #require(version.provenance?.intent)
        let session = try #require(content.sessions.values.first { $0.version(version.id) != nil })
        let pageTarget = try #require(ConsistencyAssembler.target(for: session, in: content))
        #expect(ConsistencyAssembler.imageCount(intent: intent, target: pageTarget, content: content) == 7)
    }

    @Test func importedVersionsUseTheChecklist() throws {
        var (content, _, _, oak) = makeBook()
        let sessionID = try #require(content.sessions.values.first { $0.owner.assetID == nil && !$0.versions.isEmpty }?.id)
        let imported = Version(image: ImageRef(sha256: "scan", contentType: "public.png"),
                               pixelSize: PixelSize(width: 800, height: 600), source: .imported, createdAt: .distantPast)
        content.sessions[sessionID]?.versions.append(imported)
        let plan = try #require(ConsistencyAssembler.plan(version: imported.id, content: content))
        #expect(plan.assets.map(\.name) == [oak.name])
        #expect(plan.references.first?.label == "Granny Oak – primary reference")
    }

    @Test func goneVersionHasNoPlan() {
        #expect(ConsistencyAssembler.plan(version: VersionID(), content: makeBook().content) == nil)
    }

    @Test func assembleSendsDownscaledImagesAndSkipsMissingOnes() throws {
        let (content, version, _, _) = makeBook()
        let plan = try #require(ConsistencyAssembler.plan(version: version.id, content: content))
        var data = Cast.imageData(content)
        data[version.image] = try pngData(width: 2048, height: 1024)
        data[plan.references[1].ref] = nil
        let assembled = try ConsistencyAssembler.assemble(plan, model: visionModel, imageData: data,
                                                          instructions: fakeInstructions)
        #expect(assembled.request.image.payload.pixelSize == PixelSize(width: 1024, height: 512))
        #expect(assembled.request.image.payload.contentType == UTType.jpeg.identifier)
        #expect(assembled.request.references.count == plan.references.count - 1)
        #expect(assembled.imagesSent.map(\.label) == [plan.checked.label] + plan.references.map(\.label)
            .filter { $0 != plan.references[1].label })
        #expect(assembled.request.user.contains("Image to check | Pip – primary reference | Pip – happy expression"))
        #expect(assembled.promptText == assembled.request.system + "\n\n" + assembled.request.user)
    }

    @Test func missingCheckedImageThrows() throws {
        let (content, version, _, _) = makeBook()
        let plan = try #require(ConsistencyAssembler.plan(version: version.id, content: content))
        #expect(throws: AssemblyError.baseImageMissing) {
            try ConsistencyAssembler.assemble(plan, model: visionModel, imageData: [:], instructions: fakeInstructions)
        }
    }

    @Test func downscaleKeepsAlphaAsPNGAndLeavesSmallImages() throws {
        let big = ConsistencyAssembler.downscaled(try pngData(width: 1000, height: 3000, alpha: true), contentType: "public.png")
        #expect(big.pixelSize == PixelSize(width: 341, height: 1024) || big.pixelSize == PixelSize(width: 342, height: 1024))
        #expect(big.contentType == UTType.png.identifier)
        let small = try pngData(width: 640, height: 480)
        #expect(ConsistencyAssembler.downscaled(small, contentType: "public.png").data == small)
    }

    @Test func realPersonPhotosNeedTheProvidersAcknowledgement() throws {
        var (content, version, _, _) = makeBook()
        var options = Cast.Options()
        options.primaryIsRealPerson = true
        let grandma = Cast.add(.character, "Grandma", options: options, to: &content)
        content.pages.keys.forEach { content.pages[$0]?.assetChecklist.append(grandma.id) }
        let without = try #require(ConsistencyAssembler.plan(version: version.id, content: content, provider: .openai))
        #expect(!without.references.map(\.label).contains("Grandma – primary reference"))
        content.book.acknowledgements.realPersonPhotoNotice = [.openai]
        let with = try #require(ConsistencyAssembler.plan(version: version.id, content: content, provider: .openai))
        #expect(with.references.map(\.label).contains("Grandma – primary reference"))
    }

    @Test func checkingARealPersonPhotoIsBlockedUntilAcknowledged() throws {
        var (content, version, _, _) = makeBook()
        let sessionID = try #require(content.sessions.first { $0.value.version(version.id) != nil }?.key)
        let index = try #require(content.sessions[sessionID]?.versions.firstIndex { $0.id == version.id })
        content.sessions[sessionID]?.versions[index].depictsRealPerson = true
        #expect(ConsistencyAssembler.sendsRealPersonPhoto(versionID: version.id, content: content, provider: .openai))
        #expect(ConsistencyAssembler.plan(version: version.id, content: content, provider: .openai) == nil)
        content.book.acknowledgements.realPersonPhotoNotice = [.openai]
        #expect(!ConsistencyAssembler.sendsRealPersonPhoto(versionID: version.id, content: content, provider: .openai))
        #expect(ConsistencyAssembler.plan(version: version.id, content: content, provider: .openai) != nil)
    }

    @Test func ordinaryVersionsNeedNoNotice() {
        let (content, version, _, _) = makeBook()
        #expect(!ConsistencyAssembler.sendsRealPersonPhoto(versionID: version.id, content: content, provider: .openai))
    }
}
