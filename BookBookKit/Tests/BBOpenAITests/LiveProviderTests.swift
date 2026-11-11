import BBAICore
import BBModel
import BBNet
import BBTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import BBOpenAI

/// Live OpenAI check for the Phase 2 slice (implementation-plan.md §2.2, §2.3). Runs only through
/// `scripts/live-tests.sh` (or `record-fixtures.sh`, which also records the response). Skips otherwise.
/// The key is read from the environment only and goes straight into `APIKey` and the provider.
/// No snapshot assertions.
@Suite(.serialized) struct LiveProviderTests {
    private static var enabled: Bool {
        LiveTestGate.isEnabled(for: .openai) && LiveSpendGuard.isUnderBudget()
    }

    /// Draft/low at the smallest valid size (1024x1024), about $0.01.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func slice_generateLow() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))

        // Wrap the real client so the recorder can see the response when recording is on.
        let inner = URLSessionHTTPClient()
        let captured = ResponseBox()
        let http = CapturingClient(inner: inner, box: captured)
        let provider = OpenAIImageProvider(http: http, apiKey: { apiKey })

        let request = ImageRequest(
            model: TestSupport.model, quality: .draft,
            output: OutputShape(boxAspect: 1, exactSize: PixelSize(width: 1024, height: 1024)),
            instruction: ComposedPrompt(sections: [.init(key: "request", text: "A simple flat illustration of a red balloon.")]))

        let result = try await provider.generate(request, progress: { _ in })

        if let response = captured.value {
            let directory = Self.fixtureDirectory()
            let recorder = FixtureRecorder(directory: directory, containsSecret: { apiKey.occurs(in: $0) })
            try recorder.record(response, name: "slice-generate-low-1024x1024")
        }

        // Record spend first, so a success without usage is still logged (as an estimate).
        LiveSpendGuard.record(
            test: "slice_generateLow", provider: "openai", model: request.model.id,
            usage: result.usage.map {
                LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                     outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
            },
            estimateUSD: 0.01)

        let usage = try #require(result.usage)
        #expect(OpenAIImageProvider.pixelSize(of: result.imageData) == PixelSize(width: 1024, height: 1024))
        #expect(result.pixelSize == PixelSize(width: 1024, height: 1024))
        #expect(usage.outputImageTokens > 0)
        #expect(result.parametersSent["quality"] == "low")
    }

    /// Phase 8: generate a tiny low-quality image, then refine it through `/images/edits` at low
    /// quality and the smallest size. About $0.02. No fixture is recorded.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func SP8_refinementLowQuality() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))
        let provider = OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { apiKey })
        let size = PixelSize(width: 1024, height: 1024)
        func spend(_ result: ImageResult?, _ name: String) {
            LiveSpendGuard.record(
                test: name, provider: "openai", model: TestSupport.model.id,
                usage: result?.usage.map {
                    LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                         outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
                },
                estimateUSD: 0.01)
        }

        let first = ImageRequest(
            model: TestSupport.model, quality: .draft,
            output: OutputShape(boxAspect: 1, exactSize: size),
            instruction: ComposedPrompt(sections: [.init(key: "request", text: "A simple flat illustration of a red balloon.")]))
        let generated = try await provider.generate(first, progress: { _ in })
        spend(generated, "SP8_refinementLowQuality.generate")

        var refine = first
        refine.instruction = ComposedPrompt(sections: [.init(key: "request", text: "Make the balloon blue.")])
        refine.baseImage = ImagePayload(data: generated.imageData, contentType: generated.contentType,
                                        pixelSize: generated.pixelSize)
        let refined = try await provider.generate(refine, progress: { _ in })
        spend(refined, "SP8_refinementLowQuality.edit")

        #expect(!refined.imageData.isEmpty)
        #expect(refined.pixelSize == generated.pixelSize)
        #expect(refined.parametersSent["quality"] == "low")
        #expect(refined.parametersSent["size"] == "1024x1024")
    }

    /// Phase 11: does a masked edit on a real 1024x1024 illustration still return black fills (SP-4)?
    /// Three Draft calls (masked, masked again, unmasked), about $0.06. No fixture, no files written.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func SP11_maskedEditRealIllustration() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))
        let provider = OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { apiKey })
        let size = PixelSize(width: 1024, height: 1024)
        let baseData = try Self.sp2BaseImage()
        let base = ImagePayload(data: baseData, contentType: "public.png", pixelSize: size)
        let maskRect = (x0: 341, y0: 341, x1: 682, y1: 682)  // top-left origin, half-open
        let maskPNG = try #require(Self.maskPNG(size: 1024, hole: maskRect))
        let mask = MaskPayload(pngData: maskPNG, pixelSize: size)
        let baseRGBA = try #require(Self.rgba(baseData))

        func call(_ run: String, prompt: String, mask: MaskPayload?) async throws {
            var request = ImageRequest(
                model: TestSupport.model, quality: .draft, output: OutputShape(boxAspect: 1, exactSize: size),
                instruction: ComposedPrompt(sections: [.init(key: "request", text: prompt)]),
                baseImage: base)
            request.mask = mask
            let result = try await provider.generate(request, progress: { _ in })
            LiveSpendGuard.record(
                test: "SP11_maskedEditRealIllustration.\(run)", provider: "openai", model: TestSupport.model.id,
                usage: result.usage.map {
                    LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                         outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
                },
                estimateUSD: 0.02)
            #expect(!result.imageData.isEmpty)
            print("SPIKE-RESULT SP11 \(run) sizeIs1024: \(result.pixelSize == size)")
            guard let out = Self.rgba(result.imageData), out.width == 1024, out.height == 1024 else {
                print("SPIKE-RESULT SP11 \(run) decode: failed or not 1024x1024")
                return
            }
            var inCount = 0, black = 0, outCount = 0
            var inDiff = 0.0, outDiff = 0.0
            for y in 0..<1024 {
                for x in 0..<1024 {
                    let inside = x >= maskRect.x0 && x < maskRect.x1 && y >= maskRect.y0 && y < maskRect.y1
                    let farOutside = x < maskRect.x0 - 16 || x >= maskRect.x1 + 16 || y < maskRect.y0 - 16 || y >= maskRect.y1 + 16
                    guard inside || farOutside else { continue }
                    let i = (y * 1024 + x) * 4
                    let dr = abs(Int(out.bytes[i]) - Int(baseRGBA.bytes[i]))
                    let dg = abs(Int(out.bytes[i + 1]) - Int(baseRGBA.bytes[i + 1]))
                    let db = abs(Int(out.bytes[i + 2]) - Int(baseRGBA.bytes[i + 2]))
                    let diff = Double(dr + dg + db) / 3
                    if inside {
                        inCount += 1; inDiff += diff
                        if max(out.bytes[i], out.bytes[i + 1], out.bytes[i + 2]) <= 16 { black += 1 }
                    } else {
                        outCount += 1; outDiff += diff
                    }
                }
            }
            print("SPIKE-RESULT SP11 \(run) inMaskNearBlackFraction: \(Double(black) / Double(inCount))")
            print("SPIKE-RESULT SP11 \(run) meanAbsChangeInsideMask: \(inDiff / Double(inCount))")
            print("SPIKE-RESULT SP11 \(run) meanAbsChangeOutsideMask: \(outDiff / Double(outCount))")
        }

        let maskedPrompt = "Within the masked area only, add a bright yellow sun. Keep everything else exactly as it is."
        try await call("a-masked", prompt: maskedPrompt, mask: mask)
        try await call("b-masked-repeat", prompt: maskedPrompt, mask: mask)
        try await call("c-unmasked",
                       prompt: "Add a bright yellow sun in the centre of the picture. Keep everything else exactly as it is.",
                       mask: nil)
    }

    /// Asset reference photo (PD §8.3, 2026-11-11): a real photo (macOS's own parrot user picture,
    /// no person in it) scaled to 1536 px JPEG as the app stores it, sent as a reference with the
    /// asset prompt the assembler builds. Draft 1024x1024, about $0.02. Records the response (with
    /// its image) under `Fixtures/openai/reference-photo/` in record mode, so it can be looked at.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func SP10_referencePhotoToIllustration() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))
        let source = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")
        let photo = try #require(Self.referencePhotoJPEG(source, maxPixelSize: 1536), "macOS sample photo missing")
        let captured = ResponseBox()
        let provider = OpenAIImageProvider(http: CapturingClient(inner: URLSessionHTTPClient(), box: captured),
                                           apiKey: { apiKey })
        // The prompt `ContextAssembler` builds for an asset session with a reference photo
        // (snapshot `assetSessionSendsItsReferencePhotoFirst`), for an asset named Polly.
        let sections: [ComposedPrompt.Section] = [
            .init(key: "role", text: "Illustration for a children's picture book."),
            .init(key: "style", text: "Style: Soft watercolor, warm light."),
            .init(key: "cast", text: "Cast and setting:\n- Polly (character). Image 1 shows Polly."),
            .init(key: "subject", text: "Draw a reference image of Polly for the rest of the book to follow: the full figure "
                + "from head to toe, seen from the front in a relaxed, neutral pose, alone on a plain, simple, light "
                + "background. No other characters, props or scenery."),
            .init(key: "request", text: "Draw Polly from the reference photo."),
            .init(key: "legend", text: "Reference images:\nImage 1: a photo of Polly. Base Polly on it: keep the likeness "
                + "(for a person, their face shape, hair, skin tone, build and distinguishing features; otherwise its "
                + "shape, colours and details), but draw Polly as an illustration in the book's style. Don't copy the "
                + "photo's background, lighting, pose or realism."),
        ]
        let request = ImageRequest(
            model: TestSupport.model, quality: .draft,
            output: OutputShape(boxAspect: 1, exactSize: PixelSize(width: 1024, height: 1024)),
            instruction: ComposedPrompt(sections: sections),
            references: [ReferenceImage(payload: ImagePayload(data: photo.data, contentType: "public.jpeg",
                                                              pixelSize: photo.size),
                                        sent: SentReference(image: ImageRef(sha256: "photo", contentType: "public.jpeg"),
                                                            role: "photo", label: "Reference photo"))])
        let result = try await provider.generate(request, progress: { _ in })
        LiveSpendGuard.record(
            test: "SP10_referencePhotoToIllustration", provider: "openai", model: TestSupport.model.id,
            usage: result.usage.map {
                LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                     outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
            },
            estimateUSD: 0.02)
        if let response = captured.value {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/openai/reference-photo", directoryHint: .isDirectory)
            try FixtureRecorder(directory: directory, containsSecret: { apiKey.occurs(in: $0) })
                .record(response, name: "edits-reference-photo-low-1024x1024", keepRealImage: true)
        }
        #expect(!result.imageData.isEmpty)
        #expect(result.pixelSize == PixelSize(width: 1024, height: 1024))
        if let usage = result.usage {
            print("SPIKE-RESULT SP10 inputImageTokens: \(usage.inputImageTokens) outputImageTokens: \(usage.outputImageTokens)")
        }
    }

    /// The file as `ImageImportNormalizer.normalizeReferencePhoto` stores it: upright JPEG, longest
    /// edge at most `maxPixelSize`, no metadata.
    private static func referencePhotoJPEG(_ url: URL, maxPixelSize: Int) -> (data: Data, size: PixelSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, PixelSize(width: image.width, height: image.height))
    }

    /// The real 1024x1024 SP-2 illustration, decoded from its recorded response.
    private static func sp2BaseImage(file: String = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appending(path: "Fixtures/openai/SP-2/generations-low-1024x1024.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let json = try #require(object as? [String: Any])
        let item = try #require((json["data"] as? [[String: Any]])?.first)
        let encoded = try #require(item["b64_json"] as? String)
        return try #require(Data(base64Encoded: encoded))
    }

    /// RGBA mask: alpha 0 inside `hole` (top-left origin), opaque white elsewhere.
    private static func maskPNG(size: Int, hole: (x0: Int, y0: Int, x1: Int, y1: Int)) -> Data? {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in hole.y0..<hole.y1 {
            for x in hole.x0..<hole.x1 {
                let i = (y * size + x) * 4
                bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0
            }
        }
        let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decode to 8-bit RGBA (premultiplied last, sRGB) with top-left row order.
    private static func rgba(_ data: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }

    /// Phase 9: two Draft 1024x1024 calls (the second an edit with one 1536x1024 reference, to
    /// measure its input image tokens) and a third cancelled about 2 s after it is sent. About $0.10.
    /// Usage goes to the test output; the spend log holds no prompt text or key.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func SP9_twoRequestsAndCancel() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))
        let provider = OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { apiKey })
        let size = PixelSize(width: 1024, height: 1024)
        func spend(_ result: ImageResult?, _ name: String) {
            LiveSpendGuard.record(
                test: name, provider: "openai", model: TestSupport.model.id,
                usage: result?.usage.map {
                    LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                         outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
                },
                estimateUSD: 0.02)
        }
        func request(_ text: String) -> ImageRequest {
            ImageRequest(
                model: TestSupport.model, quality: .draft, output: OutputShape(boxAspect: 1, exactSize: size),
                instruction: ComposedPrompt(sections: [.init(key: "request", text: text)]))
        }

        // 1. Plain generation.
        let first = try await provider.generate(request("A simple flat illustration of a green frog."), progress: { _ in })
        spend(first, "SP9_twoRequestsAndCancel.generate")
        print("SP9 generate usage: \(String(describing: first.usage))")

        // 2. Edit with one 1536x1024 synthetic reference: the input image tokens are the measurement.
        let referenceSize = PixelSize(width: 1536, height: 1024)
        let png = try #require(Self.syntheticPNG(width: referenceSize.width, height: referenceSize.height))
        var edit = request("Draw a similar frog in the style of the reference.")
        edit.references = [ReferenceImage(
            payload: ImagePayload(data: png, contentType: "public.png", pixelSize: referenceSize),
            sent: SentReference(image: ImageRef(sha256: "00", contentType: "public.png"), role: "style", label: "synthetic"))]
        let second = try await provider.generate(edit, progress: { _ in })
        spend(second, "SP9_twoRequestsAndCancel.edit")
        print("SP9 edit usage with a 1536x1024 reference: \(String(describing: second.usage))")
        print("SP9 input image tokens for 1536x1024 reference: \(second.usage?.inputImageTokens ?? -1)")

        // 3. Cancel about 2 s after sending. The request may still be billed, so log an estimate.
        let cancelled = request("A simple flat illustration of a yellow duck.")
        let task = Task { () -> ProviderError? in
            do throws(ProviderError) { _ = try await provider.generate(cancelled, progress: { _ in }); return nil } catch { return error }
        }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        let outcome = await task.value
        spend(nil, "SP9_twoRequestsAndCancel.cancelled")
        #expect(outcome == .cancelled)
    }

    /// Phase 12: one layout request and one consistency request (two tiny synthetic images, low
    /// detail) through Chat Completions with `store: false`. About $0.02. No fixture is recorded.
    @Test(.enabled(if: LiveProviderTests.enabled, "needs BOOKBOOK_LIVE_TESTS=1, OPENAI_API_KEY and budget left"))
    func SP12_templateAndConsistency() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap(APIKey.init))
        let provider = OpenAIChatProvider(http: URLSessionHTTPClient(), apiKey: { apiKey })
        func spend(_ usage: TokenUsage?, _ name: String, model: String) {
            LiveSpendGuard.record(
                test: name, provider: "openai", model: model,
                usage: usage.map {
                    LiveSpendGuard.Usage(inputTextTokens: $0.inputTextTokens, inputImageTokens: $0.inputImageTokens,
                                         outputTextTokens: $0.outputTextTokens, outputImageTokens: $0.outputImageTokens)
                },
                estimateUSD: 0.01)
        }

        let textModel = CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "GPT-6 Luna", kind: .text)
        let layout = LayoutRequest(
            model: textModel,
            system: "You design page layouts for children's picture books. Reply only with the requested JSON.",
            user: "Page: 8.5 x 8.5 inch square, single page. Design a template with a big picture on the top two thirds and the text below. Use fractions 0 to 1 of the page.")
        var layoutUsage: TokenUsage?
        do {
            let result = try await provider.generateLayout(layout)
            layoutUsage = result.usage
            #expect(!result.draft.boxes.isEmpty)
            #expect(result.parametersSent["store"] == "false")
        } catch {
            spend(nil, "SP12_templateAndConsistency.layout", model: textModel.id)
            throw error
        }
        spend(layoutUsage, "SP12_templateAndConsistency.layout", model: textModel.id)

        let visionModel = CatalogTextModel(provider: .openai, id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra",
                                           kind: .vision, imageDetail: "low")
        let first = try #require(Self.syntheticPNG(width: 256, height: 256))
        let second = try #require(Self.syntheticPNG(width: 256, height: 128))
        let check = ConsistencyRequest(
            model: visionModel,
            system: "You compare picture-book illustrations for visual consistency. Reply only with the requested JSON.",
            user: "Image 1 is the version being checked; image 2 is the reference. Report any differences.",
            image: LabeledImage(label: "Version", payload: ImagePayload(data: first, contentType: "public.png")),
            references: [LabeledImage(label: "Reference", payload: ImagePayload(data: second, contentType: "public.png"))])
        var visionUsage: TokenUsage?
        do {
            let result = try await provider.checkConsistency(check)
            visionUsage = result.usage
            #expect(result.parametersSent["detail"] == "low")
        } catch {
            spend(nil, "SP12_templateAndConsistency.consistency", model: visionModel.id)
            throw error
        }
        spend(visionUsage, "SP12_templateAndConsistency.consistency", model: visionModel.id)
    }

    /// A plain two-tone PNG, built at runtime.
    private static func syntheticPNG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// `Tests/BBOpenAITests/Fixtures/openai/slice/`, found from this file's path.
    private static func fixtureDirectory(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
            .appending(path: "Fixtures/openai/slice", directoryHint: .isDirectory)
    }
}

private final class ResponseBox: Sendable {
    private let stored = Mutex<HTTPResponse?>(nil)
    var value: HTTPResponse? { stored.withLock { $0 } }
    func set(_ response: HTTPResponse) { stored.withLock { $0 = response } }
}

private struct CapturingClient: HTTPClient {
    let inner: any HTTPClient
    let box: ResponseBox
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        let response = try await inner.send(request)
        box.set(response)
        return response
    }
}
