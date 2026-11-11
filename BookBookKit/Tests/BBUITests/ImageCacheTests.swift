import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

@MainActor
struct ImageCacheTests {
    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func downsamplesForScreen_keepsFullSizeForExport_andMissesAreNil() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-imagecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = Fixtures.ref
        let url = dir.appending(path: ref.fileName)

        let screen = ImageCache(maxPixelSize: 64) { dir.appending(path: $0.fileName) }
        #expect(screen.image(for: ref) == nil)

        try writePNG(width: 400, height: 200, to: url)
        let small = try #require(screen.image(for: ref))
        #expect(max(small.width, small.height) == 64)
        #expect(screen.image(for: ref) === small)

        let full = ImageCache(maxPixelSize: nil) { dir.appending(path: $0.fileName) }
        let big = try #require(full.image(for: ref))
        #expect(big.width == 400 && big.height == 200)
    }

    @Test func evictsTheLeastRecentlyUsedImage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-imagecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let refs = ["aa", "bb", "cc"].map { ImageRef(sha256: String(repeating: $0, count: 32), contentType: "public.png") }
        for ref in refs { try writePNG(width: 8, height: 8, to: dir.appending(path: ref.fileName)) }
        let cache = ImageCache(maxPixelSize: 64, capacity: 2) { dir.appending(path: $0.fileName) }

        let a = try #require(cache.image(for: refs[0]))
        let b = try #require(cache.image(for: refs[1]))
        #expect(cache.image(for: refs[0]) === a) // a is now the most recently used
        _ = cache.image(for: refs[2])            // evicts b, not a
        #expect(cache.image(for: refs[0]) === a)
        #expect(cache.image(for: refs[1]) !== b)
    }

    @Test func previewsAreSmallAndSeparate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-imagecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = Fixtures.ref
        try writePNG(width: 1024, height: 512, to: dir.appending(path: ref.fileName))
        let cache = ImageCache(maxPixelSize: 2048) { dir.appending(path: $0.fileName) }

        let preview = try #require(cache.previews.image(for: ref))
        #expect(preview.width == ImageCache.previewPixelSize && preview.height == ImageCache.previewPixelSize / 2)
        #expect(cache.previews === cache.previews)
        let large = try #require(cache.image(for: ref))
        #expect(large.width == 1024)
    }
}
