import BBLayout
import BBModel
import CoreGraphics
import Foundation
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

    public init(document: BookDocument) {
        self.document = document
    }

    /// The open template, read live from the document.
    public var template: Template? { fatalError("Phase 6 lane L4") }

    /// The geometry the open template is edited in (spread = double width).
    public var geometry: PageGeometry? { fatalError("Phase 6 lane L4") }

    // MARK: Opening and the template list

    /// Opens a template. A bundled preset the book doesn't have yet is first copied in with
    /// `.addTemplate` under its own ID. Clears the selection.
    public func open(_ id: TemplateID) { fatalError("Phase 6 lane L4") }
    /// Creates a blank template of `kind` named "New Layout" (or "New Spread"), adds it and opens it.
    public func newTemplate(kind: TemplateKind) { fatalError("Phase 6 lane L4") }
    /// Copies a template (book or preset) with new template and box IDs, named "<name> Copy",
    /// adds it and opens it.
    public func duplicate(_ id: TemplateID) { fatalError("Phase 6 lane L4") }
    /// Deletes a book template. Returns false (and does nothing) while it's in use.
    @discardableResult
    public func delete(_ id: TemplateID) -> Bool { fatalError("Phase 6 lane L4") }

    // MARK: Editing (one undo step each, unless inside an interaction)

    /// Applies `change` to a copy of the open template and performs `.updateTemplate`.
    /// No-op without an open template or when nothing changed.
    public func update(actionName: String, _ change: (inout Template) -> Void) {
        fatalError("Phase 6 lane L4")
    }

    /// Mouse-down of a drag/resize/rotate: opens an undo group (`beginUndoGroup`).
    public func beginInteraction() { fatalError("Phase 6 lane L4") }
    /// Mouse-up: closes the group as one undo step named `actionName`, and clears `activeGuides`.
    public func endInteraction(actionName: String) { fatalError("Phase 6 lane L4") }

    /// Adds an image or text box (centred in the first page's safe area, a third of its size),
    /// on top, and selects it.
    public func addBox(_ content: BoxContentKind) { fatalError("Phase 6 lane L4") }
    public func deleteSelection() { fatalError("Phase 6 lane L4") }

    public enum LayerMove: Sendable { case forward, backward, toFront, toBack }
    public func moveSelection(_ move: LayerMove) { fatalError("Phase 6 lane L4") }

    /// Aligns the selection (`Arrangement.align`); a single box aligns to its page's safe area.
    public func align(_ operation: AlignOperation) { fatalError("Phase 6 lane L4") }
    /// Distributes three or more selected boxes.
    public func distribute(_ axis: DistributeAxis) { fatalError("Phase 6 lane L4") }

    /// Nudges the selection by `delta` page points (arrow keys; ⇧ = 10 pt). One undo step.
    public func nudgeSelection(by delta: CGVector) { fatalError("Phase 6 lane L4") }
}
