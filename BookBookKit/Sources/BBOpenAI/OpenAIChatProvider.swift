import BBAICore
import BBModel
import BBNet
import Foundation
import UniformTypeIdentifiers

/// OpenAI Chat Completions adapter for the layout (structured output) and consistency (vision)
/// requests (architecture.md §7.7, §7.8; plan P-5): `store: false`, strict `json_schema`.
public struct OpenAIChatProvider: LayoutProvider, VisionProvider {
    public static let defaultBaseURL = OpenAIImageProvider.defaultBaseURL

    public var id: ProviderID { .openai }

    private let http: any HTTPClient
    private let apiKey: @Sendable () async -> APIKey?
    private let baseURL: URL

    public init(http: any HTTPClient, apiKey: @escaping @Sendable () async -> APIKey?,
                baseURL: URL = OpenAIChatProvider.defaultBaseURL) {
        self.http = http
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func generateLayout(_ request: LayoutRequest) async throws(ProviderError) -> LayoutResult {
        let messages: [[String: Any]] = [
            ["role": "system", "content": request.system],
            ["role": "user", "content": request.user],
        ]
        let reply = try await send(model: request.model.id, messages: messages,
                                   name: StructuredSchemas.templateDraftName, schema: StructuredSchemas.templateDraft)
        let draft: TemplateDraft = try reply.decode()
        return LayoutResult(draft: draft, usage: reply.usage, parametersSent: reply.parameters)
    }

    public func checkConsistency(_ request: ConsistencyRequest) async throws(ProviderError) -> ConsistencyResult {
        let detail = request.model.imageDetail ?? "low"
        var content: [[String: Any]] = [["type": "text", "text": request.user]]
        for image in [request.image] + request.references {
            guard let mime = Self.mimeType(image.payload.contentType) else {
                throw .invalidRequest(param: "image_url", nil)
            }
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image_url", "image_url": [
                "url": "data:\(mime);base64,\(image.payload.data.base64EncodedString())", "detail": detail,
            ] as [String: Any]])
        }
        let messages: [[String: Any]] = [
            ["role": "system", "content": request.system],
            ["role": "user", "content": content],
        ]
        var reply = try await send(model: request.model.id, messages: messages,
                                   name: StructuredSchemas.consistencyName, schema: StructuredSchemas.consistency)
        reply.parameters["detail"] = detail
        let decoded: ConsistencyPayload = try reply.decode()
        return ConsistencyResult(consistent: decoded.consistent, differences: decoded.differences,
                                 usage: reply.usage, parametersSent: reply.parameters)
    }

    // MARK: Wire

    private struct ConsistencyPayload: Decodable {
        var consistent: Bool
        var differences: [ConsistencyDifference]
    }

    private struct Reply {
        var content: String
        var usage: TokenUsage?
        var parameters: [String: String]
        var raw: ProviderErrorRaw

        func decode<T: Decodable>() throws(ProviderError) -> T {
            do {
                return try JSONDecoder().decode(T.self, from: Data(content.utf8))
            } catch {
                throw .invalidRequest(param: "response_format", raw)
            }
        }
    }

    static func mimeType(_ identifier: String) -> String? {
        guard let type = UTType(identifier) ?? UTType(mimeType: identifier) else { return nil }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .webP) { return "image/webp" }
        return nil
    }

    private func send(model: String, messages: [[String: Any]], name: String,
                      schema: String) async throws(ProviderError) -> Reply {
        guard let key = await apiKey() else { throw .missingKey }
        guard let schemaObject = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) else {
            throw .invalidRequest(param: "response_format", nil)
        }
        let body: [String: Any] = [
            "model": model,
            "store": false,
            "messages": messages,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": name, "strict": true, "schema": schemaObject] as [String: Any],
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw .invalidRequest(param: nil, nil)
        }
        let httpRequest = HTTPRequest(
            method: "POST", url: baseURL.appending(path: "chat/completions"),
            headers: ["Authorization": "Bearer \(key.revealForTransport())", "Content-Type": "application/json"],
            body: data)

        let response = try await OpenAIErrorMapper.send(httpRequest, via: http, key: key)

        let raw = OpenAIErrorMapper.raw(response, code: nil, key: key)
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first else {
            throw .unknown(raw)
        }
        let message = choice["message"] as? [String: Any]
        let finish = choice["finish_reason"] as? String
        if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
            throw .refused(stage: .output, categories: [], raw)
        }
        if finish == "content_filter" { throw .refused(stage: .unknown, categories: [], raw) }
        guard finish != "length", let content = message?["content"] as? String, !content.isEmpty else {
            throw .invalidRequest(param: "response_format", raw)
        }
        return Reply(content: content, usage: OpenAIUsage.parse(root["usage"]),
                     parameters: ["model": model, "store": "false", "response_format": name], raw: raw)
    }
}
