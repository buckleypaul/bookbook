import BBAICore
import BBModel
import BBNet
import Foundation
import Testing
@testable import BBOpenAI

// Offline tests for `POST /v1/images/edits` (Phase 8 L2). Fixture: SP-3 edits response.

@Suite struct OpenAIEditsTests {
    static let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    static let fixture = "SP-3/edits-base-plus-3-refs-1024"

    static func payload(_ bytes: Data = fakePNG, type: String = "public.png", size: PixelSize? = nil) -> ImagePayload {
        ImagePayload(data: bytes, contentType: type, pixelSize: size)
    }

    static func reference(_ payload: ImagePayload = payload()) -> ReferenceImage {
        ReferenceImage(payload: payload, sent: SentReference(image: ImageRef(sha256: "00", contentType: "public.png"), role: "style", label: "test"))
    }

    static func editRequest(base: ImagePayload? = payload(size: PixelSize(width: 1024, height: 1536)),
                            references: [ReferenceImage] = [],
                            exactSize: PixelSize? = PixelSize(width: 1024, height: 1536)) -> ImageRequest {
        var request = TestSupport.request(boxAspect: 1, exactSize: exactSize)
        request.baseImage = base
        request.references = references
        return request
    }

    static func provider(_ client: FixtureHTTPClient) -> OpenAIImageProvider {
        OpenAIImageProvider(http: client, apiKey: { APIKey(TestSupport.secret) }, boundary: { "TESTBOUNDARY" })
    }

    static func emptyClient() -> FixtureHTTPClient {
        TestSupport.client(.fixture(fixture))  // never consumed: these tests expect no network call
    }

    @Test func generationsWhenNoImages() async throws {
        let client = TestSupport.client(.fixture("SP-2/generations-low-1024x1024"))
        _ = try await Self.provider(client).generate(Self.editRequest(base: nil), progress: { _ in })
        #expect(client.requests.first?.url.lastPathComponent == "generations")
    }

    @Test func editsBodyGolden() async throws {
        let client = TestSupport.client(.fixture(Self.fixture))
        let request = Self.editRequest(references: [Self.reference(Self.payload(type: "public.jpeg"))])
        let result = try await Self.provider(client).generate(request, progress: { _ in })

        let sent = try #require(client.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/images/edits")
        #expect(sent.headers["Content-Type"] == "multipart/form-data; boundary=TESTBOUNDARY")
        #expect(sent.headers["Authorization"] == "Bearer \(TestSupport.secret)")
        let body = try #require(sent.body)

        var expected = Data()
        func add(_ text: String) { expected.append(Data(text.utf8)) }
        func file(_ name: String, _ mime: String) {
            add("--TESTBOUNDARY\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n")
            expected.append(Self.fakePNG)
            add("\r\n")
        }
        func field(_ name: String, _ value: String) {
            add("--TESTBOUNDARY\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        file("image1.png", "image/png")
        file("image2.jpg", "image/jpeg")
        field("prompt", "Watercolour.\n\nA fox in a hat.")
        field("model", "gpt-image-2.5-sunburst")
        field("moderation", "auto")
        field("n", "1")
        field("output_format", "png")
        field("quality", "low")
        field("size", "1024x1536")
        add("--TESTBOUNDARY--\r\n")
        #expect(body == expected)
        #expect(!String(decoding: body, as: UTF8.self).contains(TestSupport.secret))
        #expect(!String(decoding: body, as: UTF8.self).contains("Authorization"))

        #expect(result.parametersSent == [
            "model": "gpt-image-2.5-sunburst", "size": "1024x1536", "quality": "low",
            "output_format": "png", "n": "1", "moderation": "auto",
        ])
        #expect(result.usage == TokenUsage(inputTextTokens: 95, inputImageTokens: 1792, cachedInputTokens: 0,
                                           outputTextTokens: 0, outputImageTokens: 196))
        #expect(result.contentType == "public.png")
    }

    @Test func sizeIsExplicitFromRequestWithoutBasePixelSize() async throws {
        let client = TestSupport.client(.fixture(Self.fixture))
        let request = Self.editRequest(base: nil, references: [Self.reference()], exactSize: PixelSize(width: 1232, height: 816))
        let result = try await Self.provider(client).generate(request, progress: { _ in })
        #expect(client.requests.first?.url.lastPathComponent == "edits")
        #expect(result.parametersSent["size"] == "1232x816")
        let text = String(decoding: try #require(client.requests.first?.body), as: UTF8.self)
        #expect(text.contains("name=\"size\"\r\n\r\n1232x816\r\n"))
    }

    @Test func editSizeIsRequestSizeNotRawBaseSize() async throws {
        let client = TestSupport.client(.fixture(Self.fixture))
        let base = Self.payload(size: PixelSize(width: 2550, height: 3300))
        let request = Self.editRequest(base: base, exactSize: PixelSize(width: 1152, height: 1488))
        let result = try await Self.provider(client).generate(request, progress: { _ in })
        #expect(result.parametersSent["size"] == "1152x1488")
    }

    @Test func sixteenImagesAllowedSeventeenRejected() async throws {
        let ok = TestSupport.client(.fixture(Self.fixture))
        let refs15 = Array(repeating: Self.reference(), count: 15)
        _ = try await Self.provider(ok).generate(Self.editRequest(references: refs15), progress: { _ in })
        #expect(ok.requests.count == 1)

        let client = Self.emptyClient()
        let refs16 = Array(repeating: Self.reference(), count: 16)
        let error = await TestSupport.error(from: Self.provider(client), Self.editRequest(references: refs16))
        guard case .invalidRequest = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(client.requests.isEmpty)
    }

    @Test func oversizedUploadRejectedWithoutNetwork() async {
        let client = Self.emptyClient()
        let big = Data(count: 50_000_001)
        let error = await TestSupport.error(from: Self.provider(client),
                                            Self.editRequest(references: [Self.reference(Self.payload(big))]))
        guard case .invalidRequest(let param, let raw) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "image[1]")
        #expect(raw?.code == "file_above_max_size")
        #expect(client.requests.isEmpty)
    }

    @Test func heicIsRejected() async {
        let client = Self.emptyClient()
        let error = await TestSupport.error(from: Self.provider(client),
                                            Self.editRequest(base: Self.payload(type: "public.heic")))
        guard case .invalidRequest(let param, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "image[0]")
        #expect(client.requests.isEmpty)
    }
}
