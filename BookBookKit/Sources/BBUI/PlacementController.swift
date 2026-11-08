import AppKit
import BBLayout
import BBModel

/// The page canvas mode (A §6.2): draws the selected page, its overflow badges (a red "+" at a
/// text box's bottom-right when its text doesn't fit, screen only, A §8.3) and the selected
/// image box's outline, and handles clicks: select an image box, edit a text box in place
/// (through `textEditing`), or open Book Settings for a bound title/author box.
@MainActor
final class PlacementController: CanvasController {
    weak var canvas: CanvasView? {
        didSet { textEditing.canvas = canvas }
    }
    let textEditing = TextEditingController()

    private(set) var content: BookContent?
    private(set) var pageID: PageID?
    /// `content` with a spread's double-width trim, for `PageRenderer` (A §8.2).
    private var renderContent: BookContent?
    /// The page's numbers, drawn on screen as in the PDF (PD §8.2).
    private(set) var pageNumberMarks: [PageNumberMark] = []
    private var selectedImageBox: BoxID?
    private var imageSource: (any PageImageSource)?
    private var fontsRevision: Int?

    var onSelectImageBox: (BoxID?) -> Void = { _ in }
    /// Double-click on a title/author box (bound to the book, PD §8.7).
    var onOpenBookSettings: () -> Void = {}

    /// Diameter of the overflow badge, in view points.
    static let overflowBadgeDiameter: CGFloat = 16

    // MARK: Updates from SwiftUI

    func update(content: BookContent, pageID: PageID?, selectedImageBox: BoxID?, imageSource: any PageImageSource,
                fontsRevision: Int = 0) {
        let pageChanged = pageID != self.pageID
        // Fonts were registered since the layouts were made: they may have used a fallback.
        if fontsRevision != self.fontsRevision {
            self.fontsRevision = fontsRevision
            canvas?.layoutCache.removeAll()
        }
        self.content = content
        self.pageID = pageID
        let page = pageID.flatMap { content.pages[$0] }
        renderContent = page.map { PageGeometry.drawContent(for: $0, in: content) } ?? content
        pageNumberMarks = pageID.map { PageNumberMarks(content: content).marks(for: $0) } ?? []
        self.selectedImageBox = selectedImageBox
        self.imageSource = imageSource

        if let editing = textEditing.editingBoxID {
            if pageChanged || textBox(editing) == nil {
                textEditing.end()
            } else if let pageID, let (box, _) = textBox(editing) {
                textEditing.reloadIfNeeded(modelText: content.pages[pageID]?.text[editing] ?? .empty,
                                           typography: typography(for: box, in: content))
                positionEditor()
            }
        }
        canvas?.needsDisplay = true
    }

    func canvasDidResize() {
        positionEditor()
    }

    // MARK: Geometry

    private var page: Page? { pageID.flatMap { content?.pages[$0] } }

    var scene: CanvasScene? {
        guard let renderContent, let page, let imageSource else { return nil }
        var options = RenderOptions.screen
        if let editing = textEditing.editingBoxID { options.hiddenTextBoxes = [editing] }
        options.pageNumbers = pageNumberMarks
        let geometry = PageGeometry.drawGeometry(for: page, in: renderContent)
        return CanvasScene(content: renderContent, page: page, options: options, images: imageSource,
                           showsFold: geometry.isSpread, showsBleed: geometry.bleed > 0)
    }

    /// The draw geometry: double width with a fold for a spread template.
    private var geometry: PageGeometry? {
        guard let renderContent, let page else { return nil }
        return PageGeometry.drawGeometry(for: page, in: renderContent)
    }

    /// Every box on the page with its render rect (bleed-extended when bleed is on), in layer
    /// order. Hit-testing and the selection outline rotate about this rect's centre, as
    /// `PageRenderer` draws.
    var boxRects: [(box: Box, rect: CGRect)] {
        guard let content, let page, let template = content.template(for: page), let geometry else { return [] }
        return template.boxes.map { ($0, geometry.renderRect(for: $0)) }
    }

    private func textBox(_ id: BoxID) -> (box: Box, rect: CGRect)? {
        boxRects.first { $0.box.id == id && $0.box.content != .image }
    }

    /// The typography a box lays out with (as `PageRenderer`: role, then the box's overrides).
    private func typography(for box: Box, in content: BookContent) -> Typography {
        InlineTextEditor.typography(for: box, base: content.style.typography)
    }

    /// Text boxes on the page whose text doesn't fit (same container as `PageRenderer`).
    func overflowingTextBoxes() -> [(box: Box, rect: CGRect)] {
        guard let content, let page, let layoutCache = canvas?.layoutCache else { return [] }
        return boxRects.filter { box, rect in
            guard case let .text(style) = box.content,
                  let text = CoverText.boundText(for: box.role, book: content.book) ?? page.text[box.id],
                  !text.paragraphs.isEmpty
            else { return false }
            let inner = rect.insetBy(dx: CGFloat(style.padding), dy: CGFloat(style.padding))
            let size = CGSize(width: max(0, inner.width), height: max(0, inner.height))
            return layoutCache.layout(text: text, typography: typography(for: box, in: content),
                                      containerSize: size).isOverflowing
        }
    }

    // MARK: Drawing

    func drawOverlay(in ctx: CGContext, transform: CanvasTransform) {
        for (box, rect) in overflowingTextBoxes() {
            drawOverflowBadge(box: box, rect: rect, scale: transform.scale, ctx: ctx)
        }

        if let selectedImageBox, let selected = boxRects.first(where: { $0.box.id == selectedImageBox }) {
            ctx.saveGState()
            CanvasView.applyRotation(selected.box.rotationDegrees, about: selected.rect, ctx: ctx)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2 / transform.scale)
            ctx.stroke(selected.rect.insetBy(dx: -1 / transform.scale, dy: -1 / transform.scale))
            ctx.restoreGState()
        }
    }

    /// A red circle with a white "+" centred on the box's bottom-right corner (rotated with
    /// the box), constant size on screen.
    private func drawOverflowBadge(box: Box, rect: CGRect, scale: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        CanvasView.applyRotation(box.rotationDegrees, about: rect, ctx: ctx)
        let diameter = Self.overflowBadgeDiameter / scale
        let badge = CGRect(x: rect.maxX - diameter / 2, y: rect.maxY - diameter / 2, width: diameter, height: diameter)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fillEllipse(in: badge)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2 / scale)
        ctx.setLineCap(.round)
        let arm = diameter * 0.25
        ctx.move(to: CGPoint(x: badge.midX - arm, y: badge.midY))
        ctx.addLine(to: CGPoint(x: badge.midX + arm, y: badge.midY))
        ctx.move(to: CGPoint(x: badge.midX, y: badge.midY - arm))
        ctx.addLine(to: CGPoint(x: badge.midX, y: badge.midY + arm))
        ctx.strokePath()
    }

    // MARK: Mouse

    func mouseDown(with event: NSEvent, at point: CGPoint) {
        let hit = CanvasHitTest.box(at: point, in: boxRects)
        switch CanvasHitTest.click(on: hit, clickCount: event.clickCount) {
        case .deselect:
            textEditing.end()
            onSelectImageBox(nil)
        case let .selectImage(id):
            textEditing.end()
            onSelectImageBox(id)
        case let .editText(id):
            if textEditing.editingBoxID != id { beginEditing(id) }
        case .openBookSettings:
            textEditing.end()
            onOpenBookSettings()
        case .ignore:
            textEditing.end()
        }
    }

    // MARK: Text editing

    private func beginEditing(_ boxID: BoxID) {
        textEditing.end()
        // Title/author boxes show the book's fields; they're edited in Book Settings.
        guard let content, let pageID, let (box, rect) = textBox(boxID), !CoverText.isBound(box.role) else { return }
        textEditing.begin(pageID: pageID, boxID: boxID, text: content.pages[pageID]?.text[boxID] ?? .empty,
                          typography: typography(for: box, in: content),
                          textRect: CanvasHitTest.textRect(rect, box: box))
    }

    private func positionEditor() {
        guard let editing = textEditing.editingBoxID, let (box, rect) = textBox(editing) else { return }
        textEditing.place(textRect: CanvasHitTest.textRect(rect, box: box))
    }
}
