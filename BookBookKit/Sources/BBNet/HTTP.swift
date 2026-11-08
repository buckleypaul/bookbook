import Foundation

// Phase 2 contract (main thread). The Net+OpenAI lane adds URLSessionHTTPClient,
// FixtureHTTPClient, MultipartForm, Redaction and FixtureRecorder in their own files.

/// Description and mirror redact headers (`Redaction.redactedHeaders`) and omit the body, so
/// printing or dumping a request can't expose the `Authorization` / `x-goog-api-key` header.
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomReflectable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 300) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public var description: String { "\(method) \(url.absoluteString) headers=\(Redaction.redactedHeaders(headers))" }

    public var customMirror: Mirror {
        Mirror(self, children: ["method": method, "url": url, "headers": Redaction.redactedHeaders(headers)])
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data
    public var duration: Duration

    public init(status: Int, headers: [String: String], body: Data, duration: Duration = .zero) {
        self.status = status
        self.headers = headers
        self.body = body
        self.duration = duration
    }
}

/// Transport errors. Descriptions contain only the host and a URLError code; never headers or bodies.
public enum HTTPClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No network (`notConnectedToInternet`, `networkConnectionLost`, `dataNotAllowed`, …).
    case offline(host: String)
    case timedOut(host: String)
    case cancelled
    case transport(code: Int, host: String)

    public var description: String {
        switch self {
        case .offline(let host): "offline (talking to \(host))"
        case .timedOut(let host): "request to \(host) timed out"
        case .cancelled: "request cancelled"
        case .transport(let code, let host): "transport error (code \(code)) talking to \(host)"
        }
    }
}

public protocol HTTPClient: Sendable {
    /// Honours Swift task cancellation: cancelling the calling Task cancels the underlying
    /// request and throws `HTTPClientError.cancelled`.
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse
}

/// Redaction helpers (A §7.11, §7.12). Implemented by the Net lane in `Redaction.swift`.
public enum Redaction {}
