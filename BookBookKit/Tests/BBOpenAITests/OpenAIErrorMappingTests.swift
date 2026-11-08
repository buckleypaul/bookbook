import BBAICore
import BBModel
import BBNet
import Foundation
import Synchronization
import Testing
@testable import BBOpenAI

/// Phase 9: every recorded fixture and a synthetic error table (A §7.11), the list-models call,
/// transport mapping, cancellation and redaction. All offline.
enum SyntheticFixtures {
    static let root: URL = Bundle.module.resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)

    static func client(_ name: String, in folder: String = "openai-synthetic") -> FixtureHTTPClient {
        FixtureHTTPClient(root: root.appending(path: folder, directoryHint: .isDirectory), queue: [.fixture(name)])
    }

    static func generateError(_ name: String, in folder: String = "openai-synthetic") async -> ProviderError? {
        let provider = OpenAIImageProvider(http: client(name, in: folder), apiKey: { APIKey(TestSupport.secret) })
        return await TestSupport.error(from: provider)
    }
}

@Suite struct OpenAIErrorMappingTests {
    // MARK: Recorded fixtures

    @Test func recordedBlocked() async {
        for name in ["SP-5/generations-blocked-1", "SP-5/generations-blocked-2"] {
            let error = await SyntheticFixtures.generateError(name, in: "openai")
            guard case .refused(let stage, let categories, let raw) = error else { Issue.record("\(name): \(String(describing: error))"); continue }
            #expect(stage == .input)
            #expect(!categories.isEmpty)
            #expect(raw?.code == "moderation_blocked" && raw?.status == 400)
        }
    }

    @Test func recordedInvalidSizes() async {
        for name in ["SP-5/generations-invalid-size-1000", "SP-5/generations-invalid-size-1023"] {
            let error = await SyntheticFixtures.generateError(name, in: "openai")
            guard case .invalidRequest(let param, let raw) = error else { Issue.record("\(name): \(String(describing: error))"); continue }
            #expect(param == "size")
            #expect(raw?.code == "invalid_value")
        }
    }

    @Test func recordedUnknownModel() async {
        let error = await SyntheticFixtures.generateError("SP-5/generations-unknown-model", in: "openai")
        guard case .modelUnavailable(let raw) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(raw?.status == 400)
    }

    @Test func recordedInvalidKey() async {
        let error = await SyntheticFixtures.generateError("SP-5/models-invalid-key", in: "openai")
        // The recorded meta carries status 401.
        guard case .invalidKey(let raw) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(raw?.status == 401)
        #expect(raw?.body.contains("****") == false)
    }

    @Test(arguments: [
        "SP-1/generations-low-1024x1024", "SP-2/generations-low-1024x1024", "SP-2/generations-low-1024x1536",
        "SP-2/generations-low-free-1232x816", "SP-3/edits-base-plus-3-refs-1024",
    ])
    func recordedSuccessesDecodeWithUsage(name: String) async throws {
        let client = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [.fixture(name)])
        let result = try await TestSupport.provider(client).generate(TestSupport.request(), progress: { _ in })
        let usage = try #require(result.usage, "\(name) lost its usage")
        #expect(usage.outputImageTokens > 0)
        #expect(!result.imageData.isEmpty)
    }

    // MARK: Synthetic table

    @Test func rateLimitedCarriesRetryAfter() async {
        let error = await SyntheticFixtures.generateError("429-rate-limit")
        guard case .rateLimited(let retryAfter, let raw) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(retryAfter == 7)
        #expect(raw?.status == 429 && raw?.code == "rate_limit_exceeded")
        #expect(error?.isTransient == true)
    }

    @Test(arguments: ["429-insufficient-quota", "400-billing-hard-limit", "429-spend-limit"])
    func billing(name: String) async {
        let error = await SyntheticFixtures.generateError(name)
        guard case .billing(let raw) = error else { Issue.record("\(name): \(String(describing: error))"); return }
        #expect(raw?.code != nil)
        #expect(error?.isTransient == false)
    }

    @Test func forbiddenVariants() async {
        guard case .regionUnsupported = await SyntheticFixtures.generateError("403-unsupported-country") else {
            Issue.record("country"); return
        }
        guard case .verificationRequired = await SyntheticFixtures.generateError("403-unverified-org") else {
            Issue.record("unverified"); return
        }
        // Unclassified 403 stays `.unknown` with the raw kept.
        guard case .unknown(let raw) = await SyntheticFixtures.generateError("403-other") else {
            Issue.record("other 403"); return
        }
        #expect(raw?.status == 403 && raw?.code == "forbidden")
    }

    @Test(arguments: ["500", "503-overloaded", "504"])
    func serverErrorsAreTransient(name: String) async {
        let error = await SyntheticFixtures.generateError(name)
        guard case .transient(let raw) = error else { Issue.record("\(name): \(String(describing: error))"); return }
        #expect(raw != nil)
        #expect(error?.isTransient == true)
    }

    @Test func contentPolicyViolationIsRefused() async {
        let error = await SyntheticFixtures.generateError("400-content-policy")
        guard case .refused(let stage, _, let raw) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(stage == .unknown)
        #expect(raw?.code == "image_content_policy_violation")
    }

    @Test(arguments: [
        ("400-invalid-image-format", "image[]"), ("400-image-too-large", "image[]"),
        ("400-file-above-max-size", "image[]"), ("400-invalid-mask-format", "mask"),
    ])
    func imageInputProblemsAreInvalidRequests(name: String, param: String) async {
        let error = await SyntheticFixtures.generateError(name)
        guard case .invalidRequest(let got, let raw) = error else { Issue.record("\(name): \(String(describing: error))"); return }
        #expect(got == param)
        #expect(raw?.status == 400)
    }

    // MARK: List models

    private func lister(_ client: FixtureHTTPClient, key: String? = TestSupport.secret) -> OpenAIModelLister {
        OpenAIModelLister(http: client, apiKey: { key.flatMap(APIKey.init) })
    }

    @Test func listsModelIDs() async throws {
        let client = SyntheticFixtures.client("models-ok")
        let lister = lister(client)
        #expect(lister.id == .openai)
        let ids = try await lister.listModelIDs()
        #expect(ids == ["gpt-image-2.5-sunburst", "gpt-4o"])
        let sent = try #require(client.requests.first)
        #expect(sent.method == "GET" && sent.body == nil)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/models")
        #expect(sent.headers["Authorization"] == "Bearer \(TestSupport.secret)")
    }

    @Test func listModelsErrors() async throws {
        let missing = SyntheticFixtures.client("models-ok")
        do { _ = try await lister(missing, key: nil).listModelIDs(); Issue.record("expected throw") } catch {
            #expect(error == .missingKey)
        }
        #expect(missing.requests.isEmpty)

        let invalid = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [.fixture("SP-5/models-invalid-key")])
        do { _ = try await lister(invalid).listModelIDs(); Issue.record("expected throw") } catch {
            guard case .invalidKey(let raw) = error else { Issue.record("\(error)"); return }
            #expect(raw?.body.contains("****") == false)
        }

        let offline = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [.failure(.offline(host: "h"))])
        do { _ = try await lister(offline).listModelIDs(); Issue.record("expected throw") } catch {
            #expect(error == .offline)
        }

        let junk = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [
            .response(HTTPResponse(status: 200, headers: [:], body: Data("not json".utf8)))])
        do { _ = try await lister(junk).listModelIDs(); Issue.record("expected throw") } catch {
            guard case .unknown = error else { Issue.record("\(error)"); return }
        }
    }

    // MARK: Transport

    @Test func transportMapping() async {
        let cases: [(HTTPClientError, ProviderError)] = [
            (.transport(code: -1005, host: "h"), .transient(nil)),
            (.timedOut(host: "h"), .timeout), (.offline(host: "h"), .offline), (.cancelled, .cancelled),
        ]
        for (transport, expected) in cases {
            let client = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [.failure(transport)])
            #expect(await TestSupport.error(from: TestSupport.provider(client)) == expected)
        }
        #expect(ProviderError.transient(nil).isTransient)
    }

    /// Cancelling the calling Task while the request is in flight yields `.cancelled`.
    @Test func cancellingMidRequestYieldsCancelled() async {
        let client = HangingClient()
        let provider = OpenAIImageProvider(http: client, apiKey: { APIKey(TestSupport.secret) })
        let task = Task { await TestSupport.error(from: provider) }
        while !client.started { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .cancelled)

        let listTask = Task { () -> ProviderError? in
            let lister = OpenAIModelLister(http: HangingClient(), apiKey: { APIKey(TestSupport.secret) })
            do throws(ProviderError) { _ = try await lister.listModelIDs(); return nil } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(50))
        listTask.cancel()
        #expect(await listTask.value == .cancelled)
    }

    // MARK: Redaction

    /// Built at runtime so no key-shaped literal is in the source (scripts/tests/test-bootstrap.sh).
    private static var fakeKey: String { "sk-" + "proj-" + String(repeating: "Q", count: 40) }

    @Test func maskedKeyEchoIsRedactedInRaw() async {
        let body = "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"Incorrect API key provided: sk-proj-****Wxyz.\"}}"
        let client = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [
            .response(HTTPResponse(status: 401, headers: [:], body: Data(body.utf8)))])
        let error = await TestSupport.error(from: TestSupport.provider(client, key: Self.fakeKey))
        guard case .invalidKey(let raw) = error else { Issue.record("\(String(describing: error))"); return }
        let text = raw?.body ?? ""
        #expect(!text.contains("****") && !text.contains("Wxyz"))
        #expect(text.contains("sk-REDACTED"))
    }

    @Test func bodyContainingTheKeyIsWithheld() async {
        let body = "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"Incorrect API key: \(Self.fakeKey)\"}}"
        let client = FixtureHTTPClient(root: TestSupport.fixtureRoot, queue: [
            .response(HTTPResponse(status: 401, headers: [:], body: Data(body.utf8)))])
        let error = await TestSupport.error(from: TestSupport.provider(client, key: Self.fakeKey))
        guard case .invalidKey(let raw) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(raw?.body == "<body withheld: it contained credentials>")
        #expect(raw?.status == 401)
        #expect(!"\(String(describing: error))".contains(Self.fakeKey))
    }
}

/// Never answers; honours cancellation like the real client does.
private final class HangingClient: HTTPClient {
    private let flag = Mutex(false)
    var started: Bool { flag.withLock { $0 } }
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        flag.withLock { $0 = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw .cancelled
    }
}
