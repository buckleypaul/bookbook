import BBLayout
import BBModel
import CoreGraphics
import Foundation
import BBStore
import Observation

// Phase 6 contract, shared by the Layouts tab (lane L4) and the template canvas (lane L3).
// Every mutation goes through `BookDocument.perform(.updateTemplate…)` (A §6.3), so pages
// that use the template update live. L4 implements this file; L3 only uses it.

/// The Layouts tab's state for one book window: the template being edited, the box
/// selection and the live snap guides.
@MainActor @Observable
public final class TemplateEditorModel {
    public let document: BookDocument

    /// The template open in the editor (always a book template once opened).
    public private(set) var templateID: TemplateID?
    /// Selected boxes, in no particular order.
    public var selection: Set<BoxID> = []
    /// Draw sample text and placeholder art in empty boxes (`RenderOptions.previewSampleContent`).
    public var showSampleContent: Bool = true
    /// Snap guides the canvas is showing during a drag (page points); empty when idle.
    public var activeGuides: [SnapGuide] = []
    /// Snapping on/off (the canvas also disables it while ⌘ is held).
    public var snappingEnabled: Bool = true

    /// No side effects on the document: SwiftUI may build (and throw away) several models for
    /// one window; only the one that opens an interaction hooks into the document's group.
    public init(document: BookDocument) {
        self.document = document
    }

    /// An undo/redo closed the document's open group under us: forget the interaction and
    /// cancel the pending continuous-edit timer, so nothing registers after the undo. The
    /// in-flight drag sees `isInteractionOpen(_:)` turn false and stops editing.
    private func dropOpenInteraction(_ id: Int) {
        guard openInteraction == id else { return }
        openInteraction = nil
        continuousTask?.cancel()
        continuousTask = nil
        activeGuides = []
    }

    /// The open template, read live from the document.
    /// A bundled preset the book hasn't copied yet reads through until its first edit.
    public var template: Template? {
        templateID.flatMap { id in document.content.templates[id] ?? Presets.bundledTemplates.first { $0.id == id } }
    }

    /// True while the open template is a bundled preset not (yet) in the book.
    public var isUncopiedPreset: Bool {
        templateID.map { document.content.templates[$0] == nil } ?? false
    }

    /// The geometry the open template is edited in (spread = double width).
    public var geometry: PageGeometry? {
        template.map { PageGeometry(setup: document.content.style.pageSetup, kind: $0.kind) }
    }

    /// The selected boxes that still exist (an undo can remove selected boxes), in layer order.
    public var selectedBoxes: [Box] {
        template?.boxes.filter { selection.contains($0.id) } ?? []
    }

    /// The open interaction's token (nil when none is open).
    @ObservationIgnored private var openInteraction: Int?
    @ObservationIgnored private var nextInteraction = 0
    private var continuousTask: Task<Void, Never>?
    private var continuousName = ""

    // MARK: Opening and the template list

    /// Opens a template. A bundled preset the book doesn't have yet opens read-through (no
    /// document change); it is copied in under its own ID, folded into the first edit's undo
    /// step. Clears the selection.
    public func open(_ id: TemplateID) {
        finishContinuousEdit()
        guard document.content.templates[id] != nil || Presets.bundledTemplates.contains(where: { $0.id == id })
        else { return }
        templateID = id
        selection = []
        activeGuides = []
    }

    /// Creates a blank template of `kind` named "New Layout" (or "New Spread"), adds it and opens it.
    public func newTemplate(kind: TemplateKind) {
        let name = switch kind {
        case .single: "New Layout"
        case .spread: "New Spread"
        case .cover: "New Cover"
        }
        let template = Template(name: name, kind: kind, boxes: [])
        if document.perform(.addTemplate(template)) { open(template.id) }
    }

    /// Copies a template (book or preset) with new template and box IDs, named "<name> Copy",
    /// adds it and opens it.
    public func duplicate(_ id: TemplateID) {
        guard let source = document.content.templates[id] ?? Presets.bundledTemplates.first(where: { $0.id == id })
        else { return }
        var copy = source
        copy.id = TemplateID()
        copy.name = source.name + " Copy"
        copy.boxes = source.boxes.map { var box = $0; box.id = BoxID(); return box }
        if document.perform(.addTemplate(copy)) { open(copy.id) }
    }

    /// Deletes a book template. Returns false (and does nothing) while it's in use.
    @discardableResult
    public func delete(_ id: TemplateID) -> Bool {
        guard document.content.templates[id] != nil, document.content.pages(using: id).isEmpty,
              document.perform(.deleteTemplate(id)) else { return false }
        if templateID == id {
            templateID = nil
            selection = []
            activeGuides = []
        }
        return true
    }

    // MARK: Editing (one undo step each, unless inside an interaction)

    /// Applies `change` to a copy of the open template and performs `.updateTemplate`.
    /// No-op without an open template or when nothing changed.
    public func update(actionName: String, _ change: (inout Template) -> Void) {
        guard let current = template else { return }
        var edited = current
        change(&edited)
        guard edited != current else { return }
        if isUncopiedPreset {
            // First edit of a preset: copy it into the book and edit it as one undo step.
            document.beginUndoGroup(actionName: actionName)
            if document.perform(.addTemplate(current)) {
                document.perform(.updateTemplate(edited, actionName: actionName))
            }
            document.endUndoGroup(actionName: actionName)
            return
        }
        document.perform(.updateTemplate(edited, actionName: actionName))
    }

    /// Mouse-down of a drag/resize/rotate: opens an undo group (`beginUndoGroup`). Returns the
    /// interaction's token (the already-open one's, if an interaction is open); an undo or redo
    /// that closes the group ends it, after which `isInteractionOpen(token)` is false.
    /// `actionName` names the undo step when it registers (pass the name `endInteraction` will use).
    @discardableResult
    public func beginInteraction(actionName: String? = nil) -> Int {
        if let openInteraction { return openInteraction }
        nextInteraction += 1
        let id = nextInteraction
        openInteraction = id
        document.beginUndoGroup(actionName: actionName, onClosedByReplay: { [weak self] in self?.dropOpenInteraction(id) })
        return id
    }

    /// True while the interaction `token` (from `beginInteraction`) is still open: not ended,
    /// and not closed by an undo or redo.
    public func isInteractionOpen(_ token: Int) -> Bool {
        openInteraction == token
    }

    /// Mouse-up: closes the group as one undo step named `actionName`, and clears `activeGuides`.
    public func endInteraction(actionName: String) {
        activeGuides = []
        guard openInteraction != nil else { return }
        openInteraction = nil
        document.endUndoGroup(actionName: actionName)
    }

    /// For controls without begin/end events (colour wells, steppers held down): applies the
    /// edit inside an interaction that closes 0.6 s after the last change, so a burst of
    /// changes is one undo step.
    public func updateContinuously(actionName: String, _ change: (inout Template) -> Void) {
        if continuousTask != nil, continuousName != actionName { finishContinuousEdit() }
        continuousTask?.cancel()
        beginInteraction(actionName: actionName)
        continuousName = actionName
        update(actionName: actionName, change)
        continuousTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.finishContinuousEdit()
        }
    }

    /// Closes a pending `updateContinuously` burst now.
    public func finishContinuousEdit() {
        guard let task = continuousTask else { return }
        task.cancel()
        continuousTask = nil
        endInteraction(actionName: continuousName)
    }

    /// Adds an image or text box (centred in the first page's safe area, a third of its size),
    /// on top, and selects it.
    public func addBox(_ content: BoxContentKind) {
        guard let geometry else { return }
        let safe = geometry.pageSafeAreas.first ?? geometry.safeArea
        let size = CGSize(width: safe.width / 3, height: safe.height / 3)
        let rect = CGRect(x: safe.midX - size.width / 2, y: safe.midY - size.height / 2,
                          width: size.width, height: size.height)
        let box = Box(frame: geometry.normalizedFrame(for: rect), content: content)
        update(actionName: content == .image ? "Add Image Box" : "Add Text Box") { $0.boxes.append(box) }
        if template?.box(box.id) != nil { selection = [box.id] }
    }

    public func deleteSelection() {
        let ids = selection
        guard let template, template.boxes.contains(where: { ids.contains($0.id) }) else { return }
        update(actionName: ids.count == 1 ? "Delete Box" : "Delete Boxes") { $0.boxes.removeAll { ids.contains($0.id) } }
        selection = []
    }

    public enum LayerMove: Sendable { case forward, backward, toFront, toBack }
    public func moveSelection(_ move: LayerMove) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let name = switch move {
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .toFront: "Bring to Front"
        case .toBack: "Send to Back"
        }
        update(actionName: name) { template in
            var boxes = template.boxes
            switch move {
            case .forward:
                if boxes.count >= 2 {
                    for i in stride(from: boxes.count - 2, through: 0, by: -1)
                    where ids.contains(boxes[i].id) && !ids.contains(boxes[i + 1].id) {
                        boxes.swapAt(i, i + 1)
                    }
                }
            case .backward:
                if boxes.count >= 2 {
                    for i in 1..<boxes.count where ids.contains(boxes[i].id) && !ids.contains(boxes[i - 1].id) {
                        boxes.swapAt(i, i - 1)
                    }
                }
            case .toFront:
                boxes = boxes.filter { !ids.contains($0.id) } + boxes.filter { ids.contains($0.id) }
            case .toBack:
                boxes = boxes.filter { ids.contains($0.id) } + boxes.filter { !ids.contains($0.id) }
            }
            template.boxes = boxes
        }
    }

    /// Aligns the selection (`Arrangement.align`); a single box aligns to its page's safe area.
    public func align(_ operation: AlignOperation) {
        let boxes = selectedBoxes
        guard let geometry, !boxes.isEmpty else { return }
        var reference: NormalizedRect?
        if boxes.count == 1 {
            let safeAreas = geometry.pageSafeAreas
            let centre = geometry.trimRect(for: boxes[0].frame)
            let safe = safeAreas.first { $0.minX <= centre.midX && centre.midX <= $0.maxX } ?? safeAreas.first
            reference = safe.map { geometry.normalizedFrame(for: $0) }
        }
        let aligned = Arrangement.align(Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0.frame) }),
                                        operation, reference: reference)
        apply(frames: aligned, actionName: "Align Boxes")
    }

    /// Distributes three or more selected boxes.
    public func distribute(_ axis: DistributeAxis) {
        let boxes = selectedBoxes
        guard boxes.count >= 3 else { return }
        let moved = Arrangement.distribute(Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0.frame) }),
                                           axis: axis)
        apply(frames: moved, actionName: "Distribute Boxes")
    }

    /// Nudges the selection by `delta` page points (arrow keys; ⇧ = 10 pt). One undo step.
    public func nudgeSelection(by delta: CGVector) {
        guard let size = geometry?.trimSize, size.width > 0, size.height > 0 else { return }
        let dx = Double(delta.dx / size.width), dy = Double(delta.dy / size.height)
        let ids = selection
        update(actionName: "Nudge Box") { template in
            for i in template.boxes.indices where ids.contains(template.boxes[i].id) {
                template.boxes[i].frame.x += dx
                template.boxes[i].frame.y += dy
            }
        }
    }

    private func apply(frames: [BoxID: NormalizedRect], actionName: String) {
        update(actionName: actionName) { template in
            for i in template.boxes.indices {
                if let frame = frames[template.boxes[i].id] { template.boxes[i].frame = frame }
            }
        }
    }
}
