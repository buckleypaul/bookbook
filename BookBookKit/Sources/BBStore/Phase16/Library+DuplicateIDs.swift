import BBModel
import Foundation

// Duplicate Book.id (Phase 16, follow-up from Phase 3).

extension Library {
    /// A Finder copy of a package keeps its `Book.id`. For each group of packages sharing an id,
    /// one is kept and every other gets a fresh `Book.id`, written to its `book.json` through a
    /// headless `BookStore` (lock, load, journaled save, release), so it happens once per package.
    ///
    /// Keeper rule (deterministic): the package at `known[id]` (the one the index already had) if
    /// it is in the group; else the one with the earliest folder creation date; ties go to the
    /// shorter, then lexicographically smaller, folder name ("Fox.bookbook" beats "Fox copy.bookbook").
    ///
    /// Packages in `open` (open in this process) are preferred as the keeper, and a group with
    /// more than one open package is left alone until they close. `open` is only a hint: every
    /// rewrite takes the lock with `acquireLockExclusively()`, so a package whose lock any store
    /// in this process holds (open, still opening, or being written headlessly, e.g. a delivery
    /// to a closed book) is never rewritten (#3b, #3c).
    ///
    /// A package locked by another process or in this process, or unreadable, is skipped and
    /// retried on the next call.
    /// `modifiedAt` is left alone. Returns the entries that were reassigned, with their new ids.
    @discardableResult
    public func resolveDuplicateBookIDs(preferring known: [BookID: URL] = [:],
                                        open: Set<URL> = []) async -> [LibraryEntry] {
        await resolveDuplicateBookIDs(in: scan(), preferring: known, open: open)
    }

    /// The same, for `entries` from a `scan()` the caller already made.
    func resolveDuplicateBookIDs(in entries: [LibraryEntry], preferring known: [BookID: URL],
                                 open: Set<URL>) async -> [LibraryEntry] {
        let groups = Dictionary(grouping: entries, by: \.id).filter { $0.value.count > 1 }
        guard !groups.isEmpty else { return [] }
        var changed: [LibraryEntry] = []
        for (id, group) in groups.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
            let opened = group.filter { e in open.contains { Self.samePackage($0, e.url) } }
            if opened.count > 1 { continue }
            let keeper = opened.first ?? Self.keeper(in: group, preferred: known[id])
            for entry in group where !Self.samePackage(entry.url, keeper.url) {
                let store = BookStore(packageURL: entry.url)
                do throws(StoreError) {
                    if case .heldByOther = try await store.acquireLockExclusively() { continue }
                    var content = try await store.load()
                    if content.book.id == id {
                        content.book.id = BookID()
                        try await store.save(content, dirty: DirtySet(book: true))
                        var updated = entry
                        updated.id = content.book.id
                        changed.append(updated)
                    }
                    await store.releaseLock()
                } catch {
                    await store.releaseLock()
                }
            }
        }
        return changed
    }

    static func keeper(in group: [LibraryEntry], preferred: URL?) -> LibraryEntry {
        if let preferred, let match = group.first(where: { samePackage($0.url, preferred) }) {
            return match
        }
        func created(_ e: LibraryEntry) -> Date {
            (try? e.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
        }
        return group.min { a, b in
            let (ca, cb) = (created(a), created(b))
            if ca != cb { return ca < cb }
            let (na, nb) = (a.url.lastPathComponent, b.url.lastPathComponent)
            return na.count != nb.count ? na.count < nb.count : na < nb
        }!
    }

    static func samePackage(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            == b.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
