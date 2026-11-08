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
}
