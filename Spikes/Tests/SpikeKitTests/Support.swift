import Foundation
import Synchronization
@testable import SpikeKit

/// Fake keys are built at runtime so no key-shaped literal appears in the source (secret scan).
func fakeKeyString(_ tail: String = "ABCDEFGHIJKLMNOPQRSTUVWX1234") -> String { "s" + "k-" + "proj-" + tail }
func fakeKey(_ tail: String = "ABCDEFGHIJKLMNOPQRSTUVWX1234") -> APIKey { APIKey(value: fakeKeyString(tail)) }

final class MockHTTP: HTTPClient {
    private let seen = Mutex<[HTTPRequest]>([])
    private let handler: @Sendable (HTTPRequest) throws(HTTPClientError) -> HTTPResponse
    init(_ handler: @escaping @Sendable (HTTPRequest) throws(HTTPClientError) -> HTTPResponse) { self.handler = handler }
    var requests: [HTTPRequest] { seen.withLock { $0 } }
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        seen.withLock { $0.append(request) }
        return try handler(request)
    }
}

func okResponse(_ json: String = "{}") -> HTTPResponse {
    HTTPResponse(status: 200, headers: [:], body: Data(json.utf8), duration: .milliseconds(5))
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "spikekit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
