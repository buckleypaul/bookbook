import BBModel
import SwiftUI

// Phase 10 contract (main thread). The UI-core lane implements it on top of the generalized
// SessionPanel (chat, version strip, details, import with the real-person question). The
// Assets-tab lane embeds it for each reference slot and sheet item.
struct AssetSessionHost: View {
    let document: BookDocument
    let content: BookContent
    /// `.assetReference` or `.sheetItem`.
    let owner: SessionOwner
    let images: ImageCache

    var body: some View {
        Text("Session").foregroundStyle(.secondary)
    }
}
