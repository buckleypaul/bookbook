import BBModel
import BBStore
import Foundation
import ImageIO

// Phase 10 contract (main thread); bodies by the UI-core lane. Signatures are frozen.

extension BookDocument {
    /// Where an asset is used (PD §8.3), from the document's incrementally maintained
    /// `UsageIndex` (refreshed on every edit and delivery).
    public func usageSites(of asset: AssetID) -> [UsageSite] {
        usageIndex.sites(for: asset, in: content)
    }

    /// Delete an asset (not undoable, PD §8.10; the UI confirms first with `usageSites`):
    /// removes it from every checklist, rewrites its mention tokens in every session to its
    /// name as plain text, removes `assets/<id>.json`. Images and sessions are kept (its own
    /// sessions become orphans). Returns false if read-only or unknown.
    @discardableResult
    public func deleteAsset(_ id: AssetID) -> Bool {
        guard isEditable, content.assets[id] != nil else { return false }
        return performIrreversible { BookMutations.deleteAsset(id, from: &$0) }
    }

    /// Import a file into an asset's session as an `.imported` version with
    /// `depictsRealPerson` set (A §11); it becomes the asset's image. Not undoable.
    /// `owner` must be `.asset`. A missing session (legacy asset) is created.
    @discardableResult
    public func importAssetImage(from url: URL, owner: SessionOwner, depictsRealPerson: Bool) async throws -> VersionID {
        guard url.isFileURL else { throw ImageImportFailure.notAFileURL }
        guard isEditable else { throw ImageImportFailure.readOnly }
        guard owner.assetID != nil, BookMutations.sessionID(for: owner, in: content) != nil else {
            throw ImageImportFailure.assetGone
        }
        let (ref, normalized) = try await readAndStore(url)
        let versionID = VersionID()
        let stamp = Date()
        let appended = performIrreversible { content in
            BookMutations.appendImportedAssetVersion(image: ref, pixelSize: normalized.pixelSize,
                                                     owner: owner, depictsRealPerson: depictsRealPerson,
                                                     to: &content, versionID: versionID, now: stamp)
        }
        guard appended else { throw isEditable ? ImageImportFailure.assetGone : ImageImportFailure.readOnly }
        return versionID
    }

    /// "Reference Photo…" (PD §8.3): stores the file (scaled down, metadata stripped) as the
    /// photo the asset's Generate is based on. Undoable ("Set Reference Photo", through
    /// `updateAsset`); doesn't change the asset's image or revision. Returns false if nothing changed.
    @discardableResult
    public func setAssetReferencePhoto(from url: URL, for id: AssetID, depictsRealPerson: Bool) async throws -> Bool {
        guard url.isFileURL else { throw ImageImportFailure.notAFileURL }
        guard isEditable else { throw ImageImportFailure.readOnly }
        guard content.assets[id] != nil else { throw ImageImportFailure.assetGone }
        let (ref, normalized) = try await readAndStore(url, asReferencePhoto: true)
        // Re-check after the awaits: the asset may have gone, or the book closed.
        guard isEditable else { throw ImageImportFailure.readOnly }
        guard var asset = content.assets[id] else { throw ImageImportFailure.assetGone }
        asset.referencePhoto = AssetReferencePhoto(image: ref, pixelSize: normalized.pixelSize,
                                                   depictsRealPerson: depictsRealPerson)
        return perform(.updateAsset(asset, actionName: "Set Reference Photo"))
    }

    /// "Remove Reference Photo" (undoable). False if the asset has none.
    @discardableResult
    public func removeAssetReferencePhoto(for id: AssetID) -> Bool {
        guard isEditable, var asset = content.assets[id], asset.referencePhoto != nil else { return false }
        asset.referencePhoto = nil
        return perform(.updateAsset(asset, actionName: "Remove Reference Photo"))
    }

    /// True when the file looks camera-originated (EXIF camera make/model or capture date):
    /// the default answer of the real-person question (A §11). Reads metadata only.
    public nonisolated static func looksCameraOriginated(_ url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        return looksCameraOriginated(properties: properties)
    }

    /// The rule behind `looksCameraOriginated(_:)` on ImageIO properties (testable).
    nonisolated static func looksCameraOriginated(properties: [CFString: Any]) -> Bool {
        func nonEmpty(_ value: Any?) -> Bool {
            guard let text = value as? String else { return false }
            return !text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return nonEmpty(tiff[kCGImagePropertyTIFFMake]) || nonEmpty(tiff[kCGImagePropertyTIFFModel])
            || nonEmpty(exif[kCGImagePropertyExifDateTimeOriginal])
    }

    // MARK: Session lookups for any owner

    /// The session of a page box or asset (nil if the asset's session doesn't exist yet).
    public func session(for owner: SessionOwner) -> Session? {
        BookMutations.sessionID(for: owner, in: content).flatMap { content.sessions[$0] }
    }

    /// The version an asset uses as its image (nil for page boxes).
    public func chosenVersion(for owner: SessionOwner) -> VersionID? {
        switch owner {
        case .pageBox, .textBox: nil
        case let .asset(asset): content.assets[asset]?.chosen
        }
    }

    /// "Choose Image": makes `version` the asset's image (undoable, through `updateAsset`,
    /// which bumps the revision). False if nothing changed or the version isn't in its session.
    @discardableResult
    public func chooseAssetImage(_ version: VersionID, for id: AssetID) -> Bool {
        guard var asset = content.assets[id], session(for: asset.owner)?.version(version) != nil,
              asset.chosen != version else { return false }
        asset.chosen = version
        return perform(.updateAsset(asset, actionName: "Choose Image"))
    }

    /// A short label for an owner: "Page 3 · Image 1", or the asset's name.
    public func ownerLabel(_ owner: SessionOwner) -> String {
        Self.ownerLabel(owner, in: content)
    }

    nonisolated static func ownerLabel(_ owner: SessionOwner, in content: BookContent) -> String {
        switch owner {
        case let .pageBox(page, box):
            let display = DraftAllPlanner.display(page: page, box: box, in: content)
            return "\(display.pageLabel) · \(display.boxLabel)"
        case let .asset(id):
            return content.assets[id]?.name ?? "Asset"
        case let .textBox(page, box):
            let display = DraftAllPlanner.textStyleDisplay(page: page, box: box, in: content)
            return "\(display.pageLabel) · \(display.boxLabel)"
        }
    }
}
