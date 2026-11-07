import Foundation
import Testing
@testable import SpikeKit

@Suite struct EnvironmentAndKeyTests {
    @Test func descriptionIsRedacted() {
        let key = fakeKey()
        #expect(key.description == "<redacted>")
        #expect(key.debugDescription == "<redacted>")
        #expect(!"\(key)".contains(key.value))
        #expect(!String(reflecting: key).contains(key.value))
    }

    @Test func occursFindsKeyBytes() {
        let key = fakeKey()
        #expect(key.occurs(in: Data("prefix \(key.value) suffix".utf8)))
        #expect(!key.occurs(in: Data("nothing here".utf8)))
        #expect(!key.occurs(in: Data()))
    }

    @Test func stringFallback() {
        #expect(LiveEnvironment.string("BOOKBOOK_DEFINITELY_UNSET_VAR_XYZ", default: "fallback") == "fallback")
    }

    @Test func unsetKeyIsNil() {
        // If someone has a Gemini key in the environment this check is meaningless, so skip it then.
        if ProcessInfo.processInfo.environment["GEMINI_API_KEY"] == nil {
            #expect(LiveEnvironment.apiKey(.gemini) == nil)
        }
    }

    @Test func redactedHeadersAnyCase() {
        let out = redactedHeaders(["AUTHORIZATION": "Bearer x", "X-Goog-Api-Key": "k", "content-type": "a/b"])
        #expect(out["AUTHORIZATION"] == "<redacted>")
        #expect(out["X-Goog-Api-Key"] == "<redacted>")
        #expect(out["content-type"] == "a/b")
        #expect(redactedHeaders(["authorization": "z"])["authorization"] == "<redacted>")
    }

    @Test func errorMapping() {
        #expect(HTTPClientError.transport(code: -1009, host: "api.openai.com").description.contains("api.openai.com"))
        #expect(HTTPClientError.timedOut(host: "h").description.contains("h"))
        #expect(!HTTPClientError.cancelled.description.isEmpty)
        #expect(URLSessionHTTPClient.map(URLError(.cancelled), host: "h").description == HTTPClientError.cancelled.description)
        #expect(URLSessionHTTPClient.map(CancellationError(), host: "h").description == HTTPClientError.cancelled.description)
        if case .timedOut(let host) = URLSessionHTTPClient.map(URLError(.timedOut), host: "h") {
            #expect(host == "h")
        } else { Issue.record("expected timedOut") }
        if case .transport(let code, _) = URLSessionHTTPClient.map(URLError(.notConnectedToInternet), host: "h") {
            #expect(code == URLError.notConnectedToInternet.rawValue)
        } else { Issue.record("expected transport") }
    }

    @Test func httpResponseJSON() {
        #expect(okResponse("{\"a\":1}").json?["a"] as? Int == 1)
        #expect(okResponse("[1]").json == nil)
        #expect(okResponse("nope").json == nil)
    }
}

@Suite struct MultipartTests {
    @Test func encodingFormat() {
        var form = MultipartForm(boundary: "BOUNDARY")
        form.addField(name: "prompt", value: "hello")
        form.addFile(name: "image[]", filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let (contentType, body) = form.encoded()
        #expect(contentType == "multipart/form-data; boundary=BOUNDARY")
        var expected = Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nhello\r\n".utf8)
        expected.append(Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        expected.append(Data([1, 2, 3]))
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        #expect(body == expected)
    }

    @Test func emptyFormHasOnlyTerminator() {
        let (_, body) = MultipartForm(boundary: "B").encoded()
        #expect(String(decoding: body, as: UTF8.self) == "--B--\r\n")
    }

    @Test func defaultBoundaryIsUnique() {
        #expect(MultipartForm().encoded().contentType != MultipartForm().encoded().contentType)
    }
}

@Suite struct OpenAIClientTests {
    @Test func getSetsBearerAndURL() async throws {
        let key = fakeKey()
        let mock = MockHTTP { _ in okResponse() }
        let client = OpenAIClient(key: key, http: mock)
        _ = try await client.get("/models")
        let req = try #require(mock.requests.first)
        #expect(req.method == "GET")
        #expect(req.url.absoluteString == "https://api.openai.com/v1/models")
        #expect(req.headers["Authorization"] == "Bearer \(key.value)")
    }

    @Test func postJSONSetsHeadersAndBody() async throws {
        let mock = MockHTTP { _ in okResponse() }
        let client = OpenAIClient(key: fakeKey(), http: mock, baseURL: URL(string: "https://example.test/v1/")!)
        _ = try await client.postJSON("images/generations", json: ["model": "m", "n": 1])
        let req = try #require(mock.requests.first)
        #expect(req.url.absoluteString == "https://example.test/v1/images/generations")
        #expect(req.headers["Content-Type"] == "application/json")
        #expect(req.headers["Authorization"]?.hasPrefix("Bearer ") == true)
        let body = try #require(req.body)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["model"] as? String == "m")
        #expect(obj["n"] as? Int == 1)
    }

    @Test func postMultipartUsesFormContentType() async throws {
        let mock = MockHTTP { _ in okResponse() }
        let client = OpenAIClient(key: fakeKey(), http: mock)
        var form = MultipartForm(boundary: "BB")
        form.addField(name: "a", value: "b")
        _ = try await client.postMultipart("/images/edits", form: form)
        let req = try #require(mock.requests.first)
        #expect(req.headers["Content-Type"] == "multipart/form-data; boundary=BB")
        #expect(req.body == form.encoded().body)
    }

    @Test func invalidJSONThrowsWithoutKey() async {
        let key = fakeKey()
        let mock = MockHTTP { _ in okResponse() }
        let client = OpenAIClient(key: key, http: mock)
        do {
            _ = try await client.postJSON("/x", json: ["bad": Double.nan])
            Issue.record("expected throw")
        } catch {
            #expect(!"\(error)".contains(key.value))
        }
        #expect(mock.requests.isEmpty)
    }

    @Test func nothingPrintableContainsKey() async {
        let key = fakeKey()
        let mock = MockHTTP { req throws(HTTPClientError) in throw .transport(code: -1, host: req.url.host() ?? "?") }
        let client = OpenAIClient(key: key, http: mock)
        #expect(!"\(client)".contains(key.value))
        #expect(!String(reflecting: client).contains(key.value))
        #expect(!String(describing: key).contains(key.value))
        do {
            _ = try await client.get("/models")
            Issue.record("expected throw")
        } catch {
            #expect(!"\(error)".contains(key.value))
            #expect(!String(reflecting: error).contains(key.value))
        }
        #expect(!"\(redactedHeaders(mock.requests[0].headers))".contains(key.value))
    }
}

@Suite struct MaskedKeyTests {
    @Test func redactsProviderMaskedKeyEcho() {
        let masked = "sk-" + "proj-" + String(repeating: "*", count: 40) + "Ab1z"
        let text = "Incorrect API key provided: \(masked). You can find…"
        let out = redactMaskedKeys(text)
        #expect(out == "Incorrect API key provided: sk-REDACTED. You can find…")
        #expect(!out.contains("Ab1z"))
    }
}

@Suite struct ReflectionRedactionTests {
    @Test func dumpDoesNotRevealKeyOrAuthorization() {
        let secret = "sk" + "-" + String(repeating: "q", count: 30)
        let key = APIKey(value: secret)
        var out = ""
        dump(key, to: &out)
        #expect(!out.contains(secret))
        let req = HTTPRequest(method: "GET", url: URL(string: "https://example.com")!,
                              headers: ["Authorization": "Bearer \(secret)"])
        var out2 = ""
        dump(req, to: &out2)
        #expect(!out2.contains(secret))
        #expect(!String(describing: req).contains(secret))
    }
}
