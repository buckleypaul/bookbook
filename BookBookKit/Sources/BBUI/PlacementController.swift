import AppKit
import BBLayout
import BBModel

/// The page canvas mode (A §6.2): draws the selected page, its overflow badges (a red "+" at a
/// text box's bottom-right when its text doesn't fit, screen only, A §8.3) and the selected
/// image box's outline, and handles clicks: select an image box, edit a text box in place
/// (through `textEditing`), or open Book Settings for a bound title/author box.
///
/// Phase 8 crop (A §6.2, §7.5): on the selected image box with a placement, a drag pans the
/// image and a pinch or scroll zooms it around the pointer. Each drag or gesture is one undo
/// step (`onBeginCrop` / `onEndCrop` bracket it with the document's undo group); a mouse wheel,
/// which has no gesture phases, closes its step after a short pause. The maths is `CropMath`,
/// through the same `PageGeometry.imageRect` export draws with.
@MainActor
final class PlacementController: CanvasController {
    weak var canvas: CanvasView? {
        didSet { textEditing.canvas = canvas }
    }
    let textEditing = TextEditingController()

    private(set) var content: BookContent?
    private(set) var pageID: PageID?
    /// The page's numbers, drawn on screen as in the PDF (PD §8.2).
    private(set) var pageNumberMarks: [PageNumberMark] = []
    private var selectedImageBox: BoxID?
    private var imageSource: (any PageImageSource)?
    private var fontsRevision: Int?

    var onSelectImageBox: (BoxID?) -> Void = { _ in }
    /// Double-click on a title/author box (bound to the book, PD §8.7).
    var onOpenBookSettings: () -> Void = {}
    /// Opens the crop's undo group. The argument is to be called if an undo or redo closes the
    /// group first (the gesture then stops).
    var onBeginCrop: (_ onClosedByReplay: @escaping @MainActor () -> Void) -> Void = { _ in }
    /// One crop update inside the group: page, box, zoom, focal point (`BookCommand.setCrop`).
    var onCrop: (PageID, BoxID, Double, NormalizedPoint) -> Void = { _, _, _, _ in }
    /// Closes the crop's undo group.
    var onEndCrop: () -> Void = {}
    /// The image box a file drag is over (drawn highlighted). Set by `CanvasView`.
    var dropTargetBox: BoxID? {
        didSet { if dropTargetBox != oldValue { canvas?.needsDisplay = true } }
    }

    /// The selected, placed image box a crop gesture works on, captured when it starts.
    struct CropTarget {
        var pageID: PageID
        var boxID: BoxID
        /// The crop as the gesture last set it (the model may not have caught up yet).
        var placement: ImagePlacement
        var imageSize: CGSize
        /// The box's render rect (unrotated frame) and rotation.
        var boxRect: CGRect
        var rotationDegrees: Double
    }
    private struct Pan {
        var target: CropTarget
        var startPoint: CGPoint
        var began = false
    }
    private var pan: Pan?
    /// An open pinch or scroll zoom.
    private var zoom: CropTarget?
    /// Closes a mouse-wheel zoom's undo step after a pause (wheels have no gesture phases).
    private var wheelIdle: Task<Void, Never>?
    /// How long a mouse-wheel zoom waits for more ticks before closing its undo step.
    static let wheelIdleInterval: Duration = .milliseconds(500)

    /// Diameter of the overflow badge, in view points.
    static let overflowBadgeDiameter: CGFloat = 16

    // MARK: Updates from SwiftUI

    func update(content: BookContent, pageID: PageID?, selectedImageBox: BoxID?, imageSource: any PageImageSource,
                fontsRevision: Int = 0) {
        let pageChanged = pageID != self.pageID
        if pageChanged || selectedImageBox != self.selectedImageBox { endCropGestures() }
        // Fonts were registered since the layouts were made: they may have used a fallback.
        if fontsRevision != self.fontsRevision {
            self.fontsRevision = fontsRevision
            canvas?.layoutCache.removeAll()
        }
        self.content = content
        self.pageID = pageID
        let page = pageID.flatMap { content.pages[$0] }
        pageNumberMarks = pageID.map { PageNumberMarks(content: content).marks(for: $0) } ?? []
        self.selectedImageBox = selectedImageBox
        self.imageSource = imageSource
        geometry = page.map { PageGeometry.drawGeometry(for: $0, in: content) }
        if let page, let template = content.template(for: page), let geometry {
            boxRects = template.boxes.map { ($0, geometry.renderRect(for: $0)) }
        } else {
            boxRects = []
        }

        if let editing = textEditing.editingBoxID {
            let editedBox = textBox(editing)
            if pageChanged || editedBox == nil {
                textEditing.end()
            } else if let pageID, let (box, _) = editedBox {
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
        guard let content, let page, let imageSource else { return nil }
        var options = RenderOptions.screen
        if let editing = textEditing.editingBoxID { options.hiddenTextBoxes = [editing] }
        options.pageNumbers = pageNumberMarks
        return CanvasScene(content: content, page: page, options: options, images: imageSource)
    }

    /// The scene's sheet from the cached geometry (the scene shows the bleed whenever it's on).
    var sheetRect: CGRect? {
        guard page != nil, imageSource != nil, let geometry else { return nil }
        return geometry.bleedRect
    }

    /// The draw geometry: double width with a fold for a spread template. Set in `update`.
    private var geometry: PageGeometry?

    /// Every box on the page with its render rect (bleed-extended when bleed is on), in layer
    /// order. Hit-testing and the selection outline rotate about this rect's centre, as
    /// `PageRenderer` draws. Set in `update`, the only place its inputs change.
    private(set) var boxRects: [(box: Box, rect: CGRect)] = []

    private func textBox(_ id: BoxID) -> (box: Box, rect: CGRect)? {
        boxRects.first { $0.box.id == id && $0.box.content != .image }
    }

    /// The typography a box lays out with (as `PageRenderer`: role, then the box's overrides).
    private func typography(for box: Box, in content: BookContent) -> Typography {
        InlineTextEditor.typography(for: box, base: content.style.typography)
    }

    /// Text boxes on the page whose text doesn't fit (same container as `PageRenderer`).
    func overflowingTextBoxes() -> [(box: Box, rect: CGRect)] {
        guard let content, let page, let imageSource, let layoutCache = canvas?.layoutCache else { return [] }
        var renderer = PageRenderer(images: imageSource)
        renderer.layouts = layoutCache
        let overflowing = renderer.overflowingTextBoxes(page: page, in: content)
        guard !overflowing.isEmpty else { return [] }
        return boxRects.filter { overflowing.contains($0.box.id) }
    }

    // MARK: Drawing

    func drawOverlay(in ctx: CGContext, transform: CanvasTransform) {
        for (box, rect) in overflowingTextBoxes() {
            drawOverflowBadge(box: box, rect: rect, scale: transform.scale, ctx: ctx)
        }

        if let dropTargetBox, let target = boxRects.first(where: { $0.box.id == dropTargetBox }) {
            ctx.saveGState()
            CanvasView.applyRotation(target.box.rotationDegrees, about: target.rect, ctx: ctx)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(target.rect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3 / transform.scale)
            ctx.stroke(target.rect)
            ctx.restoreGState()
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
        pan = nil
        let hit = CanvasHitTest.box(at: point, in: boxRects)
        switch CanvasHitTest.click(on: hit, clickCount: event.clickCount) {
        case .deselect:
            textEditing.end()
            onSelectImageBox(nil)
        case let .selectImage(id):
            textEditing.end()
            // A press inside the already selected, placed image box may start a pan.
            if id == selectedImageBox, event.clickCount == 1, let target = cropTarget(at: point) {
                pan = Pan(target: target, startPoint: point)
            }
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

    func mouseDragged(with event: NSEvent, at point: CGPoint) {
        guard var pan else { return }
        if !pan.began {
            pan.began = true
            self.pan = pan
            onBeginCrop { [weak self] in self?.pan = nil }
        }
        panCrop(to: point)
    }

    func mouseUp(with event: NSEvent, at point: CGPoint) {
        guard let pan else { return }
        self.pan = nil
        if pan.began { onEndCrop() }
    }

    func cursor(at point: CGPoint) -> NSCursor? {
        if pan?.began == true { return .closedHand }
        let overCrop = cropTarget(at: point) != nil
        defer { showingHand = overCrop }
        // Leaving the crop puts the arrow back once; otherwise the cursor is left alone.
        return overCrop ? .openHand : (showingHand ? .arrow : nil)
    }
    private var showingHand = false

    /// Pans the open drag's crop so the image point under the press follows `point`.
    func panCrop(to point: CGPoint) {
        guard let pan else { return }
        let target = pan.target
        let delta = CropMath.unrotated(CGSize(width: point.x - pan.startPoint.x, height: point.y - pan.startPoint.y),
                                       degrees: target.rotationDegrees)
        let crop = CropMath.panned(target.placement, by: delta, imageSize: target.imageSize, boxRect: target.boxRect)
        onCrop(target.pageID, target.boxID, crop.zoom, crop.center)
    }

    // MARK: Zoom (pinch and scroll)

    func magnify(with event: NSEvent, at point: CGPoint) -> Bool {
        zoomGesture(phase: event.phase, factor: 1 + Double(event.magnification), at: point)
    }

    func scrollWheel(with event: NSEvent, at point: CGPoint) -> Bool {
        // Momentum after a trackpad scroll isn't part of the gesture; swallow it over the crop.
        if !event.momentumPhase.isEmpty { return zoom != nil || cropTarget(at: point) != nil }
        let scale = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
        let factor = exp(Double(event.scrollingDeltaY) * scale)
        guard event.phase.isEmpty else { return zoomGesture(phase: event.phase, factor: factor, at: point) }
        // A mouse wheel: one undo step per burst of ticks.
        if zoom == nil {
            guard zoomGesture(phase: .began, factor: 1, at: point) else { return false }
        }
        _ = zoomGesture(phase: .changed, factor: factor, at: point)
        wheelIdle?.cancel()
        wheelIdle = Task { [weak self] in
            do { try await Task.sleep(for: Self.wheelIdleInterval) } catch { return }
            self?.endZoom()
        }
        return true
    }

    /// Drives a zoom gesture by its phase. Returns false if the event isn't for a crop (no
    /// selected placed image box under the pointer when it begins), so the view passes it on.
    func zoomGesture(phase: NSEvent.Phase, factor: Double, at point: CGPoint) -> Bool {
        if phase.contains(.began) {
            endZoom()
            guard pan == nil, let target = cropTarget(at: point) else { return false }
            zoom = target
            onBeginCrop { [weak self] in
                self?.zoom = nil
                self?.wheelIdle?.cancel()
            }
            return true
        }
        guard var target = zoom else { return false }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            endZoom()
            return true
        }
        guard factor.isFinite, factor > 0, factor != 1 else { return true }
        let anchor = CropMath.unrotated(point, about: target.boxRect, degrees: target.rotationDegrees)
        let crop = CropMath.zoomed(target.placement, by: factor, around: anchor, imageSize: target.imageSize,
                                   boxRect: target.boxRect)
        target.placement.zoom = crop.zoom
        target.placement.center = crop.center
        zoom = target
        onCrop(target.pageID, target.boxID, crop.zoom, crop.center)
        return true
    }

    private func endZoom() {
        wheelIdle?.cancel()
        wheelIdle = nil
        guard zoom != nil else { return }
        zoom = nil
        onEndCrop()
    }

    /// Ends any open crop gesture (the page or selection changed under it).
    private func endCropGestures() {
        endZoom()
        if let pan {
            self.pan = nil
            if pan.began { onEndCrop() }
        }
    }

    /// The selected image box, if it has a placed version and (with `point`) is the topmost box
    /// under `point`.
    func cropTarget(at point: CGPoint?) -> CropTarget? {
        guard let content, let pageID, let page, let selectedImageBox,
              let entry = boxRects.first(where: { $0.box.id == selectedImageBox }), entry.box.content == .image,
              let placement = page.images[selectedImageBox]?.placement,
              let version = content.placedVersion(page: pageID, box: selectedImageBox),
              version.pixelSize.width > 0, version.pixelSize.height > 0 else { return nil }
        if let point, CanvasHitTest.box(at: point, in: boxRects)?.id != selectedImageBox { return nil }
        return CropTarget(pageID: pageID, boxID: selectedImageBox, placement: placement,
                          imageSize: CGSize(width: version.pixelSize.width, height: version.pixelSize.height),
                          boxRect: entry.rect, rotationDegrees: entry.box.rotationDegrees)
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
