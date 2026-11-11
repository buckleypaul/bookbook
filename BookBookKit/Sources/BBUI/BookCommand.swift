import BBModel
import BBStore
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
/// template in the book. (`deleteTemplate`, Phase 6, is the only way to remove one.)
public enum BookCommand: Hashable, Sendable {
    /// Replace a text box's rich text. Consecutive edits to the same box coalesce into one
    /// undo step until a 1 s pause, a box switch or a formatting change (A §6.3, Phase 4).
    /// `coalescing: false` always starts a new undo step (formatting changes use it).
    case setRichText(page: PageID, box: BoxID, text: RichText, coalescing: Bool = true)
    /// Replace the style guide's typography (Style tab form, Phase 4).
    case setTypography(Typography)
    /// Put a version from the box's session on the page (zoom 1, centred, aspect-fill).
    case chooseVersion(page: PageID, box: BoxID, version: VersionID)
    /// AI text styling (A §7.13): show a version from the text box's styling session on the
    /// page, or nil to remove the style (the template's own look).
    case chooseTextStyle(page: PageID, box: BoxID, version: VersionID?)
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
    /// Add a template to the book (Layouts tab: New, Duplicate, or editing a bundled preset,
    /// which first copies it in under its own ID). Ignored if the ID already exists (Phase 6).
    case addTemplate(Template)
    /// Replace a book template wholesale (every template-editor edit, Phase 6). Pages using it
    /// update live. Image boxes new to the template get empty sessions on the pages that use
    /// it (irreversibly, like `setPageTemplate`). `actionName` is the undo title ("Move Box",
    /// "Resize Box", "Rotate Box", …). Kind and ID can't change: mismatches are ignored.
    case updateTemplate(Template, actionName: String)
    /// Delete a book template. Ignored while any page uses it (`BookContent.pages(using:)`).
    /// Undo restores it.
    case deleteTemplate(TemplateID)
    /// Phase 7: replace the visual style (preset, description, references, negative
    /// guidance) via `StyleGuide.applying(_:)`, which bumps `visualRevision` on a real change.
    /// Undo restores the previous fields and revision exactly.
    case setStyleVisual(StyleVisual)
    /// Phase 7: replace the page setup (size, orientation, margins, bleed). Box frames are
    /// normalized to the trim and placements' focal points are clamped at draw time, so
    /// nothing else changes. `layoutChanged` flags follow from the new box aspects.
    case setPageSetup(PageSetup)
    /// Phase 7 "Mark as OK": write the current revisions and box aspect into the slot's
    /// `acknowledged` (`box: nil` = every image box on the page). Undoable.
    case markFlagsOK(page: PageID, box: BoxID?)
    /// Phase 8: pan/zoom the placed image's crop (A §7.5). `zoom` is clamped to
    /// 1…`CropMath.maximumZoom` and `center` so the image still covers the box (the box's
    /// current render rect, `CropMath.clamped`). Keeps `boxAspectWhenPlaced` and the slot's
    /// `acknowledged`. Ignored with no placement, or when the clamped crop is unchanged.
    /// One canvas drag or pinch is one undo step (an undo group).
    case setCrop(page: PageID, box: BoxID, zoom: Double, center: NormalizedPoint)
    /// Phase 10: add an asset (`Asset.makeNew`). Its session is created irreversibly (an
    /// orphan if undone). Ignored if the ID exists.
    case addAsset(Asset)
    /// Phase 10: replace an asset wholesale (every asset-field edit: name, description,
    /// the chosen image). The stored value is `asset.revised(from: old)`; a missing session
    /// (legacy asset) is created irreversibly. Type, ID and session can't change (ignored).
    /// `actionName` is the undo title ("Rename Asset", "Edit Description", "Choose Image", …).
    /// Renames rewrite nothing: prompts store tokens.
    case updateAsset(Asset, actionName: String)
    /// Phase 10: replace a page's asset checklist (order kept; unknown IDs dropped).
    case setAssetChecklist(page: PageID, [AssetID])
    /// Phase 16 (PD §8.1): merge an import from another book (`BookImporter.build`) in one undo
    /// step: adds its assets and templates (IDs that already exist are skipped) and replaces
    /// the style guide when `styleGuide` is set (the book's page setup is kept; a visual
    /// change bumps `visualRevision`). Its sessions are added irreversibly (orphans if undone,
    /// like every new session). The image files must already be in the package.
    case importFromBook(BookImport)

    /// The undo menu title ("Undo Typing", …).
    public var actionName: String {
        switch self {
        case let .setRichText(_, _, _, coalescing): coalescing ? "Typing" : "Format Text"
        case .setTypography: "Change Typography"
        case .chooseVersion: "Choose Version"
        case let .chooseTextStyle(_, _, version): version == nil ? "Remove Text Style" : "Choose Text Style"
        case .addPage: "Add Page"
        case .duplicatePage: "Duplicate Page"
        case .deletePage: "Delete Page"
        case .reorderPages: "Move Page"
        case .setPageTemplate: "Change Layout"
        case .importStoryText: "Import Story Text"
        case let .setPageDone(_, done): done ? "Mark as Done" : "Mark as Not Done"
        case .setPageNumberStyle: "Change Page Numbers"
        case .addTemplate: "Add Layout"
        case let .updateTemplate(_, name): name
        case .deleteTemplate: "Delete Layout"
        case .setStyleVisual: "Change Style"
        case .setPageSetup: "Change Page Setup"
        case .markFlagsOK: "Mark as OK"
        case .setCrop: Self.cropActionName
        case .addAsset: "New Asset"
        case let .updateAsset(_, name): name
        case .setAssetChecklist: "Change Asset Checklist"
        case .importFromBook: "Import from Book"
        }
    }

    /// The undo title of a crop drag or gesture (one `setCrop` undo group).
    public static let cropActionName = "Adjust Crop"
}

// MARK: - fixSplits

extension BookCommand {
    /// The same command with `fixSplits` set (unchanged for non-structural commands).
    public func withFixSplits(_ fix: Bool) -> BookCommand {
        switch self {
        case let .addPage(index, templateID, _): .addPage(index: index, templateID: templateID, fixSplits: fix)
        case let .duplicatePage(id, _): .duplicatePage(id, fixSplits: fix)
        case let .deletePage(id, _): .deletePage(id, fixSplits: fix)
        case let .reorderPages(order, _): .reorderPages(order, fixSplits: fix)
        case let .setPageTemplate(page, templateID, _): .setPageTemplate(page: page, templateID: templateID, fixSplits: fix)
        case let .importStoryText(texts, templateID, index, _):
            .importStoryText(texts, templateID: templateID, index: index, fixSplits: fix)
        case .setRichText, .setTypography, .chooseVersion, .chooseTextStyle, .setPageDone, .setPageNumberStyle,
             .addTemplate, .updateTemplate, .deleteTemplate, .setStyleVisual, .setPageSetup, .markFlagsOK, .setCrop,
             .addAsset, .updateAsset, .setAssetChecklist, .importFromBook: self
        }
    }

    /// Commands that can change the page sequence (and so may split a spread).
    public var isStructural: Bool {
        switch self {
        case .addPage, .duplicatePage, .deletePage, .reorderPages, .setPageTemplate, .importStoryText: true
        case .setRichText, .setTypography, .chooseVersion, .chooseTextStyle, .setPageDone, .setPageNumberStyle,
             .addTemplate, .updateTemplate, .deleteTemplate, .setStyleVisual, .setPageSetup, .markFlagsOK, .setCrop,
             .addAsset, .updateAsset, .setAssetChecklist, .importFromBook: false
        }
    }
}
