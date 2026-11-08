import BBModel
import Foundation

// Phase 3 contract (main thread). The migrator/ledger lane implements it.

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
    public func migrate(_ files: inout [String: Data], from version: Int) throws(StoreError) {}

    /// Reads `book.json`'s schema version; if older, backs up, migrates and writes the result as one
    /// journaled transaction. Returns the version migrated from, or nil if nothing was needed.
    @discardableResult
    public func migrateIfNeeded(packageURL: URL) throws(StoreError) -> Int? {
        nil
    }

    /// Copies the package to `<name>.bookbook.backup-v<N>` beside it, then moves the copy to the Trash.
    public static func backupToTrash(_ packageURL: URL, fromVersion: Int) throws {}
}
