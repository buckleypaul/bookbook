import BBModel
import CryptoKit
import Foundation

/// Imported fonts live in `fonts/<sha256>.<ext>` (A §5.1, §8.3). Importing a font isn't
/// undoable (PD §8.10) and isn't recorded in the model: every file in `fonts/` is registered
/// when the book opens. Phase 4 contract; lane C implements.
extension BookStore {
    /// Copies the font bytes into `fonts/` under their SHA-256 name (keeping the lowercased
    /// extension: ttf, otf or ttc), atomically. Storing the same bytes twice is a no-op.
    /// Returns the stored file's URL. Read-only stores throw `.readOnly`.
    public func storeFont(_ data: Data, fileExtension: String) throws(StoreError) -> URL {
        guard !isReadOnly else { throw StoreError.readOnly }
        let ext = fileExtension.lowercased()
        guard Self.fontExtensions.contains(ext) else {
            throw StoreError.io("unsupported font file extension: \(fileExtension)")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = fontsDirectory
        let dest = dir.appending(path: "\(hash).\(ext)")
        let package = packageURL
        try PackageCoding.io("storeFont") {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Refuse if `fonts/` (or the package) is a symlink leading outside the package.
            let root = package.resolvingSymlinksInPath().path(percentEncoded: false)
            let fonts = dir.resolvingSymlinksInPath().path(percentEncoded: false)
            guard fonts.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw StoreError.io("fonts folder is outside the package")
            }
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) { return }
            let tmp = dir.appending(path: ".tmp-\(UUID().uuidString)")
            do {
                try PackageCoding.writeSynced(data, to: tmp)
                try PackageCoding.rename(tmp, to: dest)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        }
        return dest
    }

    /// Every font file in `fonts/` (ttf/otf/ttc), sorted by name. Empty if the folder is missing.
    public nonisolated func fontFileURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Self.fontExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static var fontExtensions: Set<String> { ["ttf", "otf", "ttc"] }

    private nonisolated var fontsDirectory: URL {
        packageURL.appending(path: "fonts", directoryHint: .isDirectory)
    }
}
