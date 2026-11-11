import BBModel
import Foundation

/// What Clean up would delete. Deletable = unstarred versions not referenced by any page
/// placement (cover included), reference slot `chosen` or sheet item `chosen`.
/// `fileNames`/`bytesFreed` cover only image files that no remaining version, provenance,
/// style reference or other reference still uses (`ImageSweep.referencedFileNames`).
public struct CleanUpPlan: Hashable, Sendable {
    public var versionIDs: Set<VersionID>
    public var fileNames: Set<String>
    public var bytesFreed: Int64

    public init(versionIDs: Set<VersionID>, fileNames: Set<String>, bytesFreed: Int64) {
        self.versionIDs = versionIDs
        self.fileNames = fileNames
        self.bytesFreed = bytesFreed
    }

    public var isEmpty: Bool { versionIDs.isEmpty }
}

/// Clean up (A §10, PD §8.12): drops versions nothing uses and frees the image files only they used.
public enum CleanUp {
    /// Unstarred versions not referenced by any page placement (cover included) or an asset's
    /// `chosen`, and not an ancestor (via `parent`) of a kept or starred version. Versions
    /// that queued or running requests refer to are passed as `protecting`: they are kept like
    /// `chosen` versions, lineage included.
    /// `fileNames` are the image files used only by those versions
    /// (including their provenance images), computed as `ImageSweep.referencedFileNames` before
    /// minus after. `fileSize` returns a file's size in bytes by name (nil = missing, counts 0).
    public static func plan(for content: BookContent, protecting: Set<VersionID> = [],
                            fileSize: (String) -> Int64?) -> CleanUpPlan {
        var keep: Set<VersionID> = protecting
        for page in content.pages.values {
            for slot in page.images.values {
                if let p = slot.placement { keep.insert(p.versionID) }
            }
        }
        for asset in content.assets.values {
            if let c = asset.chosen { keep.insert(c) }
        }
        // Keep each kept version's whole lineage (`Version.parent` chain): refining it reads the
        // earlier instructions (`ContextAssembler.lineageInstructions`).
        for session in content.sessions.values {
            for v in session.versions where keep.contains(v.id) || v.starred {
                for ancestor in session.lineage(of: v.id) { keep.insert(ancestor.id) }
            }
        }
        var doomed: Set<VersionID> = []
        for session in content.sessions.values {
            for v in session.versions where !v.starred && !keep.contains(v.id) { doomed.insert(v.id) }
        }
        guard !doomed.isEmpty else { return CleanUpPlan(versionIDs: [], fileNames: [], bytesFreed: 0) }
        var after = content
        remove(doomed, from: &after)
        let freed = ImageSweep.referencedFileNames(in: content).subtracting(ImageSweep.referencedFileNames(in: after))
        let bytes = freed.reduce(Int64(0)) { $0 + (fileSize($1) ?? 0) }
        return CleanUpPlan(versionIDs: doomed, fileNames: freed, bytesFreed: bytes)
    }

    /// Removes the plan's versions from their sessions. Messages keep their text (and forget the
    /// version they produced); the files are deleted separately with
    /// `BookStore.deleteImages(named:)` after the content is saved (`filesToDelete`).
    public static func apply(_ plan: CleanUpPlan, to content: inout BookContent) {
        remove(plan.versionIDs, from: &content)
    }

    /// Sessions that `apply` changes, for the `DirtySet` of the save.
    public static func affectedSessions(_ plan: CleanUpPlan, in content: BookContent) -> Set<SessionID> {
        Set(content.sessions.values.filter { s in s.versions.contains { plan.versionIDs.contains($0.id) } }.map(\.id))
    }

    /// The plan's files that are still safe to delete from `content`'s package right now: those
    /// nothing in `content` uses (a file stored again since the plan, `storeImage` returning
    /// the existing file, is kept), nor queued work (`SweepProtection`), nor `keeping` (files
    /// the undo history could bring back).
    public static func filesToDelete(_ plan: CleanUpPlan, in content: BookContent, keeping: Set<String> = [],
                                     protection: SweepProtection = .shared) -> Set<String> {
        plan.fileNames
            .subtracting(ImageSweep.referencedFileNames(in: content))
            .subtracting(protection.names(for: content.book.id))
            .subtracting(keeping)
    }

    /// Like `BookMutations.deleteVersion` for each version: messages that produced one forget
    /// it, and a remaining version whose parent goes takes the nearest remaining ancestor.
    private static func remove(_ ids: Set<VersionID>, from content: inout BookContent) {
        for (sid, var session) in content.sessions where session.versions.contains(where: { ids.contains($0.id) }) {
            var parentOf: [VersionID: VersionID?] = [:]
            for v in session.versions where ids.contains(v.id) { parentOf[v.id] = v.parent }
            session.versions.removeAll { ids.contains($0.id) }
            for index in session.versions.indices {
                var parent = session.versions[index].parent
                var seen: Set<VersionID> = []
                while let p = parent, let next = parentOf[p], seen.insert(p).inserted { parent = next }
                session.versions[index].parent = parent
            }
            for index in session.messages.indices {
                if let v = session.messages[index].producedVersion, ids.contains(v) {
                    session.messages[index].producedVersion = nil
                }
            }
            content.sessions[sid] = session
        }
    }
}
