import BBLayout
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BBExport

@MainActor
private final class AlwaysBad: SpellingChecking {
    func misspelledWords(in text: String) -> [String] { text.split(separator: " ").map(String.init) }
}

@Suite("Phase 16b export")
@MainActor
struct Phase16bExportTests {
    // MARK: Cache (#6a, #6b, #6g)

    private func fixture() throws -> (ExportImagePreparer, URL, ImagePreparationRequest) {
        let dir = ImageTestSupport.tempDir()
        let source = dir.appendingPathComponent("src.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 64, height: 64), to: source)
        let cache = dir.appendingPathComponent("cache")
        let request = ImageTestSupport.request(crop: CGRect(x: 0, y: 0, width: 64, height: 64),
                                               required: CGSize(width: 32, height: 32), url: source)
        return (ExportImagePreparer(cacheDirectory: cache), cache, request)
    }

    @Test func truncatedCacheFileIsRebuilt() async throws {
        let (preparer, cache, request) = try fixture()
        let url = try await preparer.preparedFileURL(request)
        try Data([0xFF, 0xD8, 0x00]).write(to: url)   // truncated JPEG left by a crash
        let image = try await preparer.prepare(request)
        #expect(image.width == 32)
        #expect(ImagePixelSize.of(url: url) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasPrefix(".tmp-") })
    }

    @Test func writesLeaveNoTempFiles() async throws {
        let (preparer, cache, request) = try fixture()
        _ = try await preparer.preparedFileURL(request)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(names.count == 1 && !names[0].hasPrefix("."))
    }

    @Test func prunesOldFilesOnly() async throws {
        let (preparer, cache, request) = try fixture()
        let fresh = try await preparer.preparedFileURL(request)
        let old = cache.appendingPathComponent("old.jpg")
        try Data([1]).write(to: old)
        let past = Date().addingTimeInterval(-20 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        await preparer.pruneCache()
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func decodeIsEagerNotLazy() throws {
        let dir = ImageTestSupport.tempDir()
        let url = dir.appendingPathComponent("a.png")
        ImageTestSupport.writePNG(ImageTestSupport.makeImage(width: 8, height: 8), to: url)
        #expect(ImageFiles.decode(url: url)?.width == 8)
        #expect(ImageFiles.immediate as NSDictionary == [kCGImageSourceShouldCacheImmediately: true] as NSDictionary)
    }

    // MARK: Soft rule (#7c)

    @Test func shortSideRuleOnlyAppliesWhenUpscaling() {
        #expect(!PrintResolution.isSoft(upscaleFactor: 0.5, cropShortSidePixels: 300))
        #expect(!PrintResolution.isSoft(upscaleFactor: 1, cropShortSidePixels: 300))
        #expect(PrintResolution.isSoft(upscaleFactor: 1.5, cropShortSidePixels: 300))
        #expect(PrintResolution.isSoft(upscaleFactor: 3, cropShortSidePixels: 2000))
    }

    // MARK: Preflight (#6e, #6f)

    private let imageBox = Box(id: BoxID(), frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4), content: .image)
    private func content() -> (BookContent, Template) {
        let story = Template(name: "S", kind: .single, boxes: [imageBox])
        let cover = Template(name: "C", kind: .cover,
                             boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])
        let c = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, storyPageCount: 3,
                                    now: Date(timeIntervalSince1970: 1))
        return (c, story)
    }

    @Test func preflightHonoursPageSelection() {
        let (c, _) = content()
        let all = Preflight.run(c, assessments: [:], spelling: AlwaysBad())
        let story = c.storyPages.map(\.id)
        #expect(Set(all.map(\.page)) == Set(story + [c.book.coverPageID]))

        let options = ExportOptions(includeCover: false, pageRange: 2...2)
        let ids = Preflight.exportedPageIDs(c, options: options)
        #expect(ids == [story[1]])
        let some = Preflight.run(c, assessments: [:], spelling: AlwaysBad(), pages: ids)
        #expect(Set(some.map(\.page)) == [story[1]])

        let withCover = Preflight.exportedPageIDs(c, options: ExportOptions(includeCover: true, pageRange: 1...1))
        #expect(withCover == [story[0], c.book.coverPageID])
    }

    @Test func repeatedMisspellingGivesUniqueIDs() {
        var (c, _) = content()
        let box = Box(frame: NormalizedRect(x: 0, y: 0.6, width: 1, height: 0.3), content: .text(TextBoxStyle(padding: 6)))
        let t = Template(name: "T", kind: .single, boxes: [imageBox, box])
        c.templates[t.id] = t
        let page = c.storyPages[0]
        c.pages[page.id]?.templateID = t.id
        c.pages[page.id]?.text[box.id] = RichText(plain: "teh teh teh")
        let issues = Preflight.run(c, assessments: [:], spelling: AlwaysBad(), pages: [page.id])
            .filter { $0.kind == .spelling }
        #expect(issues.count == 1)
        #expect(Set(issues.map(\.id)).count == issues.count)
    }
}
