import BBModel
import CoreServices
import Foundation
import Synchronization

/// The library folder's books, cached on disk and kept fresh with FSEvents (A §5.4).
public actor LibraryIndex {
    public nonisolated let root: URL
    public nonisolated let cacheURL: URL

    private var current: [LibraryEntry] = []
    private var continuations: [UUID: AsyncStream<[LibraryEntry]>.Continuation] = [:]
    private var watcher: FSEventsWatcher?
    private var debounceTask: Task<Void, Never>?
    private var resolving = false
    /// For each id, the package that owned it before the latest scan. Updated by every scan: an
    /// id seen once is owned by its package; a duplicated id keeps its earlier owner if that
    /// package is still in the group, else has none (the keeper rule then decides).
    private var owners: [BookID: URL] = [:]
    /// Package URLs open in this process; `refreshResolvingDuplicates` never rewrites these.
    private var openPackages: @Sendable @MainActor () -> Set<URL> = { [] }

    /// `~/Library/Application Support/BookBook/library-index.json`.
    public static var defaultCacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "BookBook/library-index.json", directoryHint: .notDirectory)
    }

    public init(root: URL, cacheURL: URL = LibraryIndex.defaultCacheURL) {
        self.root = root
        self.cacheURL = cacheURL
    }

    /// The current entries, newest first. Empty until `loadCache()` or `refresh()`.
    public var entries: [LibraryEntry] { current }

    /// Reads the cached index (ignored if it was written for another root). Fast; for first paint.
    @discardableResult
    public func loadCache() -> [LibraryEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? PackageCoding.decoder().decode(CacheFile.self, from: data),
              file.root == root.path(percentEncoded: false) else { return current }
        current = file.entries
        updateOwners(from: current)
        return current
    }

    /// Rescans the folder (`*.bookbook`, `book.json`, `thumbnail.png`), updates `entries` and rewrites the cache.
    @discardableResult
    public func refresh() -> [LibraryEntry] {
        current = Library(root: root).scan()
        updateOwners(from: current)
        writeCache()
        return current
    }

    /// Tells the index which packages are open in this process (the app passes its open
    /// documents' URLs). Duplicate resolution never rewrites them.
    public func setOpenPackages(_ provider: @escaping @Sendable @MainActor () -> Set<URL>) {
        openPackages = provider
    }

    /// `refresh()` after giving every duplicate `Book.id` (a Finder copy) a fresh one; see
    /// `Library.resolveDuplicateBookIDs`. The package that owned the id before (see `owners`)
    /// keeps it, and open packages are never rewritten. A call that overlaps a run in progress
    /// just refreshes.
    @discardableResult
    public func refreshResolvingDuplicates() async -> [LibraryEntry] {
        if !resolving {
            resolving = true
            let open = await openPackages()
            await Library(root: root).resolveDuplicateBookIDs(preferring: owners, open: open)
            resolving = false
        }
        return refresh()
    }

    public func entry(for id: BookID) -> LibraryEntry? {
        current.first { $0.id == id }
    }

    /// Starts watching the folder (once) and returns a stream that yields fresh entries after each debounced change.
    /// Noise from the app's own saves inside packages is filtered (changes to `book.json` and `thumbnail.png` still count).
    public func changes() -> AsyncStream<[LibraryEntry]> {
        let (stream, continuation) = AsyncStream<[LibraryEntry]>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(id) }
        }
        startWatchingIfNeeded()
        return stream
    }

    /// Stops watching and finishes every stream from `changes()`.
    public func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        watcher?.stop()
        watcher = nil
        let all = continuations.values
        continuations = [:]
        for c in all { c.finish() }
    }

    // MARK: Private

    private struct CacheFile: Codable {
        var root: String
        var entries: [LibraryEntry]
    }

    private func updateOwners(from entries: [LibraryEntry]) {
        let previous = owners
        owners = [:]
        for (id, group) in Dictionary(grouping: entries, by: \.id) {
            if group.count == 1 {
                owners[id] = group[0].url
            } else if let before = previous[id], group.contains(where: { Library.samePackage($0.url, before) }) {
                owners[id] = before
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func writeCache() {
        let file = CacheFile(root: root.path(percentEncoded: false), entries: current)
        guard let data = try? PackageCoding.encoder().encode(file) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func startWatchingIfNeeded() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        watcher = FSEventsWatcher(root: root) { [weak self] in
            guard let self else { return }
            Task { await self.eventArrived() }
        }
    }

    private func eventArrived() {
        guard watcher != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await self.refreshAndYield()
        }
    }

    private func refreshAndYield() async {
        guard watcher != nil else { return }
        let fresh = await refreshResolvingDuplicates()
        guard watcher != nil else { return }
        for c in continuations.values { c.yield(fresh) }
    }

    /// Whether an FSEvents path matters: the package itself, its `book.json` or its `thumbnail.png`.
    /// Everything else inside a package (`.journal`, `.lock`, `images/`, `pages/`...) is the app's own save noise.
    static func isRelevant(path: String, root: URL) -> Bool {
        let rootPath = realPath(root)
        let rootParts = rootPath.split(separator: "/")
        let parts = path.split(separator: "/")
        guard parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return false }
        let rel = parts.dropFirst(rootParts.count)
        guard let first = rel.first else { return true }
        guard first.hasSuffix(".bookbook") else { return false }
        switch rel.count {
        case 1: return true
        case 2: return rel.last == "book.json" || rel.last == "thumbnail.png"
        default: return false
        }
    }
}

/// Owns one FSEvents stream on a private serial queue. Used only from `LibraryIndex`'s isolation; the callback
/// reaches the index through the immutable, Sendable `Box`.
private final class FSEventsWatcher {
    private final class Box: Sendable {
        let root: URL
        let onRelevant: @Sendable () -> Void
        init(root: URL, onRelevant: @escaping @Sendable () -> Void) {
            self.root = root
            self.onRelevant = onRelevant
        }
    }

    private var stream: FSEventStreamRef?
    private var box: Box?

    init(root: URL, onRelevant: @escaping @Sendable () -> Void) {
        let box = Box(root: root, onRelevant: onRelevant)
        // The stream owns a +1 on the box (#97): FSEvents calls `retain` when it copies the
        // context and `release` when the stream is released, so a callback still in flight on
        // the stream's queue during `stop()` never sees a freed box.
        let retainBox: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<Box>.fromOpaque(info).retain()
            return info
        }
        let releaseBox: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).release()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: retainBox, release: releaseBox, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for i in 0..<count {
                if let path = paths[i] as? String, LibraryIndex.isRelevant(path: path, root: box.root) {
                    box.onRelevant()
                    return
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        let realRoot = realPath(root)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [realRoot] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "app.bookbook.library-fsevents"))
        FSEventStreamStart(stream)
        self.stream = stream
        self.box = box
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box = nil
    }

    deinit { stop() }
}

/// The canonical path (FSEvents reports `/private/var/...`; Foundation's `resolvingSymlinksInPath` strips `/private`).
private func realPath(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    guard let resolved = realpath(path, nil) else { return url.standardizedFileURL.path(percentEncoded: false) }
    defer { free(resolved) }
    return String(cString: resolved)
}
