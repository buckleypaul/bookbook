import Foundation

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
    func run(files: [String: Data], deletions: [String], commit: Bool = true, apply shouldApply: Bool = true) throws -> URL {
        let fm = FileManager.default
        let tx = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let staged = tx.appending(path: "staged", directoryHint: .isDirectory)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        for (path, data) in files {
            let dest = staged.appending(path: path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageCoding.writeSynced(data, to: dest)
        }
        let manifest = Manifest(targets: files.keys.sorted(), deletions: deletions.sorted())
        try PackageCoding.writeSynced(PackageCoding.encoder().encode(manifest),
                                      to: tx.appending(path: Self.manifestName))
        try PackageCoding.fsync(tx)
        guard commit else { return tx }
        try PackageCoding.writeSynced(Data(), to: tx.appending(path: Self.commitName))
        try PackageCoding.fsync(tx)
        if shouldApply { try apply(tx) }
        return tx
    }

    /// Moves staged files into place, applies deletions, removes the transaction folder.
    /// Idempotent, so a half-applied transaction can be replayed.
    func apply(_ tx: URL) throws {
        let fm = FileManager.default
        let manifest = try PackageCoding.decoder().decode(
            Manifest.self, from: Data(contentsOf: tx.appending(path: Self.manifestName)))
        let staged = tx.appending(path: "staged", directoryHint: .isDirectory)
        for path in manifest.targets {
            let src = staged.appending(path: path)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dest = packageURL.appending(path: path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PackageCoding.rename(src, to: dest)
        }
        for path in manifest.deletions {
            let url = packageURL.appending(path: path)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) { try fm.removeItem(at: url) }
        }
        try fm.removeItem(at: tx)
    }

    private static var pathPattern: Regex<(Substring, Substring, Substring?)> {
        /^(book\.json|style\.json|(templates|pages|sessions)\/[0-9A-Fa-f-]{36}\.json)$/
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
        guard UUID(uuidString: tx.lastPathComponent) != nil,
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
            let src = Self.resolved(tx.appending(path: "staged").appending(path: path))
            guard src.hasPrefix(staged + "/") else { return false }
        }
        return true
    }

    /// On open: roll committed transactions forward, discard the rest.
    func recover() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        let txs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for tx in txs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let committed = fm.fileExists(atPath: tx.appending(path: Self.commitName).path(percentEncoded: false))
            // A journal may come from a shared book, so it is untrusted: anything that is not
            // exactly what this store writes is discarded whole, never partly applied.
            if committed, isSafe(tx) {
                try apply(tx)
            } else {
                try fm.removeItem(at: tx)
            }
        }
    }
}
