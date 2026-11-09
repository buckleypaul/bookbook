import BBModel
import Foundation

// Phase 10 contract (main thread); the AI lane fills in the bodies.

/// The user-visible message text queued for a sheet item by "Generate whole sheet" (and the
/// sheet item's empty-session default), e.g. "Three-quarter view" / "Sleepy expression". The
/// prompt wording that describes how to draw it lives in `Prompts/` and is added by
/// `ContextAssembler` for `.sheetItem` targets.
public enum SheetRequests {
    public static func messageText(for kind: SheetItemKind) -> String {
        switch kind {
        case let .view(view): "\(view.rawValue) view"
        case let .expression(name): "\(name) expression"
        }
    }

    /// The message text for a reference slot's first image when the user sends nothing more
    /// specific (e.g. "Reference image of Pip").
    public static func referenceMessageText(for asset: Asset) -> String { "Reference image of \(asset.name)" }
}
