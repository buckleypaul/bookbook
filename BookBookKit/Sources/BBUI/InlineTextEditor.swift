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
/// - Colour changes on one selection in quick succession (the colour panel sends one per drag
///   step) go out inside one undo group (`onBeginUndoGroup`/`onEndUndoGroup`), closed 0.6 s
///   after the last change or by any other edit (Phase 16b #76a).
/// - Inserted text (paste, drop) is run through the `RichTextBridge` round trip, so the view
///   shows only what the model keeps: no kerning, links or paragraph spacing (Phase 16b #78a).
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
    /// Opens a document undo group (`BookDocument.beginUndoGroup`): the action name, and a
    /// handler called if an undo or redo closes the group first.
    var onBeginUndoGroup: (String, @escaping @MainActor () -> Void) -> Void = { _, _ in }
    /// Closes the group opened by `onBeginUndoGroup` (`BookDocument.endUndoGroup`).
    var onEndUndoGroup: (String) -> Void = { _ in }
    /// The open colour burst: the selection it applies to and the task that closes it.
    private var colorBurst: (selection: NSRange, closer: Task<Void, Never>)?
    /// Where the text view's pending edit inserts text (from `shouldChangeTextIn`), so
    /// `textDidChange` can round-trip just the inserted characters.
    private var pendingInsertion: NSRange?
    #if DEBUG
    private var switchObserver: (any NSObjectProtocol)?
    #endif

    private static let log = Logger(subsystem: "app.bookbook", category: "InlineTextEditor")
    /// The undo name of a colour burst.
    static let colorActionName = "Text Colour"
    /// How long after the last colour change a burst closes.
    static let colorBurstIdle: Duration = .milliseconds(600)

    /// `typography` is the box's own (`InlineTextEditor.typography(for:base:)`): role-resolved,
    /// with its style overrides applied, so the editor wraps and styles like the renderer.
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
        finishColorBurst()
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

    /// Makes the text view first responder with the caret at the end (keyboard entry; a click
    /// then places it with `handleClick`).
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

    /// Hands a mouse-down that the canvas received to the text view, so the click places the
    /// caret (or, dragged, selects; with more clicks, selects the word or paragraph) as a click
    /// on the text view itself would. `event`'s window location must be where the click lands
    /// on the (upright) editor. Runs the text view's own tracking until the mouse is released.
    func handleClick(_ event: NSEvent, in window: NSWindow) {
        guard textView.window === window else { return }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        textView.mouseDown(with: event)
    }

    /// Selects at `point` (in `view`'s coordinates) without the text view's mouse tracking: the
    /// caret at the nearest insertion point, or with 2 or 3 clicks the word or paragraph there.
    /// For a rotated box, whose upright editor doesn't lie under the pointer (`handleClick` would
    /// track the real, unmapped drag).
    func select(at point: CGPoint, in view: NSView, clickCount: Int) {
        if let window = textView.window, window.firstResponder !== textView { window.makeFirstResponder(textView) }
        let length = (textView.string as NSString).length
        let index = min(max(textView.characterIndexForInsertion(at: textView.convert(point, from: view)), 0), length)
        var range = NSRange(location: index, length: 0)
        if clickCount >= 2, length > 0 {
            range = textView.selectionRange(forProposedRange: range,
                                            granularity: clickCount == 2 ? .selectByWord : .selectByParagraph)
        }
        textView.setSelectedRange(range)
    }

    /// Safety net: an editor dropped without `tearDown()` still closes its colour burst, or the
    /// document's undo group would stay open and merge every later edit into one step.
    isolated deinit {
        finishColorBurst()
    }

    func tearDown() {
        finishColorBurst()
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

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        if !isReloading, let replacementString {
            pendingInsertion = NSRange(location: affectedCharRange.location, length: replacementString.utf16.count)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        let insertion = pendingInsertion
        pendingInsertion = nil
        guard !isReloading else { return }
        finishColorBurst()
        let text = RichTextBridge.richText(from: textView.attributedString(), typography: typography)
        if let insertion { normalizeAttributes(in: insertion, to: text) }
        guard text != shownText else { return }
        shownText = text
        onChange(text, true)
        // Normalizing changes attributes only, never the model form, so `text` is still current.
        publishState(text: text)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isReloading else { return }
        if let burst = colorBurst, burst.selection != textView.selectedRange() { finishColorBurst() }
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

    /// Gives the characters in `range` exactly the attributes `RichTextBridge` would draw for
    /// `text` (the model form of the whole view), dropping what the model can't hold (kerning,
    /// links, paragraph spacing, shadows...). Attribute-only: the string, the selection and the
    /// model are unchanged. Skipped during IME composition.
    private func normalizeAttributes(in range: NSRange, to text: RichText) {
        guard range.length > 0, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        // Plain typing: skip the whole-text rebuild below.
        if Self.matchesNeighbour(range, in: storage) { return }
        let rebuilt = RichTextBridge.attributedString(from: text, typography: typography)
        guard rebuilt.string == storage.string, NSMaxRange(range) <= rebuilt.length else { return }
        // Paragraph styles span whole paragraphs; widen so pasted spacing on a partly pasted
        // paragraph is reset too.
        let target = (storage.string as NSString).paragraphRange(for: range)
        // Plain typing already matches; leave the storage (and its spelling marks) alone.
        var differs = false
        rebuilt.enumerateAttributes(in: target, options: []) { attributes, subrange, stop in
            var effective = NSRange()
            let current = storage.attributes(at: subrange.location, effectiveRange: &effective)
            if !(current as NSDictionary).isEqual(to: attributes) || NSMaxRange(effective) < NSMaxRange(subrange) {
                differs = true
                stop.pointee = true
            }
        }
        guard differs else { return }
        let typingAttributes = textView.typingAttributes
        isReloading = true
        storage.beginEditing()
        rebuilt.enumerateAttributes(in: target, options: []) { attributes, subrange, _ in
            storage.setAttributes(attributes, range: subrange)
        }
        storage.endEditing()
        isReloading = false
        // New typing after the paste takes the round-tripped formatting, not the pasted one.
        let caret = textView.selectedRange()
        if caret.length == 0, caret.location > 0, caret.location <= rebuilt.length {
            textView.typingAttributes = rebuilt.attributes(at: caret.location - 1, effectiveRange: nil)
        } else {
            textView.typingAttributes = typingAttributes
        }
    }

    /// True when the characters in `range` all carry exactly the attributes of the character
    /// next to them (before, or after at the start). The rest of the storage is already in the
    /// bridge's normal form, so such an insertion (plain typing, the common case) is too: it
    /// joins its neighbour's run, which the bridge draws with these same attributes.
    static func matchesNeighbour(_ range: NSRange, in storage: NSAttributedString) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        let neighbour = range.location > 0 ? range.location - 1 : NSMaxRange(range)
        guard neighbour < storage.length else { return false }
        var effective = NSRange()
        let inserted = storage.attributes(at: range.location, effectiveRange: &effective)
        guard NSMaxRange(effective) >= NSMaxRange(range) else { return false }
        return (inserted as NSDictionary).isEqual(to: storage.attributes(at: neighbour, effectiveRange: nil))
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
        if case .setColor = action, selection.length > 0 {
            applyColor(action, selection: selection)
            return
        }
        finishColorBurst()
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

    /// A colour change on a selection: joins the open burst on the same selection, or opens a
    /// new one (one undo step), then (re)starts the idle timer that closes it (#76a).
    private func applyColor(_ action: FormatAction, selection: NSRange) {
        if let burst = colorBurst, burst.selection != selection { finishColorBurst() }
        let text = currentText()
        let runs = RichTextFormatting.runs(in: selection, of: text)
        guard let transform = RichTextFormatting.transform(for: action, current: runs, typography: typography)
        else { return }
        let edited = RichTextFormatting.applying(transform, to: selection, of: text)
        if colorBurst == nil {
            // Nothing to change: don't open an (empty) group for it.
            guard edited != shownText else { onEndTypingStep(); publishState(); return }
            onBeginUndoGroup(Self.colorActionName) { [weak self] in self?.dropColorBurst() }
        }
        colorBurst?.closer.cancel()
        let closer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.colorBurstIdle)
            guard !Task.isCancelled else { return }
            self?.finishColorBurst()
        }
        colorBurst = (selection, closer)
        commitFormatted(edited, selection: selection)
    }

    /// True while consecutive colour changes join one undo step.
    var isColorBurstOpen: Bool { colorBurst != nil }

    /// Closes the open colour burst now (any other edit, a new selection, the editor closing).
    func finishColorBurst() {
        guard let burst = colorBurst else { return }
        burst.closer.cancel()
        colorBurst = nil
        onEndUndoGroup(Self.colorActionName)
    }

    /// An undo or redo closed the group: forget the burst without closing anything.
    private func dropColorBurst() {
        colorBurst?.closer.cancel()
        colorBurst = nil
    }

    /// The formatting at the selection (or of the typing attributes when it's empty).
    var formatState: FormatState { formatState(text: currentText()) }

    /// `formatState` for `text`, the view's current text in model form (already computed).
    private func formatState(text: RichText) -> FormatState {
        let selection = textView.selectedRange()
        let runs = selection.length == 0 ? [typingRun()] : RichTextFormatting.runs(in: selection, of: text)
        var state = RichTextFormatting.state(of: runs, typography: typography)
        state.alignment = RichTextFormatting.alignment(in: selection, of: text)
        return state
    }

    func publishState() {
        publishState(text: nil)
    }

    /// Publishes the formatting state. `text`, when given, is the view's current text in model
    /// form, so it isn't converted again.
    private func publishState(text: RichText?) {
        guard let formatting, formatting.target === self else { return }
        let state = formatState(text: text ?? currentText())
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
        publishState(text: normal)
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
                let current = RichTextBridge.modelAlignment(style.alignment)
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
                           size: common { $0.size }, color: common { $0.color }, alignment: nil,
                           resolvedSize: common { $0.size ?? typography.bodySize },
                           resolvedColor: common { $0.color ?? typography.color },
                           isFontMixed: Set(runs.map(\.fontFamily)).count > 1)
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

extension InlineTextEditor {
    /// The typography a text box lays out with, the same as `PageRenderer`'s: the style guide
    /// resolved for the box's role (title-role boxes use the title font), with the box's style
    /// overrides on top (A §4.2). The canvas passes this to the editor, so every load, reload
    /// and format commit in the editor (`RichTextBridge`) matches the rendered page.
    static func typography(for box: Box, base: Typography) -> Typography {
        let resolved = base.resolved(for: box.role)
        guard case let .text(style) = box.content else { return resolved }
        return resolved.applying(style)
    }
}

/// A flipped container (top-left origin, like the page).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
