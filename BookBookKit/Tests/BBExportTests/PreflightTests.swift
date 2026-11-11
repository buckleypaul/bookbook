import BBLayout
import BBModel
import BBTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import BBExport

@MainActor
private final class FakeSpelling: SpellingChecking {
    var bad: Set<String>
    init(_ bad: Set<String> = []) { self.bad = bad }
    func misspelledWords(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { bad.contains($0) }
    }
}

@MainActor
private enum PF {
    static let imageBox = Box(id: BoxID("00000000-0000-0000-0000-0000000000C1"),
                              frame: NormalizedRect(x: 0.08, y: 0.06, width: 0.84, height: 0.5), content: .image)
    static let textBox = Box(id: BoxID("00000000-0000-0000-0000-0000000000C2"),
                             frame: NormalizedRect(x: 0.08, y: 0.6, width: 0.84, height: 0.3),
                             content: .text(TextBoxStyle(padding: 6)))
    static let story = Template(id: TemplateID("00000000-0000-0000-0000-0000000000C3"), name: "S", kind: .single,
                                boxes: [imageBox, textBox])
    static let cover = Template(id: TemplateID("00000000-0000-0000-0000-0000000000C4"), name: "C", kind: .cover,
                                boxes: [Box(id: BoxID("00000000-0000-0000-0000-0000000000C5"),
                                            frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])
    static let coverImageBox = cover.boxes[0].id
    static let now = Date(timeIntervalSince1970: 1)
    static let ref = ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png")

    /// A fully clean two-story-page book: every image placed, short text, available fonts.
    static func clean() -> BookContent {
        precondition(TestFonts.registerAll())
        var c = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, storyPageCount: 2, now: now)
        c.style.typography = Typography(
            bodyFont: FontRef(postScriptName: TestFonts.Face.regular.rawValue),
            titleFont: FontRef(postScriptName: TestFonts.Face.bold.rawValue),
            bodySize: 15, color: .black, lineSpacing: 1.2, alignment: .leading)
        c.style.pageSetup = PageSetup(trimSize: PointSize(width: 300, height: 300), orientation: .portrait,
                                      margins: EdgeInsetsPt(all: 18))
        place(&c, page: c.book.coverPageID, box: coverImageBox)
        for id in c.book.pageOrder {
            place(&c, page: id, box: imageBox.id)
            c.pages[id]?.text[textBox.id] = RichText(plain: "A fox ran home.")
        }
        return c
    }

    static func place(_ c: inout BookContent, page: PageID, box: BoxID, provenance: Provenance? = nil,
                      consistency: ConsistencyReport? = nil) {
        let sid = c.pages[page]!.images[box]!.sessionID
        let v = Version(image: ref, pixelSize: PixelSize(width: 8, height: 8),
                        source: provenance == nil ? .imported : .generated, createdAt: now,
                        provenance: provenance, consistency: consistency)
        c.sessions[sid]?.versions.append(v)
        let template = c.template(for: c.pages[page]!)!
        let aspect = c.boxAspect(template.box(box)!, in: template)
        c.pages[page]?.images[box]?.placement = ImagePlacement(versionID: v.id, boxAspectWhenPlaced: aspect)
    }

    static func provenance(style: Int = 0, assets: [AssetID: Int] = [:]) -> Provenance {
        let intent = GenerationIntent(messageText: "x", provider: .openai, model: "m", quality: .standard)
        return Provenance(provider: .openai, model: "m", quality: .standard, outputSize: PixelSize(width: 8, height: 8),
                          promptSent: "p", styleRevision: style, assetRevisions: assets, storyTextIncluded: false,
                          intent: intent)
    }

    static func run(_ c: BookContent, assessments: [BoxImageKey: ImageAssessment] = [:],
                    bad: Set<String> = []) -> [PreflightIssue] {
        Preflight.run(c, assessments: assessments, spelling: FakeSpelling(bad))
    }
}

@MainActor
struct PreflightTests {
    @Test func cleanBookHasNoIssues() {
        #expect(PF.run(PF.clean()).isEmpty)
    }

    @Test func emptyImageBox() {
        var c = PF.clean()
        let p = c.book.pageOrder[1]
        c.pages[p]?.images[PF.imageBox.id]?.placement = nil
        let issues = PF.run(c)
        #expect(issues.map(\.kind) == [.emptyImageBox])
        #expect(issues[0].page == p && issues[0].box == PF.imageBox.id)
    }

    @Test func textOverflow() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        c.pages[p]?.text[PF.textBox.id] = RichText(plain: String(repeating: "The fox ran home. ", count: 80))
        let issues = PF.run(c)
        #expect(issues.map(\.kind) == [.textOverflow])
        #expect(issues[0].box == PF.textBox.id)
    }

    @Test func textOverflow_onASpread_measuresAtTheSpreadWidth() throws {
        // A text box across both halves of a spread: 0.92 of 600 pt, not of the 300 pt page.
        var c = PF.clean()
        let box = Box(id: BoxID("00000000-0000-0000-0000-0000000000C6"),
                      frame: NormalizedRect(x: 0.04, y: 0.6, width: 0.92, height: 0.3),
                      content: .text(TextBoxStyle(padding: 6)))
        let spread = Template(id: TemplateID("00000000-0000-0000-0000-0000000000C7"), name: "Sp", kind: .spread,
                              boxes: [box])
        c.templates[spread.id] = spread
        let p = c.book.pageOrder[1]
        c.pages[p]?.templateID = spread.id
        c.pages[p]?.images = [:]
        // Fits at the spread's width; wraps past the box at a single page's width.
        let text = RichText(plain: String(repeating: "The fox ran home. ", count: 10))
        c.pages[p]?.text = [box.id: text]
        let geometry = PageGeometry(setup: c.style.pageSetup, kind: .spread)
        let inner = geometry.renderRect(for: box).insetBy(dx: 6, dy: 6).size
        let typography = c.style.typography.resolved(for: box.role)
        #expect(!TextBoxLayout(text: text, typography: typography, containerSize: inner).isOverflowing)
        #expect(TextBoxLayout(text: text, typography: typography,
                              containerSize: CGSize(width: inner.width / 2 - 6, height: inner.height)).isOverflowing)
        #expect(!PF.run(c).contains { $0.kind == .textOverflow })

        c.pages[p]?.text = [box.id: RichText(plain: String(repeating: "The fox ran home. ", count: 60))]
        #expect(PF.run(c).contains { $0.kind == .textOverflow && $0.page == p && $0.box == box.id })
    }

    @Test func spellingOnePerWordPerBox() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        c.pages[p]?.text[PF.textBox.id] = RichText(plain: "A teh fox and teh hen.")
        let issues = PF.run(c, bad: ["teh"])
        #expect(issues.map(\.kind) == [.spelling])
        #expect(issues.allSatisfy { $0.detail == "“teh”" && $0.box == PF.textBox.id })
    }

    @Test func softImage() {
        let c = PF.clean()
        let p = c.book.pageOrder[0]
        let key = BoxImageKey(page: p, box: PF.imageBox.id)
        func assessment(soft: Bool) -> ImageAssessment {
            ImageAssessment(key: key, image: PF.ref, availablePixels: CGSize(width: 512, height: 512),
                            requiredPixels: CGSize(width: 2550, height: 2550), upscaleFactor: 5, isSoft: soft)
        }
        #expect(PF.run(c, assessments: [key: assessment(soft: false)]).isEmpty)
        let issues = PF.run(c, assessments: [key: assessment(soft: true)])
        #expect(issues.map(\.kind) == [.softImage])
        #expect(issues[0].detail == "512×512 px available; needs 2550×2550 px")
    }

    @Test func styleChanged() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        PF.place(&c, page: p, box: PF.imageBox.id, provenance: PF.provenance(style: 0))
        c.style.visualRevision = 1
        #expect(PF.run(c).map(\.kind) == [.styleChanged])
    }

    @Test func assetChanged() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        var asset = Asset.makeNew(type: .place, name: "Pond")
        asset.revision = 3
        c.assets[asset.id] = asset
        PF.place(&c, page: p, box: PF.imageBox.id, provenance: PF.provenance(assets: [asset.id: 1]))
        #expect(PF.run(c).map(\.kind) == [.assetChanged])
    }

    @Test func layoutChanged() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        c.pages[p]?.images[PF.imageBox.id]?.placement?.boxAspectWhenPlaced *= 2
        #expect(PF.run(c).map(\.kind) == [.layoutChanged])
    }

    @Test func consistencyWarning() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        let report = ConsistencyReport(checkedAt: PF.now, provider: .openai, model: "m", consistent: false,
                                       differences: [], warns: true,
                                       sent: ConsistencySent(promptSent: "p", imagesSent: []))
        PF.place(&c, page: p, box: PF.imageBox.id, consistency: report)
        #expect(PF.run(c).map(\.kind) == [.consistencyWarning])
    }

    @Test func missingFontOncePerPagePerName() {
        var c = PF.clean()
        let p = c.book.pageOrder[0]
        let ghost = "NoSuchFont-Regular"
        var text = RichText(plain: "Hello there")
        text.paragraphs[0].runs[0].fontFamily = ghost
        c.pages[p]?.text[PF.textBox.id] = text
        let issues = PF.run(c)
        #expect(issues.map(\.kind) == [.missingFont])
        #expect(issues[0].page == p && issues[0].detail.contains(ghost))
    }

    @Test func missingFontReportedOnceOnFirstPage() {
        var c = PF.clean()
        let ghost = "NoSuchFont-Regular"
        for p in c.book.pageOrder {
            var text = RichText(plain: "Hello there")
            text.paragraphs[0].runs[0].fontFamily = ghost
            c.pages[p]?.text[PF.textBox.id] = text
        }
        let issues = PF.run(c)
        #expect(issues.map(\.kind) == [.missingFont])
        #expect(issues[0].page == c.book.pageOrder[0])
    }

    @Test func orderingCoverFirstThenStoryPagesThenKind() {
        var c = PF.clean()
        let cover = c.book.coverPageID
        let (p0, p1) = (c.book.pageOrder[0], c.book.pageOrder[1])
        c.pages[p1]?.images[PF.imageBox.id]?.placement = nil
        c.pages[p0]?.text[PF.textBox.id] = RichText(plain: "teh fox")
        c.pages[p0]?.images[PF.imageBox.id]?.placement = nil
        c.pages[cover]?.images[PF.coverImageBox]?.placement = nil
        let issues = PF.run(c, bad: ["teh"])
        #expect(issues.map(\.page) == [cover, p0, p0, p1])
        #expect(issues.map(\.kind) == [.emptyImageBox, .emptyImageBox, .spelling, .emptyImageBox])
    }
}
