import AppKit
import SwiftUI

// Phase 6 contract: the template editor's canvas (lane L3 implements; lane L4 embeds it).

/// The visual template editor: draws the open template with `PageRenderer` (sample content when
/// `model.showSampleContent`), the fold on spreads, trim/safe-area guides, selection handles and
/// snap guides, and handles click/shift-click selection, drag, resize, rotate, arrow-key nudges
/// and Delete. Edits go through `model` only.
public struct TemplateCanvas: NSViewRepresentable {
    public let model: TemplateEditorModel
    public let imageSource: ImageCache

    public init(model: TemplateEditorModel, imageSource: ImageCache) {
        self.model = model
        self.imageSource = imageSource
    }

    public func makeNSView(context: Context) -> NSView { NSView() } // Phase 6 lane L3
    public func updateNSView(_ nsView: NSView, context: Context) {}  // Phase 6 lane L3
}
