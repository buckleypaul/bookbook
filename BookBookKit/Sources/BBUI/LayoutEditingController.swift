import AppKit
import BBLayout
import BBModel
import Observation

/// The template editor mode (PD §8.4, A §6.2): draws the open template with sample content,
/// the trim, bleed and safe areas (`PageRenderer`'s screen guides, as on the page canvas), selection handles and live snap guides, and turns clicks,
/// drags and keys into `TemplateEditorModel` edits. Each drag is one undo step
/// (`beginInteraction` … `endInteraction`). The maths lives in `LayoutEditingMath`.
@MainActor
final class LayoutEditingController: CanvasController {
    weak var canvas: CanvasView? {
        didSet { canvas?.needsDisplay = true }
    }
    let model: TemplateEditorModel
    let imageSource: ImageCache

    /// Screen sizes (view points), divided by the zoom for page space.
    static let handleSize: CGFloat = 7
    static let handleTolerance: CGFloat = 6
    static let rotationKnobOffset: CGFloat = 20
    static let snapThreshold: CGFloat = 6
    /// How far the mouse must move (view points) before a press becomes a drag.
    static let dragSlop: CGFloat = 3

    /// The stand-in page the template is drawn on.
    private let previewPageID = PageID()
    private var fontsRevision: Int?
    private var drag: Drag?

    private enum DragKind {
        case move(boxes: [EditableBox], targets: SnapTargets)
        case resize(box: EditableBox, handle: BoxHandle, targets: SnapTargets)
        case rotate(box: EditableBox)

        var actionName: String {
            switch self {
            case .move: "Move Box"
            case .resize: "Resize Box"
            case .rotate: "Rotate Box"
            }
        }
    }

    private struct Drag {
        var kind: DragKind
        var geometry: PageGeometry
        /// Each box's bleed-pushed edges when the drag began, to turn render rects back into frames.
        var pushedEdges: [BoxID: EdgeSet]
        var start: CGPoint
        var current: CGPoint
        var modifiers: NSEvent.ModifierFlags
        /// The interaction token once the undo group is open (the mouse moved past the slop).
        var interaction: Int?
    }

    init(model: TemplateEditorModel, imageSource: ImageCache) {
        self.model = model
        self.imageSource = imageSource
    }

    // MARK: Scene

    var scene: CanvasScene? {
        guard let template = model.template, let geometry = model.geometry else { return nil }
        var content = model.document.content
        content.templates[template.id] = template
        content.style.pageSetup = geometry.setup
        let page = Page(id: previewPageID, kind: .story, templateID: template.id)
        var options = RenderOptions.screen
        options.previewSampleContent = model.showSampleContent
        return CanvasScene(content: content, page: page, options: options, images: imageSource,
                           showsFold: geometry.isSpread, showsBleed: geometry.bleed > 0)
    }

    /// Re-registers observation of everything the canvas shows; a change redraws.
    func willDraw() {
        let revision = withObservationTracking {
            _ = model.template
            _ = model.geometry
            _ = model.selection
            _ = model.activeGuides
            _ = model.showSampleContent
            _ = model.document.content
            return model.document.fontsRevision
        } onChange: { [weak self] in
            Task { @MainActor in self?.canvas?.needsDisplay = true }
        }
        // Fonts were registered since the layouts were made: they may have used a fallback.
        if revision != fontsRevision {
            fontsRevision = revision
            canvas?.layoutCache.removeAll()
        }
    }

    /// Render rects (bleed-extended): see `LayoutEditingMath.editableBoxes`.
    private func editableBoxes(_ template: Template, _ geometry: PageGeometry) -> [EditableBox] {
        LayoutEditingMath.editableBoxes(template, geometry: geometry)
    }

    private func pushedEdges(_ template: Template, _ geometry: PageGeometry) -> [BoxID: EdgeSet] {
        Dictionary(template.boxes.map { ($0.id, geometry.pushedBleedEdges(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// The one selected box, if exactly one is selected (only it gets handles).
    private func singleSelected(in boxes: [EditableBox]) -> EditableBox? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return boxes.first { $0.id == id }
    }

    // MARK: Drawing

    func drawOverlay(in ctx: CGContext, transform: CanvasTransform) {
        guard let template = model.template, let geometry = model.geometry else { return }
        let s = transform.scale
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // The trim line, the bleed and each page's safe area are `PageRenderer`'s screen guides
        // (the same as the page canvas); this overlay adds selection, handles and snap guides.
        let boxes = editableBoxes(template, geometry)
        let accent = NSColor.controlAccentColor.cgColor
        for box in boxes where model.selection.contains(box.id) {
            ctx.saveGState()
            CanvasView.applyRotation(box.rotationDegrees, about: box.rect, ctx: ctx)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 / s)
            ctx.stroke(box.rect)
            ctx.restoreGState()
        }

        if let box = singleSelected(in: boxes) {
            let knobOffset = Self.rotationKnobOffset / s
            let top = BoxHitTesting.position(of: .top, of: box, rotationKnobOffset: knobOffset)
            let knob = BoxHitTesting.position(of: .rotation, of: box, rotationKnobOffset: knobOffset)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1 / s)
            ctx.move(to: top)
            ctx.addLine(to: knob)
            ctx.strokePath()

            let size = Self.handleSize / s
            ctx.setLineWidth(1 / s)
            for handle in BoxHandle.allCases {
                let p = BoxHitTesting.position(of: handle, of: box, rotationKnobOffset: knobOffset)
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(accent)
                if handle == .rotation {
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                } else {
                    ctx.fill(rect)
                    ctx.stroke(rect)
                }
            }
        }

        // Live snap guides.
        if !model.activeGuides.isEmpty {
            ctx.setStrokeColor(NSColor.systemPink.cgColor)
            ctx.setLineWidth(1 / s)
            for guide in model.activeGuides {
                switch guide.axis {
                case .vertical:
                    ctx.move(to: CGPoint(x: guide.position, y: guide.span.lowerBound))
                    ctx.addLine(to: CGPoint(x: guide.position, y: guide.span.upperBound))
                case .horizontal:
                    ctx.move(to: CGPoint(x: guide.span.lowerBound, y: guide.position))
                    ctx.addLine(to: CGPoint(x: guide.span.upperBound, y: guide.position))
                }
            }
            ctx.strokePath()
        }
    }

    // MARK: Mouse

    func mouseDown(with event: NSEvent, at point: CGPoint) {
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
        drag = nil
        guard let template = model.template, let geometry = model.geometry, let scale = canvas?.transform?.scale
        else { return }
        let boxes = editableBoxes(template, geometry)
        let shift = event.modifierFlags.contains(.shift)
        func targets(excluding moving: Set<BoxID>) -> SnapTargets {
            LayoutEditingMath.snapTargets(geometry: geometry, others: boxes.filter { !moving.contains($0.id) })
        }

        // A handle of the selected box comes first: it may sit outside the box.
        if !shift, let box = singleSelected(in: boxes),
           let handle = BoxHitTesting.handle(at: point, of: box, tolerance: Self.handleTolerance / scale,
                                             rotationKnobOffset: Self.rotationKnobOffset / scale) {
            let kind: DragKind = handle == .rotation
                ? .rotate(box: box)
                : .resize(box: box, handle: handle, targets: targets(excluding: [box.id]))
            drag = Drag(kind: kind, geometry: geometry, pushedEdges: pushedEdges(template, geometry),
                        start: point, current: point, modifiers: event.modifierFlags)
            return
        }

        let hit = BoxHitTesting.box(at: point, in: boxes)
        let (selection, canMove) = LayoutEditingMath.click(on: hit, selection: model.selection, shift: shift)
        if selection != model.selection { model.selection = selection }
        guard canMove else { return }
        let moving = boxes.filter { selection.contains($0.id) }
        drag = Drag(kind: .move(boxes: moving, targets: targets(excluding: selection)), geometry: geometry,
                    pushedEdges: pushedEdges(template, geometry),
                    start: point, current: point, modifiers: event.modifierFlags)
    }

    func mouseDragged(with event: NSEvent, at point: CGPoint) {
        guard var drag, let scale = canvas?.transform?.scale else { return }
        drag.current = point
        drag.modifiers = event.modifierFlags
        if let interaction = drag.interaction {
            // An undo or redo mid-drag closed the group: the drag is over until the next mouse-down.
            guard model.isInteractionOpen(interaction) else { return cancelDrag() }
        } else {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) * scale >= Self.dragSlop else { return }
            drag.interaction = model.beginInteraction(actionName: drag.kind.actionName)
        }
        self.drag = drag
        apply(drag, scale: scale)
    }

    func mouseUp(with event: NSEvent, at point: CGPoint) {
        guard let drag else { return }
        self.drag = nil
        // Closes only this drag's group (a no-op if an undo or redo already ended it).
        if let interaction = drag.interaction {
            model.endInteraction(interaction, actionName: drag.kind.actionName)
        }
    }

    /// Drops a drag whose interaction an undo or redo ended. Edits nothing.
    private func cancelDrag() {
        drag = nil
        model.activeGuides = []
        canvas?.needsDisplay = true
    }

    /// ⌘ (snapping off) or ⇧ (aspect / 15°) pressed or released mid-drag: re-apply.
    func flagsChanged(with event: NSEvent) {
        guard var drag, let interaction = drag.interaction, let scale = canvas?.transform?.scale else { return }
        guard model.isInteractionOpen(interaction) else { return cancelDrag() }
        drag.modifiers = event.modifierFlags
        self.drag = drag
        apply(drag, scale: scale)
    }

    private func apply(_ drag: Drag, scale: CGFloat) {
        let geometry = drag.geometry
        let snapping = model.snappingEnabled && !drag.modifiers.contains(.command)
        let shift = drag.modifiers.contains(.shift)
        let threshold = Self.snapThreshold / scale
        var guides: [SnapGuide] = []
        switch drag.kind {
        case let .move(boxes, targets):
            let delta = CGVector(dx: drag.current.x - drag.start.x, dy: drag.current.y - drag.start.y)
            let result = LayoutEditingMath.move(boxes, by: delta, targets: snapping ? targets : nil, threshold: threshold)
            guides = result.guides
            model.update(actionName: drag.kind.actionName) { template in
                for index in template.boxes.indices {
                    let id = template.boxes[index].id
                    if let rect = result.rects[id] {
                        template.boxes[index].frame = LayoutEditingMath.frame(
                            forRender: rect, pushedEdges: drag.pushedEdges[id] ?? [], geometry: geometry)
                    }
                }
            }
        case let .resize(box, handle, targets):
            let result = LayoutEditingMath.resize(box, handle: handle, from: drag.start, to: drag.current,
                                                  keepAspect: shift, targets: snapping ? targets : nil,
                                                  threshold: threshold)
            guides = result.guides
            model.update(actionName: drag.kind.actionName) { template in
                if let index = template.boxes.firstIndex(where: { $0.id == box.id }) {
                    template.boxes[index].frame = LayoutEditingMath.frame(
                        forRender: result.rect, pushedEdges: drag.pushedEdges[box.id] ?? [], geometry: geometry)
                }
            }
        case let .rotate(box):
            let degrees = LayoutEditingMath.rotation(of: box, from: drag.start, to: drag.current, snapToStep: shift)
            model.update(actionName: drag.kind.actionName) { template in
                if let index = template.boxes.firstIndex(where: { $0.id == box.id }) {
                    template.boxes[index].rotationDegrees = degrees
                }
            }
        }
        if model.activeGuides != guides { model.activeGuides = guides }
    }

    // MARK: Keys

    func keyDown(with event: NSEvent) -> Bool {
        guard drag == nil, !model.selection.isEmpty else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: model.nudgeSelection(by: CGVector(dx: -step, dy: 0)) // ←
        case 124: model.nudgeSelection(by: CGVector(dx: step, dy: 0))  // →
        case 125: model.nudgeSelection(by: CGVector(dx: 0, dy: step))  // ↓ (page y is down)
        case 126: model.nudgeSelection(by: CGVector(dx: 0, dy: -step)) // ↑
        case 51, 117: model.deleteSelection()                          // Backspace, Delete
        default: return false
        }
        return true
    }

    // MARK: Cursor

    func cursor(at point: CGPoint) -> NSCursor? {
        guard drag == nil, let template = model.template, let geometry = model.geometry,
              let scale = canvas?.transform?.scale,
              let box = singleSelected(in: editableBoxes(template, geometry)),
              let handle = BoxHitTesting.handle(at: point, of: box, tolerance: Self.handleTolerance / scale,
                                                rotationKnobOffset: Self.rotationKnobOffset / scale)
        else { return .arrow }
        if handle == .rotation { return .crosshair }
        let position: NSCursor.FrameResizePosition = switch LayoutEditingMath.cursorHandle(
            for: handle, rotationDegrees: box.rotationDegrees) {
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        case .topLeft, .rotation: .topLeft
        }
        return .frameResize(position: position, directions: .all)
    }
}
