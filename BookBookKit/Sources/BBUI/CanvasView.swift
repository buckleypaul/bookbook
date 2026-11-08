import AppKit
import BBLayout
import BBModel
import SwiftUI

/// The page canvas (A §6.2): a layer-backed, flipped `NSView` that draws the selected page with
/// `PageRenderer`, scaled to fit, and hosts the in-place text editor. Text layouts come from
/// one `TextBoxLayoutCache`; a text box whose text doesn't fit gets a red "+" badge at its
/// bottom-right corner (screen only, A §8.3).
///
/// HOT SPOT (plan §2.5): one lane at a time.
@MainActor
final class CanvasView: NSView {
    private(set) var content: BookContent?
    private(set) var pageID: PageID?
    private var selectedImageBox: BoxID?
    private var imageSource: (any PageImageSource)?
    private var editor: InlineTextEditor?
    /// Shared by the overflow badges (and, after the Phase 4 merge, the renderer).
    let layoutCache = TextBoxLayoutCache()
    private var fontsRevision: Int?

    var onSelectImageBox: (BoxID?) -> Void = { _ in }
    /// A text change: page, box, text, and whether it may coalesce with the typing before it.
    var onTextChange: (PageID, BoxID, RichText, Bool) -> Void = { _, _, _, _ in }
    /// Ends the document's typing undo step (formatting with no text change, editor closing).
    var onEndTypingStep: () -> Void = {}
    var undoManagerProvider: () -> UndoManager? = { nil }
    /// The window's format bar / Format menu controller; the editor drives it.
    weak var formatting: TextFormatController?

    /// Diameter of the overflow badge, in view points.
    static let overflowBadgeDiameter: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var editingBoxID: BoxID? { editor?.boxID }

    // MARK: Updates from SwiftUI

    func update(content: BookContent, pageID: PageID?, selectedImageBox: BoxID?, imageSource: any PageImageSource,
                fontsRevision: Int = 0) {
        let pageChanged = pageID != self.pageID
        // Fonts were registered since the layouts were made: they may have used a fallback.
        if fontsRevision != self.fontsRevision {
            self.fontsRevision = fontsRevision
            layoutCache.removeAll()
        }
        self.content = content
        self.pageID = pageID
        self.selectedImageBox = selectedImageBox
        self.imageSource = imageSource

        if let editor {
            if pageChanged || textBox(editor.boxID) == nil {
                endEditing()
            } else if let pageID, let (box, _) = textBox(editor.boxID) {
                editor.reloadIfNeeded(modelText: content.pages[pageID]?.text[editor.boxID] ?? .empty,
                                      typography: typography(for: box, in: content))
                positionEditor()
            }
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionEditor()
        needsDisplay = true
    }

    // MARK: Geometry

    private var page: Page? { pageID.flatMap { content?.pages[$0] } }

    private var geometry: PageGeometry? { content.map { PageGeometry(setup: $0.style.pageSetup) } }

    private var transform: CanvasTransform? {
        guard let geometry else { return nil }
        return CanvasTransform(viewSize: bounds.size, pageSize: geometry.trimSize)
    }

    /// Every box on the page with its render rect, in layer order.
    private var boxRects: [(box: Box, rect: CGRect)] {
        guard let content, let page, let template = content.template(for: page), let geometry else { return [] }
        return template.boxes.map { ($0, geometry.renderRect(for: $0)) }
    }

    private func textBox(_ id: BoxID) -> (box: Box, rect: CGRect)? {
        boxRects.first { $0.box.id == id && $0.box.content != .image }
    }

    /// The typography a box lays out with (title-role boxes use the title font).
    private func typography(for box: Box, in content: BookContent) -> Typography {
        content.style.typography.resolved(for: box.role)
    }

    /// Text boxes on the page whose text doesn't fit (same container as `PageRenderer`).
    func overflowingTextBoxes() -> [(box: Box, rect: CGRect)] {
        guard let content, let page else { return [] }
        return boxRects.filter { box, rect in
            guard case let .text(style) = box.content, let text = page.text[box.id], !text.paragraphs.isEmpty
            else { return false }
            let inner = rect.insetBy(dx: CGFloat(style.padding), dy: CGFloat(style.padding))
            let size = CGSize(width: max(0, inner.width), height: max(0, inner.height))
            return layoutCache.layout(text: text, typography: typography(for: box, in: content),
                                      containerSize: size).isOverflowing
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        guard let content, let page, let imageSource, let transform, let geometry else { return }
        let trim = CGRect(origin: .zero, size: geometry.trimSize)

        ctx.saveGState()
        ctx.translateBy(x: transform.origin.x, y: transform.origin.y)
        ctx.scaleBy(x: transform.scale, y: transform.scale)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(trim)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: trim)
        var options = RenderOptions.screen
        if let editing = editor?.boxID { options.hiddenTextBoxes = [editing] }
        let renderer = PageRenderer(images: imageSource)
        // TODO(merge): renderer.layouts = layoutCache
        renderer.draw(page: page, in: content, into: ctx, options: options)
        ctx.restoreGState()

        for (box, rect) in overflowingTextBoxes() {
            drawOverflowBadge(box: box, rect: rect, scale: transform.scale, ctx: ctx)
        }

        if let selectedImageBox, let selected = boxRects.first(where: { $0.box.id == selectedImageBox }) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2 / transform.scale)
            ctx.stroke(selected.rect.insetBy(dx: -1 / transform.scale, dy: -1 / transform.scale))
        }
        ctx.restoreGState()
    }

    /// A red circle with a white "+" centred on the box's bottom-right corner (rotated with
    /// the box), constant size on screen.
    private func drawOverflowBadge(box: Box, rect: CGRect, scale: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if box.rotationDegrees != 0, box.rotationDegrees.isFinite {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(box.rotationDegrees) * .pi / 180)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
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

    override func mouseDown(with event: NSEvent) {
        guard let transform else { return }
        let point = transform.toPage(convert(event.locationInWindow, from: nil))
        guard let hit = CanvasHitTest.box(at: point, in: boxRects) else {
            endEditing()
            onSelectImageBox(nil)
            return
        }
        switch hit.content {
        case .image:
            endEditing()
            onSelectImageBox(hit.id)
        case .text:
            if editor?.boxID != hit.id { beginEditing(hit.id) }
        }
    }

    // MARK: Text editing

    private func beginEditing(_ boxID: BoxID) {
        endEditing()
        guard let content, let pageID, let (box, _) = textBox(boxID) else { return }
        let editor = InlineTextEditor(
            pageID: pageID, boxID: boxID, text: content.pages[pageID]?.text[boxID] ?? .empty,
            typography: typography(for: box, in: content), formatting: formatting,
            undoManager: { [weak self] in self?.undoManagerProvider() },
            onChange: { [weak self] text, coalescing in self?.onTextChange(pageID, boxID, text, coalescing) })
        editor.onCancel = { [weak self] in self?.endEditing() }
        editor.onEndTypingStep = { [weak self] in self?.onEndTypingStep() }
        self.editor = editor
        addSubview(editor.host)
        positionEditor()
        editor.beginEditing(in: window)
        needsDisplay = true
    }

    func endEditing() {
        guard let editor else { return }
        let wasFirstResponder = window?.firstResponder === editor.textView
        editor.tearDown()
        self.editor = nil
        onEndTypingStep()
        if wasFirstResponder { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func positionEditor() {
        guard let editor, let transform, let (box, rect) = textBox(editor.boxID) else { return }
        let textRect = CanvasHitTest.textRect(rect, box: box)
        editor.place(viewRect: transform.toView(textRect), pageSize: textRect.size)
    }
}

/// SwiftUI wrapper for `CanvasView`.
struct PageCanvas: NSViewRepresentable {
    let document: BookDocument
    let content: BookContent
    let pageID: PageID?
    let imageSource: ImageCache
    @Binding var selectedImageBox: BoxID?

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(frame: .zero)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        let document = document, selection = $selectedImageBox
        let undoManager = context.environment.undoManager
        view.onSelectImageBox = { selection.wrappedValue = $0 }
        view.onTextChange = { page, box, text, coalescing in
            document.perform(.setRichText(page: page, box: box, text: text, coalescing: coalescing))
        }
        view.onEndTypingStep = { document.endTypingStep() }
        view.formatting = document.formatting
        view.undoManagerProvider = { [weak undoManager] in undoManager }
        view.update(content: content, pageID: pageID, selectedImageBox: selectedImageBox, imageSource: imageSource,
                    fontsRevision: document.fontsRevision)
    }

    static func dismantleNSView(_ view: CanvasView, coordinator: ()) {
        view.endEditing()
    }
}
