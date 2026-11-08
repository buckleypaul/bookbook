import BBModel
import Foundation

/// An undoable edit (A §6.3, plan P-3). Applied only through `BookDocument.perform(_:)`.
///
/// Commands touch the book's page order and pages only. They never touch sessions (AI
/// results live there), except that `addPage` creates the new page's empty sessions, which
/// stay behind as harmless orphans if the add is undone.
public enum BookCommand: Hashable, Sendable {
    /// Replace a text box's rich text. Not coalesced in Phase 2 (Phase 4 adds coalescing).
    case setRichText(page: PageID, box: BoxID, text: RichText)
    /// Put a version from the box's session on the page (zoom 1, centred, aspect-fill).
    case chooseVersion(page: PageID, box: BoxID, version: VersionID)
    /// Insert a new story page using `templateID` at `index` in `pageOrder` (clamped).
    case addPage(index: Int, templateID: TemplateID)
    case deletePage(PageID)

    /// The undo menu title ("Undo Typing", …).
    public var actionName: String {
        switch self {
        case .setRichText: "Typing"
        case .chooseVersion: "Choose Version"
        case .addPage: "Add Page"
        case .deletePage: "Delete Page"
        }
    }
}
