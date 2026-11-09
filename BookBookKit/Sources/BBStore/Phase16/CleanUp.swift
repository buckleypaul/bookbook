import BBModel
import Foundation

/// Clean up (A §10, PD §8.12): drops versions nothing uses and frees the image files only they used.
public enum CleanUp {
    /// Unstarred versions not referenced by any page placement (cover included), reference slot
    /// `chosen` or sheet item `chosen`, and not an ancestor (via `parent`) of a kept or starred version. Versions
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
            for slot in asset.references { if let c = slot.chosen { keep.insert(c) } }
            for item in asset.sheet?.items ?? [] { if let c = item.chosen { keep.insert(c) } }
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

    /// Removes the plan's versions from their sessions. Messages keep their text; the files are
    /// deleted separately with `BookStore.deleteImages(named:)` after the content is saved.
    public static func apply(_ plan: CleanUpPlan, to content: inout BookContent) {
        remove(plan.versionIDs, from: &content)
    }

    /// Sessions that `apply` changes, for the `DirtySet` of the save.
    public static func affectedSessions(_ plan: CleanUpPlan, in content: BookContent) -> Set<SessionID> {
        Set(content.sessions.values.filter { s in s.versions.contains { plan.versionIDs.contains($0.id) } }.map(\.id))
    }

    private static func remove(_ ids: Set<VersionID>, from content: inout BookContent) {
        for (sid, var session) in content.sessions where session.versions.contains(where: { ids.contains($0.id) }) {
            session.versions.removeAll { ids.contains($0.id) }
            content.sessions[sid] = session
        }
    }
}
