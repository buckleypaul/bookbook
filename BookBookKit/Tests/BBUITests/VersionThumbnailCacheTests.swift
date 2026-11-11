import BBModel
import CoreGraphics
import Testing
@testable import BBUI

@MainActor
struct VersionThumbnailCacheTests {
    @Test func keepsADecodedThumbnailPerRef() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let ref = ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")
        let other = ImageRef(sha256: ref.sha256, contentType: "public.jpeg")
        #expect(VersionThumbnailCache.image(for: ref) == nil)
        VersionThumbnailCache.insert(image, for: ref)
        #expect(VersionThumbnailCache.image(for: ref) === image)
        #expect(VersionThumbnailCache.image(for: other) == nil)
    }
}
