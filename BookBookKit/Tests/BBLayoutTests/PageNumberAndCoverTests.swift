import Foundation
import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@MainActor
@Suite("Page numbers and bound cover text")
struct PageNumberAndCoverTests {
    init() { LayoutFixtures.registerFonts() }

    static let trim = PointSize(width: 300, height: 400)
    static let setup = PageSetup(trimSize: trim, orientation: .portrait, margins: EdgeInsetsPt(all: 30))

    static func geometry() -> PageGeometry { PageGeometry(setup: setup) }

    static func style(_ position: PageNumberPosition) -> PageNumberStyle {
        PageNumberStyle(enabled: true, position: position, size: 12)
    }

    static let single = Template(name: "S", kind: .single, boxes: [])
    static let spread = Template(name: "Sp", kind: .spread, boxes: [])

    func placement(_ position: PageNumberPosition, left: Bool, half: Int = 0,
                   template: Template = single) -> PageNumberDrawing.Placement {
        PageNumberDrawing.placement(for: PageNumberMark(text: "3", half: half, isLeftHand: left),
                                    style: Self.style(position), template: template, geometry: Self.geometry())
    }

    @Test func bottomCenter_isCentredInBottomMarginBand() {
        let p = placement(.bottomCenter, left: false)
        #expect(p.alignment == .center)
        #expect(p.rect.minX == 30 && p.rect.maxX == 270)
        #expect(abs(p.rect.midY - 385) < 0.01) // band 370...400
    }

    @Test func topCenter_isInTopBand() {
        let p = placement(.topCenter, left: false)
        #expect(abs(p.rect.midY - 15) < 0.01)
    }

    @Test func outerAndInner_followTheHand() {
        #expect(placement(.bottomOuter, left: true).alignment == .leading)
        #expect(placement(.bottomOuter, left: false).alignment == .trailing)
        #expect(placement(.bottomInner, left: true).alignment == .trailing)
        #expect(placement(.bottomInner, left: false).alignment == .leading)
        #expect(placement(.topOuter, left: false).alignment == .trailing)
        #expect(placement(.topInner, left: false).alignment == .leading)
    }

    @Test func spreadHalves_useTheirHalf() {
        let left = placement(.bottomCenter, left: true, half: 0, template: Self.spread)
        let right = placement(.bottomCenter, left: false, half: 1, template: Self.spread)
        #expect(left.rect.minX == 30 && left.rect.maxX == 120)
        #expect(right.rect.minX == 180 && right.rect.maxX == 270)
    }

    @Test func slotBox_winsOverPosition() {
        let slot = Box(frame: NormalizedRect(x: 0.4, y: 0.9, width: 0.2, height: 0.05),
                       content: .text(TextBoxStyle()), role: .pageNumberSlot)
        let template = Template(name: "Slot", kind: .single, boxes: [slot])
        let p = placement(.topOuter, left: true, template: template)
        #expect(p.alignment == .center)
        #expect(p.rect == Self.geometry().renderRect(for: slot))
    }

    @Test func slotBox_inSpreadIsPickedByHalf() {
        let l = Box(frame: NormalizedRect(x: 0.2, y: 0.9, width: 0.1, height: 0.05),
                    content: .text(TextBoxStyle()), role: .pageNumberSlot)
        let r = Box(frame: NormalizedRect(x: 0.7, y: 0.9, width: 0.1, height: 0.05),
                    content: .text(TextBoxStyle()), role: .pageNumberSlot)
        let template = Template(name: "Slots", kind: .spread, boxes: [l, r])
        #expect(placement(.bottomCenter, left: true, half: 0, template: template).rect.midX == 75)
        #expect(placement(.bottomCenter, left: false, half: 1, template: template).rect.midX == 225)
    }

    // MARK: Pixels

    /// Bounding box (top-left origin, 1 px = 1 pt) of dark pixels, and the raw bytes.
    func ink(_ page: Page, in content: BookContent, marks: [PageNumberMark] = []) -> (CGRect?, [UInt8]) {
        let size = Self.geometry().trimSize
        let ctx = LayoutFixtures.flippedBitmap(size: size, scale: 1)
        PageRenderer(images: DictionaryImageSource())
            .draw(page: page, in: content, into: ctx, options: RenderOptions(target: .pdfTrim, pageNumbers: marks))
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: stride * h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        // Bitmap memory row 0 is the top of the image, which is page y = 0 under the flipped CTM.
        for y in 0..<h {
            for x in 0..<w where bytes[y * stride + x * 4] < 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let rect = maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (rect, bytes)
    }

    static func book(cover: Template = Template(name: "C", kind: .cover, boxes: []), title: String = "T",
                     author: String = "") -> BookContent {
        var content = BookContent.makeNew(title: title, author: author, storyTemplate: single, coverTemplate: cover,
                                          storyPageCount: 1, now: Date(timeIntervalSince1970: 0))
        content.style.typography = LayoutFixtures.typography
        content.style.pageSetup = setup
        return content
    }

    @Test func renderedNumber_sitsInTheBandOnTheRightSide() throws {
        var content = Self.book()
        let page = content.storyPages[0]
        let cases: [(PageNumberPosition, Bool, String)] = [
            (.bottomCenter, true, "mid"), (.bottomOuter, true, "left"),
            (.bottomOuter, false, "right"), (.topInner, false, "left"),
        ]
        for (position, left, side) in cases {
            content.style.pageNumbers = Self.style(position)
            let (rect, _) = ink(page, in: content, marks: [PageNumberMark(text: "7", half: 0, isLeftHand: left)])
            let r = try #require(rect)
            switch side {
            case "mid": #expect(abs(r.midX - 150) < 8)
            case "left": #expect(r.minX >= 29 && r.maxX < 80)
            default: #expect(r.maxX <= 271 && r.minX > 220)
            }
            if position == .topInner { #expect(r.maxY < 30) } else { #expect(r.minY > 370) }
        }
    }

    @Test func noMarks_drawsNothing() {
        let content = Self.book()
        #expect(ink(content.storyPages[0], in: content).0 == nil)
    }

    @Test func boundTitleAndAuthor_replaceStoredText() throws {
        let titleBox = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2),
                           content: .text(TextBoxStyle()), role: .title)
        let authorBox = Box(frame: NormalizedRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1),
                            content: .text(TextBoxStyle()), role: .author)
        var content = Self.book(cover: Template(name: "Cover", kind: .cover, boxes: [titleBox, authorBox]),
                                title: "Fox", author: "Ann")
        var page = try #require(content.coverPage)

        let (bound, boundBytes) = ink(page, in: content)
        let r = try #require(bound)
        #expect(r.minY < 0.3 * 400 && r.maxY > 0.7 * 400) // title near the top, author lower down

        page.text[titleBox.id] = RichText(plain: "STORED TITLE THAT SHOULD NOT SHOW")
        page.text[authorBox.id] = RichText(plain: "STORED AUTHOR")
        #expect(ink(page, in: content).1 == boundBytes)

        content.book.title = ""
        content.book.author = ""
        #expect(ink(page, in: content).0 == nil)
    }

    @Test func boundTitle_countsInOverflow() throws {
        let titleBox = Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03),
                           content: .text(TextBoxStyle()), role: .title)
        var content = Self.book(cover: Template(name: "Cover", kind: .cover, boxes: [titleBox]),
                                title: "A very long title that cannot fit in a tiny box at all")
        let page = try #require(content.coverPage)
        let renderer = PageRenderer(images: DictionaryImageSource())
        #expect(renderer.overflowingTextBoxes(page: page, in: content) == [titleBox.id])
        content.book.title = "Hi"
        #expect(renderer.overflowingTextBoxes(page: page, in: content).isEmpty)
    }
}
