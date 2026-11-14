import AppKit
import BBLayout
import BBModel

/// The page canvas's in-place text editing (A §6.2, §8.3): owns the one `InlineTextEditor`,
/// lays it over the active text box and tears it down. `PlacementController` decides when.
@MainActor
final class TextEditingController {
    weak var canvas: CanvasView?
    private(set) var editor: InlineTextEditor?

    /// A text change: page, box, text, and whether it may coalesce with the typing before it.
    var onTextChange: (PageID, BoxID, RichText, Bool) -> Void = { _, _, _, _ in }
    /// Ends the document's typing undo step (formatting with no text change, editor closing).
    var onEndTypingStep: () -> Void = {}
    /// Opens / closes a document undo group for a burst of colour changes (`InlineTextEditor`).
    var onBeginUndoGroup: (String, @escaping @MainActor () -> Void) -> Void = { _, _ in }
    var onEndUndoGroup: (String) -> Void = { _ in }
    var undoManagerProvider: () -> UndoManager? = { nil }
    /// The window's format bar / Format menu controller; the editor drives it.
    weak var formatting: TextFormatController?

    var editingBoxID: BoxID? { editor?.boxID }

    /// Opens the editor on `boxID`, closing any other first. `typography` is the box's own
    /// (`InlineTextEditor.typography(for:base:)`); `textRect` is in page points.
    func begin(pageID: PageID, boxID: BoxID, text: RichText, typography: Typography, textRect: CGRect) {
        end()
        guard let canvas else { return }
        let editor = InlineTextEditor(
            pageID: pageID, boxID: boxID, text: text,
            typography: typography, formatting: formatting,
            undoManager: { [weak self] in self?.undoManagerProvider() },
            onChange: { [weak self] text, coalescing in self?.onTextChange(pageID, boxID, text, coalescing) })
        editor.onCancel = { [weak self] in self?.end() }
        editor.onEndTypingStep = { [weak self] in self?.onEndTypingStep() }
        editor.onBeginUndoGroup = { [weak self] name, onClosed in self?.onBeginUndoGroup(name, onClosed) }
        // Keeps the document's closer even if this controller goes first, so the editor's
        // deinit can still close an open colour burst (#76a).
        let endGroup = onEndUndoGroup
        editor.onEndUndoGroup = { [weak self] name in (self?.onEndUndoGroup ?? endGroup)(name) }
        self.editor = editor
        canvas.addSubview(editor.host)
        place(textRect: textRect)
        editor.beginEditing(in: canvas.window)
        canvas.needsDisplay = true
    }

    func end() {
        guard let editor else { return }
        let window = canvas?.window
        let wasFirstResponder = window?.firstResponder === editor.textView
        editor.tearDown()
        self.editor = nil
        onEndTypingStep()
        if wasFirstResponder, let canvas { window?.makeFirstResponder(canvas) }
        canvas?.needsDisplay = true
    }

    /// Reloads the editor if the model's text or typography changed from outside (undo/redo).
    func reloadIfNeeded(modelText: RichText, typography: Typography) {
        editor?.reloadIfNeeded(modelText: modelText, typography: typography)
    }

    /// Lays the editor over `textRect` (page points).
    func place(textRect: CGRect) {
        guard let editor, let transform = canvas?.transform else { return }
        editor.place(viewRect: transform.toView(textRect), pageSize: textRect.size)
    }

    /// Passes a canvas mouse-down at `point` (page points) on the edited box to the editor, so
    /// the click places the caret where it landed instead of leaving it at the end. `boxRect`
    /// and `rotationDegrees` are the box's render rect and rotation.
    ///
    /// An upright box forwards the event to the text view, which then tracks the mouse itself
    /// (drag to select, double-click for a word); that needs a window (does nothing otherwise,
    /// e.g. in tests) and returns once the mouse is released. A rotated box is edited upright, so
    /// the text view's tracking would follow the real, unrotated drag: there the point is mapped
    /// into the upright box and the caret (or, with more clicks, the word or paragraph) is
    /// selected directly, with no drag-select.
    func handleClick(_ event: NSEvent, at point: CGPoint, boxRect: CGRect, rotationDegrees: Double) {
        guard let editor, let canvas, let transform = canvas.transform else { return }
        if rotationDegrees != 0 {
            let upright = Self.uprightPoint(point, boxRect: boxRect, rotationDegrees: rotationDegrees)
            editor.select(at: transform.toView(upright), in: canvas, clickCount: event.clickCount)
            return
        }
        guard let window = canvas.window else { return }
        // Redraw the page without the box's text now: the text view tracks the mouse until it's
        // released, and the rendered text would show under the editor's until then.
        canvas.displayIfNeeded()
        editor.handleClick(event, in: window)
    }

    /// `point` (page points) on a box drawn rotated by `rotationDegrees` about `boxRect`'s
    /// centre, mapped to where it falls on the upright box (where the editor lies).
    static func uprightPoint(_ point: CGPoint, boxRect: CGRect, rotationDegrees: Double) -> CGPoint {
        rotationDegrees == 0 ? point : CropMath.unrotated(point, about: boxRect, degrees: rotationDegrees)
    }
}
