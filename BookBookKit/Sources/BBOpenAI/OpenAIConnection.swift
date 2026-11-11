import BBAICore
import BBModel
import BBNet
import Foundation

/// What every OpenAI endpoint call shares: the HTTP client, the stored key and the base URL.
/// It fetches the key, adds the `Authorization: Bearer` header and maps transport failures and
/// error responses through `OpenAIErrorMapper`. The key goes only into that header and the
/// mapper's redaction checks, never into an error, a log or a description (plan §2.2).
struct OpenAIConnection: Sendable {
    let http: any HTTPClient
    let apiKey: @Sendable () async -> APIKey?
    let baseURL: URL

    /// The stored key; `.missingKey` when there is none (so nothing is sent).
    func key() async throws(ProviderError) -> APIKey {
        guard let key = await apiKey() else { throw .missingKey }
        return key
    }

    /// Sends `method` to `path` (under the base URL) with `key`'s Bearer header and, when given,
    /// `Content-Type`. Returns the 2xx response; anything else throws the mapped error.
    /// `received` runs once a response (any status) has arrived.
    func send(_ method: String, _ path: String, contentType: String? = nil, body: Data? = nil,
              timeout: TimeInterval = 300, key: APIKey,
              received: () -> Void = {}) async throws(ProviderError) -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(key.revealForTransport())"]
        if let contentType { headers["Content-Type"] = contentType }
        let request = HTTPRequest(method: method, url: baseURL.appending(path: path), headers: headers, body: body,
                                  timeout: timeout)
        return try await OpenAIErrorMapper.send(request, via: http, key: key, received: received)
    }
}
