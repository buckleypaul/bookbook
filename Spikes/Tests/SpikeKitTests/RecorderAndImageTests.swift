import Foundation
import Testing
@testable import SpikeKit

@Suite struct RecorderTests {
    private func resp(_ body: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: 200, headers: headers, body: Data(body.utf8), duration: .milliseconds(1234))
    }
    private func read(_ root: URL, _ rel: String) throws -> Data { try Data(contentsOf: root.appending(path: rel)) }
    private func exists(_ root: URL, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: rel).path) }

    @Test func headerAllowlist() {
        for h in ["content-type", "retry-after", "x-request-id", "x-ratelimit-remaining-tokens"] { #expect(FixtureRecorder.isAllowedHeader(h)) }
        for h in ["authorization", "set-cookie", "openai-organization", "openai-project", "x-goog-api-key"] { #expect(!FixtureRecorder.isAllowedHeader(h)) }
    }

    @Test func defaultRootIsSpikesFixtures() {
        let root = FixtureRecorder.defaultRoot()
        #expect(root.lastPathComponent == "Fixtures")
        #expect(root.deletingLastPathComponent().lastPathComponent == "Spikes")
    }

    @Test func noOpWhenNotRecording() throws {
        guard !LiveEnvironment.isRecording else { return }
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .openai, spike: "SP1", key: fakeKey(), root: dir)
        try rec.record(resp("{}"), name: "x")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func writesBodyAndMeta() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .openai, spike: "SP1_models", key: fakeKey(), root: dir, forceRecording: true)
        let r = resp(#"{"b":1,"a":"x/y"}"#, headers: ["content-type": "application/json", "Authorization": "Bearer nope", "x-ratelimit-limit-requests": "5", "openai-organization": "org-abc"])
        try rec.record(r, name: "list")
        let body = String(decoding: try read(dir, "openai/SP1_models/list.json"), as: UTF8.self)
        #expect(body.contains("\"a\" : \"x/y\""))
        let a = try #require(body.range(of: "\"a\""))
        let b = try #require(body.range(of: "\"b\""))
        #expect(a.lowerBound < b.lowerBound)  // sorted keys
        let meta = try #require(JSONSerialization.jsonObject(with: read(dir, "openai/SP1_models/list.meta.json")) as? [String: Any])
        #expect(meta["status"] as? Int == 200)
        #expect(meta["durationMs"] as? Int == 1234)
        let headers = try #require(meta["headers"] as? [String: String])
        #expect(headers == ["content-type": "application/json", "x-ratelimit-limit-requests": "5"])
    }

    @Test func replacesImagesAndIDs() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .gemini, spike: "SG", key: fakeKey(), root: dir, forceRecording: true)
        let big = Data(repeating: 7, count: 5000).base64EncodedString()
        let body = #"{"data":[{"b64_json":"\#(big)"}],"c":[{"inlineData":{"mimeType":"image/png","data":"\#(big)"}}],"org":"org-abc123XYZ","p":"proj_abcDEF123","other":{"data":"keep"}}"#
        try rec.record(resp(body), name: "gen")
        let text = String(decoding: try read(dir, "gemini/SG/gen.json"), as: UTF8.self)
        let placeholder = TestImages.placeholder().base64EncodedString()
        #expect(!text.contains(big))
        #expect(text.components(separatedBy: placeholder).count == 3)  // two substitutions
        #expect(text.contains("org-PLACEHOLDER") && text.contains("proj_PLACEHOLDER"))
        #expect(!text.contains("abc123XYZ"))
        #expect(text.contains("\"keep\""))

        try rec.record(resp(body), name: "real", keepRealImage: true)
        let real = String(decoding: try read(dir, "gemini/SG/real.json"), as: UTF8.self)
        #expect(real.contains(big))
        #expect(real.contains("org-PLACEHOLDER"))
    }

    @Test func nonJSONWrittenRaw() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .openai, spike: "S", key: fakeKey(), root: dir, forceRecording: true)
        try rec.record(resp("plain text org-abcdef1234"), name: "t")
        #expect(String(decoding: try read(dir, "openai/S/t.json"), as: UTF8.self) == "plain text org-PLACEHOLDER")
    }

    @Test func refusesWhenBodyContainsKey() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A key that does not match the secret patterns, so only occurs(in:) can catch it.
        let rec = FixtureRecorder(provider: .openai, spike: "S", key: APIKey(value: "plain-test-key-value"), root: dir, forceRecording: true)
        #expect(throws: FixtureRecorderError.self) { try rec.record(resp(#"{"echo":"plain-test-key-value"}"#), name: "bad") }
        #expect(!exists(dir, "openai/S/bad.json"))
        #expect(!exists(dir, "openai/S/bad.meta.json"))
    }

    @Test func refusesSecretPatterns() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .openai, spike: "S", key: APIKey(value: "unrelated-key"), root: dir, forceRecording: true)
        let openAIShaped = "s" + "k-" + String(repeating: "q", count: 24)
        let googleShaped = "AI" + "za" + String(repeating: "Z", count: 35)
        for secret in [openAIShaped, googleShaped] {
            let r = resp(#"{"m":"\#(secret)"}"#)
            #expect(throws: FixtureRecorderError.self) { try rec.record(r, name: "bad") }
        }
        #expect(!exists(dir, "openai/S/bad.json"))
        // A short fragment is fine.
        try rec.record(resp(#"{"m":"task-force sk-short"}"#), name: "ok")
        #expect(exists(dir, "openai/S/ok.json"))
    }

    @Test func rejectsPathyNames() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rec = FixtureRecorder(provider: .openai, spike: "S", key: fakeKey(), root: dir, forceRecording: true)
        #expect(throws: FixtureRecorderError.self) { try rec.record(resp("{}"), name: "../escape") }
    }

    @Test func errorDescriptionsDoNotLeak() {
        #expect(!FixtureRecorderError.containsKey(file: "a.json").description.isEmpty)
        #expect(!FixtureRecorderError.writeFailed(file: "a.json").description.isEmpty)
    }
}

@Suite struct TestImageTests {
    private let colors = [RGB(255, 0, 0), RGB(0, 255, 0), RGB(0, 0, 255), RGB(255, 255, 0)]

    @Test func quadrantsDecodeToRightColours() throws {
        let img = try #require(TestImages.decode(TestImages.quadrants(size: 64, colors: colors)))
        #expect(img.width == 64 && img.height == 64)
        for (q, c) in zip(Quadrant.allCases, colors) {
            #expect(img.meanColor(of: q) == c, "quadrant \(q)")
            #expect(img.fraction(of: q, near: c, tolerance: 2) == 1)
        }
        #expect(img.pixel(x: 0, y: 0) == colors[0])
        #expect(img.pixel(x: 63, y: 0) == colors[1])
        #expect(img.pixel(x: 0, y: 63) == colors[2])
        #expect(img.pixel(x: 63, y: 63) == colors[3])
        #expect(img.alpha(x: 5, y: 5) == 255)
    }

    @Test func maskAlphaPerQuadrant() throws {
        let img = try #require(TestImages.decode(TestImages.mask(size: 32, transparent: [.topLeft, .bottomRight])))
        #expect(img.alpha(x: 2, y: 2) == 0)
        #expect(img.alpha(x: 29, y: 29) == 0)
        #expect(img.alpha(x: 29, y: 2) == 255)
        #expect(img.alpha(x: 2, y: 29) == 255)
    }

    @Test func solidAndDistance() throws {
        let img = try #require(TestImages.decode(TestImages.solid(width: 8, height: 4, color: RGB(10, 20, 30))))
        #expect(img.width == 8 && img.height == 4)
        #expect(img.pixel(x: 7, y: 3) == RGB(10, 20, 30))
        #expect(RGB(0, 0, 0).distance(to: RGB(3, 4, 0)) == 5)
    }

    @Test func noiseIsDeterministicAndIncompressible() throws {
        let a = TestImages.noise(width: 64, height: 64, seed: 1)
        #expect(a == TestImages.noise(width: 64, height: 64, seed: 1))
        #expect(a != TestImages.noise(width: 64, height: 64, seed: 2))
        #expect(a.count > 12_000)  // 64*64*3 random bytes barely compress
        let img = try #require(TestImages.decode(a))
        #expect(img.width == 64 && img.height == 64)
    }

    @Test func placeholderIs64Square() throws {
        let img = try #require(TestImages.decode(TestImages.placeholder()))
        #expect(img.width == 64 && img.height == 64)
    }

    @Test func decodeGarbageIsNil() {
        #expect(TestImages.decode(Data("not an image".utf8)) == nil)
    }
}
