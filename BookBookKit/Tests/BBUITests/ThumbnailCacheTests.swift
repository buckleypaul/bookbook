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
        // The stale rendition is deleted when the new one is written.
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func newRenditionKeepsOtherSizesAndSources() async throws {
        let a = dir.appending(path: "a.png")
        let b = dir.appending(path: "b.png")
        try Self.writePNG(width: 64, height: 64, to: a)
        try Self.writePNG(width: 64, height: 64, to: b)
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let id = BookID()
        let small = try #require(await cache.rendition(of: a, bookID: id, maxPixelSize: 16))
        let other = try #require(await cache.rendition(of: b, bookID: id, maxPixelSize: 32))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: a.path)
        let renewed = try #require(await cache.rendition(of: a, bookID: id, maxPixelSize: 32))
        #expect(renewed != small)
        for url in [small, other, renewed] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func sourcesWithTheSameFileNameDoNotPruneEachOther() async throws {
        // Every library thumbnail is a `thumbnail.png`; a Finder copy of a book keeps its ID.
        let first = dir.appending(path: "One.bookbook/thumbnail.png")
        let copy = dir.appending(path: "One copy.bookbook/thumbnail.png")
        for url in [first, copy] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.writePNG(width: 64, height: 64, to: url)
        }
        let cache = ThumbnailCache(root: dir.appending(path: "cache"))
        let id = BookID()
        let a = try #require(await cache.rendition(of: first, bookID: id, maxPixelSize: 32))
        let b = try #require(await cache.rendition(of: copy, bookID: id, maxPixelSize: 32))
        #expect(a != b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: copy.path)
        let renewed = try #require(await cache.rendition(of: copy, bookID: id, maxPixelSize: 32))
        #expect(FileManager.default.fileExists(atPath: a.path), "the other source's rendition stays")
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: renewed.path))
    }

    @Test func writingARenditionPrunesOldStyleNames() async throws {
        let src = dir.appending(path: "a.png")
        try Self.writePNG(width: 64, height: 64, to: src)
        let root = dir.appending(path: "cache")
        let id = BookID()
        let folder = root.appending(path: id.rawValue.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appending(path: String(repeating: "0123456789abcdef", count: 2) + ".png")
        let unrelated = folder.appending(path: "notes.png")
        for url in [legacy, unrelated] { try Data([1]).write(to: url) }
        #expect(ThumbnailCache.isLegacyRendition(legacy.lastPathComponent))
        #expect(!ThumbnailCache.isLegacyRendition(unrelated.lastPathComponent))

        let out = try #require(await ThumbnailCache(root: root).rendition(of: src, bookID: id, maxPixelSize: 32))
        #expect(!ThumbnailCache.isLegacyRendition(out.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: out.path))
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

    @Test func placedImagesDecodeAtAboutAPixelPerOutputPixel() {
        func use(_ width: Double, _ height: Double, zoom: Double = 1) -> PlacedImageSource.Use {
            PlacedImageSource.Use(boxPixelSize: CGSize(width: width, height: height),
                                  placement: ImagePlacement(versionID: VersionID(), zoom: zoom,
                                                            boxAspectWhenPlaced: width / height))
        }
        let big = CGSize(width: 4000, height: 3000)
        // Zoom 1, same aspect: about the box's size.
        #expect(PlacedImageSource.decodePixelSize(imageSize: big, uses: [use(400, 300)]) == 400)
        // Aspect-fill into a wide box: the image overflows the box's height.
        #expect(PlacedImageSource.decodePixelSize(imageSize: CGSize(width: 1000, height: 1000),
                                                  uses: [use(400, 200)]) == 400)
        // A zoomed-in crop needs zoom times as much; the largest use wins.
        #expect(PlacedImageSource.decodePixelSize(imageSize: big, uses: [use(400, 300, zoom: 4)]) == 1600)
        #expect(PlacedImageSource.decodePixelSize(imageSize: big, uses: [use(100, 75), use(400, 300, zoom: 2)]) == 800)
        // Capped at the image's full size (nil = decode whole).
        #expect(PlacedImageSource.decodePixelSize(imageSize: CGSize(width: 1024, height: 768),
                                                  uses: [use(400, 300, zoom: 4)]) == nil)
    }

    @MainActor
    @Test func placedImageSourceDecodesEachRefAtItsSize() throws {
        let ref = Fixtures.ref
        let url = dir.appending(path: ref.fileName)
        try Self.writePNG(width: 2000, height: 1000, to: url)
        func source(zoom: Double) -> PlacedImageSource {
            let placement = ImagePlacement(versionID: VersionID(), zoom: zoom, boxAspectWhenPlaced: 2)
            return PlacedImageSource(uses: [ref: [PlacedImageSource.Use(boxPixelSize: CGSize(width: 200, height: 100),
                                                                        placement: placement)]],
                                     urlForRef: { _ in url })
        }
        let plain = source(zoom: 1)
        let small = try #require(plain.image(for: ref))
        #expect(small.width == 200 && small.height == 100)
        #expect(plain.image(for: ref) === small)
        let zoomed = try #require(source(zoom: 4).image(for: ref))
        #expect(zoomed.width == 800 && zoomed.height == 400)
        let whole = try #require(source(zoom: 20).image(for: ref))
        #expect(whole.width == 2000 && whole.height == 1000)
    }
}
