import BBModel
import Foundation

/// Serializes all I/O for one book package (A §5.1–5.3). One per open book.
public actor BookStore {
    public nonisolated let packageURL: URL
    private let debounce: Duration

    private var pending: (content: BookContent, dirty: DirtySet, generation: Int)?
    private var timer: Task<Void, Never>?
    private var timerToken = 0
    private var autosaveResultHandler: (@Sendable (StoreError?) -> Void)?
    private var readOnly = false
    /// Set while this store holds `.lock` (wrote it, or found this process's own lock): the
    /// per-process holder key taken at acquire (the package's real path then), counted in
    /// `BookLock`'s holders, so a release after the package moved (e.g. trashed) still drops the
    /// right count.
    private var lockKey: String?
    /// Test hook (fault injection): see `SaveStep`.
    private var saveFaultHook: SaveFaultHook?
    /// Counts `storeImage` calls. Clean Up reads it before planning and passes it to
    /// `deleteImages(named:keepingImagesStoredAfter:)`, which keeps any file handed out since.
    public private(set) var imageStoreGeneration = 0
    /// The `imageStoreGeneration` at which `storeImage` last returned each file name (a new
    /// file or a dedup hit on an existing one). One entry per file stored in this session.
    private(set) var imageHandOuts: [String: Int] = [:]

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
            for dir in ["templates", "pages", "sessions", "assets", "images"] {
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

    /// Rolls a committed journal forward (or discards an uncommitted one), migrates an older
    /// schema, repairs the cost ledger, reads the book, deletes the session files of retired
    /// asset sessions (see `readContent`), then sweeps orphan images. Read-only: only reads (a
    /// committed journal is left for the writer to replay; retired sessions are dropped in memory).
    public func load() throws(StoreError) -> BookContent {
        let fm = FileManager.default
        if !readOnly {
            try PackageCoding.io("recover journal") { try Journal(packageURL: packageURL).recover() }
        }
        guard fm.fileExists(atPath: packageURL.appending(path: PackageCoding.bookPath).path(percentEncoded: false)) else {
            throw StoreError.notFound(packageURL.lastPathComponent)
        }
        if !readOnly {
            try Migrator.standard.migrateIfNeeded(packageURL: packageURL)
            try CostLedger(packageURL: packageURL).repair()
        }
        let (content, retired) = try readContent()
        // Housekeeping only: a failed delete or sweep (e.g. a symlinked `images/`) never blocks
        // the open. The sweep then frees the images only the retired sessions used.
        if !readOnly {
            if !retired.isEmpty {
                let deletions = retired.map { PackageCoding.sessionPath($0) }
                _ = try? PackageCoding.io("drop retired sessions") {
                    try Journal(packageURL: packageURL).run(files: [:], deletions: deletions)
                }
            }
            _ = try? sweepOrphanImages(referencedBy: content)
        }
        return content
    }

    /// The book's content, plus the sessions dropped because the 2026-11-11 one-image-per-asset
    /// change retired them (`RetiredAssetSessions`). Any other undecodable file fails the open.
    private func readContent() throws(StoreError) -> (BookContent, Set<SessionID>) {
        // Also guards a migrator that leaves a newer book untouched, and read-only opens (no migration).
        struct SchemaProbe: Decodable { var schemaVersion: Int }
        let bookData = try readFile(PackageCoding.bookPath)
        let probe = try PackageCoding.decode(SchemaProbe.self, from: bookData, what: "book.json")
        if probe.schemaVersion > Book.currentSchemaVersion { throw StoreError.schemaTooNew(probe.schemaVersion) }
        let book = try PackageCoding.decode(Book.self, from: bookData, what: "book.json")
        var style = try PackageCoding.decode(StyleGuide.self, from: readFile(PackageCoding.stylePath), what: "style.json")
        style.styleReferences.removeAll { !$0.isValid }
        var templates: [TemplateID: Template] = [:]
        for t in try readAll("templates", Template.self) { templates[t.id] = t }
        var pages: [PageID: Page] = [:]
        for p in try readAll("pages", Page.self) { pages[p.id] = p }
        var sessions: [SessionID: Session] = [:]
        var retired: Set<SessionID> = []
        for file in try readAll("sessions", Session.self, skippingLegacySheetItems: true) {
            switch file {
            case let .decoded(s): sessions[s.id] = s.droppingInvalidImageRefs()
            case let .legacySheetItem(id): retired.insert(id)
            }
        }
        // Older packages have no `assets/` folder (readAll tolerates that); no schema bump.
        var assets: [AssetID: Asset] = [:]
        for var a in try readAll("assets", Asset.self) {
            if a.referencePhoto?.image.isValid == false { a.referencePhoto = nil }
            assets[a.id] = a
        }
        retired.formUnion(RetiredAssetSessions.drop(from: &sessions, assets: assets))
        let content = BookContent(book: book, style: style, templates: templates, pages: pages,
                                  sessions: sessions, assets: assets)
        return (content, retired)
    }

    /// Saves the dirty entities of `content` as one journaled transaction (A §5.2).
    public func save(_ content: BookContent, dirty: DirtySet) throws(StoreError) {
        guard !readOnly else { throw StoreError.readOnly }
        let files = try PackageCoding.files(for: content, dirty: dirty)
        let deletions = dirty.deletedPages.map { PackageCoding.pagePath($0) }
            + dirty.deletedTemplates.map { PackageCoding.templatePath($0) }.filter { files[$0] == nil }
            + dirty.deletedAssets.map { PackageCoding.assetPath($0) }.filter { files[$0] == nil }
        guard !files.isEmpty || !deletions.isEmpty else { return }
        let fault = saveFaultHook
        try PackageCoding.io("save") {
            // Step 1 (image files) happened in `storeImage` before this call.
            try fault?(.imagesWritten, 0)
            try Journal(packageURL: packageURL).run(files: files, deletions: deletions, fault: fault)
        }
    }

    /// Test hook: called after each save step; throwing `SimulatedCrash` stops the save there.
    func setSaveFaultHook(_ hook: SaveFaultHook?) {
        saveFaultHook = hook
    }

    /// Debounced autosave (1 s after the last call). Dirty sets accumulate; the content with the
    /// highest `generation` wins, so an out-of-order older snapshot is ignored.
    /// Read-only: nothing is scheduled and the result handler gets `.readOnly`.
    public func scheduleSave(_ content: BookContent, dirty: DirtySet, generation: Int) {
        guard !readOnly else {
            autosaveResultHandler?(.readOnly)
            return
        }
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
        // Holds the store strongly until it fires (short-lived), so a save scheduled just before
        // the document closes still completes. A newer schedule or `flush` cancels it.
        timer = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            self.fire(token)
        }
    }

    /// Called after every timer-fired or flushed save: nil on success, the error on failure.
    /// A failed save keeps its pending snapshot, so the next `flush` or `scheduleSave` retries.
    public func setAutosaveResultHandler(_ handler: @escaping @Sendable (StoreError?) -> Void) {
        autosaveResultHandler = handler
    }

    private func fire(_ token: Int) {
        guard token == timerToken else { return }
        timer = nil
        do throws(StoreError) {
            try performPending()
            autosaveResultHandler?(nil)
        } catch {
            autosaveResultHandler?(error)
        }
    }

    /// Performs any pending scheduled save now (window close, quit, hide). A no-op (and no
    /// handler call) if nothing is pending.
    public func flush() throws(StoreError) {
        timer?.cancel()
        timer = nil
        timerToken += 1
        guard pending != nil else { return }
        do throws(StoreError) {
            try performPending()
            autosaveResultHandler?(nil)
        } catch {
            autosaveResultHandler?(error)
            throw error
        }
    }

    private func performPending() throws(StoreError) {
        guard let p = pending else { return }
        try save(p.content, dirty: p.dirty)
        pending = nil
    }

    /// Writes image bytes to `images/<sha256>.<ext>` (temp file + rename; idempotent) and
    /// returns the ref. Called before the JSON that refers to it is saved.
    public func storeImage(_ data: Data, contentType: String) throws(StoreError) -> ImageRef {
        guard !readOnly else { throw StoreError.readOnly }
        let ref = ImageRef(sha256: PackageCoding.sha256Hex(data), contentType: contentType)
        guard ref.isValid else { throw StoreError.io("unsupported image content type: \(contentType)") }
        let dest = imageURL(for: ref)
        try PackageCoding.io("storeImage") {
            let fm = FileManager.default
            let dir = dest.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Refuse if `images/` (or the package) is a symlink leading outside the package.
            guard CanonicalPath.isInside(dir, packageURL) else {
                throw StoreError.io("images folder is outside the package")
            }
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                // Same bytes as an existing file, maybe a >24 h orphan: make it young again so the
                // open-time sweep can't remove it before the JSON that refers to it is saved (#100).
                try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path(percentEncoded: false))
                return
            }
            try PackageCoding.writeAtomically(data, to: dest, tempIn: dir)
        }
        // The caller may put this ref into content later; a Clean Up already under way must not
        // delete the file from under it (`deleteImages(named:keepingImagesStoredAfter:)`).
        imageStoreGeneration += 1
        imageHandOuts[ref.fileName] = imageStoreGeneration
        return ref
    }

    /// Where an image file lives (it may not exist yet). Always inside `images/`: a ref that
    /// fails validation (untrusted `sha256`) maps to a file name that never exists.
    public nonisolated func imageURL(for ref: ImageRef) -> URL {
        let images = packageURL.appending(path: "images", directoryHint: .isDirectory)
        return images.appending(path: ref.isValid ? ref.fileName : "_invalid-image")
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
        try readAll(folder, type, skippingLegacySheetItems: false).compactMap {
            if case let .decoded(value) = $0 { value } else { nil }
        }
    }

    private enum ReadFile<T> {
        case decoded(T)
        /// A session file whose owner is a legacy character-sheet item (`LegacySheetItemError`).
        case legacySheetItem(SessionID)
    }

    /// Every `<folder>/*.json`, decoded. With `skippingLegacySheetItems`, a file that throws
    /// `LegacySheetItemError` is reported by the ID in its name instead of failing the read.
    private func readAll<T: Decodable>(_ folder: String, _ type: T.Type,
                                       skippingLegacySheetItems: Bool) throws(StoreError) -> [ReadFile<T>] {
        let dir = packageURL.appending(path: folder, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { return [] }
        let urls = try PackageCoding.io("list \(folder)") {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        }
        var out: [ReadFile<T>] = []
        for url in urls where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            let data = try PackageCoding.io("read \(url.lastPathComponent)") { try Data(contentsOf: url) }
            let what = "\(folder)/\(url.lastPathComponent)"
            guard skippingLegacySheetItems else {
                out.append(.decoded(try PackageCoding.decode(T.self, from: data, what: what)))
                continue
            }
            if let value = try PackageCoding.decodeUnlessLegacySheetItem(T.self, from: data, what: what) {
                out.append(.decoded(value))
            } else if let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                out.append(.legacySheetItem(SessionID(rawValue: uuid)))
            }
            // A legacy sheet file with a non-UUID name: ignored (and left in place).
        }
        return out
    }

    // MARK: Phase 3 contract: lock, read-only, thumbnail, sweep

    /// Takes `<package>/.lock` (A §5.3). A lock held by this process, or a stale one on this Mac
    /// (dead PID, or a PID reused by a process that started after the lock was taken), is taken
    /// over. Call before `load()`. A lock from another Mac is treated as live; see `takeOverLock`.
    public func acquireLock() throws(StoreError) -> LockAcquisition {
        try acquireLock(exclusiveInProcess: false)
    }

    /// Like `acquireLock()`, but also reports `.heldByOther` (naming this process) when another
    /// store in this process already holds the lock, or `.lock` already names this process. For
    /// background jobs that must not touch a book this process has open, is opening, or is
    /// writing headlessly (duplicate-ID resolution, #3b/#3c).
    public func acquireLockExclusively() throws(StoreError) -> LockAcquisition {
        try acquireLock(exclusiveInProcess: true)
    }

    private func acquireLock(exclusiveInProcess: Bool) throws(StoreError) -> LockAcquisition {
        if lockKey != nil { return exclusiveInProcess ? .heldByOther(BookLock.currentOwner()) : .acquired }
        let lock = BookLock(packageURL: packageURL)
        let key = lock.holderKey
        let outcome = try PackageCoding.io("acquire lock") {
            try lock.acquireHold(key: key, exclusiveInProcess: exclusiveInProcess)
        }
        switch outcome {
        case .wrote, .reentrant:
            lockKey = key
            return .acquired
        case .heldByOther(let owner):
            return .heldByOther(owner)
        }
    }

    /// "Open Anyway" (#99b): replaces a lock that `acquireLock()` reported as
    /// `.heldByOther(expectedOwner)` (typically another Mac's, which can never be proved stale
    /// from here) with this process's, after the user confirms. Succeeds only if `.lock` still
    /// names exactly `expectedOwner` (or has been removed meanwhile). If the file changed since,
    /// returns `.heldByOther` with the owner it names now (or `expectedOwner` if it is
    /// unreadable; call `acquireLock()` again in that case), and the caller may ask the user
    /// again. On `.acquired` this store holds the lock as if `acquireLock()` had
    /// succeeded; release it with `releaseLock()`. The other process is not told: if it is
    /// still running, both may write (the user accepted that risk).
    public func takeOverLock(expectedOwner: LockOwner) throws(StoreError) -> LockAcquisition {
        if lockKey != nil { return .acquired }
        let lock = BookLock(packageURL: packageURL)
        let key = lock.holderKey
        let outcome = try PackageCoding.io("take over lock") { try lock.takeOverHold(key: key, expected: expectedOwner) }
        switch outcome {
        case .tookOver:
            lockKey = key
            return .acquired
        case .ownerChanged(let owner):
            return .heldByOther(owner ?? expectedOwner)
        }
    }

    /// Gives up this store's hold on `.lock`. Safe to call more than once. Holds are counted per
    /// process: the file is removed only when the last store in this process holding it releases,
    /// whichever store wrote it.
    public func releaseLock() {
        guard let key = lockKey else { return }
        lockKey = nil
        BookLock(packageURL: packageURL).releaseHold(key: key)
    }

    /// A store dropped without `releaseLock()` gives up its hold, so `.lock` doesn't stay until
    /// the process exits (#105c).
    deinit {
        if let key = lockKey { BookLock(packageURL: packageURL).releaseHold(key: key) }
    }

    /// After this, `load()` never writes (no journal replay, migration, sweep or ledger repair) and
    /// `save`, `scheduleSave`, `storeImage` and `writeThumbnail` refuse with `.readOnly`.
    public func setReadOnly() {
        readOnly = true
        timer?.cancel()
        timer = nil
        timerToken += 1
        pending = nil
    }

    public var isReadOnly: Bool { readOnly }

    /// `<package>/thumbnail.png` (A §5.1).
    public nonisolated var thumbnailURL: URL {
        packageURL.appending(path: "thumbnail.png", directoryHint: .notDirectory)
    }

    /// Writes `thumbnail.png` atomically (temp file + rename). Not journaled: it's a rebuildable cache.
    public func writeThumbnail(_ png: Data) throws(StoreError) {
        guard !readOnly else { throw StoreError.readOnly }
        let dest = thumbnailURL
        try PackageCoding.io("writeThumbnail") {
            try PackageCoding.writeAtomically(png, to: dest, tempIn: packageURL, tempPrefix: ".thumbnail.png.tmp-")
        }
    }

    /// Deletes `images/` files that no JSON in `content` refers to and that are older than `minimumAge` (A §5.2).
    /// Files named in `SweepProtection.shared` for this book are kept too. `load()` calls this at
    /// open; public for tests and Phase 16 clean-up. Returns the number removed.
    @discardableResult
    public func sweepOrphanImages(referencedBy content: BookContent, minimumAge: TimeInterval = 86_400,
                                  now: Date = Date()) throws(StoreError) -> Int {
        guard !readOnly else { return 0 }
        // Plus files the queue still needs (e.g. a queued region edit's mask, #29a).
        let referenced = ImageSweep.referencedFileNames(in: content)
            .union(SweepProtection.shared.names(for: content.book.id))
        return try PackageCoding.io("sweep images") {
            try ImageSweep.sweep(packageURL: packageURL, referenced: referenced, minimumAge: minimumAge, now: now)
        }
    }
}

/// Load-time migration for the 2026-11-11 one-image-per-asset change. A legacy asset decodes
/// keeping only its primary slot (`Asset.init(from:)`); this drops the sessions of its other
/// slots, whose legacy `assetReference` owner decodes as `.asset` but whose ID isn't the asset's
/// `sessionID`. (Character-sheet sessions never decode: `readAll` skips them.) Sessions of
/// deleted assets stay, as `deleteAsset` leaves them. `load()` deletes the dropped files and the
/// orphan sweep frees their images.
enum RetiredAssetSessions {
    /// Removes the retired sessions from `sessions` and returns their IDs.
    static func drop(from sessions: inout [SessionID: Session], assets: [AssetID: Asset]) -> Set<SessionID> {
        var dropped: Set<SessionID> = []
        for (id, session) in sessions {
            guard case let .asset(assetID) = session.owner, let asset = assets[assetID],
                  asset.sessionID != id else { continue }
            dropped.insert(id)
        }
        for id in dropped { sessions[id] = nil }
        return dropped
    }
}
