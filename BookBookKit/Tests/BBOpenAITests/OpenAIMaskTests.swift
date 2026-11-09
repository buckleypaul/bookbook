import BBAICore
import BBModel
import BBNet
import Foundation
import Testing
@testable import BBOpenAI

// Offline tests for region-edit masks on `POST /v1/images/edits` (Phase 11 L1).

@Suite struct OpenAIMaskTests {
    static let size = PixelSize(width: 1024, height: 1536)
    static let maskBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA, 0xBB])

    static func mask(size: PixelSize = size, bytes: Data = maskBytes) -> MaskPayload {
        MaskPayload(pngData: bytes, pixelSize: size)
    }

    static func request(base: ImagePayload? = OpenAIEditsTests.payload(size: size), mask: MaskPayload? = mask(),
                        references: [ReferenceImage] = []) -> ImageRequest {
        var request = OpenAIEditsTests.editRequest(base: base, references: references, exactSize: size)
        request.mask = mask
        return request
    }

    @Test func maskPartAfterImagesWithFilenameAndType() async throws {
        let client = TestSupport.client(.fixture(OpenAIEditsTests.fixture))
        let result = try await OpenAIEditsTests.provider(client)
            .generate(Self.request(references: [OpenAIEditsTests.reference()]), progress: { _ in })
        let body = try #require(client.requests.first?.body)
        let text = String(decoding: body, as: UTF8.self)
        let maskHeader = "name=\"mask\"; filename=\"mask.png\"\r\nContent-Type: image/png\r\n\r\n"
        let maskRange = try #require(text.range(of: maskHeader))
        let lastImage = try #require(text.range(of: "filename=\"image2.png\"", options: .backwards))
        let prompt = try #require(text.range(of: "name=\"prompt\""))
        #expect(lastImage.lowerBound < maskRange.lowerBound)
        #expect(maskRange.upperBound <= prompt.lowerBound)
        #expect(body.range(of: Self.maskBytes) != nil)
        #expect(!text.contains("name=\"mask\"\r\n\r\n"))  // not duplicated as a text field
        #expect(text.contains("name=\"size\"\r\n\r\n1024x1536\r\n"))
        #expect(result.parametersSent["mask"] == "1024x1536 png")
    }

    @Test func sizeMismatchFailsWithoutRequest() async {
        let client = OpenAIEditsTests.emptyClient()
        let error = await TestSupport.error(
            from: OpenAIEditsTests.provider(client),
            Self.request(mask: Self.mask(size: PixelSize(width: 512, height: 768))))
        guard case .invalidRequest(let param, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "mask")
        #expect(client.requests.isEmpty)
    }

    @Test func maskWithoutBaseFails() async {
        let client = OpenAIEditsTests.emptyClient()
        let error = await TestSupport.error(
            from: OpenAIEditsTests.provider(client),
            Self.request(base: nil, references: [OpenAIEditsTests.reference()]))
        guard case .invalidRequest(let param, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "mask")
        #expect(client.requests.isEmpty)
    }

    @Test func oversizedMaskRejected() async {
        let client = OpenAIEditsTests.emptyClient()
        let error = await TestSupport.error(
            from: OpenAIEditsTests.provider(client), Self.request(mask: Self.mask(bytes: Data(count: 50_000_001))))
        guard case .invalidRequest(let param, let raw) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "mask")
        #expect(raw?.code == "file_above_max_size")
        #expect(client.requests.isEmpty)
    }

    @Test func noMaskNoMaskPart() async throws {
        let client = TestSupport.client(.fixture(OpenAIEditsTests.fixture))
        let result = try await OpenAIEditsTests.provider(client).generate(Self.request(mask: nil), progress: { _ in })
        let text = String(decoding: try #require(client.requests.first?.body), as: UTF8.self)
        #expect(!text.contains("name=\"mask\""))
        #expect(result.parametersSent["mask"] == nil)
    }

    @Test func invalidMaskFormatMapsToInvalidRequest() async {
        let error = await SyntheticFixtures.generateError("400-invalid-mask-format")
        guard case .invalidRequest(let param, let raw) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(param == "mask")
        #expect(raw?.code == "invalid_mask_image_format")
    }
}
