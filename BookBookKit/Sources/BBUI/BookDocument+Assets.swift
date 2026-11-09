import BBModel
import BBStore
import Foundation

// Phase 10 contract (main thread). The UI-core lane fills in the bodies; signatures are frozen.

extension BookDocument {
    /// Where an asset is used (PD §8.3), from the document's incrementally maintained
    /// `UsageIndex` (refreshed on every edit and delivery).
    public func usageSites(of asset: AssetID) -> [UsageSite] { [] }

    /// Delete an asset (not undoable, PD §8.10; the UI confirms first with `usageSites`):
    /// removes it from every checklist, rewrites its mention tokens in every session to its
    /// name as plain text, removes `assets/<id>.json`. Images and sessions are kept (its own
    /// sessions become orphans). Returns false if read-only or unknown.
    @discardableResult
    public func deleteAsset(_ id: AssetID) -> Bool { false }

    /// Import a file into an asset reference slot or sheet item session as an `.imported`
    /// version with `depictsRealPerson` set (A §11), choosing it if nothing is chosen yet.
    /// Not undoable. `owner` must be `.assetReference` or `.sheetItem`.
    @discardableResult
    public func importAssetImage(from url: URL, owner: SessionOwner, depictsRealPerson: Bool) async throws -> VersionID {
        throw ImageImportFailure.boxGone
    }

    /// True when the file looks camera-originated (EXIF camera make/model or capture date):
    /// the default answer of the real-person question (A §11). Reads metadata only.
    public nonisolated static func looksCameraOriginated(_ url: URL) async -> Bool { false }
}
