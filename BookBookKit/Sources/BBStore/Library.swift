import BBModel
import Foundation

/// The library folder: a scan plus create (Phase 2; the index and FSEvents come in Phase 3).
public struct Library: Sendable {
    public var root: URL

    public init(root: URL = Library.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/BookBook/Library/` (A §5.4).
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "BookBook/Library", directoryHint: .isDirectory)
    }

    /// Every readable `*.bookbook` in `root`, newest first. Unreadable packages are skipped.
    public func scan() -> [LibraryEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var entries: [LibraryEntry] = []
        for url in urls where url.pathExtension == "bookbook" {
            guard let data = try? Data(contentsOf: url.appending(path: PackageCoding.bookPath)),
                  let book = try? PackageCoding.decoder().decode(Book.self, from: data) else { continue }
            entries.append(Self.entry(for: book, at: url))
        }
        return entries.sorted {
            $0.modifiedAt != $1.modifiedAt
                ? $0.modifiedAt > $1.modifiedAt
                : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    /// Creates `<title>.bookbook` (a unique name if taken) from the built-in presets, with one
    /// story page (decided 2026-11-08), creating `root` if needed. The title is trimmed and an
    /// empty one becomes "Untitled" (`NewBookSpec.resolvedTitle`).
    public func createBook(title: String, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        try createBook(spec: NewBookSpec(title: title), now: now)
    }

    /// An entry for `book` stored at `url`, with its thumbnail if `thumbnail.png` exists.
    static func entry(for book: Book, at url: URL) -> LibraryEntry {
        let thumb = url.appending(path: "thumbnail.png", directoryHint: .notDirectory)
        let hasThumb = FileManager.default.fileExists(atPath: thumb.path(percentEncoded: false))
        return LibraryEntry(id: book.id, title: book.title, url: url, modifiedAt: book.modifiedAt,
                            thumbnailURL: hasThumb ? thumb : nil)
    }

    /// Copies the package at `source` into `root` as `<title>.bookbook` (unique name if taken),
    /// leaving out `.lock` and `.journal`, then rewrites its `book.json` as `book` after `edit`.
    /// `makeWritable` resets permissions (a bundled copy can be read-only). Removes the partial
    /// copy on failure. `what` labels the copy step in errors.
    func copyPackage(from source: URL, book: Book, title: String, what: String, makeWritable: Bool = false,
                     edit: (inout Book) -> Void) throws(StoreError) -> LibraryEntry {
        let fm = FileManager.default
        var book = book
        try PackageCoding.io("create library") { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let dest = Self.uniquePackageURL(in: root, title: title)
        do {
            try PackageCoding.io(what) {
                try fm.copyItem(at: source, to: dest)
                for skipped in [".lock", ".journal"] {
                    let item = dest.appending(path: skipped)
                    if fm.fileExists(atPath: item.path(percentEncoded: false)) { try fm.removeItem(at: item) }
                }
                if makeWritable { try Self.makeWritable(dest) }
            }
            edit(&book)
            let data = try PackageCoding.encode(book)
            try PackageCoding.io("write book.json") {
                try data.write(to: dest.appending(path: PackageCoding.bookPath), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return Self.entry(for: book, at: dest)
    }

    /// Sets 0755 on `url` and every folder inside it, and 0644 on every file.
    private static func makeWritable(_ url: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        guard let walker = fm.enumerator(atPath: url.path(percentEncoded: false)) else { return }
        for case let rel as String in walker {
            let p = url.appending(path: rel).path(percentEncoded: false)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: p, isDirectory: &isDir)
            try fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o755 : 0o644], ofItemAtPath: p)
        }
    }

    /// `<sanitized title>.bookbook` in `folder`, or with " 2", " 3"... if the name is taken.
    static func uniquePackageURL(in folder: URL, title: String) -> URL {
        let fm = FileManager.default
        var base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Untitled" }
        var url = folder.appending(path: "\(base).bookbook", directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(base) \(n).bookbook", directoryHint: .isDirectory)
            n += 1
        }
        return url
    }
}

// MARK: Phase 3 library operations

extension Library {
    /// Runs `body` holding the package's `.lock` (#103). A lock held by another live process throws
    /// `.locked`; this process's own lock is fine (re-entrant: the app flushes or closes first).
    static func withPackageLock<T>(_ url: URL, _ body: () throws(StoreError) -> T) throws(StoreError) -> T {
        let lock = BookLock(packageURL: url)
        let key = lock.holderKey
        let outcome = try PackageCoding.io("acquire lock") { try lock.acquireHold(key: key) }
        if case .heldByOther(let owner) = outcome { throw StoreError.locked(owner) }
        defer { lock.releaseHold(key: key) }
        return try body()
    }

    /// Recursive copy with a new `Book.id` and the title "<title> copy" (folder name collision-safe).
    /// Holds the source's lock throughout (`.locked` if another process has it open) and rolls a
    /// committed journal forward first, so the copy includes it; then skips `.lock` and `.journal`.
    /// The source must be flushed first if it's open in this process.
    public func duplicate(_ entry: LibraryEntry, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        try Self.withPackageLock(entry.url) { () throws(StoreError) -> LibraryEntry in
            try PackageCoding.io("recover journal") { try Journal(packageURL: entry.url).recover() }
            return try duplicateLocked(entry, now: now)
        }
    }

    private func duplicateLocked(_ entry: LibraryEntry, now: Date) throws(StoreError) -> LibraryEntry {
        let titles = Set(scan().map(\.title))
        var title = "\(entry.title) copy"
        var n = 2
        while titles.contains(title) {
            title = "\(entry.title) copy \(n)"
            n += 1
        }
        let sourceData = try PackageCoding.io("read book") {
            try Data(contentsOf: entry.url.appending(path: PackageCoding.bookPath))
        }
        let book = try PackageCoding.decode(Book.self, from: sourceData, what: "book.json")
        return try copyPackage(from: entry.url, book: book, title: title, what: "duplicate book") {
            $0.id = BookID()
            $0.title = title
            $0.modifiedAt = now
        }
    }

    /// Moves the package to the Trash (`FileManager.trashItem`). Returns its URL in the Trash.
    /// Holds the package's lock while doing so: `.locked` if another process has it open (#103).
    @discardableResult
    public func trash(_ entry: LibraryEntry) throws(StoreError) -> URL? {
        try Self.withPackageLock(entry.url) { () throws(StoreError) -> URL? in
            try PackageCoding.io("trash book") {
                var result: NSURL?
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: &result)
                // Our `.lock` moved with it; drop it so a restored book doesn't carry it.
                if let trashed = result as URL? { BookLock(packageURL: trashed).release(BookLock.currentOwner()) }
                return result as URL?
            }
        }
    }

    /// Sets the title of a closed book through a headless `BookStore` (lock, load, save, release).
    /// The package folder keeps its name. Throws `.locked` if another process holds it.
    public func rename(_ entry: LibraryEntry, to title: String, now: Date = Date()) async throws(StoreError) -> LibraryEntry {
        let store = BookStore(packageURL: entry.url)
        do throws(StoreError) {
            if case .heldByOther(let owner) = try await store.acquireLock() { throw StoreError.locked(owner) }
            var content = try await store.load()
            content.book.title = title
            content.book.modifiedAt = now
            try await store.save(content, dirty: DirtySet(book: true))
            await store.releaseLock()
        } catch {
            await store.releaseLock()
            throw error
        }
        var updated = entry
        updated.title = title
        updated.modifiedAt = now
        return updated
    }

    /// Moves every `*.bookbook` from this library's root into `newRoot` (created if needed); a name clash gets " 2" etc.
    /// Returns the new package URLs. Stops at the first failure, leaving moved books in `newRoot`.
    public func moveBooks(to newRoot: URL) throws(StoreError) -> [URL] {
        let fm = FileManager.default
        try PackageCoding.io("create new library folder") {
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        }
        let items = try PackageCoding.io("list library") {
            try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        }.filter { $0.pathExtension == "bookbook" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moved: [URL] = []
        for item in items {
            let dest = Self.uniquePackageURL(in: newRoot, title: item.deletingPathExtension().lastPathComponent)
            try PackageCoding.io("move \(item.lastPathComponent)") { try fm.moveItem(at: item, to: dest) }
            moved.append(dest)
        }
        return moved
    }
}
