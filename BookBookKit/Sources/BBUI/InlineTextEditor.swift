import AppKit
import BBLayout
import BBModel
import os

/// The in-place editor for one text box (A §8.3, SL-2): a TextKit 2 `NSTextView` laid over
/// the box, with the same container settings as `TextBoxLayout`.
///
/// - Its own undo is off (`allowsUndo = false`, A §6.3); every change goes out as a
///   `.setRichText` command, so ⌘Z reaches the window's `UndoManager` via the responder chain.
/// - It never touches `NSTextView.layoutManager` (that would switch the view to TextKit 1); a
///   DEBUG assertion watches for the switch.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    let pageID: PageID
    let boxID: BoxID
    /// Holds the text view in page-space bounds, so the editor scales with the canvas.
    let host = FlippedView()
    let textView: NSTextView
    private var typography: Typography
    /// The rich text the view currently shows (what was last loaded or sent).
    private(set) var shownText: RichText
    private let onChange: (RichText) -> Void
    /// Escape ends editing.
    var onCancel: () -> Void = {}
    private let undoManagerProvider: () -> UndoManager?
    #if DEBUG
    private var switchObserver: (any NSObjectProtocol)?
    #endif

    private static let log = Logger(subsystem: "app.bookbook", category: "InlineTextEditor")

    init(pageID: PageID, boxID: BoxID, text: RichText, typography: Typography,
         undoManager: @escaping () -> UndoManager?, onChange: @escaping (RichText) -> Void) {
        self.pageID = pageID
        self.boxID = boxID
        self.typography = typography
        self.shownText = text
        self.onChange = onChange
        self.undoManagerProvider = undoManager
        self.textView = NSTextView(usingTextLayoutManager: true)
        super.init()

        #if DEBUG
        switchObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: nil
        ) { _ in
            assertionFailure("Inline editor switched to TextKit 1 (something touched NSTextView.layoutManager)")
        }
        #endif

        configure()
        load(text)
        host.addSubview(textView)
    }

    private func configure() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = TextContainerSettings.textContainerInset
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        if let container = tv.textContainer {
            container.lineFragmentPadding = TextContainerSettings.lineFragmentPadding
            container.widthTracksTextView = false
            container.heightTracksTextView = false
        }
        host.clipsToBounds = false
    }

    /// Places the editor: `viewRect` is the box's text area in canvas coordinates, `pageSize`
    /// the same area in page points (the bounds of `host`).
    func place(viewRect: CGRect, pageSize: CGSize) {
        host.frame = viewRect
        host.bounds = CGRect(origin: .zero, size: pageSize)
        textView.minSize = pageSize
        textView.maxSize = CGSize(width: pageSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.size = CGSize(width: pageSize.width, height: .greatestFiniteMagnitude)
        textView.frame = CGRect(origin: .zero, size: CGSize(width: pageSize.width,
                                                             height: max(pageSize.height, textView.frame.height)))
    }

    /// Reloads the view if the model's text changed from outside (undo/redo).
    func reloadIfNeeded(modelText: RichText, typography: Typography) {
        guard modelText != shownText || typography != self.typography else { return }
        guard !textView.hasMarkedText() else { return }
        self.typography = typography
        let selection = textView.selectedRange()
        load(modelText)
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    private func load(_ text: RichText) {
        shownText = text
        let attributed = RichTextBridge.attributedString(from: text, typography: typography)
        textView.textStorage?.setAttributedString(attributed)
        if attributed.length == 0 {
            textView.typingAttributes = RichTextBridge.defaultAttributes(typography: typography)
        }
    }

    func beginEditing(in window: NSWindow?) {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window?.makeFirstResponder(textView)
        #if DEBUG
        // ⌘Z goes up the responder chain to the window; check that it's the document's manager.
        if let window, let expected = undoManagerProvider(), window.undoManager !== expected {
            Self.log.fault("The window's undo manager isn't the document's: ⌘Z won't undo typing")
        }
        #endif
    }

    func tearDown() {
        #if DEBUG
        if let switchObserver { NotificationCenter.default.removeObserver(switchObserver) }
        switchObserver = nil
        #endif
        textView.delegate = nil
        host.removeFromSuperview()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let text = RichTextBridge.richText(from: textView.attributedString(), typography: typography)
        guard text != shownText else { return }
        shownText = text
        onChange(text)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCancel()
        return true
    }

    /// Undo for the text view's own operations resolves to the document's manager.
    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManagerProvider()
    }
}

/// A flipped container (top-left origin, like the page).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
