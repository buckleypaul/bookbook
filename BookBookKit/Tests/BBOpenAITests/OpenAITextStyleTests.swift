import BBAICore
import BBModel
import BBNet
import Foundation
import Testing
@testable import BBOpenAI

// Offline tests for AI text styling (A §7.13): the chat adapter's text-style request and the
// image adapter's transparent-background parameter. Responses are written inline.

@Suite struct OpenAITextStyleTests {
    static let request = TextStyleRequest(model: OpenAIChatProviderTests.textModel, system: "SYS", user: "USER")

    static let draftJSON = #"""
    {"fontFamily":"Georgia","fontSize":28,"textColor":"#3A2A10","alignment":"center","textInset":0.12,"panelColor":null,"decoration":"A gold storybook frame with vines.","summary":"A golden vine frame."}
    """#

    @Test func styleTextDecodesDraftAndSendsStrictSchema() async throws {
        let usage: [String: Any] = ["prompt_tokens": 400, "completion_tokens": 120]
        let message: [String: Any] = ["role": "assistant", "refusal": NSNull(), "content": Self.draftJSON]
        let root: [String: Any] = ["choices": [["finish_reason": "stop", "index": 0, "message": message]], "usage": usage]
        let data = try JSONSerialization.data(withJSONObject: root)
        let client = TestSupport.client(.response(HTTPResponse(status: 200, headers: [:], body: data, duration: .zero)))

        let result = try await OpenAIChatProviderTests.provider(client).styleText(Self.request)

        #expect(result.draft == TextStyleDraft(fontFamily: "Georgia", fontSize: 28, textColor: "#3A2A10",
                                               alignment: .center, textInset: 0.12, panelColor: nil,
                                               decoration: "A gold storybook frame with vines.",
                                               summary: "A golden vine frame."))
        #expect(result.usage == TokenUsage(inputTextTokens: 400, inputImageTokens: 0, cachedInputTokens: 0,
                                           outputTextTokens: 120, outputImageTokens: 0))
        #expect(result.parametersSent == ["model": "gpt-6-luna", "store": "false", "response_format": "text_style"])

        let sent = try #require(client.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        let body = try OpenAIChatProviderTests.body(client)
        #expect(body["store"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.map { $0["content"] as? String } == ["SYS", "USER"])
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "text_style")
        #expect(schema["strict"] as? Bool == true)
        let object = try #require(schema["schema"] as? [String: Any])
        #expect(object["additionalProperties"] as? Bool == false)
        #expect((object["required"] as? [String])?.count == 8)
    }

    @Test func nullsDecodeAsKeep() async throws {
        let content = #"{"fontFamily":null,"fontSize":null,"textColor":null,"alignment":null,"textInset":0,"panelColor":null,"decoration":null,"summary":"Kept it simple."}"#
        let client = TestSupport.client(OpenAIChatProviderTests.chat(content: content))
        let result = try await OpenAIChatProviderTests.provider(client).styleText(Self.request)
        #expect(result.draft == TextStyleDraft(summary: "Kept it simple."))
    }

    @Test func refusalMapsToRefused() async {
        let client = TestSupport.client(OpenAIChatProviderTests.chat(refusal: "I can't help with that."))
        let error = await OpenAIChatProviderTests.error { () async throws(ProviderError) in
            _ = try await OpenAIChatProviderTests.provider(client).styleText(Self.request)
        }
        guard case .refused(let stage, _, _)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(stage == .output)
    }

    @Test func badContentMapsToInvalidRequest() async {
        let client = TestSupport.client(OpenAIChatProviderTests.chat(content: #"{"summary":1}"#))
        let error = await OpenAIChatProviderTests.error { () async throws(ProviderError) in
            _ = try await OpenAIChatProviderTests.provider(client).styleText(Self.request)
        }
        guard case .invalidRequest(let param, _)? = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "response_format")
    }

    @Test func missingKeySendsNothing() async {
        let client = TestSupport.client(OpenAIChatProviderTests.chat(content: Self.draftJSON))
        let error = await OpenAIChatProviderTests.error { () async throws(ProviderError) in
            _ = try await OpenAIChatProviderTests.provider(client, key: nil).styleText(Self.request)
        }
        #expect(error == .missingKey)
        #expect(client.requests.isEmpty)
    }

    // MARK: Transparent background

    static func imageRequest(transparent: Bool, modelSupports: Bool) -> ImageRequest {
        var request = TestSupport.request()
        request.model.image.supportsTransparentBackground = modelSupports
        request.transparentBackground = transparent
        return request
    }

    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func backgroundIsTransparentOnlyWhenAskedAndSupported(asked: Bool, supported: Bool, sent: Bool) throws {
        let parameters = try OpenAIImageProvider.parameters(for: Self.imageRequest(transparent: asked,
                                                                                   modelSupports: supported))
        #expect((parameters["background"] as? String == "transparent") == sent)
        #expect(sent || parameters["background"] == nil)
    }

    @Test func transparentBackgroundLandsInBodyAndParametersSent() async throws {
        let client = TestSupport.client(.fixture("SP-2/generations-low-1024x1024"))
        let result = try await TestSupport.provider(client).generate(
            Self.imageRequest(transparent: true, modelSupports: true), progress: { _ in })
        let sentBody = try #require(client.requests.first?.body)
        let json = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["background"] as? String == "transparent")
        #expect(result.parametersSent["background"] == "transparent")
    }
}
