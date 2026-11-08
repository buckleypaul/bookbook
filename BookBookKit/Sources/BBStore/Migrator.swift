import BBModel
import Foundation

/// Ordered, pure schema migrations run when a book is opened (A §5.1).
public struct Migrator: Sendable {
    /// Migrates every JSON file in a package from schema `from` to `from + 1`.
    /// `files` maps package-relative paths (`book.json`, `style.json`, `pages/<uuid>.json`, …) to their bytes;
    /// a step may change, add or remove entries. It must also set `book.json`'s `schemaVersion` to `from + 1`.
    public struct Step: Sendable {
        public var from: Int
        public var apply: @Sendable (_ files: inout [String: Data]) throws -> Void

        public init(from: Int, apply: @escaping @Sendable (_ files: inout [String: Data]) throws -> Void) {
            self.from = from
            self.apply = apply
        }
    }

    public var steps: [Step]
    public var currentVersion: Int
    /// Called with the package URL and its old version before anything is written.
    public var backup: @Sendable (_ packageURL: URL, _ fromVersion: Int) throws -> Void

    public init(steps: [Step], currentVersion: Int = Book.currentSchemaVersion,
                backup: @escaping @Sendable (_ packageURL: URL, _ fromVersion: Int) throws -> Void = Migrator.backupToTrash) {
        self.steps = steps
        self.currentVersion = currentVersion
        self.backup = backup
    }

    /// The app's migrations. Empty while the schema is at v1.
    public static let standard = Migrator(steps: [])

    /// Pure: runs the steps on `files` from `version` up to `currentVersion`.
    /// Throws `.schemaTooNew` if `version > currentVersion`, `.corrupt` if a step is missing or fails.
    /// On failure `files` is left unchanged.
    public func migrate(_ files: inout [String: Data], from version: Int) throws(StoreError) {
        if version > currentVersion { throw StoreError.schemaTooNew(version) }
        var working = files
        var v = version
        while v < currentVersion {
            guard let step = steps.first(where: { $0.from == v }) else {
                throw StoreError.corrupt("no migration from schema v\(v)")
            }
            do { try step.apply(&working) } catch let e as StoreError { throw e } catch {
                throw StoreError.corrupt("migration from v\(v) failed: \(error)")
            }
            v += 1
        }
        files = working
    }

    /// Reads `book.json`'s schema version; if older, backs up, migrates and writes the result as one
    /// journaled transaction. Returns the version migrated from, or nil if nothing was needed.
    @discardableResult
    public func migrateIfNeeded(packageURL: URL) throws(StoreError) -> Int? {
        struct SchemaProbe: Decodable { var schemaVersion: Int }
        let original = try Self.gather(packageURL)
        guard let bookData = original[PackageCoding.bookPath] else {
            throw StoreError.notFound(packageURL.lastPathComponent)
        }
        let version = try PackageCoding.decode(SchemaProbe.self, from: bookData, what: "book.json").schemaVersion
        if version > currentVersion { throw StoreError.schemaTooNew(version) }
        if version == currentVersion { return nil }
        var migrated = original
        try migrate(&migrated, from: version)
        let changed = migrated.filter { original[$0.key] != $0.value }
        let removed = original.keys.filter { migrated[$0] == nil }
        try PackageCoding.io("migration backup") { try backup(packageURL, version) }
        try PackageCoding.io("migration write") {
            try Journal(packageURL: packageURL).run(files: changed, deletions: removed)
        }
        return version
    }

    /// Every JSON file the store owns, keyed by package-relative path.
    private static func gather(_ packageURL: URL) throws(StoreError) -> [String: Data] {
        try PackageCoding.io("read package") {
            let fm = FileManager.default
            var out: [String: Data] = [:]
            for name in [PackageCoding.bookPath, PackageCoding.stylePath] {
                let url = packageURL.appending(path: name)
                if fm.fileExists(atPath: url.path(percentEncoded: false)) { out[name] = try Data(contentsOf: url) }
            }
            for dir in ["templates", "pages", "assets", "sessions"] {
                let folder = packageURL.appending(path: dir, directoryHint: .isDirectory)
                guard fm.fileExists(atPath: folder.path(percentEncoded: false)) else { continue }
                for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                    out["\(dir)/\(url.lastPathComponent)"] = try Data(contentsOf: url)
                }
            }
            return out
        }
    }

    /// Copies the package to `<name>.bookbook.backup-v<N>` beside it, then moves the copy to the Trash.
    public static func backupToTrash(_ packageURL: URL, fromVersion: Int) throws {
        let fm = FileManager.default
        let base = packageURL.deletingPathExtension().lastPathComponent
        let copy = packageURL.deletingLastPathComponent()
            .appending(path: "\(base).bookbook.backup-v\(fromVersion)", directoryHint: .isDirectory)
        if fm.fileExists(atPath: copy.path(percentEncoded: false)) { try fm.removeItem(at: copy) }
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: packageURL, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            if name == ".lock" || name == ".journal" { continue }
            try fm.copyItem(at: item, to: copy.appending(path: name))
        }
        try fm.trashItem(at: copy, resultingItemURL: nil)
    }
}
