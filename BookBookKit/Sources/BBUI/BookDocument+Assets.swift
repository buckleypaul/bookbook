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
        var deleted = false
        performIrreversible { content in
            let dirty = BookMutations.deleteAsset(id, from: &content)
            deleted = !dirty.isEmpty
            return dirty
        }
        return deleted
    }

    /// Import a file into an asset reference slot or sheet item session as an `.imported`
    /// version with `depictsRealPerson` set (A §11), choosing it if nothing is chosen yet.
    /// Not undoable. `owner` must be `.assetReference` or `.sheetItem`.
    @discardableResult
    public func importAssetImage(from url: URL, owner: SessionOwner, depictsRealPerson: Bool) async throws -> VersionID {
        guard url.isFileURL else { throw ImageImportFailure.notAFileURL }
        guard isEditable else { throw ImageImportFailure.readOnly }
        guard owner.assetID != nil, BookMutations.sessionID(for: owner, in: content) != nil else {
            throw ImageImportFailure.assetGone
        }
        let (ref, normalized) = try await readAndStore(url)
        let versionID = VersionID()
        var appended = false
        let stamp = Date()
        performIrreversible { content in
            let dirty = BookMutations.appendImportedAssetVersion(image: ref, pixelSize: normalized.pixelSize,
                                                                 owner: owner, depictsRealPerson: depictsRealPerson,
                                                                 to: &content, versionID: versionID, now: stamp)
            appended = !dirty.isEmpty
            return dirty
        }
        guard appended else { throw isEditable ? ImageImportFailure.assetGone : ImageImportFailure.readOnly }
        return versionID
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

    /// The session of a page box, asset slot or sheet item.
    public func session(for owner: SessionOwner) -> Session? {
        BookMutations.sessionID(for: owner, in: content).flatMap { content.sessions[$0] }
    }

    /// The version an asset slot or sheet item uses as its reference (nil for page boxes).
    public func chosenVersion(for owner: SessionOwner) -> VersionID? {
        switch owner {
        case .pageBox: nil
        case let .assetReference(asset, slot): content.assets[asset]?.references.first { $0.id == slot }?.chosen
        case let .sheetItem(asset, item): content.assets[asset]?.sheet?.items.first { $0.id == item }?.chosen
        }
    }

    /// "Choose Reference": makes `version` the slot's or item's reference image (undoable,
    /// through `updateAsset`). False if nothing changed or the owner is a page box.
    @discardableResult
    public func chooseReference(_ version: VersionID, for owner: SessionOwner) -> Bool {
        guard let id = owner.assetID, var asset = content.assets[id],
              session(for: owner)?.version(version) != nil else { return false }
        switch owner {
        case .pageBox:
            return false
        case let .assetReference(_, slot):
            guard let i = asset.references.firstIndex(where: { $0.id == slot }) else { return false }
            asset.references[i].chosen = version
        case let .sheetItem(_, item):
            guard let i = asset.sheet?.items.firstIndex(where: { $0.id == item }) else { return false }
            asset.sheet?.items[i].chosen = version
        }
        return perform(.updateAsset(asset, actionName: "Choose Reference"))
    }

    /// A short label for an owner: "Page 3 · Image 1", "Pip · Primary", "Pip · Sleepy expression".
    public func ownerLabel(_ owner: SessionOwner) -> String {
        Self.ownerLabel(owner, in: content)
    }

    nonisolated static func ownerLabel(_ owner: SessionOwner, in content: BookContent) -> String {
        switch owner {
        case let .pageBox(page, box):
            let display = DraftAllPlanner.display(page: page, box: box, in: content)
            return "\(display.pageLabel) · \(display.boxLabel)"
        case let .assetReference(id, slot):
            let asset = content.assets[id]
            let label = asset?.references.first { $0.id == slot }?.label ?? "Reference"
            return "\(asset?.name ?? "Asset") · \(label)"
        case let .sheetItem(id, item):
            let asset = content.assets[id]
            let kind = asset?.sheet?.items.first { $0.id == item }?.kind
            return "\(asset?.name ?? "Asset") · \(kind.map(SheetItemText.title) ?? "Sheet item")"
        }
    }
}

/// Display names for sheet items ("Three-quarter view", "Sleepy expression").
public enum SheetItemText {
    public static func title(_ kind: SheetItemKind) -> String {
        switch kind {
        case let .view(view): viewName(view) + " view"
        case let .expression(name): name.prefix(1).uppercased() + name.dropFirst() + " expression"
        }
    }

    public static func viewName(_ view: SheetView) -> String {
        switch view {
        case .front: "Front"
        case .threeQuarter: "Three-quarter"
        case .side: "Side"
        case .back: "Back"
        }
    }
}
