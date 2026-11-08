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

    /// On open: roll committed transactions forward, discard the rest.
    func recover() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { return }
        let txs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for tx in txs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let committed = fm.fileExists(atPath: tx.appending(path: Self.commitName).path(percentEncoded: false))
            if committed {
                try apply(tx)
            } else {
                try fm.removeItem(at: tx)
            }
        }
    }
}
