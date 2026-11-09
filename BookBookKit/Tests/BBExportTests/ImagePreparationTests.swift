import BBLayout
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBExport

/// Counts upscale calls and delegates to the real upscaler.
final class CountingUpscaler: Upscaler, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func upscale(_ image: CGImage, to size: CGSize) async throws -> CGImage {
        lock.withLock { _count += 1 }
        return try await CoreImageUpscaler().upscale(image, to: size)
    }
}

enum ImageTestSupport {
    static func makeImage(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-img-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        return (i.width, i.height)
    }

    static func request(crop: CGRect, required: CGSize, url: URL, sha: String = "ab") -> ImagePreparationRequest {
        ImagePreparationRequest(key: BoxImageKey(page: PageID(), box: BoxID()),
                                image: ImageRef(sha256: sha, contentType: "public.png"),
                                sourceURL: url, cropPixels: crop, requiredPixels: required)
    }
}

@Suite("Image assessment")
struct ImageAssessmentTests {
    let preparer = ExportImagePreparer(cacheDirectory: ImageTestSupport.tempDir())

    @Test func smallSourceOnFullPageIsSoft() async {
        // 512 px across a full 8.5 x 11 in box: needs 2550 px, factor ~5.
        let r = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 512, height: 512),
                                         required: CGSize(width: 2550, height: 3300), url: URL(fileURLWithPath: "/x"))
        let a = await preparer.assess(r)
        #expect(a.isSoft)
        #expect(a.upscaleFactor > 5)
    }

    @Test func largeSourceForSmallBoxIsNotSoft() async {
        let r = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 3000, height: 3000),
                                         required: CGSize(width: 1500, height: 1500), url: URL(fileURLWithPath: "/x"))
        let a = await preparer.assess(r)
        #expect(!a.isSoft)
        #expect(a.upscaleFactor == 0.5)
    }

    @Test func factorBoundary() async {
        let url = URL(fileURLWithPath: "/x")
        let at = await preparer.assess(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 1000, height: 1000), required: CGSize(width: 2500, height: 2500), url: url))
        #expect(at.upscaleFactor == 2.5)
        #expect(!at.isSoft)
        let over = await preparer.assess(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 1000, height: 1000), required: CGSize(width: 2501, height: 2501), url: url))
        #expect(over.isSoft)
    }

    @Test func shortSideBoundary() async {
        let url = URL(fileURLWithPath: "/x")
        let at = await preparer.assess(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 600, height: 900), required: CGSize(width: 600, height: 900), url: url))
        #expect(!at.isSoft)
        let under = await preparer.assess(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 599, height: 900), required: CGSize(width: 600, height: 900), url: url))
        #expect(under.isSoft)
    }

    @Test func limitingAxisWins() async {
        let a = await preparer.assess(ImageTestSupport.request(
            crop: CGRect(x: 0, y: 0, width: 2000, height: 1000), required: CGSize(width: 1000, height: 2000),
            url: URL(fileURLWithPath: "/x")))
        #expect(a.upscaleFactor == 2)
    }
}

@Suite("Image planner")
struct ImagePlannerTests {
    static let boxID = BoxID("00000000-0000-0000-0000-0000000000D1")
    static let ref = ImageRef(sha256: String(repeating: "ef", count: 32), contentType: "public.png")

    static func book(frame: NormalizedRect, placement: (VersionID) -> ImagePlacement) -> (BookContent, Page) {
        let template = Template(name: "Image", kind: .single, boxes: [Box(id: boxID, frame: frame, content: .image)])
        var content = BookContent.makeNew(title: "T", author: "A", storyTemplate: template,
                                          coverTemplate: Template(name: "Cover", kind: .cover, boxes: []),
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        content.style.pageSetup.trimSize = PointSize(width: 612, height: 792)
        content.style.pageSetup.bleedEnabled = false
        let pageID = content.book.pageOrder[0]
        var page = content.pages[pageID]!
        var slot = page.images[boxID]!
        var session = content.sessions[slot.sessionID]!
        let version = Version(image: ref, pixelSize: PixelSize(width: 1000, height: 1000), source: .imported,
                              createdAt: Date(timeIntervalSince1970: 0))
        session.versions.append(version)
        content.sessions[session.id] = session
        slot.placement = placement(version.id)
        page.images[boxID] = slot
        content.pages[pageID] = page
        return (content, page)
    }

    static func plan(_ content: BookContent, _ page: Page, size: CGSize = CGSize(width: 1000, height: 1000)) -> [ImagePreparationRequest] {
        ImagePreparationPlanner.requests(page: page, in: content,
                                         imageURL: { _ in URL(fileURLWithPath: "/img.png") }, pixelSize: { _ in size })
    }

    @Test func zoomOneCentred() throws {
        let (content, page) = Self.book(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1)) {
            ImagePlacement(versionID: $0, boxAspectWhenPlaced: 612.0 / 792)
        }
        let r = try #require(Self.plan(content, page).first)
        #expect(r.requiredPixels == CGSize(width: 2550, height: 3300))
        // Square image fills a 612x792 box by height: visible width = 612/792 * 1000 = 772.7 px, full height.
        #expect(r.cropPixels.height == 1000)
        #expect(abs(r.cropPixels.width - 772.7) <= 2)
        #expect(abs(r.cropPixels.midX - 500) <= 1)
    }

    @Test func zoomTwoOffCentre() throws {
        let (content, page) = Self.book(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1)) {
            ImagePlacement(versionID: $0, zoom: 2, center: NormalizedPoint(x: 0.25, y: 0.5), boxAspectWhenPlaced: 612.0 / 792)
        }
        let r = try #require(Self.plan(content, page).first)
        // Half of the zoom-1 crop: 386.4 x 500, centred on x = 250, y = 500.
        #expect(abs(r.cropPixels.width - 386.4) <= 2)
        #expect(abs(r.cropPixels.height - 500) <= 2)
        #expect(abs(r.cropPixels.midX - 250) <= 2)
        #expect(abs(r.cropPixels.midY - 500) <= 2)
        #expect(r.requiredPixels == CGSize(width: 2550, height: 3300))
    }

    @Test func focalPointClampedToImage() throws {
        let (content, page) = Self.book(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1)) {
            ImagePlacement(versionID: $0, zoom: 2, center: NormalizedPoint(x: 0, y: 0), boxAspectWhenPlaced: 612.0 / 792)
        }
        let r = try #require(Self.plan(content, page).first)
        #expect(r.cropPixels.minX == 0)
        #expect(r.cropPixels.minY == 0)
        #expect(CGRect(x: 0, y: 0, width: 1000, height: 1000).contains(r.cropPixels))
    }

    @Test func partialBoxRequiredPixelsRoundUp() throws {
        // 0.5 x 0.5 of Letter = 306 x 396 pt -> 1275 x 1650 px.
        let (content, page) = Self.book(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)) {
            ImagePlacement(versionID: $0, boxAspectWhenPlaced: 306.0 / 396)
        }
        let r = try #require(Self.plan(content, page).first)
        #expect(r.requiredPixels == CGSize(width: 1275, height: 1650))
    }

    @Test func unknownPixelSizeSkipped() {
        let (content, page) = Self.book(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1)) {
            ImagePlacement(versionID: $0, boxAspectWhenPlaced: 1)
        }
        let none = ImagePreparationPlanner.requests(page: page, in: content,
                                                    imageURL: { _ in URL(fileURLWithPath: "/x") }, pixelSize: { _ in nil })
        #expect(none.isEmpty)
    }
}

@Suite("Export image preparer")
struct ExportImagePreparerTests {
    @Test func upscalerHitsExactSize() async throws {
        let out = try await CoreImageUpscaler().upscale(ImageTestSupport.makeImage(width: 50, height: 70),
                                                        to: CGSize(width: 333, height: 201))
        #expect(out.width == 333 && out.height == 201)
        let down = try await CoreImageUpscaler().upscale(ImageTestSupport.makeImage(width: 400, height: 300),
                                                         to: CGSize(width: 101, height: 77))
        #expect(down.width == 101 && down.height == 77)
    }

    @Test func pixelSizeWithoutDecode() throws {
        let dir = ImageTestSupport.tempDir()
        let url = dir.appendingPathComponent("a.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 120, height: 80), to: url)
        #expect(ImagePixelSize.of(url: url) == CGSize(width: 120, height: 80))
        #expect(ImagePixelSize.of(url: dir.appendingPathComponent("missing.png")) == nil)
    }

    @Test func prepareOutputMatchesRequiredPixelsAndCaches() async throws {
        let dir = ImageTestSupport.tempDir()
        let src = dir.appendingPathComponent("src.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 200, height: 200), to: src)
        let counter = CountingUpscaler()
        let preparer = ExportImagePreparer(cacheDirectory: dir.appendingPathComponent("cache"), upscaler: counter)
        let req = ImageTestSupport.request(crop: CGRect(x: 20, y: 10, width: 150, height: 100),
                                           required: CGSize(width: 450, height: 300), url: src)

        let image = try await preparer.prepare(req)
        #expect(image.width == 450 && image.height == 300)
        #expect(counter.count == 1)

        let file = try await preparer.preparedFileURL(req)
        #expect(file.pathExtension == "jpg")
        #expect(file.lastPathComponent.hasSuffix("-450x300.jpg"))
        let again = try await preparer.prepare(req)
        #expect(again.width == 450 && again.height == 300)
        #expect(counter.count == 1, "cache hit must not run the upscaler")
        #expect(try await preparer.preparedFileURL(req) == file)
    }

    @Test func downsampleOutputSize() async throws {
        let dir = ImageTestSupport.tempDir()
        let src = dir.appendingPathComponent("src.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 800, height: 600), to: src)
        let preparer = ExportImagePreparer(cacheDirectory: dir.appendingPathComponent("cache"))
        let req = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 800, height: 600),
                                           required: CGSize(width: 300, height: 225), url: src)
        let image = try await preparer.prepare(req)
        #expect(image.width == 300 && image.height == 225)
    }

    @Test func alphaSourceEncodesPNG() async throws {
        let dir = ImageTestSupport.tempDir()
        let src = dir.appendingPathComponent("alpha.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 64, height: 64, alpha: true), to: src)
        let preparer = ExportImagePreparer(cacheDirectory: dir.appendingPathComponent("cache"))
        let req = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 64, height: 64),
                                           required: CGSize(width: 128, height: 128), url: src)
        let file = try await preparer.preparedFileURL(req)
        #expect(file.pathExtension == "png")
        #expect(ImageTestSupport.pixelSize(of: file)! == (128, 128))
    }

    @Test func unreadableSourceThrows() async {
        let preparer = ExportImagePreparer(cacheDirectory: ImageTestSupport.tempDir())
        let req = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 10, height: 10),
                                           required: CGSize(width: 20, height: 20), url: URL(fileURLWithPath: "/nope.png"))
        await #expect(throws: ExportError.self) { _ = try await preparer.prepare(req) }
    }
}
