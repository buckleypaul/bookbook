import BBModel
import SwiftUI

/// The session for an asset reference slot or character-sheet item (PD §8.3: asset images are
/// made in sessions like pages): the generalized `SessionPanel` with chosen-version semantics
/// (clicking a version makes it the reference, undoable), no story-text toggle and no page
/// checklist, and the real-person question on import. The Assets tab embeds one per slot and
/// sheet item.
struct AssetSessionHost: View {
    let document: BookDocument
    let content: BookContent
    /// `.assetReference` or `.sheetItem`.
    let owner: SessionOwner
    let images: ImageCache

    var body: some View {
        if owner.assetID != nil {
            SessionPanel(document: document, content: content, owner: owner, images: images)
                .id(owner)
        } else {
            ContentUnavailableView("Not an Asset Session", systemImage: "photo")
        }
    }
}
