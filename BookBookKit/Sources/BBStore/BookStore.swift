import BBModel
import CryptoKit
import Foundation

/// Serializes all I/O for one book package (A §5.1–5.3). One per open book.
public actor BookStore {
    public nonisolated let packageURL: URL
    private let debounce: Duration

    private var pending: (content: BookContent, dirty: DirtySet, generation: Int)?
    private var timer: Task<Void, Never>?
    private var timerToken = 0

    public init(packageURL: URL) {
        self.init(packageURL: packageURL, debounce: .seconds(1))
    }

    /// Tests use a short debounce.
    public init(packageURL: URL, debounce: Duration) {
        self.packageURL = packageURL
        self.debounce = debounce
    }

    /// Writes a new package at `url` (fails if it exists). Staged in a sibling folder, then
    /// renamed into place, so a crash never leaves a half-written package at `url`.
    public static func create(_ content: BookContent, at url: URL) throws(StoreError) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            throw StoreError.io("already exists: \(url.lastPathComponent)")
        }
        let files = try PackageCoding.files(for: content, dirty: .all(content))
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try PackageCoding.io("create") {
            defer { try? fm.removeItem(at: tmp) }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            for dir in ["templates", "pages", "sessions", "images"] {
                try fm.createDirectory(at: tmp.appending(path: dir, directoryHint: .isDirectory),
                                       withIntermediateDirectories: true)
            }
            for (path, data) in files {
                try PackageCoding.writeSynced(data, to: tmp.appending(path: path))
            }
            try PackageCoding.fsync(tmp)
            try PackageCoding.rename(tmp, to: url)
        }
    }

    /// Rolls a committed journal forward (or discards an uncommitted one), then reads the book.
    public func load() throws(StoreError) -> BookContent {
        try PackageCoding.io("recover journal") { try Journal(packageURL: packageURL).recover() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: packageURL.appending(path: PackageCoding.bookPath).path(percentEncoded: false)) else {
            throw StoreError.notFound(packageURL.lastPathComponent)
        }
        struct SchemaProbe: Decodable { var schemaVersion: Int }
        let bookData = try readFile(PackageCoding.bookPath)
        let probe = try PackageCoding.decode(SchemaProbe.self, from: bookData, what: "book.json")
        if probe.schemaVersion > Book.currentSchemaVersion { throw StoreError.schemaTooNew(probe.schemaVersion) }
        let book = try PackageCoding.decode(Book.self, from: bookData, what: "book.json")
        let style = try PackageCoding.decode(StyleGuide.self, from: readFile(PackageCoding.stylePath), what: "style.json")
        var templates: [TemplateID: Template] = [:]
        for t in try readAll("templates", Template.self) { templates[t.id] = t }
        var pages: [PageID: Page] = [:]
        for p in try readAll("pages", Page.self) { pages[p.id] = p }
        var sessions: [SessionID: Session] = [:]
        for s in try readAll("sessions", Session.self) { sessions[s.id] = s }
        return BookContent(book: book, style: style, templates: templates, pages: pages, sessions: sessions)
    }

    /// Saves the dirty entities of `content` as one journaled transaction (A §5.2).
    public func save(_ content: BookContent, dirty: DirtySet) throws(StoreError) {
        let files = try PackageCoding.files(for: content, dirty: dirty)
        let deletions = dirty.deletedPages.map { PackageCoding.pagePath($0) }
        guard !files.isEmpty || !deletions.isEmpty else { return }
        try PackageCoding.io("save") {
            try Journal(packageURL: packageURL).run(files: files, deletions: deletions)
        }
    }

    /// Debounced autosave (1 s after the last call). Dirty sets accumulate; the content with the
    /// highest `generation` wins, so an out-of-order older snapshot is ignored.
    public func scheduleSave(_ content: BookContent, dirty: DirtySet, generation: Int) {
        if var p = pending {
            p.dirty.formUnion(dirty)
            if generation >= p.generation {
                p.content = content
                p.generation = generation
            }
            pending = p
        } else {
            pending = (content, dirty, generation)
        }
        timer?.cancel()
        timerToken += 1
        let token = timerToken
        let delay = debounce
        timer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.fire(token)
        }
    }

    private func fire(_ token: Int) {
        guard token == timerToken else { return }
        timer = nil
        // On failure the pending save is kept so the next flush retries it.
        try? performPending()
    }

    /// Performs any pending scheduled save now (window close, quit, hide).
    public func flush() throws(StoreError) {
        timer?.cancel()
        timer = nil
        timerToken += 1
        try performPending()
    }

    private func performPending() throws(StoreError) {
        guard let p = pending else { return }
        try save(p.content, dirty: p.dirty)
        pending = nil
    }

    /// Writes image bytes to `images/<sha256>.<ext>` (temp file + rename; idempotent) and
    /// returns the ref. Called before the JSON that refers to it is saved.
    public func storeImage(_ data: Data, contentType: String) throws(StoreError) -> ImageRef {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ref = ImageRef(sha256: hash, contentType: contentType)
        let dest = imageURL(for: ref)
        try PackageCoding.io("storeImage") {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) { return }
            let dir = dest.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appending(path: ".tmp-\(UUID().uuidString)")
            do {
                try PackageCoding.writeSynced(data, to: tmp)
                try PackageCoding.rename(tmp, to: dest)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        return ref
    }

    /// Where an image file lives (it may not exist yet).
    public nonisolated func imageURL(for ref: ImageRef) -> URL {
        packageURL.appending(path: "images").appending(path: ref.fileName)
    }

    // MARK: Reading

    private func readFile(_ path: String) throws(StoreError) -> Data {
        let url = packageURL.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw StoreError.notFound(path)
        }
        return try PackageCoding.io("read \(path)") { try Data(contentsOf: url) }
    }

    private func readAll<T: Decodable>(_ folder: String, _ type: T.Type) throws(StoreError) -> [T] {
        let dir = packageURL.appending(path: folder, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { return [] }
        let urls = try PackageCoding.io("list \(folder)") {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        }
        var out: [T] = []
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            let data = try PackageCoding.io("read \(url.lastPathComponent)") { try Data(contentsOf: url) }
            out.append(try PackageCoding.decode(T.self, from: data, what: "\(folder)/\(url.lastPathComponent)"))
        }
        return out
    }
}
