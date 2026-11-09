import BBAICore
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BBAI

/// Phase 11 (A §7.6): a region edit through assembly and the queue — mask attached, local
/// composite, `.noImage` on a blank area, raw output kept.
@Suite struct RegionEditPipelineTests {
    static let size = PixelSize(width: 64, height: 48)
    /// Edit area: a 24x16 rectangle at (20, 16).
    static let drawing = RegionMaskDrawing(pixelSize: size, operations: [
        .lasso(points: [CGPoint(x: 20, y: 16), CGPoint(x: 44, y: 16), CGPoint(x: 44, y: 32), CGPoint(x: 20, y: 32)],
               erase: false),
    ])

    struct Book {
        var book: SliceBook
        var base: Version
        var basePNG: Data
        var maskRef: ImageRef
        var maskPNG: Data
        var messageID: MessageID

        var images: [ImageRef: Data] { [base.image: basePNG, maskRef: maskPNG] }

        func intent(mask: ImageRef? = nil) -> GenerationIntent {
            var value = BBAITests.intent("make the scarf yellow", story: false)
            value.refines = base.id
            value.regionMask = mask ?? maskRef
            return value
        }

        func item(_ intent: GenerationIntent) -> QueueItem {
            QueueItem(bookID: book.content.book.id, target: book.target, messageID: messageID, intent: intent)
        }
    }

    static func makeBook() throws -> Book {
        var book = SliceBook.make()
        let basePNG = Pixels.noisyPNG(size.width, size.height, seed: 7)
        let base = Version(image: RegionEditPipelineTests.ref(basePNG), pixelSize: size, source: .generated,
                           createdAt: Date(timeIntervalSince1970: 1))
        let maskPNG = try ImageOps.grayscalePNG(ImageOps.rasterize(drawing))
        let pending = Message(role: .user, text: "make the scarf yellow", refines: base.id, queueItemID: QueueItemID(),
                              createdAt: Date(timeIntervalSince1970: 2))
        let id = book.sessionID
        book.content.sessions[id]?.versions = [base]
        book.content.sessions[id]?.messages = [pending]
        return Book(book: book, base: base, basePNG: basePNG, maskRef: ref(maskPNG), maskPNG: maskPNG,
                    messageID: pending.id)
    }

    static func ref(_ data: Data) -> ImageRef { GenerationQueue.imageRef(for: data, contentType: "public.png") }

    // MARK: Assembly

    @Test func assemblerAttachesProviderMaskAtBaseSize() throws {
        let b = try Self.makeBook()
        let (request, report) = try assembleBook(b.book, b.intent(), messageID: b.messageID, imageData: b.images)
        let mask = try #require(request.mask)
        #expect(mask.pixelSize == Self.size)
        #expect(mask.ref == b.maskRef)
        #expect(request.baseImage?.ref == b.base.image)
        #expect(request.baseImage?.pixelSize == Self.size)
        // The wire mask: alpha 0 inside the edit area, opaque outside.
        let alpha = Pixels.alpha(mask.pngData)
        #expect(alpha.w == 64 && alpha.h == 48)
        #expect(alpha.bytes[24 * 64 + 32] == 0)
        #expect(alpha.bytes[2 * 64 + 2] == 255)
        #expect(alpha.bytes[40 * 64 + 60] == 255)
        // The prompt tells the model what the transparent area means; the mask isn't a reference.
        #expect(report.promptText.contains("transparent"))
        #expect(report.referencesSent.map(\.role) == ["base"])
        assertPromptSnapshot(report.promptText)
    }

    @Test func noRegionSectionWithoutAMask() throws {
        let b = try Self.makeBook()
        var plain = b.intent()
        plain.regionMask = nil
        let (request, report) = try assembleBook(b.book, plain, messageID: b.messageID, imageData: b.images)
        #expect(request.mask == nil)
        #expect(!report.promptText.contains("transparent"))
    }

    @Test func missingOrMismatchedMaskFailsAssembly() throws {
        let b = try Self.makeBook()
        var images = b.images
        images[b.maskRef] = nil
        #expect(throws: AssemblyError.maskImageMissing) {
            try assembleBook(b.book, b.intent(), messageID: b.messageID, imageData: images)
        }
        let small = try ImageOps.grayscalePNG(ImageOps.rasterize(RegionMaskDrawing(
            pixelSize: PixelSize(width: 32, height: 24), operations: [.invert])))
        images[b.maskRef] = small
        #expect(throws: AssemblyError.maskSizeMismatch) {
            try assembleBook(b.book, b.intent(), messageID: b.messageID, imageData: images)
        }
        guard case .invalidRequest(param: "mask", _) = AssemblyError.maskImageMissing.providerError else {
            Issue.record("expected an invalidRequest on mask")
            return
        }
    }

    // MARK: Queue

    func makeQueue(_ b: Book, outcome: Result<ImageResult, ProviderError>,
                   images: [ImageRef: Data]? = nil) throws -> (GenerationQueue, FakeHost, FakeProvider) {
        let host = FakeHost(content: b.book.content, images: images ?? b.images)
        let provider = FakeProvider(outcomes: [outcome], gated: false)
        let queue = GenerationQueue(providers: [.openai: provider], catalog: try ModelCatalog.bundled(), host: host,
                                    pricing: FakePricing(), now: { Date(timeIntervalSince1970: 100) })
        return (queue, host, provider)
    }

    static func rawResult(_ png: Data, size: PixelSize) -> ImageResult {
        ImageResult(imageData: png, contentType: "public.png", pixelSize: size, usage: TokenUsage(outputImageTokens: 7),
                    parametersSent: ["size": "\(size.width)x\(size.height)", "mask": "64x48 png"])
    }

    @Test func successCompositesThroughTheMaskAndKeepsTheRawOutput() async throws {
        let b = try Self.makeBook()
        // The provider repaints everything (and at twice the size): only the masked area may change.
        let raw = Pixels.solidPNG(128, 96, r: 250, g: 210, b: 20)
        let (queue, host, provider) = try makeQueue(
            b, outcome: .success(Self.rawResult(raw, size: PixelSize(width: 128, height: 96))))
        let item = b.item(b.intent())
        await queue.enqueue(item)
        await eventually("delivery") { await host.delivered().count == 1 }
        let delivery = try #require(await host.delivered().first)
        guard case let .success(result, provenance) = delivery.outcome else {
            Issue.record("expected success")
            return
        }
        let request = try #require(await provider.receivedRequests().first)
        #expect(request.mask?.pixelSize == Self.size)
        #expect(await host.reads().contains(b.maskRef))

        // Provenance and the stored raw image.
        let rawRef = Self.ref(raw)
        #expect(provenance.maskSent == b.maskRef)
        #expect(provenance.rawOutput == rawRef)
        #expect(provenance.featherPixels == ImageOps.defaultFeatherPixels)
        #expect(provenance.outputSize == PixelSize(width: 128, height: 96))
        #expect(provenance.parametersSent["mask"] == "64x48 png")
        #expect(provenance.intent == item.intent)
        #expect(delivery.additionalImages == [rawRef: raw])

        // The version image is the composite, at the base's size.
        #expect(result.pixelSize == Self.size)
        #expect(result.contentType == "public.png")
        let out = Pixels.rgba(result.imageData)
        let original = Pixels.rgba(b.basePNG)
        #expect(out.w == 64 && out.h == 48)
        let band = Int(ImageOps.defaultFeatherPixels)
        var outsideChecked = 0
        for y in 0..<48 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                let farOutside = x < 20 - band || x >= 44 + band || y < 16 - band || y >= 32 + band
                if farOutside {
                    outsideChecked += 1
                    #expect(Array(out.bytes[i..<i + 3]) == Array(original.bytes[i..<i + 3]), "pixel \(x),\(y)")
                }
            }
        }
        #expect(outsideChecked > 1000)
        let centre = (24 * 64 + 32) * 4
        #expect(Array(out.bytes[centre..<centre + 3]) == [250, 210, 20])
        // The call was charged once, as completed.
        #expect(await host.recorded().map(\.status) == [.completed])
    }

    @Test func blackFillFailsAsNoImageWithoutAVersionButIsCharged() async throws {
        let b = try Self.makeBook()
        let raw = Pixels.solidPNG(64, 48, r: 0, g: 0, b: 0)
        let (queue, host, _) = try makeQueue(b, outcome: .success(Self.rawResult(raw, size: Self.size)))
        let item = b.item(b.intent())
        await queue.enqueue(item)
        await eventually("delivery") { await host.delivered().count == 1 }
        let delivery = try #require(await host.delivered().first)
        guard case let .failure(error) = delivery.outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(RegionEditFailure.isBlankArea(error))
        let records = await host.recorded()
        #expect(records.map(\.status) == [.completed])
        #expect(records.first?.actual == Decimal(string: "0.012"))
        let entry = try #require(await queue.snapshot().entries.first { $0.id == item.id })
        #expect(entry.failure?.error == error)

        let advice = RefusalAdvisor.advise(error, context: AdviceContext(provider: .openai, report: nil))
        #expect(advice.explanation == "The model returned a blank area instead of an edit.")
        #expect(advice.fixes == ["Try again.", "Or select a slightly larger area."])
    }

    @Test func missingMaskFailsTheItemWithoutCallingTheProvider() async throws {
        let b = try Self.makeBook()
        var images = b.images
        images[b.maskRef] = nil
        let (queue, host, provider) = try makeQueue(b, outcome: .success(okResult()), images: images)
        await queue.enqueue(b.item(b.intent()))
        await eventually("delivery") { await host.delivered().count == 1 }
        guard case .failure(.invalidRequest(param: "mask", _)) = try #require(await host.delivered().first).outcome else {
            Issue.record("expected invalidRequest(mask)")
            return
        }
        #expect(await provider.receivedRequests().isEmpty)
        #expect(await host.recorded().isEmpty)
    }
}

/// Pixel helpers for region-edit tests.
enum Pixels {
    static func encodeRGBA(_ bytes: [UInt8], _ w: Int, _ h: Int) -> Data {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let img = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func noisyPNG(_ w: Int, _ h: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                bytes[i * 4 + c] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return encodeRGBA(bytes, w, h)
    }

    static func solidPNG(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i * 4] = r; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = b }
        return encodeRGBA(bytes, w, h)
    }

    static func rgba(_ data: Data) -> (w: Int, h: Int, bytes: [UInt8]) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, bytes)
    }

    static func alpha(_ data: Data) -> (w: Int, h: Int, bytes: [UInt8]) {
        let px = rgba(data)
        return (px.w, px.h, stride(from: 3, to: px.bytes.count, by: 4).map { px.bytes[$0] })
    }
}
