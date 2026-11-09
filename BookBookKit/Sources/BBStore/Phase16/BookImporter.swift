import BBModel
import Foundation

/// Import from another book (A §5.4, PD §8.1). Pure logic over two `BookContent` values plus the
/// image-file copy. Nothing here touches the target's JSON; the `.importFromBook` command applies
/// the returned `BookImport`.
public enum BookImporter {
    // MARK: Clashes

    /// Selected items whose name (trimmed, case-insensitive) matches an item of the same kind in
    /// `target` (assets are compared across all asset types), or another selected item of that kind.
    /// Every member of a selected-vs-selected group is reported. Order: assets by name, then templates.
    public static func clashes(source: BookContent, target: BookContent,
                               selection: BookImportSelection) -> [BookImportClash] {
        clashes(source: source, target: target, selection: selection, renames: [:])
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func clashes(source: BookContent, target: BookContent, selection: BookImportSelection,
                               renames: [BookImportItem: String]) -> [BookImportClash] {
        func effective(_ item: BookImportItem, _ name: String) -> String { renames[item] ?? name }

        let assets: [(BookImportItem, String)] = selection.assets.compactMap { id in
            source.assets[id].map { (.asset(id), effective(.asset(id), $0.name)) }
        }
        let templates: [(BookImportItem, String)] = selection.templates.compactMap { id in
            source.templates[id].map { (.template(id), effective(.template(id), $0.name)) }
        }

        func find(_ selected: [(BookImportItem, String)], existing: Set<String>) -> [BookImportClash] {
            var counts: [String: Int] = [:]
            for (_, name) in selected { counts[key(name), default: 0] += 1 }
            return selected.filter { existing.contains(key($0.1)) || counts[key($0.1), default: 0] > 1 }
                .sorted { (key($0.1), $0.1) < (key($1.1), $1.1) }
                .map { BookImportClash(item: $0.0, name: $0.1) }
        }
        return find(assets, existing: Set(target.assets.values.map { key($0.name) }))
            + find(templates, existing: Set(target.templates.values.map { key($0.name) }))
    }

    /// Source IDs of selected templates whose `pageRole` the import clears because the target, or a
    /// template imported before it (same order as `build`), already has that role. The sheet shows
    /// these as "kept as a regular template".
    public static func roleDemotions(source: BookContent, target: BookContent,
                                     selection: BookImportSelection) -> Set<TemplateID> {
        var taken = Set(target.templates.values.compactMap(\.pageRole))
        var demoted: Set<TemplateID> = []
        for old in orderedTemplates(source: source, selection: selection) {
            guard let role = old.pageRole else { continue }
            if taken.contains(role) { demoted.insert(old.id) } else { taken.insert(role) }
        }
        return demoted
    }

    private static func orderedTemplates(source: BookContent, selection: BookImportSelection) -> [Template] {
        selection.templates.compactMap { source.templates[$0] }.sorted {
            (key($0.name), $0.id.rawValue.uuidString) < (key($1.name), $1.id.rawValue.uuidString)
        }
    }

    // MARK: Build

    /// The ID-remapped content to merge. `renames` gives new names for clashing items (keyed by
    /// source ID). Throws `.missingSourceItem` for a selected item absent from `source`, and
    /// `.unresolvedClashes` when a clash remains after the renames (including a rename that clashes).
    ///
    /// Assets get a new `AssetID`, new slot/sheet-item UUIDs and revision 1. Each slot/item whose
    /// `chosen` resolves in the source gets a new session holding one `.imported` copy of that
    /// version (new `VersionID`, no parent, no provenance); otherwise `chosen` is nil and the
    /// session is empty. Source sessions are not copied (A §5.4).
    public static func build(source: BookContent, target: BookContent, selection: BookImportSelection,
                             renames: [BookImportItem: String] = [:],
                             now: Date = Date()) throws(BookImportError) -> BookImport {
        for id in selection.assets.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        where source.assets[id] == nil {
            throw .missingSourceItem(.asset(id))
        }
        for id in selection.templates.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        where source.templates[id] == nil {
            throw .missingSourceItem(.template(id))
        }
        let remaining = clashes(source: source, target: target, selection: selection, renames: renames)
        if !remaining.isEmpty { throw .unresolvedClashes(remaining) }

        var result = BookImport()
        var images: Set<ImageRef> = []

        let sortedAssets = selection.assets.compactMap { source.assets[$0] }.sorted {
            (key($0.name), $0.id.rawValue.uuidString) < (key($1.name), $1.id.rawValue.uuidString)
        }
        for old in sortedAssets {
            var asset = old
            asset.id = AssetID()
            asset.name = (renames[.asset(old.id)] ?? old.name).trimmingCharacters(in: .whitespacesAndNewlines)
            asset.revision = 1
            asset.revisionHighWater = 1

            func copySession(sessionID: SessionID, chosen: VersionID?,
                             owner: SessionOwner) -> (SessionID, VersionID?) {
                var session = Session(owner: owner)
                var newChosen: VersionID?
                if let chosen, let v = source.sessions[sessionID]?.version(chosen) {
                    let copy = Version(image: v.image, pixelSize: v.pixelSize, source: .imported, parent: nil,
                                       createdAt: now, starred: false, provenance: nil,
                                       depictsRealPerson: v.depictsRealPerson, consistency: nil)
                    session.versions = [copy]
                    newChosen = copy.id
                    images.insert(v.image)
                }
                result.sessions.append(session)
                return (session.id, newChosen)
            }

            for i in asset.references.indices {
                let slot = asset.references[i]
                let newSlotID = UUID()
                let (sid, chosen) = copySession(sessionID: slot.sessionID, chosen: slot.chosen,
                                                owner: .assetReference(asset.id, newSlotID))
                asset.references[i].id = newSlotID
                asset.references[i].sessionID = sid
                asset.references[i].chosen = chosen
            }
            if var sheet = asset.sheet {
                for i in sheet.items.indices {
                    let item = sheet.items[i]
                    let newItemID = UUID()
                    let (sid, chosen) = copySession(sessionID: item.sessionID, chosen: item.chosen,
                                                    owner: .sheetItem(asset.id, newItemID))
                    sheet.items[i].id = newItemID
                    sheet.items[i].sessionID = sid
                    sheet.items[i].chosen = chosen
                }
                asset.sheet = sheet
            }
            result.assets.append(asset)
        }

        let demoted = roleDemotions(source: source, target: target, selection: selection)
        for old in orderedTemplates(source: source, selection: selection) {
            var template = old
            if demoted.contains(old.id) { template.pageRole = nil }
            template.id = TemplateID()
            template.name = (renames[.template(old.id)] ?? old.name).trimmingCharacters(in: .whitespacesAndNewlines)
            for i in template.boxes.indices { template.boxes[i].id = BoxID() }
            result.templates.append(template)
        }

        if selection.styleGuide {
            result.styleGuide = source.style
            images.formUnion(source.style.styleReferences)
        }
        result.images = images
        return result
    }

    // MARK: Image files

    /// Copies each image's file from `sourcePackage/images/` into the target package through
    /// `BookStore.storeImage`, which names files by SHA-256. A file the target already has is
    /// skipped (counted in `skippedDuplicates`). The source bytes are re-hashed, so a corrupt
    /// source file throws `.corrupt` instead of being stored under the wrong name. A missing source
    /// file throws `.notFound`. Call before the `.importFromBook` command runs.
    public static func copyImages(_ images: Set<ImageRef>, from sourcePackage: URL,
                                  into target: BookStore) async throws(StoreError) -> BookImportCopyReport {
        var report = BookImportCopyReport(copied: 0, skippedDuplicates: 0)
        let fm = FileManager.default
        for ref in images.sorted(by: { $0.fileName < $1.fileName }) {
            guard ref.isValid else { throw StoreError.io("invalid image reference") }
            if fm.fileExists(atPath: target.imageURL(for: ref).path(percentEncoded: false)) {
                report.skippedDuplicates += 1
                continue
            }
            let url = sourcePackage.appending(path: "images", directoryHint: .isDirectory).appending(path: ref.fileName)
            guard fm.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw StoreError.notFound("images/\(ref.fileName)")
            }
            let data = try PackageCoding.io("read source image") { try Data(contentsOf: url) }
            guard PackageCoding.sha256Hex(data) == ref.sha256 else { throw StoreError.corrupt("images/\(ref.fileName)") }
            _ = try await target.storeImage(data, contentType: ref.contentType)
            report.copied += 1
        }
        return report
    }
}
