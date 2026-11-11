import BBAICore
import BBModel
import BBNet
import Foundation

/// `GET /v1/models` with the stored key: "Test connection" and the Settings model-churn check
/// (architecture.md §7.1). Sends no book data, only the `Authorization` header.
public struct OpenAIModelLister: ModelLister {
    public var id: ProviderID { .openai }

    private let connection: OpenAIConnection

    public init(http: any HTTPClient, apiKey: @escaping @Sendable () async -> APIKey?,
                baseURL: URL = OpenAIImageProvider.defaultBaseURL) {
        self.connection = OpenAIConnection(http: http, apiKey: apiKey, baseURL: baseURL)
    }

    public func listModelIDs() async throws(ProviderError) -> Set<String> {
        let key = try await connection.key()
        let response = try await connection.send("GET", "models", timeout: 60, key: key)
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            throw .unknown(OpenAIErrorMapper.raw(response, code: nil, key: key))
        }
        return Set(data.compactMap { $0["id"] as? String })
    }
}
