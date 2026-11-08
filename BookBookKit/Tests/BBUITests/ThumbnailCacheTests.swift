import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ThumbnailCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil)
        else { return nil }
        return (i.width, i.height)
    }

    @Test func downsamplesPreservingAspect() async throws {
        let src = dir.appending(path: "a.png")
        try Self.writePNG(width: 400, height: 200, to: src)
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let out = try #require(await cache.rendition(of: src, bookID: BookID(), maxPixelSize: 100))
        let size = try #require(Self.pixelSize(out))
        #expect(size.0 == 100 && size.1 == 50)
        #expect(out.path.contains("cache"))
    }

    @Test func secondCallReusesFile() async throws {
        let src = dir.appending(path: "a.png")
        try Self.writePNG(width: 64, height: 64, to: src)
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let id = BookID()
        let first = try #require(await cache.rendition(of: src, bookID: id, maxPixelSize: 32))
        let stamp = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try #require(await cache.rendition(of: src, bookID: id, maxPixelSize: 32))
        #expect(first == second)
        #expect(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
    }

    @Test func changedSourceGetsNewRendition() async throws {
        let src = dir.appending(path: "a.png")
        try Self.writePNG(width: 64, height: 64, to: src)
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let id = BookID()
        let first = try #require(await cache.rendition(of: src, bookID: id, maxPixelSize: 32))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: src.path)
        let second = try #require(await cache.rendition(of: src, bookID: id, maxPixelSize: 32))
        #expect(first != second)
    }

    @Test func unreadableSourceIsNil() async throws {
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let missing = dir.appending(path: "missing.png")
        #expect(await cache.rendition(of: missing, bookID: BookID(), maxPixelSize: 32) == nil)
        let junk = dir.appending(path: "junk.png")
        try Data("not an image".utf8).write(to: junk)
        #expect(await cache.rendition(of: junk, bookID: BookID(), maxPixelSize: 32) == nil)
    }

    @Test func removeAllDeletesBookFolder() async throws {
        let src = dir.appending(path: "a.png")
        try Self.writePNG(width: 64, height: 64, to: src)
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let id = BookID()
        let out = try #require(await cache.rendition(of: src, bookID: id, maxPixelSize: 32))
        await cache.removeAll(for: id)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path))
    }

    @MainActor
    @Test func bookThumbnail() throws {
        let template = Template(name: "T", kind: .single, boxes: [
            Box(id: BoxID(), frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image),
        ])
        let content = BookContent.makeNew(title: "B", storyTemplate: template,
                                          coverTemplate: Template(name: "C", kind: .cover, boxes: []),
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        let none = URL(filePath: "/nonexistent")
        let data = try #require(BookThumbnail.png(for: content, imageURL: { _ in none }, maxPixelSize: 512))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == 512)

        var empty = content
        empty.book.pageOrder = []
        empty.pages = [:] // no cover either
        #expect(BookThumbnail.png(for: empty, imageURL: { _ in none }) == nil)
    }
}
