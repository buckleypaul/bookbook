import Foundation
import Testing
@testable import BBModel

/// Flag derivation (A §4.4), revision bump rules (A §4.1), page setup presets and decoding.
struct StyleFlagsTests {
    static let imageBox = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), content: .image)
    static let story = Template(name: "S", kind: .single, boxes: [imageBox])
    static let cover = Template(name: "C", kind: .cover, boxes: [
        Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image),
    ])
    static let now = Date(timeIntervalSince1970: 1)

    static func provenance(styleRevision: Int) -> Provenance {
        let intent = GenerationIntent(messageText: "fox", refines: nil, provider: .openai, model: "m", quality: .standard)
        return Provenance(provider: .openai, model: "m", quality: .standard,
                          outputSize: PixelSize(width: 1024, height: 1024), promptSent: "p",
                          styleRevision: styleRevision, storyTextIncluded: false, intent: intent)
    }

    /// A one-page book with a version placed in the story image box.
    static func book(provenance: Provenance?, aspectWhenPlaced: Double? = nil) -> (BookContent, PageID, BoxID) {
        var content = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, now: now)
        let pageID = content.book.pageOrder[0]
        let sessionID = content.pages[pageID]!.images[imageBox.id]!.sessionID
        let version = Version(image: ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png"),
                              pixelSize: PixelSize(width: 1024, height: 1024), source: provenance == nil ? .imported : .generated,
                              createdAt: now, provenance: provenance)
        content.sessions[sessionID]?.versions.append(version)
        let aspect = aspectWhenPlaced ?? content.boxAspect(imageBox, in: story)
        content.pages[pageID]?.images[imageBox.id]?.placement = ImagePlacement(versionID: version.id, boxAspectWhenPlaced: aspect)
        return (content, pageID, imageBox.id)
    }

    // MARK: Style flag

    @Test(arguments: [
        (0, 0, 0, false), (0, 1, 0, true), (1, 1, 0, false), (0, 2, 1, true), (0, 2, 2, false), (0, 3, 2, true), (5, 3, 0, false),
    ])
    func styleChanged(placed: Int, visual: Int, acknowledged: Int, expected: Bool) {
        var (content, page, box) = Self.book(provenance: Self.provenance(styleRevision: placed))
        content.style.visualRevision = visual
        content.pages[page]?.images[box]?.acknowledged.styleRevision = acknowledged
        #expect(content.imageFlags(page: page, box: box).contains(.styleChanged) == expected)
    }

    @Test func importedVersionNeverGetsStyleChanged() {
        var (content, page, box) = Self.book(provenance: nil)
        content.style.visualRevision = 9
        #expect(content.imageFlags(page: page, box: box).isEmpty)
    }

    @Test func emptyBoxHasNoFlags() {
        var (content, page, box) = Self.book(provenance: Self.provenance(styleRevision: 0))
        content.pages[page]?.images[box]?.placement = nil
        content.style.visualRevision = 3
        content.style.pageSetup = content.style.pageSetup.applying(preset: .square8, orientation: .square)
        #expect(content.imageFlags(page: page, box: box).isEmpty)
        #expect(content.imageFlags(of: content.pages[page]!).isEmpty)
    }

    // MARK: Layout flag

    @Test(arguments: [(1.0, false), (1.04, false), (1.06, true), (0.96, false), (0.94, true), (1.5, true), (0.5, true)])
    func layoutThreshold(factor: Double, expected: Bool) {
        let (base, _, _) = Self.book(provenance: nil)
        let aspect = base.boxAspect(Self.imageBox, in: Self.story)
        let (content, page, box) = Self.book(provenance: nil, aspectWhenPlaced: aspect * factor)
        // log(1/factor) magnitude is what matters; both sides of 5% are covered by the arguments.
        #expect(content.imageFlags(page: page, box: box).contains(.layoutChanged) == expected)
    }

    @Test func acknowledgedAspectReplacesPlacedAspect() {
        var (content, page, box) = Self.book(provenance: nil, aspectWhenPlaced: 3)
        #expect(content.imageFlags(page: page, box: box).contains(.layoutChanged))
        let aspect = content.boxAspect(Self.imageBox, in: Self.story)
        content.pages[page]?.images[box]?.acknowledged.boxAspect = aspect
        #expect(!content.imageFlags(page: page, box: box).contains(.layoutChanged))
    }

    @Test func pageSetupChangeFlagsLayout() {
        var (content, page, box) = Self.book(provenance: nil)
        #expect(content.imageFlags(page: page, box: box).isEmpty)
        content.style.pageSetup = content.style.pageSetup.applying(preset: .square8, orientation: .square)
        #expect(content.imageFlags(page: page, box: box).contains(.layoutChanged))
    }

    @Test func bleedChangesAspect() {
        var content = BookContent.makeNew(title: "T", storyTemplate: Self.story, coverTemplate: Self.cover, now: Self.now)
        let full = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), bleedEdges: .all, content: .image)
        #expect(content.boxAspect(full) == 612.0 / 792.0)
        content.style.pageSetup.bleedEnabled = true
        content.style.pageSetup.bleedAmount = 9
        #expect(abs(content.boxAspect(full) - 630.0 / 810.0) < 1e-12)
        // Only leading edge bleeds.
        let leading = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), bleedEdges: .leading, content: .image)
        #expect(abs(content.boxAspect(leading) - 621.0 / 792.0) < 1e-12)
        // No bleed edges: unchanged.
        #expect(abs(content.boxAspect(Self.imageBox) - (0.8 * 612) / (0.5 * 792)) < 1e-9)
    }

    @Test func spreadTemplateUsesDoubleWidth() {
        let content = BookContent.makeNew(title: "T", storyTemplate: Self.story, coverTemplate: Self.cover, now: Self.now)
        let box = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)
        let spread = Template(name: "Sp", kind: .spread, boxes: [box])
        #expect(content.boxAspect(box, in: spread) == 1224.0 / 792.0)
        #expect(content.boxAspect(box, in: Self.story) == 612.0 / 792.0)
    }

    // MARK: Revision bumps

    @Test func revisionBumpRules() {
        let base = StyleGuide(visualDescription: "a", visualRevision: 4)
        var v = base.visual
        #expect(base.applying(v) == base)

        v.presetID = "watercolour"
        let presetOnly = base.applying(v)
        #expect(presetOnly.visualRevision == 4)
        #expect(presetOnly.presetID == "watercolour")

        v = base.visual
        v.visualDescription = "b"
        #expect(base.applying(v).visualRevision == 5)

        v = base.visual
        v.negativeGuidance = "none"
        #expect(base.applying(v).visualRevision == 5)

        v = base.visual
        v.styleReferences = [ImageRef(sha256: String(repeating: "cd", count: 32), contentType: "public.png")]
        #expect(base.applying(v).visualRevision == 5)

        // Several fields at once still bump once.
        v.visualDescription = "c"
        #expect(base.applying(v).visualRevision == 5)
    }

    // MARK: PageSetup

    @Test func presetsAndOrientation() {
        let base = PageSetup.letterPortrait
        let a4 = base.applying(preset: .a4, orientation: .portrait)
        #expect(a4.trimSize == PointSize(width: 595.28, height: 841.89))
        #expect(a4.orientation == .portrait)
        #expect(a4.sizePreset == .a4)
        #expect(a4.margins == base.margins)

        let land = base.applying(preset: .usLetter, orientation: .landscape)
        #expect(land.trimSize == PointSize(width: 792, height: 612))
        #expect(land.orientation == .landscape)

        let square = base.applying(preset: .square8, orientation: .landscape)
        #expect(square.trimSize == PointSize(width: 576, height: 576))
        #expect(square.orientation == .square)

        let tenByEight = base.applying(preset: .tenByEight, orientation: .portrait)
        #expect(tenByEight.trimSize == PointSize(width: 576, height: 720))

        let custom = base.applying(preset: .custom, orientation: .portrait, customSize: PointSize(width: 500, height: 300))
        #expect(custom.trimSize == PointSize(width: 500, height: 300))
        #expect(custom.orientation == .landscape)
        #expect(custom.sizePreset == .custom)
    }

    @Test func presetTable() {
        #expect(PageSizePreset.allCases.filter { $0 != .custom }.allSatisfy { $0.baseSize != nil })
        #expect(PageSizePreset.custom.baseSize == nil)
        #expect(PageSizePreset.halfLetter.displayName == "5.5 × 8.5 in")
        #expect(PageSizePreset.custom.displayName == "Custom")
    }

    @Test(arguments: [(612.0, 792.0, PageSizePreset.usLetter), (792.0, 612.0, .usLetter), (595.28, 841.89, .custom), (576.0, 576.0, .custom)])
    func decodeWithoutSizePreset(w: Double, h: Double, expected: PageSizePreset) throws {
        let json = """
        {"trimSize":{"width":\(w),"height":\(h)},"orientation":"portrait","margins":{"top":36,"leading":36,"bottom":36,"trailing":36},
         "bleedEnabled":false,"bleedAmount":9}
        """
        let setup = try JSONDecoder().decode(PageSetup.self, from: Data(json.utf8))
        #expect(setup.sizePreset == expected)
    }

    @Test func codableRoundTripKeepsPreset() throws {
        let setup = PageSetup.letterPortrait.applying(preset: .a5, orientation: .portrait)
        let back = try JSONDecoder().decode(PageSetup.self, from: JSONEncoder().encode(setup))
        #expect(back == setup)
    }
}
