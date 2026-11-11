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
        removeUndoObserver()
        continuousTask?.cancel()
        continuousTask = nil
        activeGuides = []
    }

    /// The open template, read live from the document.
    /// A bundled preset the book hasn't copied yet reads through until its first edit.
    public var template: Template? {
        templateID.flatMap { Presets.template($0, in: document.content) }
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
    @ObservationIgnored private var continuousToken: Int?
    /// True once `update` has edited inside the open interaction (so its group has registered).
    @ObservationIgnored private var interactionEdited = false
    @ObservationIgnored private var undoObservers: [any NSObjectProtocol] = []

    private func removeUndoObserver() {
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = []
    }

    // MARK: Opening and the template list

    /// Opens a template. A bundled preset the book doesn't have yet opens read-through (no
    /// document change); it is copied in under its own ID, folded into the first edit's undo
    /// step. Clears the selection.
    public func open(_ id: TemplateID) {
        finishContinuousEdit()
        guard Presets.template(id, in: document.content) != nil
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
        guard let source = Presets.template(id, in: document.content)
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
        // A one-shot edit never joins a pending continuous burst: close the burst first.
        finishContinuousEdit()
        applyUpdate(actionName: actionName, change)
    }

    /// `update` for any template (book or uncopied preset), open or not: the Layouts chat
    /// applies a reply to the template it was asked about even after the user opened another.
    public func update(_ id: TemplateID, actionName: String, _ change: (inout Template) -> Void) {
        if id == templateID { return update(actionName: actionName, change) }
        guard let current = Presets.template(id, in: document.content) else { return }
        applyUpdate(to: current, preset: document.content.templates[id] == nil, actionName: actionName, change)
    }

    private func applyUpdate(actionName: String, _ change: (inout Template) -> Void) {
        guard let current = template else { return }
        applyUpdate(to: current, preset: isUncopiedPreset, actionName: actionName, change)
    }

    private func applyUpdate(to current: Template, preset: Bool, actionName: String,
                             _ change: (inout Template) -> Void) {
        var edited = current
        change(&edited)
        guard edited != current else { return }
        // A bleed edge moved off a spread's fold doesn't start bleeding (#64), whichever edit
        // moved it: drags, nudges, align/distribute or the inspector's frame fields.
        if edited.kind == current.kind {
            let geometry = PageGeometry(setup: document.content.style.pageSetup, kind: current.kind)
            LayoutEditingMath.dropBleedMovedOffFold(in: &edited, from: current, geometry: geometry)
        }
        if openInteraction != nil, current.id == templateID { interactionEdited = true }
        if preset {
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
        // A pending continuous burst (stepper, colour well) is its own undo step.
        finishContinuousEdit()
        return openOrJoinInteraction(actionName: actionName)
    }

    private func openOrJoinInteraction(actionName: String?) -> Int {
        if let openInteraction { return openInteraction }
        nextInteraction += 1
        let id = nextInteraction
        openInteraction = id
        interactionEdited = false
        document.beginUndoGroup(actionName: actionName, onClosedByReplay: { [weak self] in self?.dropOpenInteraction(id) })
        // An undo/redo before the first edit finds nothing registered to close the group, so
        // end the interaction here (nothing registers; the group is empty).
        if let manager = document.undoManager {
            let handler: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.openInteraction == id, !self.interactionEdited else { return }
                    self.dropOpenInteraction(id)
                    self.document.endUndoGroup(actionName: actionName ?? "")
                }
            }
            undoObservers = [
                NotificationCenter.default.addObserver(forName: .NSUndoManagerWillUndoChange, object: manager,
                                                       queue: .main, using: handler),
                NotificationCenter.default.addObserver(forName: .NSUndoManagerWillRedoChange, object: manager,
                                                       queue: .main, using: handler),
            ]
        }
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
        removeUndoObserver()
        document.endUndoGroup(actionName: actionName)
    }

    /// Mouse-up of the interaction `token` came from: closes it only if it is still the open
    /// one, so a stale caller can't close someone else's group.
    public func endInteraction(_ token: Int, actionName: String) {
        guard openInteraction == token else { return }
        endInteraction(actionName: actionName)
    }

    /// For controls without begin/end events (colour wells, steppers held down): applies the
    /// edit inside an interaction that closes 0.6 s after the last change, so a burst of
    /// changes is one undo step.
    public func updateContinuously(actionName: String, _ change: (inout Template) -> Void) {
        if continuousTask != nil, continuousName != actionName { finishContinuousEdit() }
        continuousTask?.cancel()
        continuousToken = openOrJoinInteraction(actionName: actionName)
        continuousName = actionName
        applyUpdate(actionName: actionName, change)
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
        if let token = continuousToken { endInteraction(token, actionName: continuousName) }
        continuousToken = nil
    }

    /// How far each new box steps down and right from one already at its spot (page points).
    static let newBoxCascadeStep: CGFloat = 18

    /// Adds an image or text box (a third of the first page's safe area, centred in it, or
    /// cascaded down and right past boxes already there, #54a), on top, and selects it.
    public func addBox(_ content: BoxContentKind) {
        guard let geometry, let current = template else { return }
        let safe = geometry.pageSafeAreas.first ?? geometry.safeArea
        let size = CGSize(width: safe.width / 3, height: safe.height / 3)
        let rect = Self.newBoxRect(size: size, safe: safe,
                                   existing: current.boxes.map { geometry.trimRect(for: $0.frame) })
        let box = Box(frame: geometry.normalizedFrame(for: rect), content: content)
        update(actionName: content == .image ? "Add Image Box" : "Add Text Box") { $0.boxes.append(box) }
        if template?.box(box.id) != nil { selection = [box.id] }
    }

    /// Where a new box of `size` goes: centred in `safe`, then stepped by `newBoxCascadeStep`
    /// down and right while a box in `existing` (trim rects) already starts at that spot.
    /// Clamped to `safe`; once a clamped spot is taken too, the cascade restarts at the safe
    /// area's top-left corner and finally gives up (the box may then overlap one).
    static func newBoxRect(size: CGSize, safe: CGRect, existing: [CGRect]) -> CGRect {
        let step = newBoxCascadeStep
        func clamped(_ origin: CGPoint) -> CGRect {
            let x = min(max(origin.x, safe.minX), max(safe.minX, safe.maxX - size.width))
            let y = min(max(origin.y, safe.minY), max(safe.minY, safe.maxY - size.height))
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        func taken(_ rect: CGRect) -> Bool {
            existing.contains { abs($0.minX - rect.minX) < step / 2 && abs($0.minY - rect.minY) < step / 2 }
        }
        let starts = [CGPoint(x: safe.midX - size.width / 2, y: safe.midY - size.height / 2),
                      CGPoint(x: safe.minX, y: safe.minY)]
        for start in starts {
            var rect = clamped(start)
            var previous: CGRect?
            while taken(rect), rect != previous {
                previous = rect
                rect = clamped(CGPoint(x: rect.minX + step, y: rect.minY + step))
            }
            if !taken(rect) { return rect }
        }
        return clamped(starts[0])
    }

    public func deleteSelection() {
        let ids = selection
        guard let template, template.boxes.contains(where: { ids.contains($0.id) }) else { return }
        update(actionName: ids.count == 1 ? "Delete Box" : "Delete Boxes") { $0.boxes.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// False when reordering the selection would change nothing you can see: text always draws
    /// above images (A §8), so order only matters among boxes of the same kind. True needs a
    /// selected box with another box of its kind in the template.
    public var layerOrderHasVisibleEffect: Bool {
        guard let template else { return false }
        func isText(_ box: Box) -> Bool { if case .text = box.content { true } else { false } }
        return selectedBoxes.contains { box in
            template.boxes.contains { $0.id != box.id && isText($0) == isText(box) }
        }
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
        guard let geometry, case let size = geometry.trimSize, size.width > 0, size.height > 0 else { return }
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
