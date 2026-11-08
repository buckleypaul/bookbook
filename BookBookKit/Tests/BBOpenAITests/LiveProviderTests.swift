import BBAICore
import BBModel
import BBNet
import BBTestSupport
import Foundation
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

        let usage = try #require(result.usage)
        LiveSpendGuard.record(
            test: "slice_generateLow", provider: "openai", model: request.model.id,
            usage: LiveSpendGuard.Usage(inputTextTokens: usage.inputTextTokens, inputImageTokens: usage.inputImageTokens,
                                        outputTextTokens: usage.outputTextTokens, outputImageTokens: usage.outputImageTokens))

        #expect(OpenAIImageProvider.pixelSize(of: result.imageData) == PixelSize(width: 1024, height: 1024))
        #expect(result.pixelSize == PixelSize(width: 1024, height: 1024))
        #expect(usage.outputImageTokens > 0)
        #expect(result.parametersSent["quality"] == "low")
    }

    /// `Tests/BBOpenAITests/Fixtures/openai/slice/`, found from this file's path.
    private static func fixtureDirectory(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
            .appending(path: "Fixtures/openai/slice", directoryHint: .isDirectory)
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HTTPResponse?
    var value: HTTPResponse? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ response: HTTPResponse) { lock.lock(); stored = response; lock.unlock() }
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
