import BBAICore
import BBModel
import BBNet
import Foundation
import Testing
@testable import BBOpenAI

// Offline tests: the Chat Completions adapter against the SP-7 fixtures.

@Suite struct OpenAIChatProviderTests {
    static let textModel = CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "Luna", kind: .text)
    static let visionModel = CatalogTextModel(provider: .openai, id: "gpt-6.1-terra", displayName: "Terra", kind: .vision,
                                              imageDetail: "low")

    static func provider(_ client: FixtureHTTPClient, key: String? = TestSupport.secret) -> OpenAIChatProvider {
        OpenAIChatProvider(http: client, apiKey: { key.flatMap(APIKey.init) })
    }

    static let layout = LayoutRequest(model: textModel, system: "SYS", user: "USER")

    static func consistency(model: CatalogTextModel = visionModel) -> ConsistencyRequest {
        ConsistencyRequest(
            model: model, system: "SYS", user: "USER",
            image: LabeledImage(label: "Candidate", payload: ImagePayload(data: Data([1, 2, 3]), contentType: "public.png")),
            references: [LabeledImage(label: "Pip", payload: ImagePayload(data: Data([4, 5]), contentType: "public.jpeg"))])
    }

    static func body(_ client: FixtureHTTPClient) throws -> [String: Any] {
        let sent = try #require(client.requests.first)
        let data = try #require(sent.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func response(_ json: String, status: Int = 200) -> FixtureHTTPClient.Outcome {
        .response(HTTPResponse(status: status, headers: [:], body: Data(json.utf8), duration: .zero))
    }

    static func chat(content: String? = nil, refusal: String? = nil, finish: String = "stop") -> FixtureHTTPClient.Outcome {
        let message: [String: Any] = ["role": "assistant", "refusal": refusal ?? NSNull(), "content": content ?? NSNull()]
        let root: [String: Any] = ["choices": [["finish_reason": finish, "index": 0, "message": message]]]
        let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
        return .response(HTTPResponse(status: 200, headers: [:], body: data, duration: .zero))
    }

    static func error(_ work: () async throws(ProviderError) -> Void) async -> ProviderError? {
        do { try await work(); return nil } catch { return error }
    }

    @Test func layoutDecodesFixtureAndSendsStrictSchema() async throws {
        let client = TestSupport.client(.fixture("SP-7/chat-template-draft"))
        let result = try await Self.provider(client).generateLayout(Self.layout)

        #expect(result.draft.name == "Picture Above")
        #expect(result.draft.boxes.count == 2)
        #expect(result.draft.boxes[0].kind == .image)
        #expect(result.draft.boxes[1].textAlignment == .center)
        #expect(result.draft.boxes[0].textAlignment == nil)
        #expect(result.usage == TokenUsage(inputTextTokens: 224, inputImageTokens: 0, cachedInputTokens: 0,
                                           outputTextTokens: 253, outputImageTokens: 0))
        #expect(result.parametersSent == ["model": "gpt-6-luna", "store": "false", "response_format": "template_draft"])

        let sent = try #require(client.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer \(TestSupport.secret)")
        let body = try Self.body(client)
        #expect(body["store"] as? Bool == false)
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["temperature"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.map { $0["content"] as? String } == ["SYS", "USER"])
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "template_draft")
        #expect(schema["strict"] as? Bool == true)
        let object = try #require(schema["schema"] as? [String: Any])
        #expect(object["additionalProperties"] as? Bool == false)
        #expect(object["required"] as? [String] == ["name", "boxes"])
    }

    @Test func consistencyDecodesFixtureAndSendsImagesInOrder() async throws {
        let client = TestSupport.client(.fixture("SP-7/chat-consistency"))
        let result = try await Self.provider(client).checkConsistency(Self.consistency())

        #expect(!result.consistent)
        #expect(result.differences == [ConsistencyDifference(
            asset: "Pip's scarf", aspect: "colour", observed: "Solid blue", expected: "Solid red", severity: .major)])
        #expect(result.usage?.inputTextTokens == 306)
        #expect(result.usage?.inputImageTokens == 0)
        #expect(result.usage?.outputTextTokens == 71)
        #expect(result.parametersSent == ["model": "gpt-6.1-terra", "store": "false",
                                          "response_format": "consistency_result", "detail": "low"])

        let body = try Self.body(client)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["content"] as? String == "SYS")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["text", "text", "image_url", "text", "image_url"])
        #expect(parts[0]["text"] as? String == "USER")
        #expect(parts[1]["text"] as? String == "Candidate")
        #expect(parts[3]["text"] as? String == "Pip")
        let first = try #require(parts[2]["image_url"] as? [String: Any])
        #expect(first["url"] as? String == "data:image/png;base64,AQID")
        #expect(first["detail"] as? String == "low")
        let second = try #require(parts[4]["image_url"] as? [String: Any])
        #expect(second["url"] as? String == "data:image/jpeg;base64,BAU=")
        let format = try #require(body["response_format"] as? [String: Any])
        #expect((format["json_schema"] as? [String: Any])?["name"] as? String == "consistency_result")
    }

    @Test func detailFollowsCatalogModel() async throws {
        var model = Self.visionModel
        model.imageDetail = "high"
        let client = TestSupport.client(.fixture("SP-7/chat-consistency"))
        let result = try await Self.provider(client).checkConsistency(Self.consistency(model: model))
        #expect(result.parametersSent["detail"] == "high")
        model.imageDetail = nil
        let client2 = TestSupport.client(.fixture("SP-7/chat-consistency"))
        let result2 = try await Self.provider(client2).checkConsistency(Self.consistency(model: model))
        #expect(result2.parametersSent["detail"] == "low")
    }

    @Test func usageSplitsCachedTokens() async throws {
        let json = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"name\":\"A\",\"boxes\":[]}","refusal":null}}],"usage":{"prompt_tokens":100,"completion_tokens":40,"prompt_tokens_details":{"cached_tokens":64}}}"#
        let client = TestSupport.client(Self.response(json))
        let result = try await Self.provider(client).generateLayout(Self.layout)
        #expect(result.usage == TokenUsage(inputTextTokens: 100, inputImageTokens: 0, cachedInputTokens: 64,
                                           outputTextTokens: 40, outputImageTokens: 0))
    }

    @Test func refusalMapsToRefused() async {
        let client = TestSupport.client(Self.chat(refusal: "I can't help with that."))
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client).generateLayout(Self.layout) }
        guard case .refused(let stage, let categories, let raw)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(stage == .output)
        #expect(categories.isEmpty)
        #expect(raw?.body.contains("can't help") == true)
    }

    @Test func contentFilterMapsToRefused() async {
        let client = TestSupport.client(Self.chat(finish: "content_filter"))
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client).checkConsistency(Self.consistency()) }
        guard case .refused(let stage, _, _)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(stage == .unknown)
    }

    @Test(arguments: [
        ("length", "{\"name\":\"A\",\"bo"), ("stop", "not json"), ("stop", "{\"name\":1}"), ("stop", ""),
    ])
    func badContentMapsToInvalidRequest(finish: String, content: String) async {
        let client = TestSupport.client(Self.chat(content: content, finish: finish))
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client).generateLayout(Self.layout) }
        guard case .invalidRequest(let param, let raw)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "response_format")
        #expect(raw?.body.contains(TestSupport.secret) != true)
    }

    @Test func nullContentMapsToInvalidRequest() async {
        let client = TestSupport.client(Self.chat())
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client).generateLayout(Self.layout) }
        guard case .invalidRequest(let param, _)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "response_format")
    }

    @Test func httpErrorsUseTheMapper() async {
        let unauthorized = TestSupport.client(Self.response(#"{"error":{"message":"bad key","code":"invalid_api_key"}}"#, status: 401))
        let e1 = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(unauthorized).generateLayout(Self.layout) }
        guard case .invalidKey? = e1 else { Issue.record("got \(String(describing: e1))"); return }

        let limited = TestSupport.client(Self.response(#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#, status: 429))
        let e2 = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(limited).checkConsistency(Self.consistency()) }
        guard case .rateLimited? = e2 else { Issue.record("got \(String(describing: e2))"); return }
    }

    @Test func missingKeySendsNothing() async {
        let client = TestSupport.client(.fixture("SP-7/chat-template-draft"))
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client, key: nil).generateLayout(Self.layout) }
        #expect(error == .missingKey)
        #expect(client.requests.isEmpty)
    }

    @Test func transportFailuresMap() async {
        let timed = TestSupport.client(.failure(.timedOut(host: "api.openai.com")))
        let e1 = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(timed).generateLayout(Self.layout) }
        #expect(e1 == .timeout)
        let cancelled = TestSupport.client(.failure(.cancelled))
        let e2 = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(cancelled).checkConsistency(Self.consistency()) }
        #expect(e2 == .cancelled)
    }

    @Test func errorBodyNeverCarriesTheKey() async {
        let body = #"{"error":{"message":"bad \#(TestSupport.secret)","code":"invalid_api_key"}}"#
        let client = TestSupport.client(Self.response(body, status: 401))
        let error = await Self.error { () async throws(ProviderError) in _ = try await Self.provider(client).generateLayout(Self.layout) }
        guard case .invalidKey(let raw)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(raw?.body.contains(TestSupport.secret) != true)
    }
}
