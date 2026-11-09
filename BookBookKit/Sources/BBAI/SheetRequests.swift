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
        case let .view(view): capitalizedFirst("\(ReferenceSelector.displayName(view: view)) view")
        case let .expression(name): capitalizedFirst("\(ReferenceSelector.displayName(expression: name)) expression")
        }
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The message text for a reference slot's first image when the user sends nothing more
    /// specific (e.g. "Reference image of Pip").
    public static func referenceMessageText(for asset: Asset) -> String { "Reference image of \(asset.name)" }
}
