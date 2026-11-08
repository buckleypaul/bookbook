import BBModel
import Foundation

/// An undoable edit (A §6.3, plan P-3). Applied only through `BookDocument.perform(_:)`.
///
/// Commands touch the book's page order and pages only. They never touch sessions (AI
/// results live there), except that `addPage` creates the new page's empty sessions, which
/// stay behind as harmless orphans if the add is undone.
public enum BookCommand: Hashable, Sendable {
    /// Replace a text box's rich text. Consecutive edits to the same box coalesce into one
    /// undo step until a 1 s pause, a box switch or a formatting change (A §6.3, Phase 4).
    /// `coalescing: false` always starts a new undo step (formatting changes use it).
    case setRichText(page: PageID, box: BoxID, text: RichText, coalescing: Bool = true)
    /// Replace the style guide's typography (Style tab form, Phase 4).
    case setTypography(Typography)
    /// Put a version from the box's session on the page (zoom 1, centred, aspect-fill).
    case chooseVersion(page: PageID, box: BoxID, version: VersionID)
    /// Insert a new story page using `templateID` at `index` in `pageOrder` (clamped).
    case addPage(index: Int, templateID: TemplateID)
    case deletePage(PageID)

    /// The undo menu title ("Undo Typing", …).
    public var actionName: String {
        switch self {
        case let .setRichText(_, _, _, coalescing): coalescing ? "Typing" : "Format Text"
        case .setTypography: "Change Typography"
        case .chooseVersion: "Choose Version"
        case .addPage: "Add Page"
        case .deletePage: "Delete Page"
        }
    }
}
