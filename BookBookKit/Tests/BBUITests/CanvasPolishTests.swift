import AppKit
import BBLayout
import BBModel
import Foundation
import Testing
@testable import BBUI

/// UI polish on the page canvas and the format bar: click-to-caret mapping, the I-beam over
/// text boxes, overflow badge tooltips, and the resolved size / colour the format bar shows.
@MainActor
struct CanvasPolishTests {
    final class NoImages: PageImageSource {
        func image(for ref: ImageRef) -> CGImage? { nil }
    }

    func mouseDown() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func canvas(_ content: BookContent) -> CanvasView {
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        view.update(content: content, pageID: Fixtures.firstPage(content), selectedImageBox: nil,
                    imageSource: NoImages())
        return view
    }

    func centre(of id: BoxID, in view: CanvasView) throws -> CGPoint {
        let rect = try #require(view.boxRects.first { $0.box.id == id }?.rect)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: Click to caret

    @Test func clickOnARotatedBox_mapsToTheUprightEditor() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20) // centre (50, 10)
        // A point 30 below the centre of a box turned 90° clockwise lies 30 right of centre on the
        // upright box (where its start was turned to); without rotation it's unchanged.
        let upright = TextEditingController.uprightPoint(CGPoint(x: 50, y: 40), boxRect: rect, rotationDegrees: 90)
        #expect(abs(upright.x - 80) < 1e-9 && abs(upright.y - 10) < 1e-9)
        #expect(TextEditingController.uprightPoint(CGPoint(x: 7, y: 9), boxRect: rect, rotationDegrees: 0)
            == CGPoint(x: 7, y: 9))
        // Mapping back with the box's rotation returns the click.
        let back = BoxHitTesting.unrotate(upright, rect: rect, rotationDegrees: -90)
        #expect(abs(back.x - 50) < 1e-9 && abs(back.y - 40) < 1e-9)
    }

    @Test func clickWithoutAWindow_startsEditingWithTheCaretAtTheEnd() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        content.pages[page]?.text[Fixtures.textBox.id] = RichText(plain: "Once upon a time")
        let view = canvas(content)
        let point = try centre(of: Fixtures.textBox.id, in: view)
        view.placement.mouseDown(with: mouseDown(), at: point)
        let editor = try #require(view.placement.textEditing.editor)
        #expect(editor.boxID == Fixtures.textBox.id)
        // No window to track the click in: the keyboard-entry fallback.
        #expect(editor.textView.selectedRange() == NSRange(location: 16, length: 0))
        view.endEditing()
    }

    // MARK: Cursor

    @Test func cursor_isAnIBeamOverEditableText_andTheArrowComesBackOnce() throws {
        let view = canvas(Fixtures.book())
        let placement = view.placement
        let text = try centre(of: Fixtures.textBox.id, in: view)
        let image = try centre(of: Fixtures.imageBox.id, in: view)
        #expect(placement.cursor(at: text) == .iBeam)
        #expect(placement.cursor(at: image) == .arrow, "leaving the text puts the arrow back")
        #expect(placement.cursor(at: image) == nil, "then the cursor is left alone")
    }

    // MARK: Overflow badge

    @Test func overflowBadge_hasATooltipOverItsCorner() throws {
        var content = Fixtures.book()
        let page = Fixtures.firstPage(content)
        content.pages[page]?.text[Fixtures.textBox.id] =
            RichText(plain: String(repeating: "A long line of story text that won't fit. ", count: 80))
        let view = canvas(content)

        let ctx = try #require(CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.current = previous

        let tip = try #require(view.tips.first)
        #expect(view.tips.count == 1)
        #expect(tip.text == "This text doesn't fit in its box.")
        let transform = try #require(view.transform)
        let rect = try #require(view.boxRects.first { $0.box.id == Fixtures.textBox.id }?.rect)
        let corner = transform.toView(CGPoint(x: rect.maxX, y: rect.maxY))
        #expect(tip.viewRect.contains(corner))
        #expect(tip.viewRect.width >= PlacementController.overflowBadgeDiameter)
        let elements = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        #expect(elements.contains { $0.accessibilityLabel() == tip.text })
    }

    @Test func overflowBadgeCentre_turnsWithTheBox() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20) // centre (50, 10)
        let upright = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .text(TextBoxStyle()))
        #expect(PlacementController.overflowBadgeCentre(box: upright, rect: rect) == CGPoint(x: 100, y: 20))
        var turned = upright
        turned.rotationDegrees = 90
        // Bottom-right (50, 10) from the centre, turned 90° clockwise on a y-down page: (-10, 50).
        let centre = PlacementController.overflowBadgeCentre(box: turned, rect: rect)
        #expect(abs(centre.x - 40) < 1e-9 && abs(centre.y - 60) < 1e-9)
    }

    /// The canvas draws with `NSColor(Crayon…)` resolved at draw time: the bridged colour must
    /// still follow the appearance.
    @Test func crayonColoursBridgeToAppKitPerAppearance() throws {
        func resolved(_ name: NSAppearance.Name) throws -> CGColor {
            let appearance = try #require(NSAppearance(named: name))
            var color: CGColor?
            appearance.performAsCurrentDrawingAppearance { color = NSColor(Crayon.paper).cgColor }
            return try #require(color)
        }
        let light = try resolved(.aqua), dark = try resolved(.darkAqua)
        #expect(light != dark)
        let components = try #require(NSColor(cgColor: light)?.usingColorSpace(.sRGB))
        #expect(abs(components.redComponent - 1) < 0.01, "light paper is cream (FFF8EC)")
    }

    // MARK: Format bar

    @Test func formatState_resolvesSizeAndColourWhenFollowingTheStyle() {
        let typography = Typography.default
        let plain = RichTextFormatting.state(of: [Run(text: "a")], typography: typography)
        #expect(plain.size == nil && plain.color == nil, "no overrides")
        #expect(plain.resolvedSize == typography.bodySize)
        #expect(plain.resolvedColor == typography.color)
        #expect(!plain.isFontMixed)
        #expect(FormatBar.sizeLabel(plain) == String(format: "%g", typography.bodySize))
        #expect(FormatBar.fontLabel(plain) == "Style Default")

        let red = RGBA(red: 1, green: 0, blue: 0)
        let mixed = RichTextFormatting.state(
            of: [Run(text: "a"), Run(text: "b", fontFamily: "Georgia", size: 40, color: red)], typography: typography)
        #expect(mixed.resolvedSize == nil && mixed.resolvedColor == nil && mixed.isFontMixed)
        #expect(FormatBar.sizeLabel(mixed) == "–")
        #expect(FormatBar.fontLabel(mixed) == "Mixed")
        #expect(FormatBar.sizeLabel(nil) == "–")

        // An override equal to the style's size draws the same: not mixed.
        let same = RichTextFormatting.state(of: [Run(text: "a"), Run(text: "b", size: typography.bodySize)],
                                            typography: typography)
        #expect(same.resolvedSize == typography.bodySize)
    }

    @Test func alignmentChoices_haveLabelsAndShortcuts() {
        #expect(FormatBar.alignments.map(\.title) == ["Style Default", "Align Left", "Centre", "Align Right", "Justify"])
        #expect(FormatBar.alignments.first?.value == nil)
        #expect(FormatBar.alignmentHelp.contains("Align Left (⌘{)"))
    }
}
