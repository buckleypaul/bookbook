import BBAICore
import BBModel
import BBNet
import Foundation

/// What every OpenAI endpoint call shares: the HTTP client, the stored key and the base URL.
/// It fetches the key, adds the `Authorization: Bearer` header and maps transport failures and
/// error responses through `OpenAIErrorMapper`. The key goes only into that header and the
/// mapper's redaction checks, never into an error, a log or a description (plan §2.2).
struct OpenAIConnection: Sendable {
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    let http: any HTTPClient
    let apiKey: @Sendable () async -> APIKey?
    let baseURL: URL

    /// The stored key; `.missingKey` when there is none (so nothing is sent).
    func key() async throws(ProviderError) -> APIKey {
        guard let key = await apiKey() else { throw .missingKey }
        return key
    }

    /// Sends `method` to `path` (under the base URL) with `key`'s Bearer header and, when given,
    /// `Content-Type`. Returns the 2xx response; transport failures and non-2xx responses throw
    /// the mapped `ProviderError`, so every endpoint maps them the same way. `received` runs once a
    /// response (any status) has arrived, before the status is checked.
    func send(_ method: String, _ path: String, contentType: String? = nil, body: Data? = nil,
              timeout: TimeInterval = 300, key: APIKey,
              received: () -> Void = {}) async throws(ProviderError) -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(key.revealForTransport())"]
        if let contentType { headers["Content-Type"] = contentType }
        let request = HTTPRequest(method: method, url: baseURL.appending(path: path), headers: headers, body: body,
                                  timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw OpenAIErrorMapper.map(error)
        }
        received()
        guard (200..<300).contains(response.status) else { throw OpenAIErrorMapper.map(response, key: key) }
        return response
    }

    /// The response body's top-level JSON object; `.unknown` with the redacted raw response
    /// when the body isn't one.
    static func jsonRoot(of response: HTTPResponse, key: APIKey) throws(ProviderError) -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw .unknown(OpenAIErrorMapper.raw(response, code: nil, key: key))
        }
        return root
    }
}
