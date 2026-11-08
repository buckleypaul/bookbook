import Foundation
import os

/// Production `HTTPClient` over an ephemeral `URLSession` (architecture.md §7.12).
///
/// Logs only host, status and duration (`privacy: .public`); never URLs with query strings,
/// headers or bodies.
public struct URLSessionHTTPClient: HTTPClient {
    private static let logger = Logger(subsystem: "app.bookbook", category: "net")
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        let host = request.url.host() ?? "unknown-host"
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            // `URLSession.data(for:)` cancels the underlying task when the calling Task is cancelled
            // and throws `URLError.cancelled`, which maps to `.cancelled`.
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            let mapped = Self.map(error, host: host)
            Self.logger.info("request to \(host, privacy: .public) failed: \(mapped.description, privacy: .public)")
            throw mapped
        }
        let elapsed = clock.now - start
        guard let http = response as? HTTPURLResponse else {
            throw .transport(code: URLError.badServerResponse.rawValue, host: host)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        let millis = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.logger.info("\(host, privacy: .public) status \(http.statusCode, privacy: .public) in \(millis, privacy: .public) ms")
        return HTTPResponse(status: http.statusCode, headers: headers, body: data, duration: elapsed)
    }

    /// URLError codes that mean "no usable network".
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]

    static func map(_ error: any Error, host: String) -> HTTPClientError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            if offlineCodes.contains(urlError.code) { return .offline(host: host) }
            switch urlError.code {
            case .timedOut: return .timedOut(host: host)
            case .cancelled: return .cancelled
            default: return .transport(code: urlError.code.rawValue, host: host)
            }
        }
        return .transport(code: (error as NSError).code, host: host)
    }
}
