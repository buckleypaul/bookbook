import BBModel
import BBStore
import Foundation

/// Phase 8 session edits that are not undoable (PD §8.10): star, delete, reset. Each goes
/// through `performIrreversible`; the box is addressed by page and box, never by session.
extension BookDocument {
    @discardableResult
    public func setStarred(_ starred: Bool, version: VersionID, page: PageID, box: BoxID) -> Bool {
        mutateSession(page: page, box: box) { BookMutations.setStarred(starred, version: version, in: $0, to: &$1) }
    }

    /// Deletes a version; any box showing it (on any page) becomes empty. Callers confirm first.
    @discardableResult
    public func deleteVersion(_ version: VersionID, page: PageID, box: BoxID) -> Bool {
        mutateSession(page: page, box: box) { BookMutations.deleteVersion(version, in: $0, to: &$1) }
    }

    /// Clears the chat (and, with `keepVersions: false`, the versions and the box's placement).
    /// Callers confirm first.
    @discardableResult
    public func resetSession(page: PageID, box: BoxID, keepVersions: Bool) -> Bool {
        mutateSession(page: page, box: box) { BookMutations.resetSession($0, keepVersions: keepVersions, to: &$1) }
    }

    private func mutateSession(page: PageID, box: BoxID,
                               _ body: (SessionID, inout BookContent) -> DirtySet) -> Bool {
        guard let sessionID = content.pages[page]?.images[box]?.sessionID else { return false }
        var changed = false
        performIrreversible { content in
            let dirty = body(sessionID, &content)
            changed = !dirty.isEmpty
            return dirty
        }
        return changed
    }
}
