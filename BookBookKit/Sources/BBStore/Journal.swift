import Foundation
import Synchronization

/// The steps of one save (A §5.2). Test hook: a `SaveFaultHook` is called after each step
/// completes and may throw `SimulatedCrash` to stop the save there, as if the process had died.
enum SaveStep: Int, CaseIterable, Sendable {
    /// Step 1: new image files are in `images/` (they are stored before `save` is called).
    case imagesWritten = 1
    /// Step 2: staged files and `manifest.json` written.
    case staged
    /// Step 3: fsync, `COMMIT`, fsync.
    case committed
    /// Step 4: one rename or deletion applied. Called after each, with the running count.
    case renamed
    /// Step 5: the transaction folder removed.
    case cleanedUp
}

/// Thrown by a test's fault hook. Nothing after the faulting step runs, not even clean-up.
struct SimulatedCrash: Error {}

/// `(step, operationsApplied)`: `operationsApplied` counts step-4 renames and deletions so far.
typealias SaveFaultHook = @Sendable (_ step: SaveStep, _ operationsApplied: Int) throws -> Void

/// A journaled transaction (A §5.2 steps 2-5). Staged files live in
/// `.journal/<txid>/staged/<relative path>`; `manifest.json` lists targets and deletions;
/// an empty `COMMIT` file makes the transaction durable.
struct Journal {
    struct Manifest: Codable, Equatable {
        var targets: [String]
        var deletions: [String]
    }

    static let folderName = ".journal"
    static let commitName = "COMMIT"
    static let manifestName = "manifest.json"

    let packageURL: URL

    var root: URL { packageURL.appending(path: Self.folderName, directoryHint: .isDirectory) }

    /// Stages (and, if `commit`, commits and applies) one transaction. Returns the txid folder.
    /// `commit: false` exists so tests can simulate a crash before COMMIT.
    @discardableResult
    func run(files: [String: Data], deletions: [String], commit: Bool = true, apply shouldApply: Bool = true,
             fault: SaveFaultHook? = nil) throws -> URL {
        let fm = FileManager.default
        let tx = root.appending(path: Self.newTxid(), directoryHint: .isDirectory)
        let staged = tx.appending(path: "staged", directoryHint: .isDirectory)
        // Another store in this process opening the book must not discard this transaction
        // while it is still uncommitted. (A crashed process leaves no entry, so it is recovered.)
        let key = tx.standardizedFileURL.path(percentEncoded: false)
        Self.inFlight.withLock { _ = $0.insert(key) }
        defer { Self.inFlight.withLock { _ = $0.remove(key) } }
        try Self.createDirectoryRetrying(staged)
        for (path, data) in files {
            let dest = staged.appending(path: path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageCoding.writeSynced(data, to: dest)
        }
        let manifest = Manifest(targets: files.keys.sorted(), deletions: deletions.sorted())
        try PackageCoding.writeSynced(PackageCoding.encoder().encode(manifest),
                                      to: tx.appending(path: Self.manifestName))
        try PackageCoding.fsync(tx)
        try fault?(.staged, 0)
        guard commit else { return tx }
        try PackageCoding.writeSynced(Data(), to: tx.appending(path: Self.commitName))
        try PackageCoding.fsync(tx)
        try fault?(.committed, 0)
        if shouldApply { try apply(tx, fault: fault) }
        return tx
    }

    /// Moves staged files into place, applies deletions, removes the transaction folder.
    /// Idempotent, so a half-applied transaction can be replayed.
    func apply(_ tx: URL, fault: SaveFaultHook? = nil) throws {
        let fm = FileManager.default
        let manifest = try PackageCoding.decoder().decode(
            Manifest.self, from: Data(contentsOf: tx.appending(path: Self.manifestName)))
        let staged = tx.appending(path: "staged", directoryHint: .isDirectory)
        var applied = 0
        for path in manifest.targets {
            let src = staged.appending(path: path)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dest = packageURL.appending(path: path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageCoding.rename(src, to: dest)
            applied += 1
            try fault?(.renamed, applied)
        }
        for path in manifest.deletions {
            let url = packageURL.appending(path: path)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) { try fm.removeItem(at: url) }
            applied += 1
            try fault?(.renamed, applied)
        }
        try Self.removeIfPresent(tx)
        removeRootIfEmpty()
        try fault?(.cleanedUp, applied)
    }

    /// `.journal/` exists only while a save is in flight (A §5.1). `rmdir(2)` fails harmlessly
    /// while another transaction is still in it.
    func removeRootIfEmpty() {
        // ENOTEMPTY (another transaction appeared) and ENOENT (already gone) are both fine.
        _ = rmdir(root.path(percentEncoded: false))
    }

    /// Transaction folders this process is writing right now (standardized paths).
    private static let inFlight = Mutex<Set<String>>([])

    /// `mkdir -p` that survives another store `rmdir`-ing an empty `.journal` between creating
    /// it and creating the transaction folder inside it. Once the tx folder exists, `.journal`
    /// is non-empty and no `rmdir` can remove it.
    static func createDirectoryRetrying(_ url: URL) throws {
        var attempt = 0
        while true {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return
            } catch where attempt < 5 && isNoSuchFile(error) {
                attempt += 1
            }
        }
    }

    static func isNoSuchFile(_ error: any Error) -> Bool {
        if let e = error as? CocoaError, e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    /// `removeItem` that treats "already gone" as success (another store finished it first).
    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch where isNoSuchFile(error) {}
    }

    private static var pathPattern: Regex<(Substring, Substring, Substring?)> {
        /^(book\.json|style\.json|(templates|pages|sessions)\/[0-9A-Fa-f-]{36}\.json)$/
    }

    /// `<20-digit wall-clock nanoseconds>-<UUID>`: names sort by creation time, so recovery
    /// replays committed transactions oldest-first.
    /// Strictly increasing within the process: `Date` only resolves ~240 ns, so two saves in
    /// the same instant would otherwise tie and fall back to random UUID order.
    static func newTxid() -> String {
        let ns = lastTxidNanoseconds.withLock { last in
            last = max(last + 1, UInt64(max(0, Date().timeIntervalSince1970) * 1e9))
            return last
        }
        let digits = String(ns)
        return String(repeating: "0", count: max(0, 20 - digits.count)) + digits + "-" + UUID().uuidString
    }

    private static let lastTxidNanoseconds = Mutex<UInt64>(0)

    private static var txidPattern: Regex<Substring> {
        /^[0-9]{20}-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/
    }

    /// Symlink-resolved path without a trailing slash.
    private static func resolved(_ url: URL) -> String {
        var p = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True if the txid folder name, every manifest path and every resolved source and
    /// destination parent stay inside the journal / package.
    func isSafe(_ tx: URL) -> Bool {
        guard tx.lastPathComponent.wholeMatch(of: Self.txidPattern) != nil,
              let data = try? Data(contentsOf: tx.appending(path: Self.manifestName)),
              let manifest = try? PackageCoding.decoder().decode(Manifest.self, from: data) else { return false }
        let package = Self.resolved(packageURL)
        let staged = Self.resolved(tx.appending(path: "staged"))
        let journal = Self.resolved(root)
        guard staged.hasPrefix(journal + "/") else { return false }
        for path in manifest.targets + manifest.deletions {
            guard path.wholeMatch(of: Self.pathPattern) != nil else { return false }
            let dest = Self.resolved(packageURL.appending(path: path).deletingLastPathComponent())
            guard dest == package || dest.hasPrefix(package + "/") else { return false }
        }
        for path in manifest.targets {
            let srcURL = tx.appending(path: "staged").appending(path: path)
            // Already renamed by a crashed apply: `apply` skips it, and a missing path cannot be
            // resolved (so it would wrongly fail the prefix check and discard a half-applied commit).
            guard FileManager.default.fileExists(atPath: srcURL.path(percentEncoded: false)) else { continue }
            let src = Self.resolved(srcURL)
            guard src.hasPrefix(staged + "/") else { return false }
        }
        return true
    }

    /// On open: roll committed transactions forward, discard the rest.
    func recover() throws {
        let fm = FileManager.default
        let txs: [URL]
        do {
            txs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch where Self.isNoSuchFile(error) {
            return // no journal (or another store just removed the empty folder): nothing to recover
        }
        for tx in txs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Still being written by another store in this process: theirs to finish.
            let key = tx.standardizedFileURL.path(percentEncoded: false)
            if Self.inFlight.withLock({ $0.contains(key) }) { continue }
            let committed = fm.fileExists(atPath: tx.appending(path: Self.commitName).path(percentEncoded: false))
            // A journal may come from a shared book, so it is untrusted: anything that is not
            // exactly what this store writes is discarded whole, never partly applied.
            if committed, isSafe(tx) {
                try apply(tx)
            } else {
                try Self.removeIfPresent(tx)
            }
        }
        removeRootIfEmpty()
    }
}
