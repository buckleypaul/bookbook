import AppKit
import BBLayout
import BBModel
import SwiftUI

/// The page canvas (A §6.2): a layer-backed, flipped `NSView` that draws the selected page with
/// `PageRenderer`, scaled to fit, and hosts the in-place text editor.
///
/// HOT SPOT (plan §2.5): one lane at a time.
@MainActor
final class CanvasView: NSView {
    private(set) var content: BookContent?
    private(set) var pageID: PageID?
    private var selectedImageBox: BoxID?
    private var imageSource: (any PageImageSource)?
    private var editor: InlineTextEditor?

    var onSelectImageBox: (BoxID?) -> Void = { _ in }
    var onTextChange: (PageID, BoxID, RichText) -> Void = { _, _, _ in }
    var undoManagerProvider: () -> UndoManager? = { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var editingBoxID: BoxID? { editor?.boxID }

    // MARK: Updates from SwiftUI

    func update(content: BookContent, pageID: PageID?, selectedImageBox: BoxID?, imageSource: any PageImageSource) {
        let pageChanged = pageID != self.pageID
        self.content = content
        self.pageID = pageID
        self.selectedImageBox = selectedImageBox
        self.imageSource = imageSource

        if let editor {
            if pageChanged || textBox(editor.boxID) == nil {
                endEditing()
            } else if let pageID {
                editor.reloadIfNeeded(modelText: content.pages[pageID]?.text[editor.boxID] ?? .empty,
                                      typography: content.style.typography)
                positionEditor()
            }
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionEditor()
        needsDisplay = true
    }

    // MARK: Geometry

    private var page: Page? { pageID.flatMap { content?.pages[$0] } }

    private var geometry: PageGeometry? { content.map { PageGeometry(setup: $0.style.pageSetup) } }

    private var transform: CanvasTransform? {
        guard let geometry else { return nil }
        return CanvasTransform(viewSize: bounds.size, pageSize: geometry.trimSize)
    }

    /// Every box on the page with its render rect, in layer order.
    private var boxRects: [(box: Box, rect: CGRect)] {
        guard let content, let page, let template = content.template(for: page), let geometry else { return [] }
        return template.boxes.map { ($0, geometry.renderRect(for: $0)) }
    }

    private func textBox(_ id: BoxID) -> (box: Box, rect: CGRect)? {
        boxRects.first { $0.box.id == id && $0.box.content != .image }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        guard let content, let page, let imageSource, let transform, let geometry else { return }
        let trim = CGRect(origin: .zero, size: geometry.trimSize)

        ctx.saveGState()
        ctx.translateBy(x: transform.origin.x, y: transform.origin.y)
        ctx.scaleBy(x: transform.scale, y: transform.scale)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(trim)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: trim)
        var options = RenderOptions.screen
        if let editing = editor?.boxID { options.hiddenTextBoxes = [editing] }
        PageRenderer(images: imageSource).draw(page: page, in: content, into: ctx, options: options)
        ctx.restoreGState()

        if let selectedImageBox, let selected = boxRects.first(where: { $0.box.id == selectedImageBox }) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2 / transform.scale)
            ctx.stroke(selected.rect.insetBy(dx: -1 / transform.scale, dy: -1 / transform.scale))
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let transform else { return }
        let point = transform.toPage(convert(event.locationInWindow, from: nil))
        guard let hit = CanvasHitTest.box(at: point, in: boxRects) else {
            endEditing()
            onSelectImageBox(nil)
            return
        }
        switch hit.content {
        case .image:
            endEditing()
            onSelectImageBox(hit.id)
        case .text:
            if editor?.boxID != hit.id { beginEditing(hit.id) }
        }
    }

    // MARK: Text editing

    private func beginEditing(_ boxID: BoxID) {
        endEditing()
        guard let content, let pageID, textBox(boxID) != nil else { return }
        let editor = InlineTextEditor(
            pageID: pageID, boxID: boxID, text: content.pages[pageID]?.text[boxID] ?? .empty,
            typography: content.style.typography, undoManager: { [weak self] in self?.undoManagerProvider() },
            onChange: { [weak self] text in self?.onTextChange(pageID, boxID, text) })
        editor.onCancel = { [weak self] in self?.endEditing() }
        self.editor = editor
        addSubview(editor.host)
        positionEditor()
        editor.beginEditing(in: window)
        needsDisplay = true
    }

    func endEditing() {
        guard let editor else { return }
        let wasFirstResponder = window?.firstResponder === editor.textView
        editor.tearDown()
        self.editor = nil
        if wasFirstResponder { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func positionEditor() {
        guard let editor, let transform, let (box, rect) = textBox(editor.boxID) else { return }
        let textRect = CanvasHitTest.textRect(rect, box: box)
        editor.place(viewRect: transform.toView(textRect), pageSize: textRect.size)
    }
}

/// SwiftUI wrapper for `CanvasView`.
struct PageCanvas: NSViewRepresentable {
    let document: BookDocument
    let content: BookContent
    let pageID: PageID?
    let imageSource: ImageCache
    @Binding var selectedImageBox: BoxID?

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(frame: .zero)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        let document = document, selection = $selectedImageBox
        let undoManager = context.environment.undoManager
        view.onSelectImageBox = { selection.wrappedValue = $0 }
        view.onTextChange = { page, box, text in
            document.perform(.setRichText(page: page, box: box, text: text))
        }
        view.undoManagerProvider = { [weak undoManager] in undoManager }
        view.update(content: content, pageID: pageID, selectedImageBox: selectedImageBox, imageSource: imageSource)
    }

    static func dismantleNSView(_ view: CanvasView, coordinator: ()) {
        view.endEditing()
    }
}
