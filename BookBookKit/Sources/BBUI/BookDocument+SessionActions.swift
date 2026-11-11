import BBModel
import BBStore
import Foundation

/// Phase 8 session edits that are not undoable (PD §8.10): star, delete, reset. Each goes
/// through `performIrreversible`; the box is addressed by page and box, never by session.
extension BookDocument {
    /// Clears the chat (and, with `keepVersions: false`, the versions and the box's placement).
    /// Callers confirm first.
    @discardableResult
    public func resetSession(page: PageID, box: BoxID, keepVersions: Bool) -> Bool {
        mutateSession(page: page, box: box) { BookMutations.resetSession($0, keepVersions: keepVersions, to: &$1) }
    }

    // Phase 10: the same for any session owner (assets included).
    // Deleting an asset's chosen version clears that choice too.

    @discardableResult
    public func setStarred(_ starred: Bool, version: VersionID, owner: SessionOwner) -> Bool {
        mutateSession(owner) { BookMutations.setStarred(starred, version: version, in: $0, to: &$1) }
    }

    @discardableResult
    public func deleteVersion(_ version: VersionID, owner: SessionOwner) -> Bool {
        mutateSession(owner) { BookMutations.deleteVersion(version, in: $0, to: &$1) }
    }

    @discardableResult
    public func resetSession(owner: SessionOwner, keepVersions: Bool) -> Bool {
        mutateSession(owner) { BookMutations.resetSession($0, keepVersions: keepVersions, to: &$1) }
    }

    private func mutateSession(page: PageID, box: BoxID,
                               _ body: (SessionID, inout BookContent) -> DirtySet) -> Bool {
        mutateSession(.pageBox(page, box), body)
    }

    private func mutateSession(_ owner: SessionOwner, _ body: (SessionID, inout BookContent) -> DirtySet) -> Bool {
        guard let sessionID = BookMutations.sessionID(for: owner, in: content) else { return false }
        return performIrreversible { body(sessionID, &$0) }
    }
}
