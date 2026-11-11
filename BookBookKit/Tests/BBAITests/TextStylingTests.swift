import BBAICore
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BBAI

// AI text styling (A §7.13): the text-style prompt, normaliser and estimate; the decoration's
// image request; local white keying in the queue; no consistency follow-ups.

/// The slice book with a styling session on its text box.
struct TextBoxBook {
    var book: SliceBook
    var sessionID: SessionID
    var target: GenerationTarget { .textBox(book.pageID, book.textBox) }

    static func make(versions: [Version] = [], messages: [Message] = []) -> TextBoxBook {
        var book = SliceBook.make()
        let session = Session(owner: .textBox(book.pageID, book.textBox), messages: messages, versions: versions)
        book.content.sessions[session.id] = session
        book.content.pages[book.pageID]?.textStyles[book.textBox] = TextStyleSlot(sessionID: session.id,
                                                                                  versionID: versions.last?.id)
        return TextBoxBook(book: book, sessionID: session.id)
    }

    static let call = TextStyleCall(provider: .openai, model: "gpt-6-luna", system: "S", user: "U")

    static func intent(_ message: String = "a gold storybook frame with vines, playful font",
                       decoration: String? = "An ornate gold storybook frame with curling green vines at the corners.",
                       refines: VersionID? = nil) -> GenerationIntent {
        var value = BBAITests.intent(message, story: false)
        value.refines = refines
        value.textStyle = TextStyleIntent(styling: TextStyling(fontSize: 24, insetFraction: 0.12),
                                          decorationPrompt: decoration, summary: "A golden vine frame.", call: call)
        return value
    }

    func assemble(_ intent: GenerationIntent = TextBoxBook.intent(), messageID: MessageID? = nil,
                  model: CatalogModel? = nil, imageData: [ImageRef: Data] = [:]) throws -> (ImageRequest, AssemblyReport) {
        try ContextAssembler.assemble(intent: intent, target: target, messageID: messageID, content: book.content,
                                      model: model ?? testModel(), imageData: imageData)
    }
}

@Suite struct TextStylePromptTests {
    static let snapshot = TextStyleSnapshot(fontFamily: "Georgia", fontSize: 18, textColor: RGBA(red: 0.2, green: 0.2, blue: 0.2),
                                            alignment: .leading, textInset: 0, panelColor: nil, decoration: nil)
    static let model = CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "Luna", kind: .text)

    static func request(text: String = "The little fox found a red umbrella.", history: [String] = [],
                        current: TextStyleSnapshot = snapshot) -> TextStyleRequest {
        TextStylePrompt.request(instruction: "  a gold storybook frame with vines, playful font ",
                                boxText: text, boxRole: nil, boxSizePoints: PointSize(width: 380, height: 126),
                                current: current, history: history, styleDescription: "Soft watercolor, warm light.",
                                fonts: ["Georgia", "Chalkboard SE", "Marker Felt"], model: model)
    }

    @Test func textStylePromptSnapshot() {
        var current = Self.snapshot
        current.decoration = "A thin blue border."
        current.panelColor = RGBA(red: 1, green: 1, blue: 0.9)
        let request = Self.request(history: ["make it blue", " "], current: current)
        #expect(request.model == Self.model)
        assertPromptSnapshot("SYSTEM:\n" + request.system + "\n\nUSER:\n" + request.user)
    }

    @Test func userPromptCarriesEverything() {
        let request = Self.request()
        #expect(TextStylePrompt.set == "textstyle-v1")
        #expect(request.system.contains("JSON"))
        #expect(request.system.contains("never") || request.system.contains("Never"))
        #expect(request.user.hasPrefix("Instruction:\na gold storybook frame with vines, playful font\n"))
        #expect(request.user.contains("(none)"))
        #expect(request.user.contains("Soft watercolor, warm light."))
        #expect(request.user.contains("- Role: story text"))
        #expect(request.user.contains("380 x 126 pt (landscape, about 3:1)"))
        #expect(request.user.contains("- Chalkboard SE"))
        #expect(request.user.contains("\"fontFamily\" : \"Georgia\""))
        #expect(request.user.contains("\"textColor\" : \"#333333\""))
        #expect(request.user.contains("\"decoration\" : null"))
        #expect(!request.user.contains("{{"))
    }

    @Test func longTextIsTruncated() {
        let text = String(repeating: "word ", count: 400)
        let request = Self.request(text: text)
        #expect(request.user.contains("…"))
        #expect(!request.user.contains(text.trimmingCharacters(in: .whitespaces)))
    }

    @Test func roles() {
        #expect(TextStylePrompt.roleText(.title).contains("title"))
        #expect(TextStylePrompt.roleText(.author).contains("author"))
        #expect(TextStylePrompt.roleText(nil) == "story text")
    }

    @Test func estimateUsesTheTextStyleBlockThenTheTemplateBlock() throws {
        let list = try PriceList.bundled()
        let request = Self.request()
        let estimate = CostEstimator.estimate(textStyle: request, priceList: list)
        let amount = try #require(estimate.amount)
        // gpt-6-luna: 900 in at $0.10/M + 450 out at $0.50/M.
        #expect(amount == Decimal(900) * Decimal(string: "0.1")! / 1_000_000 + Decimal(450) * Decimal(string: "0.5")! / 1_000_000)

        let typical = PriceEntry.TypicalRequest(inputTokens: 100, outputTokens: 200)
        let fallback = PriceList(asOf: "t", entries: [PriceEntry(
            provider: .openai, model: "gpt-6-luna", asOf: "t", perMillionTokens: ["textIn": 1, "textOut": 2],
            estimation: .init(typicalTemplateRequest: typical))])
        #expect(CostEstimator.estimate(textStyle: request, priceList: fallback).amount
            == Decimal(100 * 1 + 200 * 2) / 1_000_000)
        #expect(CostEstimator.estimate(textStyle: request, priceList: PriceList(asOf: "t", entries: [])) == .unknown)
    }
}

@Suite struct TextStyleNormalizerTests {
    static let fonts = ["Georgia": "Georgia", "Chalkboard SE": "ChalkboardSE-Regular"]

    @Test func validDraftMapsToStyling() {
        let draft = TextStyleDraft(fontFamily: "Chalkboard SE", fontSize: 30, textColor: "#3A2A10", alignment: .center,
                                   textInset: 0.15, panelColor: "#FFF8E0", decoration: "  A gold frame.  ",
                                   summary: " A golden frame. ")
        let out = TextStyleNormalizer.styling(from: draft, fonts: Self.fonts, current: TextStylePromptTests.snapshot)
        #expect(out.styling.font == FontRef(postScriptName: "ChalkboardSE-Regular"))
        #expect(out.styling.fontSize == 30)
        #expect(out.styling.color == TemplateNormalizer.parseHex("#3A2A10"))
        #expect(out.styling.alignment == .center)
        #expect(out.styling.insetFraction == 0.15)
        #expect(out.styling.background == TemplateNormalizer.parseHex("#FFF8E0"))
        #expect(out.decorationPrompt == "A gold frame.")
        #expect(out.summary == "A golden frame.")
    }

    @Test func invalidValuesAreDroppedOrClamped() {
        let draft = TextStyleDraft(fontFamily: "Comic Sans MS", fontSize: 1000, textColor: "gold", alignment: nil,
                                   textInset: 0.9, panelColor: "#12345", decoration: "   ", summary: "  ")
        let out = TextStyleNormalizer.styling(from: draft, fonts: Self.fonts, current: TextStylePromptTests.snapshot)
        #expect(out.styling.font == nil)
        #expect(out.styling.fontSize == 288)
        #expect(out.styling.color == nil)
        #expect(out.styling.alignment == nil)
        #expect(out.styling.insetFraction == TextStyling.maxInsetFraction)
        #expect(out.styling.background == nil)
        #expect(out.decorationPrompt == nil)
        #expect(out.summary == "Styled the text.")

        let small = TextStyleDraft(fontSize: 2, textInset: -1, summary: "x")
        let clamped = TextStyleNormalizer.styling(from: small, fonts: Self.fonts, current: TextStylePromptTests.snapshot)
        #expect(clamped.styling.fontSize == 6)
        #expect(clamped.styling.insetFraction == 0)
        #expect(TextStyleNormalizer.styling(from: TextStyleDraft(textInset: .nan, summary: "x"), fonts: Self.fonts,
                                            current: TextStylePromptTests.snapshot).styling.insetFraction == 0)
    }

    @Test func nilsKeep() {
        let out = TextStyleNormalizer.styling(from: TextStyleDraft(summary: "Kept."), fonts: Self.fonts,
                                              current: TextStylePromptTests.snapshot)
        #expect(out.styling == TextStyling())
        #expect(out.decorationPrompt == nil)
    }

    @Test func fontMatchIgnoresCaseAndSpacing() {
        let draft = TextStyleDraft(fontFamily: "chalkboardse", summary: "x")
        let out = TextStyleNormalizer.styling(from: draft, fonts: Self.fonts, current: TextStylePromptTests.snapshot)
        #expect(out.styling.font?.postScriptName == "ChalkboardSE-Regular")
    }
}

@Suite struct DecorationContextTests {
    @Test func decorationRequestPrompt() throws {
        let b = TextBoxBook.make()
        let (request, report) = try b.assemble()
        assertPromptSnapshot(request.instruction.rendered)
        #expect(request.instruction.sections.map(\.key) == ["role", "style", "avoid", "request", "composition", "background"])
        #expect(request.transparentBackground)
        #expect(request.baseImage == nil && request.references.isEmpty)
        #expect(!report.storyTextIncluded && report.storyText == nil)
        let rendered = request.instruction.rendered
        #expect(rendered.contains("An ornate gold storybook frame"))
        #expect(!rendered.contains("playful font"))
        #expect(!rendered.contains("red umbrella"))
        #expect(rendered.contains("pure white (#FFFFFF)"))
        #expect(rendered.contains("No letters, words"))
        let single = try #require(b.book.content.templates.values.first { $0.kind == .single })
        let box = try #require(single.box(b.book.textBox))
        #expect(abs(request.output.boxAspect - b.book.content.boxAspect(box, in: single)) < 1e-9)
    }

    @Test func transparentCapableModelAsksForTransparency() throws {
        var model = try testModel()
        model.image.supportsTransparentBackground = true
        let (request, _) = try TextBoxBook.make().assemble(model: model)
        #expect(request.instruction.rendered.contains("Background: transparent"))
        #expect(!request.instruction.rendered.contains("#FFFFFF"))
    }

    @Test func fallsBackToTheMessageWithoutADecorationPrompt() throws {
        let (request, _) = try TextBoxBook.make().assemble(TextBoxBook.intent("a ribbon banner", decoration: nil))
        #expect(request.instruction.rendered.contains("a ribbon banner"))
    }

    @Test func noAssetsEvenWhenTheChecklistHasThem() throws {
        var b = TextBoxBook.make()
        let asset = Asset(type: .character, name: "Pip", description: "A small fox.")
        b.book.content.assets[asset.id] = asset
        b.book.content.pages[b.book.pageID]?.assetChecklist = [asset.id]
        let (request, _) = try b.assemble()
        #expect(!request.instruction.rendered.contains("Pip"))
        #expect(ContextAssembler.assetsInPlay(intent: TextBoxBook.intent(), target: b.target, content: b.book.content).isEmpty)
    }

    @Test func refinementSendsTheCurrentDecorationAndHistory() throws {
        let v1 = Version(image: ImageRef(sha256: "deco1", contentType: "public.png"),
                         pixelSize: PixelSize(width: 1536, height: 512), source: .generated,
                         createdAt: Date(timeIntervalSince1970: 1))
        let first = Message(role: .user, text: "a gold frame", producedVersion: v1.id, createdAt: Date(timeIntervalSince1970: 1))
        let pending = Message(role: .user, text: "make the vines thicker", queueItemID: QueueItemID(),
                              createdAt: Date(timeIntervalSince1970: 2))
        let b = TextBoxBook.make(versions: [v1], messages: [first, pending])
        let intent = TextBoxBook.intent("make the vines thicker",
                                        decoration: "An ornate gold frame with thick curling vines.", refines: v1.id)
        let (request, report) = try b.assemble(intent, messageID: pending.id,
                                               imageData: [v1.image: Data("png".utf8)])
        assertPromptSnapshot(request.instruction.rendered)
        #expect(request.baseImage?.ref == v1.image)
        #expect(report.referencesSent.first?.label == "Current decoration (v1)")
        #expect(request.instruction.rendered.contains("current decoration, oldest first: 1) a gold frame"))
        #expect(request.instruction.rendered.contains("the current decoration to edit"))
        #expect(request.output.exactSize != nil)
    }

    @Test func resolvesByMessageAndRejectsOtherTargets() throws {
        let pending = Message(role: .user, text: "frame", queueItemID: QueueItemID(), createdAt: Date(timeIntervalSince1970: 1))
        let b = TextBoxBook.make(messages: [pending])
        #expect((try? b.assemble(messageID: pending.id)) != nil)
        // The image box isn't a text box; a picture session's message doesn't resolve a text-box target.
        let model = try testModel()
        #expect((try? ContextAssembler.assemble(intent: TextBoxBook.intent(), target: .textBox(b.book.pageID, b.book.imageBox),
                                                content: b.book.content, model: model)) == nil)
        #expect((try? ContextAssembler.assemble(intent: TextBoxBook.intent(), target: .textBox(b.book.pageID, BoxID()),
                                                content: b.book.content, model: model)) == nil)
        // A text-box session never resolves a page-box target.
        #expect((try? ContextAssembler.assemble(intent: TextBoxBook.intent(), target: b.book.target,
                                                messageID: pending.id, content: b.book.content, model: model)) == nil)
    }

    @Test func consistencyNeverApplies() throws {
        let v1 = Version(image: ImageRef(sha256: "deco1", contentType: "public.png"),
                         pixelSize: PixelSize(width: 1536, height: 512), source: .generated,
                         createdAt: Date(timeIntervalSince1970: 1))
        let b = TextBoxBook.make(versions: [v1])
        let session = try #require(b.book.content.sessions[b.sessionID])
        #expect(ConsistencyAssembler.target(for: session, in: b.book.content) == b.target)
        #expect(!ConsistencyAssembler.checksApply(to: b.target))
        #expect(ConsistencyAssembler.checksApply(to: b.book.target))
        #expect(ConsistencyAssembler.plan(version: v1.id, content: b.book.content) == nil)
        #expect(ConsistencyAssembler.imageCount(intent: TextBoxBook.intent(), target: b.target,
                                                content: b.book.content) == nil)
    }

    @Test func estimateInputResolves() throws {
        let b = TextBoxBook.make()
        let input = try #require(CostEstimator.estimateInput(intent: TextBoxBook.intent(), target: b.target,
                                                             content: b.book.content, catalog: try ModelCatalog.bundled()))
        #expect(input.inputImageSizes.isEmpty)
    }
}

@Suite struct WhiteKeyTests {
    /// 40x40 white with a 6 px opaque gold frame, a soft 50% gold pixel and near-white noise.
    static func framePNG() -> Data {
        let w = 40, h = 40
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let i = (y * w + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        }
        for y in 0..<h {
            for x in 0..<w where x < 6 || y < 6 || x >= w - 6 || y >= h - 6 { set(x, y, 200, 150, 30) }
        }
        set(10, 10, 241, 232, 210)  // a pale, anti-aliased edge
        set(20, 20, 250, 248, 252)  // near white
        return Pixels.encodeRGBA(bytes, w, h)
    }

    static func pixel(_ px: (w: Int, h: Int, bytes: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * px.w + x) * 4
        return Array(px.bytes[i..<(i + 4)])
    }

    @Test func whiteBecomesTransparentAndTheFrameStaysOpaque() throws {
        let source = Self.framePNG()
        #expect(ImageOps.hasTransparentPixels(source) == false)
        let keyed = try #require(ImageOps.keyOutWhite(pngData: source))
        #expect(ImageOps.hasTransparentPixels(keyed) == true)
        let px = Pixels.rgba(keyed)
        #expect(px.w == 40 && px.h == 40)
        // Frame: opaque, colour unchanged.
        #expect(Self.pixel(px, 0, 0) == [200, 150, 30, 255])
        #expect(Self.pixel(px, 39, 20) == [200, 150, 30, 255])
        // Centre and near-white: fully transparent.
        #expect(Self.pixel(px, 25, 25)[3] == 0)
        #expect(Self.pixel(px, 20, 20)[3] == 0)
        // Soft edge: partly transparent, its colour un-blended away from white (premultiplied bytes).
        let soft = Self.pixel(px, 10, 10)
        #expect(soft[3] > 0 && soft[3] < 255)
        let alpha = Double(soft[3]) / 255
        #expect(Double(soft[2]) / alpha < 200)
    }

    @Test func undecodableIsNil() {
        #expect(ImageOps.keyOutWhite(pngData: Data("nope".utf8)) == nil)
        #expect(ImageOps.hasTransparentPixels(Data("nope".utf8)) == nil)
    }
}

@Suite struct DecorationQueueTests {
    func run(_ output: Data, checkConsistency: Bool = false) async throws -> (GenerationDelivery, FakeVision) {
        let b = TextBoxBook.make()
        let host = FakeHost(content: b.book.content)
        let result = ImageResult(imageData: output, contentType: "public.png", pixelSize: PixelSize(width: 40, height: 40),
                                 parametersSent: ["size": "40x40"])
        let provider = FakeProvider(outcomes: [.success(result)], gated: false)
        let vision = FakeVision()
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), now: { Date(timeIntervalSince1970: 100) },
                                    visionProviders: [.openai: vision])
        var intent = TextBoxBook.intent()
        intent.checkConsistency = checkConsistency
        await queue.enqueue(QueueItem(bookID: b.book.content.book.id, target: b.target, messageID: MessageID(), intent: intent))
        await eventually("delivery") { await host.delivered().count == 1 }
        let request = try #require(await provider.receivedRequests().first)
        #expect(request.transparentBackground)
        return (try #require(await host.delivered().first), vision)
    }

    @Test func opaqueOutputIsKeyedAndTheRawKept() async throws {
        let raw = WhiteKeyTests.framePNG()
        let (delivery, vision) = try await run(raw, checkConsistency: true)
        guard case let .success(result, provenance) = delivery.outcome else {
            Issue.record("expected success")
            return
        }
        #expect(ImageOps.hasTransparentPixels(result.imageData) == true)
        #expect(result.pixelSize == PixelSize(width: 40, height: 40))
        #expect(result.contentType == "public.png")
        #expect(provenance.parametersSent[GenerationQueue.localWhiteKeyParameter] == "true")
        #expect(provenance.parametersSent["size"] == "40x40")
        let rawRef = try #require(provenance.rawOutput)
        #expect(delivery.additionalImages[rawRef] == raw)
        // No consistency follow-up for a decoration, even when the intent asked for one.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await vision.received().isEmpty)
    }

    @Test func transparentOutputIsLeftAlone() async throws {
        let transparent = try #require(ImageOps.keyOutWhite(pngData: WhiteKeyTests.framePNG()))
        let (delivery, _) = try await run(transparent)
        guard case let .success(result, provenance) = delivery.outcome else {
            Issue.record("expected success")
            return
        }
        #expect(result.imageData == transparent)
        #expect(provenance.parametersSent[GenerationQueue.localWhiteKeyParameter] == nil)
        #expect(provenance.rawOutput == nil)
        #expect(delivery.additionalImages.isEmpty)
    }
}
