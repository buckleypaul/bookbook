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
}
