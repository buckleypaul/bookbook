import AppKit
import BBLayout
import BBModel
import os

/// The in-place editor for one text box (A §8.3, SL-2): a TextKit 2 `NSTextView` laid over
/// the box, with the same container settings as `TextBoxLayout`.
///
/// - Its own undo is off (`allowsUndo = false`, A §6.3); every change goes out as a
///   `.setRichText` command, so ⌘Z reaches the window's `UndoManager` via the responder chain.
/// - Typing goes out with `coalescing: true`; each format action (`TextFormatTarget`) goes out
///   as one `coalescing: false` command, which ends the typing undo step (A §6.3).
/// - While editing it is `formatting.target` and keeps `formatting.state` current.
/// - It never touches `NSTextView.layoutManager` (that would switch the view to TextKit 1); a
///   DEBUG assertion watches for the switch.
@MainActor
final class InlineTextEditor: NSObject, NSTextViewDelegate, TextFormatTarget {
    let pageID: PageID
    let boxID: BoxID
    /// Holds the text view in page-space bounds, so the editor scales with the canvas.
    let host = FlippedView()
    let textView: NSTextView
    private var typography: Typography
    /// The rich text the view currently shows (what was last loaded or sent).
    private(set) var shownText: RichText
    /// True while the view is being reloaded from the model (its changes aren't edits).
    private var isReloading = false
    /// A text change: the new text, and whether it may coalesce with the typing before it.
    private let onChange: (RichText, Bool) -> Void
    /// A formatting change that didn't change the text (typing attributes on an empty
    /// selection): ends the typing undo step.
    var onEndTypingStep: () -> Void = {}
    private weak var formatting: TextFormatController?
    /// Escape ends editing.
    var onCancel: () -> Void = {}
    private let undoManagerProvider: () -> UndoManager?
    #if DEBUG
    private var switchObserver: (any NSObjectProtocol)?
    #endif

    private static let log = Logger(subsystem: "app.bookbook", category: "InlineTextEditor")

    init(pageID: PageID, boxID: BoxID, text: RichText, typography: Typography,
         formatting: TextFormatController? = nil,
         undoManager: @escaping () -> UndoManager?, onChange: @escaping (RichText, Bool) -> Void) {
        self.pageID = pageID
        self.boxID = boxID
        self.typography = typography
        self.shownText = text
        self.onChange = onChange
        self.formatting = formatting
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
        // An undo during IME composition: commit the marked text first, so the view and the model
        // don't drift apart (the next keystroke would otherwise overwrite the undo).
        isReloading = true
        if textView.hasMarkedText() { textView.unmarkText() }
        self.typography = typography
        let selection = textView.selectedRange()
        load(modelText)
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        isReloading = false
        publishState()
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
        formatting?.target = self
        publishState()
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
        if let formatting, formatting.target === self {
            formatting.target = nil
            formatting.state = nil
        }
        host.removeFromSuperview()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let text = RichTextBridge.richText(from: textView.attributedString(), typography: typography)
        guard text != shownText else { return }
        shownText = text
        onChange(text, true)
        publishState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isReloading else { return }
        publishState()
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

// MARK: Formatting (TextFormatTarget)

extension InlineTextEditor {
    /// Applies a format action to the selection, or to the typing attributes when the selection
    /// is empty (alignment always applies to the caret's paragraphs). A change to the text goes
    /// out as one non-coalescing `setRichText`.
    func apply(_ action: FormatAction) {
        if textView.hasMarkedText() { textView.unmarkText() }
        let selection = textView.selectedRange()
        let text = currentText()
        if case .setAlignment(let alignment) = action {
            if selection.length == 0 { applyToTypingAttributes(action) }
            let edited = RichTextFormatting.settingAlignment(alignment, in: selection, of: text)
            commitFormatted(edited, selection: selection)
            return
        }
        if selection.length == 0 {
            applyToTypingAttributes(action)
            onEndTypingStep()
            publishState()
            return
        }
        let runs = RichTextFormatting.runs(in: selection, of: text)
        guard let transform = RichTextFormatting.transform(for: action, current: runs, typography: typography)
        else { return }
        commitFormatted(RichTextFormatting.applying(transform, to: selection, of: text), selection: selection)
    }

    /// The formatting at the selection (or of the typing attributes when it's empty).
    var formatState: FormatState {
        let selection = textView.selectedRange()
        let text = currentText()
        let runs = selection.length == 0 ? [typingRun()] : RichTextFormatting.runs(in: selection, of: text)
        var state = RichTextFormatting.state(of: runs, typography: typography)
        state.alignment = RichTextFormatting.alignment(in: selection, of: text)
        return state
    }

    func publishState() {
        guard let formatting, formatting.target === self else { return }
        let state = formatState
        if formatting.state != state { formatting.state = state }
    }

    /// The view's text in model form.
    private func currentText() -> RichText {
        RichTextBridge.richText(from: textView.attributedString(), typography: typography)
    }

    /// Loads `edited`, keeps the selection, and sends it if it changed.
    private func commitFormatted(_ edited: RichText, selection: NSRange) {
        let typingAttributes = textView.typingAttributes
        isReloading = true
        let attributed = RichTextBridge.attributedString(from: edited, typography: typography)
        textView.textStorage?.setAttributedString(attributed)
        let length = attributed.length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        if selection.length == 0 { textView.typingAttributes = typingAttributes }
        isReloading = false
        // Normal form, so the next keystroke's comparison is exact.
        let normal = currentText()
        if normal != shownText {
            shownText = normal
            onChange(normal, false)
        } else {
            onEndTypingStep()
        }
        publishState()
    }

    /// The run new typing would get, read from the typing attributes.
    private func typingRun() -> Run {
        let probe = NSAttributedString(string: "x", attributes: textView.typingAttributes)
        let run = RichTextBridge.richText(from: probe, typography: typography).paragraphs.first?.runs.first
        return run ?? Run(text: "x")
    }

    private func applyToTypingAttributes(_ action: FormatAction) {
        var run = typingRun()
        var alignment: TextAlignment?
        if case .setAlignment(let value) = action {
            alignment = value
        } else {
            if let transform = RichTextFormatting.transform(for: action, current: [run], typography: typography) {
                transform(&run)
            }
            if let style = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle {
                let current = RichTextFormatting.modelAlignment(style.alignment)
                alignment = current == typography.alignment ? nil : current
            }
        }
        run.text = "x"
        let attributed = RichTextBridge.attributedString(
            from: RichText(paragraphs: [Paragraph(runs: [run], alignment: alignment)]), typography: typography)
        textView.typingAttributes = attributed.attributes(at: 0, effectiveRange: nil)
    }
}

/// Pure edits of `RichText` over a UTF-16 range of its attributed form (paragraphs joined by
/// one newline), used by the editor's format actions.
@MainActor
enum RichTextFormatting {
    /// Points per step for Bigger / Smaller.
    static let sizeStep: Double = 1
    static let minimumSize: Double = 1

    /// The model alignment for a paragraph style's alignment (as `RichTextBridge` maps it).
    static func modelAlignment(_ alignment: NSTextAlignment) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .right: .trailing
        case .justified: .justified
        default: .leading
        }
    }

    /// The runs inside `range` (whole runs, unsplit); empty for an empty range.
    static func runs(in range: NSRange, of text: RichText) -> [Run] {
        var result: [Run] = []
        var offset = 0
        for paragraph in text.paragraphs {
            for run in paragraph.runs {
                let length = run.text.utf16.count
                if max(offset, range.location) < min(offset + length, NSMaxRange(range)) { result.append(run) }
                offset += length
            }
            offset += 1 // the newline separator
        }
        return result
    }

    /// Applies `transform` to the characters in `range`, splitting runs at its edges.
    static func applying(_ transform: (inout Run) -> Void, to range: NSRange, of text: RichText) -> RichText {
        var offset = 0
        var paragraphs: [Paragraph] = []
        for paragraph in text.paragraphs {
            var runs: [Run] = []
            for run in paragraph.runs {
                let units = Array(run.text.utf16)
                let start = offset
                offset += units.count
                let lower = min(max(range.location - start, 0), units.count)
                let upper = min(max(NSMaxRange(range) - start, 0), units.count)
                guard lower < upper else {
                    runs.append(run)
                    continue
                }
                for (from, to, inside) in [(0, lower, false), (lower, upper, true), (upper, units.count, false)]
                where from < to {
                    var piece = run
                    piece.text = String(decoding: units[from..<to], as: UTF16.self)
                    if inside { transform(&piece) }
                    runs.append(piece)
                }
            }
            offset += 1 // the newline separator
            paragraphs.append(Paragraph(runs: runs, alignment: paragraph.alignment))
        }
        return RichText(paragraphs: paragraphs)
    }

    /// Sets the alignment of every paragraph `range` touches (the caret's, if it's empty).
    static func settingAlignment(_ alignment: TextAlignment?, in range: NSRange, of text: RichText) -> RichText {
        var copy = text
        if copy.paragraphs.isEmpty { copy.paragraphs = [Paragraph(runs: [Run(text: "")])] }
        for index in paragraphIndexes(in: range, of: copy) { copy.paragraphs[index].alignment = alignment }
        return copy
    }

    /// The common alignment override of the paragraphs `range` touches; nil if mixed or default.
    static func alignment(in range: NSRange, of text: RichText) -> TextAlignment? {
        let values = Set(paragraphIndexes(in: range, of: text).map { text.paragraphs[$0].alignment })
        return values.count == 1 ? values.first ?? nil : nil
    }

    /// Common values of `runs`; nil where they differ (or, for overrides, where none is set).
    /// Bold and italic are what the runs draw (A §4.2: the stored flags are relative to the base
    /// face), so B is on over a bold title even though its runs store `bold: false`.
    static func state(of runs: [Run], typography: Typography) -> FormatState {
        func common<T: Hashable>(_ key: (Run) -> T?) -> T? {
            let values = Set(runs.map(key))
            return values.count == 1 ? values.first ?? nil : nil
        }
        let drawn = runs.map { RichTextBridge.drawnTraits(of: $0, typography: typography) }
        func commonDrawn(_ key: ((bold: Bool, italic: Bool)) -> Bool) -> Bool? {
            let values = Set(drawn.map(key))
            return values.count == 1 ? values.first : nil
        }
        return FormatState(bold: commonDrawn(\.bold), italic: commonDrawn(\.italic),
                           underline: common { $0.underline }, font: common { $0.fontFamily },
                           size: common { $0.size }, color: common { $0.color }, alignment: nil)
    }

    /// The run transform for a (non-alignment) action, given the runs it applies to.
    /// Bold and italic toggle what is drawn: if every run draws bold, they all become non-bold,
    /// else all bold; each run's relative flag is set to get there from its base face (A §4.2).
    static func transform(for action: FormatAction, current runs: [Run],
                          typography: Typography) -> ((inout Run) -> Void)? {
        switch action {
        case .toggleBold:
            let value = !runs.allSatisfy { RichTextBridge.drawnTraits(of: $0, typography: typography).bold }
            return { run in
                var base = run
                base.bold = false
                run.bold = RichTextBridge.drawnTraits(of: base, typography: typography).bold != value
            }
        case .toggleItalic:
            let value = !runs.allSatisfy { RichTextBridge.drawnTraits(of: $0, typography: typography).italic }
            return { run in
                var base = run
                base.italic = false
                run.italic = RichTextBridge.drawnTraits(of: base, typography: typography).italic != value
            }
        case .toggleUnderline:
            let value = !runs.allSatisfy(\.underline)
            return { $0.underline = value }
        case .setFont(let name):
            return { $0.fontFamily = name }
        case .setSize(let size):
            return { $0.size = size.map { max(minimumSize, $0) } }
        case .setColor(let color):
            return { $0.color = color }
        case .biggerText, .smallerText:
            let step = action == .biggerText ? sizeStep : -sizeStep
            let base = typography.bodySize
            return { run in run.size = max(minimumSize, (run.size ?? base) + step) }
        case .setAlignment:
            return nil
        }
    }

    /// Paragraphs that `range` touches: those it overlaps, or the caret's if it's empty.
    private static func paragraphIndexes(in range: NSRange, of text: RichText) -> [Int] {
        var result: [Int] = []
        var start = 0
        for (index, paragraph) in text.paragraphs.enumerated() {
            let end = start + paragraph.runs.reduce(0) { $0 + $1.text.utf16.count } // separator at `end`
            let touches = range.length == 0
                ? (range.location >= start && range.location <= end)
                : (range.location <= end && NSMaxRange(range) > start)
            if touches { result.append(index) }
            start = end + 1
        }
        if result.isEmpty, !text.paragraphs.isEmpty { result = [text.paragraphs.count - 1] }
        return result
    }
}

/// A flipped container (top-left origin, like the page).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
