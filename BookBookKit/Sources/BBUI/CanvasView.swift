import AppKit
import BBLayout
import BBModel
import SwiftUI

/// What the canvas draws: one page or spread, through `PageRenderer`.
@MainActor
struct CanvasScene {
    /// The content to render. `style.pageSetup` is the draw trim (double width for a spread).
    var content: BookContent
    var page: Page
    var options: RenderOptions
    var images: any PageImageSource
    /// Draw the centre fold (screen only).
    var showsFold: Bool = false
    /// Show the bleed area around the trim (the sheet grows by the bleed).
    var showsBleed: Bool = false
}

/// A canvas mode (plan Phase 6 Risks): supplies the scene and its overlays and handles input.
/// `CanvasView` owns the drawing set-up, the fit-to-view transform and event forwarding.
/// Every point a controller receives is in page space (trim points, top-left origin, y down).
@MainActor
protocol CanvasController: AnyObject {
    /// Set by `CanvasView.controller`.
    var canvas: CanvasView? { get set }
    /// What to draw; nil leaves the canvas empty.
    var scene: CanvasScene? { get }
    /// Called before each draw (observation, cache upkeep).
    func willDraw()
    /// Draws over the rendered page, in page space (the context is already transformed).
    func drawOverlay(in ctx: CGContext, transform: CanvasTransform)
    func mouseDown(with event: NSEvent, at point: CGPoint)
    func mouseDragged(with event: NSEvent, at point: CGPoint)
    func mouseUp(with event: NSEvent, at point: CGPoint)
    func flagsChanged(with event: NSEvent)
    /// True if the controller handled the key.
    func keyDown(with event: NSEvent) -> Bool
    /// The cursor to show over `point`; nil leaves the cursor alone.
    func cursor(at point: CGPoint) -> NSCursor?
    /// The view's size changed (re-place subviews).
    func canvasDidResize()
}

extension CanvasController {
    func willDraw() {}
    func drawOverlay(in ctx: CGContext, transform: CanvasTransform) {}
    func mouseDown(with event: NSEvent, at point: CGPoint) {}
    func mouseDragged(with event: NSEvent, at point: CGPoint) {}
    func mouseUp(with event: NSEvent, at point: CGPoint) {}
    func flagsChanged(with event: NSEvent) {}
    func keyDown(with event: NSEvent) -> Bool { false }
    func cursor(at point: CGPoint) -> NSCursor? { nil }
    func canvasDidResize() {}
}

/// The canvas (A §6.2): a layer-backed, flipped `NSView` that draws its controller's scene with
/// `PageRenderer`, scaled to fit, plus the controller's overlays, and forwards input to the
/// controller. Modes: `PlacementController` (+ `TextEditingController`) for the page canvas,
/// `LayoutEditingController` for the template editor. Text layouts come from one
/// `TextBoxLayoutCache`.
///
/// HOT SPOT (plan §2.5): one lane at a time.
@MainActor
final class CanvasView: NSView {
    /// The active mode.
    var controller: (any CanvasController)? {
        didSet {
            if oldValue !== controller { oldValue?.canvas = nil }
            controller?.canvas = self
            needsDisplay = true
        }
    }
    /// Shared by the renderer and the controllers (overflow badges).
    let layoutCache = TextBoxLayoutCache()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.canvasDidResize()
        needsDisplay = true
    }

    // MARK: Geometry

    /// The scene's geometry (its `setup` is the draw trim: double width for a spread).
    var geometry: PageGeometry? { controller?.scene.map { PageGeometry(setup: $0.content.style.pageSetup) } }

    /// The area fitted to the view: the trim, grown by the bleed when it's shown.
    private func sheetRect(_ scene: CanvasScene, geometry: PageGeometry) -> CGRect {
        scene.showsBleed ? geometry.trimRect.insetBy(dx: -geometry.bleed, dy: -geometry.bleed) : geometry.trimRect
    }

    /// View ↔ page transform.
    var transform: CanvasTransform? {
        guard let scene = controller?.scene else { return nil }
        let geometry = PageGeometry(setup: scene.content.style.pageSetup)
        return CanvasTransform(viewSize: bounds.size, fitting: sheetRect(scene, geometry: geometry))
    }

    private var lastPagePoint: CGPoint?

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        transform?.toPage(convert(event.locationInWindow, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        controller?.willDraw()
        guard let controller, let scene = controller.scene else { return }
        let geometry = PageGeometry(setup: scene.content.style.pageSetup)
        let sheet = sheetRect(scene, geometry: geometry)
        let transform = CanvasTransform(viewSize: bounds.size, fitting: sheet)

        ctx.saveGState()
        ctx.translateBy(x: transform.origin.x, y: transform.origin.y)
        ctx.scaleBy(x: transform.scale, y: transform.scale)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(sheet)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: sheet)
        var renderer = PageRenderer(images: scene.images)
        renderer.layouts = layoutCache
        renderer.draw(page: scene.page, in: scene.content, into: ctx, options: scene.options)
        ctx.restoreGState()

        if scene.showsFold {
            // The fold, on screen only.
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(1 / transform.scale)
            ctx.setLineDash(phase: 0, lengths: [4 / transform.scale, 3 / transform.scale])
            ctx.move(to: CGPoint(x: geometry.foldX, y: 0))
            ctx.addLine(to: CGPoint(x: geometry.foldX, y: geometry.trimSize.height))
            ctx.strokePath()
            ctx.restoreGState()
        }

        controller.drawOverlay(in: ctx, transform: transform)
        ctx.restoreGState()
    }

    /// Applies `rotationDegrees` about `rect`'s centre (as `PageRenderer` does).
    static func applyRotation(_ rotationDegrees: Double, about rect: CGRect, ctx: CGContext) {
        guard rotationDegrees != 0, rotationDegrees.isFinite else { return }
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(rotationDegrees) * .pi / 180)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard let controller, let point = pagePoint(event) else { return }
        lastPagePoint = point
        controller.mouseDown(with: event, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let point = pagePoint(event) else { return }
        lastPagePoint = point
        controller.mouseDragged(with: event, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        // Always deliver mouse-up: a drag's undo group must close even if the pointer left
        // the page (no page point), so fall back to the last known position.
        let point = pagePoint(event) ?? lastPagePoint ?? .zero
        controller.mouseUp(with: event, at: point)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.flagsChanged(with: event)
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.keyDown(with: event) != true { super.keyDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if let point = pagePoint(event), let cursor = controller?.cursor(at: point) {
            cursor.set()
        } else {
            super.mouseMoved(with: event)
        }
    }
}

// MARK: - Page canvas

extension CanvasView {
    /// The page-canvas mode, created on first use.
    var placement: PlacementController {
        if let placement = controller as? PlacementController { return placement }
        let placement = PlacementController()
        controller = placement
        return placement
    }

    func update(content: BookContent, pageID: PageID?, selectedImageBox: BoxID?, imageSource: any PageImageSource,
                fontsRevision: Int = 0) {
        placement.update(content: content, pageID: pageID, selectedImageBox: selectedImageBox,
                         imageSource: imageSource, fontsRevision: fontsRevision)
    }

    var content: BookContent? { placement.content }
    var pageID: PageID? { placement.pageID }
    /// The page's numbers, drawn on screen as in the PDF (PD §8.2).
    var pageNumberMarks: [PageNumberMark] { placement.pageNumberMarks }
    /// Every box on the page with its render rect, in layer order.
    var boxRects: [(box: Box, rect: CGRect)] { placement.boxRects }
    func overflowingTextBoxes() -> [(box: Box, rect: CGRect)] { placement.overflowingTextBoxes() }
    var editingBoxID: BoxID? { placement.textEditing.editingBoxID }
    func endEditing() { placement.textEditing.end() }

    var onSelectImageBox: (BoxID?) -> Void {
        get { placement.onSelectImageBox }
        set { placement.onSelectImageBox = newValue }
    }
    /// Double-click on a title/author box (bound to the book, PD §8.7).
    var onOpenBookSettings: () -> Void {
        get { placement.onOpenBookSettings }
        set { placement.onOpenBookSettings = newValue }
    }
    /// A text change: page, box, text, and whether it may coalesce with the typing before it.
    var onTextChange: (PageID, BoxID, RichText, Bool) -> Void {
        get { placement.textEditing.onTextChange }
        set { placement.textEditing.onTextChange = newValue }
    }
    /// Ends the document's typing undo step (formatting with no text change, editor closing).
    var onEndTypingStep: () -> Void {
        get { placement.textEditing.onEndTypingStep }
        set { placement.textEditing.onEndTypingStep = newValue }
    }
    var undoManagerProvider: () -> UndoManager? {
        get { placement.textEditing.undoManagerProvider }
        set { placement.textEditing.undoManagerProvider = newValue }
    }
    /// The window's format bar / Format menu controller; the editor drives it.
    var formatting: TextFormatController? {
        get { placement.textEditing.formatting }
        set { placement.textEditing.formatting = newValue }
    }
}

/// SwiftUI wrapper for the page canvas.
struct PageCanvas: NSViewRepresentable {
    let document: BookDocument
    let content: BookContent
    let pageID: PageID?
    let imageSource: ImageCache
    @Binding var selectedImageBox: BoxID?
    /// Double-click on a title/author box.
    var onOpenBookSettings: () -> Void = {}

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero)
        view.controller = PlacementController()
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        let document = document, selection = $selectedImageBox
        let undoManager = context.environment.undoManager
        view.onSelectImageBox = { selection.wrappedValue = $0 }
        view.onTextChange = { page, box, text, coalescing in
            document.perform(.setRichText(page: page, box: box, text: text, coalescing: coalescing))
        }
        view.onEndTypingStep = { document.endTypingStep() }
        view.onOpenBookSettings = onOpenBookSettings
        view.formatting = document.formatting
        view.undoManagerProvider = { [weak undoManager] in undoManager }
        view.update(content: content, pageID: pageID, selectedImageBox: selectedImageBox, imageSource: imageSource,
                    fontsRevision: document.fontsRevision)
    }

    static func dismantleNSView(_ view: CanvasView, coordinator: ()) {
        view.endEditing()
    }
}
