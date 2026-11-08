import BBAICore
import BBModel
import BBNet
import Foundation
import Testing
@testable import BBOpenAI

// Offline tests: the provider against Phase 0 fixtures (SP-1, SP-2, SP-5).

enum TestSupport {
    static let fixtureRoot: URL = Bundle.module.resourceURL!.appending(path: "Fixtures/openai", directoryHint: .isDirectory)

    /// Built at runtime, deliberately not key-shaped.
    static let secret = "bookbook-test-" + UUID().uuidString

    static let model = CatalogModel(
        provider: .openai, id: "gpt-image-2.5-sunburst", displayName: "GPT Image 2.5 Sunburst",
        image: ImageCapabilities(
            maxReferenceImages: 16, maxImageBytes: 50_000_000, maxRequestBytes: 20_000_000, supportsMask: true,
            nativeMultiTurn: false,
            aspect: .free(minRatio: 0.3333, maxRatio: 3.0, multipleOf: 16, minPixels: 655_360, maxPixels: 8_294_400,
                          experimentalAbovePixels: 3_686_400),
            quality: [
                .draft: QualityMapping(param: "low", targetPixels: 1_048_576),
                .standard: QualityMapping(param: "medium", targetPixels: 1_572_864),
                .high: QualityMapping(param: "high", targetPixels: 3_686_400),
            ]))

    static func request(boxAspect: Double = 1232.0 / 816.0, exactSize: PixelSize? = nil) -> ImageRequest {
        ImageRequest(model: model, quality: .draft,
                     output: OutputShape(boxAspect: boxAspect, exactSize: exactSize),
                     instruction: ComposedPrompt(sections: [
                        .init(key: "style", text: "Watercolour."), .init(key: "request", text: "A fox in a hat."),
                     ]))
    }

    static func provider(_ client: FixtureHTTPClient, key: String? = secret) -> OpenAIImageProvider {
        OpenAIImageProvider(http: client, apiKey: { key.flatMap(APIKey.init) })
    }

    static func client(_ outcome: FixtureHTTPClient.Outcome) -> FixtureHTTPClient {
        FixtureHTTPClient(root: fixtureRoot, queue: [outcome])
    }

    static func error(from provider: OpenAIImageProvider, _ request: ImageRequest = TestSupport.request()) async -> ProviderError? {
        do {
            _ = try await provider.generate(request, progress: { _ in })
            return nil
        } catch { return error }
    }
}

@Suite struct OpenAIImageProviderTests {
    @Test func successDecodesImageSizeUsageAndSendsExpectedJSON() async throws {
        let client = TestSupport.client(.fixture("SP-2/generations-low-1024x1024"))
        let provider = TestSupport.provider(client)
        #expect(provider.id == .openai)

        let events = Mutex2<[GenerationProgress]>([])
        let result = try await provider.generate(TestSupport.request()) { events.append($0) }

        #expect(events.value == [.sent, .receiving])
        #expect(result.contentType == "public.png")
        #expect(result.pixelSize == PixelSize(width: 1024, height: 1024))
        #expect(result.usage == TokenUsage(inputTextTokens: 26, inputImageTokens: 0, cachedInputTokens: 0,
                                           outputTextTokens: 0, outputImageTokens: 196))
        #expect(result.revisedPrompt == nil)

        let sent = try #require(client.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(sent.headers["Authorization"] == "Bearer \(TestSupport.secret)")
        let sentBody = try #require(sent.body)
        let json = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["model"] as? String == "gpt-image-2.5-sunburst")
        #expect(json["size"] as? String == "1264x832")
        #expect(json["quality"] as? String == "low")
        #expect(json["output_format"] as? String == "png")
        #expect(json["n"] as? Int == 1)
        #expect(json["moderation"] as? String == "auto")
        #expect(json["prompt"] as? String == "Watercolour.\n\nA fox in a hat.")
        #expect(Set(json.keys) == ["model", "prompt", "size", "quality", "output_format", "n", "moderation"])

        #expect(result.parametersSent == [
            "model": "gpt-image-2.5-sunburst", "size": "1264x832", "quality": "low",
            "output_format": "png", "n": "1", "moderation": "auto",
        ])
        // The key is only in the captured header: not in the request description or the result.
        #expect(!sent.description.contains(TestSupport.secret))
        #expect(!"\(result.parametersSent)".contains(TestSupport.secret))
    }

    @Test func exactSizeOverridesTheFitter() async throws {
        let client = TestSupport.client(.fixture("SP-2/generations-low-free-1232x816"))
        let result = try await TestSupport.provider(client).generate(
            TestSupport.request(exactSize: PixelSize(width: 1232, height: 816)), progress: { _ in })
        let sentBody = try #require(client.requests.first?.body)
        let json = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["size"] as? String == "1232x816")
        #expect(result.pixelSize == PixelSize(width: 64, height: 64))  // fixture holds the placeholder image
        #expect(result.usage?.outputImageTokens == 133)
    }

    @Test func moderationRefusal() async throws {
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.fixture("SP-5/generations-blocked-1"))))
        guard case .refused(let stage, let categories, let raw) = error else {
            Issue.record("expected .refused, got \(String(describing: error))"); return
        }
        #expect(stage == .input)
        #expect(categories == ["other"])
        #expect(raw?.status == 400 && raw?.code == "moderation_blocked")
    }

    @Test func invalidKeyRedactsTheMaskedEcho() async throws {
        let client = TestSupport.client(.fixtureWithStatus("SP-5/models-invalid-key", 401))
        let error = await TestSupport.error(from: TestSupport.provider(client))
        guard case .invalidKey(let raw) = error else { Issue.record("expected .invalidKey, got \(String(describing: error))"); return }
        let body = try #require(raw?.body)
        #expect(raw?.status == 401 && raw?.code == "invalid_api_key")
        #expect(!body.contains("****"))
        #expect(!body.contains("bookbook*"))
        #expect(body.contains("sk-REDACTED"))
        #expect(!"\(error as Any)".contains(TestSupport.secret))
    }

    @Test func unknownModel() async {
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.fixture("SP-5/generations-unknown-model"))))
        guard case .modelUnavailable(let raw) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(raw?.code == "invalid_value")
    }

    @Test func notFoundIsModelUnavailable() async {
        let error = await TestSupport.error(from: TestSupport.provider(
            TestSupport.client(.fixtureWithStatus("SP-5/generations-unknown-model", 404))))
        guard case .modelUnavailable = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func invalidSize() async {
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.fixture("SP-5/generations-invalid-size-1023"))))
        guard case .invalidRequest(let param, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "size")
    }

    @Test(arguments: [500, 502, 503, 504])
    func serverErrorsAreTransient(status: Int) async {
        let response = HTTPResponse(status: status, headers: [:], body: Data("{\"error\":{\"code\":\"server_is_overloaded\"}}".utf8))
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.response(response))))
        guard case .transient(let raw) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(raw?.status == status)
        #expect(error?.isTransient == true)
    }

    @Test func rateLimitAndBilling() async {
        func respond(_ body: String, headers: [String: String] = [:]) async -> ProviderError? {
            await TestSupport.error(from: TestSupport.provider(TestSupport.client(
                .response(HTTPResponse(status: 429, headers: headers, body: Data(body.utf8))))))
        }
        guard case .rateLimited(let retryAfter, _) = await respond("{\"error\":{\"code\":\"rate_limit_exceeded\"}}",
                                                                   headers: ["retry-after": "7"]) else {
            Issue.record("expected .rateLimited"); return
        }
        #expect(retryAfter == 7)
        for code in ["insufficient_quota", "credit_balance_exhausted", "monthly_spend_limit_exceeded"] {
            guard case .billing = await respond("{\"error\":{\"code\":\"\(code)\"}}") else {
                Issue.record("expected .billing for \(code)"); return
            }
        }
    }

    @Test func authorisationAndRegionMapping() async {
        func respond(_ status: Int, _ body: String) async -> ProviderError? {
            await TestSupport.error(from: TestSupport.provider(TestSupport.client(
                .response(HTTPResponse(status: status, headers: [:], body: Data(body.utf8))))))
        }
        guard case .verificationRequired = await respond(
            403, "{\"error\":{\"code\":null,\"message\":\"Your organization must be verified to use gpt-image\"}}") else {
            Issue.record("expected .verificationRequired"); return
        }
        guard case .regionUnsupported = await respond(
            403, "{\"error\":{\"code\":\"unsupported_country_region_territory\",\"message\":\"Country, region, or territory not supported\"}}") else {
            Issue.record("expected .regionUnsupported"); return
        }
    }

    @Test func emptyDataIsNoImage() async {
        let response = HTTPResponse(status: 200, headers: [:], body: Data("{\"data\":[]}".utf8))
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.response(response))))
        guard case .noImage = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func transportFailuresMap() async {
        let cases: [(HTTPClientError, ProviderError)] = [
            (.offline(host: "h"), .offline), (.timedOut(host: "h"), .timeout), (.cancelled, .cancelled),
        ]
        for (transport, expected) in cases {
            let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.failure(transport))))
            #expect(error == expected)
        }
    }

    @Test func missingKeySendsNothing() async {
        let client = TestSupport.client(.fixture("SP-2/generations-low-1024x1024"))
        let error = await TestSupport.error(from: TestSupport.provider(client, key: nil))
        #expect(error == .missingKey)
        #expect(client.requests.isEmpty)
    }

    @Test func fixedRatioModelsCannotBeSentToOpenAI() async {
        var request = TestSupport.request()
        request.model.image.aspect = .fixed(ratios: ["1:1"])
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(.fixture("SP-2/generations-low-1024x1024"))), request)
        guard case .invalidRequest(let param, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "size")
    }

    @Test func errorsNeverContainTheKey() async {
        // A server that (wrongly) echoes the key: the raw body is withheld.
        let body = "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"bad \(TestSupport.secret)\"}}"
        let error = await TestSupport.error(from: TestSupport.provider(TestSupport.client(
            .response(HTTPResponse(status: 401, headers: [:], body: Data(body.utf8))))))
        #expect(!"\(error as Any)".contains(TestSupport.secret))
    }
}

/// Tiny lock-protected box for progress events in a `@Sendable` closure.
final class Mutex2<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func append<Element>(_ element: Element) where Value == [Element] {
        lock.lock(); defer { lock.unlock() }; stored.append(element)
    }
}
