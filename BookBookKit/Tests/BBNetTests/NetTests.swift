import Foundation
import Testing
@testable import BBNet

/// A non-key-shaped secret built at runtime (never a `sk-` string).
private func makeSecret() -> String { "bookbook-test-" + UUID().uuidString }

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "bbnet-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite struct RedactionTests {
    @Test func headersAreRedactedInAnyCase() {
        let out = Redaction.redactedHeaders(["AUTHORIZATION": "Bearer abc", "X-Goog-Api-Key": "k", "Accept": "x"])
        #expect(out["AUTHORIZATION"] == "<redacted>")
        #expect(out["X-Goog-Api-Key"] == "<redacted>")
        #expect(out["Accept"] == "x")
    }

    @Test func requestDescriptionAndDumpHideSecrets() {
        let secret = makeSecret()
        let request = HTTPRequest(method: "POST", url: URL(string: "https://example.com/v1/x")!,
                                  headers: ["Authorization": "Bearer \(secret)", "x-goog-api-key": secret],
                                  body: Data(secret.utf8))
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!request.description.contains(secret))
        #expect(!"\(request)".contains(secret))
        #expect(!String(reflecting: request).contains(secret))
        #expect(!dumped.contains(secret))
        #expect(request.description.contains("<redacted>"))
    }

    @Test func maskedKeyEchoesAreRedacted() {
        let skForm = "Incorrect API key provided: " + "sk-proj-" + "********************" + "abcd. Find it at x."
        let plainForm = "Incorrect API key provided: bookbook*************-key. You can find"
        for text in [skForm, plainForm] {
            let out = Redaction.redactMaskedKeys(text)
            #expect(!out.contains("****"))
            #expect(out.contains("sk-REDACTED"))
        }
        #expect(Redaction.redactMaskedKeys("nothing to see") == "nothing to see")
    }

    @Test func clientErrorDescriptionsCarryNoSecrets() {
        let errors: [HTTPClientError] = [.offline(host: "h"), .timedOut(host: "h"), .cancelled, .transport(code: 1, host: "h")]
        for error in errors { #expect(!error.description.contains("Bearer")) }
    }
}

@Suite struct URLErrorMappingTests {
    @Test(arguments: [
        URLError.Code.notConnectedToInternet, .dataNotAllowed,
        .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ])
    func offlineCodes(code: URLError.Code) {
        #expect(URLSessionHTTPClient.map(URLError(code), host: "h") == .offline(host: "h"))
    }

    @Test func timeoutCancelAndOther() {
        #expect(URLSessionHTTPClient.map(URLError(.timedOut), host: "h") == .timedOut(host: "h"))
        #expect(URLSessionHTTPClient.map(URLError(.cancelled), host: "h") == .cancelled)
        #expect(URLSessionHTTPClient.map(CancellationError(), host: "h") == .cancelled)
        #expect(URLSessionHTTPClient.map(URLError(.badURL), host: "h") == .transport(code: URLError.badURL.rawValue, host: "h"))
        #expect(URLSessionHTTPClient.map(NSError(domain: "x", code: 7), host: "h") == .transport(code: 7, host: "h"))
    }

    @Test func cancellingTheTaskThrowsCancelled() async {
        // A non-routable address would hang; cancel straight away and expect `.cancelled`
        // (or `.offline` on a machine with no network at all, where the connect fails first).
        let client = URLSessionHTTPClient()
        let task = Task {
            do throws(HTTPClientError) {
                _ = try await client.send(HTTPRequest(method: "GET", url: URL(string: "http://10.255.255.1/")!, timeout: 30))
                return HTTPClientError.transport(code: 0, host: "none")
            } catch { return error }
        }
        task.cancel()
        let error = await task.value
        #expect(error == .cancelled || { if case .offline = error { true } else { false } }())
    }
}

@Suite struct MultipartTests {
    @Test func encodesFieldsAndFiles() {
        var form = MultipartForm(boundary: "B")
        form.addField(name: "prompt", value: "a \"cat\"")
        form.addFile(name: "image[]", filename: "a\"b.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let (contentType, body) = form.encoded()
        #expect(contentType == "multipart/form-data; boundary=B")
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\na \"cat\"\r\n".utf8)
        expected.append(Data("--B\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"a%22b.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        expected.append(Data([1, 2, 3]))
        expected.append(Data("\r\n--B--\r\n".utf8))
        #expect(body == expected)
    }
}

@Suite struct FixtureRecorderTests {
    private func response(_ body: String, headers: [String: String] = [:], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8), duration: .milliseconds(250))
    }

    @Test func refusesToWriteWhenKeyBytesAppear() throws {
        let secret = makeSecret()
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FixtureRecorder(directory: dir, containsSecret: { $0.range(of: Data(secret.utf8)) != nil }, recording: true)
        #expect(throws: FixtureRecorderError.self) {
            try recorder.record(response("{\"echo\":\"\(secret)\"}"), name: "leak")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "leak.json").path))
    }

    @Test func refusesKeyShapedStrings() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FixtureRecorder(directory: dir, containsSecret: { _ in false }, recording: true)
        let shaped = "sk-" + String(repeating: "a", count: 30)
        #expect(throws: FixtureRecorderError.self) { try recorder.record(response("{\"x\":\"\(shaped)\"}"), name: "shaped") }
    }

    @Test func keepsOnlyAllowedHeadersAndAppliesPlaceholders() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FixtureRecorder(directory: dir, containsSecret: { _ in false }, recording: true)
        let body = """
        {"error":{"message":"org-abc123def456 proj_abc123def456 bookbook*************-key"},
         "data":[{"b64_json":"AAAA"}]}
        """
        try recorder.record(
            response(body, headers: ["Content-Type": "application/json", "Set-Cookie": "a=b", "X-Request-Id": "req_1",
                                     "x-ratelimit-remaining": "9", "openai-organization": "org-zzzzzzzzzz",
                                     "Retry-After": "3"], status: 400),
            name: "case")
        let meta = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appending(path: "case.meta.json"))) as? [String: Any])
        #expect(meta["status"] as? Int == 400)
        #expect(meta["durationMs"] as? Int == 250)
        let headers = try #require(meta["headers"] as? [String: String])
        #expect(Set(headers.keys) == ["content-type", "x-request-id", "x-ratelimit-remaining", "retry-after"])
        let text = try String(contentsOf: dir.appending(path: "case.json"), encoding: .utf8)
        #expect(text.contains("org-PLACEHOLDER") && text.contains("proj_PLACEHOLDER") && text.contains("sk-REDACTED"))
        #expect(!text.contains("org-abc123def456") && !text.contains("****"))
        #expect(!text.contains("\"AAAA\""))  // image replaced by the placeholder PNG
    }

    @Test func doesNothingWhenNotRecording() {
        let dir = tempDirectory()
        let recorder = FixtureRecorder(directory: dir, containsSecret: { _ in false }, recording: false)
        #expect(throws: Never.self) { try recorder.record(response("{}"), name: "x") }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite struct FixtureHTTPClientTests {
    @Test func replaysFixturesInOrderAndRecordsRequests() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FixtureRecorder(directory: dir, containsSecret: { _ in false }, recording: true)
        try recorder.record(HTTPResponse(status: 429, headers: ["retry-after": "2"], body: Data("{\"a\":1}".utf8)), name: "limited")
        let client = FixtureHTTPClient(root: dir, queue: [.fixture("limited"), .failure(.offline(host: "h"))])
        let url = URL(string: "https://example.com/x")!
        let first = try await client.send(HTTPRequest(method: "POST", url: url, body: Data("one".utf8)))
        #expect(first.status == 429 && first.headers["retry-after"] == "2")
        await #expect(throws: HTTPClientError.offline(host: "h")) {
            _ = try await client.send(HTTPRequest(method: "POST", url: url, body: Data("two".utf8)))
        }
        #expect(client.requests.map { $0.body.map { String(decoding: $0, as: UTF8.self) } } == ["one", "two"])
    }

    @Test func missingFixtureIsATransportError() async {
        let client = FixtureHTTPClient(root: tempDirectory(), queue: [.fixture("nope")])
        await #expect(throws: HTTPClientError.self) {
            _ = try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://example.com")!))
        }
    }
}
