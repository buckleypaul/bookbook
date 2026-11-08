import BBModel
import Foundation

/// An undoable edit (A §6.3, plan P-3). Applied only through `BookDocument.perform(_:)`.
///
/// Commands touch the book's page order, pages, templates and style only. They never touch
/// sessions (AI results live there), except that commands creating image boxes (`addPage`,
/// `duplicatePage`, `importStoryText`, `setPageTemplate`, blank insertion) create those
/// boxes' sessions irreversibly; they stay behind as harmless orphans if undone.
///
/// Structural commands (Phase 5) take `fixSplits`. With `true`, `perform` inserts blank
/// text-only pages (`Presets.textOnlyTemplateID`) where `PageSequencer.blankInsertions`
/// says, in the same undo step. Use `BookDocument.wouldSplitSpread(_:)` first to decide
/// whether to show the spread-split warning (PD §8.5).
///
/// A command whose `templateID` names a bundled preset the book doesn't have yet copies
/// that preset into the book (as does blank insertion for the text-only preset). Like new
/// sessions, the copy is made irreversibly: undo removes the pages but leaves the unused
/// template in the book, because a package can't delete a template file (`DirtySet`).
public enum BookCommand: Hashable, Sendable {
    /// Replace a text box's rich text. Consecutive edits to the same box coalesce into one
    /// undo step until a 1 s pause, a box switch or a formatting change (A §6.3, Phase 4).
    /// `coalescing: false` always starts a new undo step (formatting changes use it).
    case setRichText(page: PageID, box: BoxID, text: RichText, coalescing: Bool = true)
    /// Replace the style guide's typography (Style tab form, Phase 4).
    case setTypography(Typography)
    /// Put a version from the box's session on the page (zoom 1, centred, aspect-fill).
    case chooseVersion(page: PageID, box: BoxID, version: VersionID)
    /// Insert a new story page using `templateID` (single or spread) at `index` in
    /// `pageOrder` (clamped).
    case addPage(index: Int, templateID: TemplateID, fixSplits: Bool = false)
    /// Insert a copy right after the page: same template and text, image placements copied
    /// with copies of the boxes' sessions (new IDs).
    case duplicatePage(PageID, fixSplits: Bool = false)
    case deletePage(PageID, fixSplits: Bool = false)
    /// Replace `pageOrder` with a permutation of it (drag-and-drop). Ignored if not a
    /// permutation.
    case reorderPages([PageID], fixSplits: Bool = false)
    /// Change a story or cover page's template, reassigning content with
    /// `TemplateReassignment`. Cover pages accept only `.cover` templates; story pages
    /// only `.single`/`.spread`.
    case setPageTemplate(page: PageID, templateID: TemplateID, fixSplits: Bool = false)
    /// Story text import (PD §8.5): one new page per element, text in the template's first
    /// text box (reading order), inserted at `index` in `pageOrder`. One undo step.
    case importStoryText([RichText], templateID: TemplateID, index: Int, fixSplits: Bool = false)
    /// Mark a page done / not done (status badge, A §4.4).
    case setPageDone(PageID, Bool)
    /// Replace the style guide's page-number style.
    case setPageNumberStyle(PageNumberStyle)

    /// The undo menu title ("Undo Typing", …).
    public var actionName: String {
        switch self {
        case let .setRichText(_, _, _, coalescing): coalescing ? "Typing" : "Format Text"
        case .setTypography: "Change Typography"
        case .chooseVersion: "Choose Version"
        case .addPage: "Add Page"
        case .duplicatePage: "Duplicate Page"
        case .deletePage: "Delete Page"
        case .reorderPages: "Move Page"
        case .setPageTemplate: "Change Layout"
        case .importStoryText: "Import Story Text"
        case let .setPageDone(_, done): done ? "Mark as Done" : "Mark as Not Done"
        case .setPageNumberStyle: "Change Page Numbers"
        }
    }
}
