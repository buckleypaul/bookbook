import Foundation

/// Phase 8 lineage helpers (A §7.6). The thread is linear in the UI, but versions form a tree
/// through `Version.parent`; refining a version uses only its lineage (root → that version).
extension Session {
    /// Messages in the current epoch, in thread order (older epochs are hidden after a reset).
    public var visibleMessages: [Message] { messages.filter { $0.epoch == resetEpoch } }

    /// The chain of versions from the root to `id`, root first, `id` last. Empty if `id` isn't
    /// in the session. A dangling or cyclic `parent` ends the chain at the last valid version.
    public func lineage(of id: VersionID) -> [Version] {
        var chain: [Version] = []
        var seen: Set<VersionID> = []
        var next: VersionID? = id
        while let current = next, !seen.contains(current), let version = version(current) {
            chain.append(version)
            seen.insert(current)
            next = version.parent
        }
        return chain.reversed()
    }

    /// The user instructions along `id`'s lineage, oldest first: current-epoch `.user` messages
    /// whose `producedVersion` is in the lineage. Used for stateless-mode condensation and
    /// mention resolution (A §7.3, §7.6). Messages from earlier epochs never contribute.
    public func lineageInstructions(of id: VersionID) -> [Message] {
        let ids = Set(lineage(of: id).map(\.id))
        return visibleMessages.filter { message in
            guard message.role == .user, let produced = message.producedVersion else { return false }
            return ids.contains(produced)
        }
    }

    /// The 1-based number shown in the UI ("v3", "refined version 3"): position in the strip.
    public func versionNumber(_ id: VersionID) -> Int? {
        versions.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The session holding `message`, used to resolve queue items by message rather than by a
    /// box ID that may have moved (Phase 5 follow-up).
    public func containsMessage(_ message: MessageID) -> Bool { messages.contains { $0.id == message } }
}

extension BookContent {
    /// The session that holds `message`, if any.
    public func session(containing message: MessageID) -> Session? {
        sessions.values.first { $0.containsMessage(message) }
    }
}
