import AppKit
import SwiftUI

/// The visual template editor: draws the open template with `PageRenderer` (sample content when
/// `model.showSampleContent`), the fold on spreads, trim/safe-area guides, selection handles and
/// snap guides, and handles click/shift-click selection, drag, resize, rotate, arrow-key nudges
/// and Delete. Edits go through `model` only. A `CanvasView` in `LayoutEditingController` mode,
/// which redraws itself when the model changes (Observation tracking).
public struct TemplateCanvas: NSViewRepresentable {
    public let model: TemplateEditorModel
    public let imageSource: ImageCache

    public init(model: TemplateEditorModel, imageSource: ImageCache) {
        self.model = model
        self.imageSource = imageSource
    }

    public func makeNSView(context: Context) -> NSView {
        let view = CanvasView(frame: .zero)
        view.controller = LayoutEditingController(model: model, imageSource: imageSource)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CanvasView else { return }
        if let current = view.controller as? LayoutEditingController,
           current.model === model, current.imageSource === imageSource {
            view.needsDisplay = true
        } else {
            view.controller = LayoutEditingController(model: model, imageSource: imageSource)
        }
    }
}
