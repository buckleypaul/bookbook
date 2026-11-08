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
