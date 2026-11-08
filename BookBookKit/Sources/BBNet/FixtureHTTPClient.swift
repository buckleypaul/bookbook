import Foundation
import Synchronization

/// Replays recorded fixtures (`<name>.json` body + `<name>.meta.json` with `status` and allow-listed
/// `headers`) in place of the network, and remembers every request it received so tests can
/// assert on the JSON that was sent. Used by adapter and queue tests; never by the app.
public final class FixtureHTTPClient: HTTPClient {
    /// What to answer a request with.
    public enum Outcome: Sendable {
        /// A fixture under the client's root, named without extension (e.g. `SP-5/generations-blocked-1`).
        case fixture(String)
        /// A fixture's body and headers with a different status (e.g. serve a 401 body as a generations 401).
        case fixtureWithStatus(String, Int)
        case response(HTTPResponse)
        case failure(HTTPClientError)
    }

    public typealias Responder = @Sendable (_ request: HTTPRequest, _ index: Int) -> Outcome

    private let root: URL
    private let responder: Responder
    private let log = Mutex<[HTTPRequest]>([])

    /// Answers each request with `responder(request, zeroBasedIndex)`.
    public init(root: URL, responder: @escaping Responder) {
        self.root = root
        self.responder = responder
    }

    /// Answers requests in order from `queue`; the last outcome repeats once the queue is used up.
    public convenience init(root: URL, queue: [Outcome]) {
        precondition(!queue.isEmpty, "FixtureHTTPClient needs at least one outcome")
        self.init(root: root) { _, index in queue[min(index, queue.count - 1)] }
    }

    /// Every request received so far, in order.
    public var requests: [HTTPRequest] { log.withLock { $0 } }

    public func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        let index = log.withLock { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        if Task.isCancelled { throw .cancelled }
        let host = request.url.host() ?? "fixture"
        switch responder(request, index) {
        case .failure(let error): throw error
        case .response(let response): return response
        case .fixture(let name): return try load(name, status: nil, host: host)
        case .fixtureWithStatus(let name, let status): return try load(name, status: status, host: host)
        }
    }

    private func load(_ name: String, status: Int?, host: String) throws(HTTPClientError) -> HTTPResponse {
        guard let body = try? Data(contentsOf: root.appending(path: "\(name).json")),
              let metaData = try? Data(contentsOf: root.appending(path: "\(name).meta.json")),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
              let recordedStatus = meta["status"] as? Int else {
            throw .transport(code: URLError.fileDoesNotExist.rawValue, host: host)
        }
        let headers = (meta["headers"] as? [String: String]) ?? [:]
        let millis = (meta["durationMs"] as? Int) ?? 0
        return HTTPResponse(status: status ?? recordedStatus, headers: headers, body: body,
                            duration: .milliseconds(millis))
    }
}
