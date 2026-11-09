import BBModel
import Foundation

/// Deletes `images/` files that no JSON refers to (A §5.2). Only `images/` is ever touched, so
/// `.journal`, `.lock`, `thumbnail.png` and `costs.jsonl` are never candidates.
enum ImageSweep {
    /// File names (`<sha256>.<ext>`) of every image `content` refers to: session versions, the
    /// references sent or omitted in their provenance, and the style guide's references.
    static func referencedFileNames(in content: BookContent) -> Set<String> {
        var refs: [ImageRef] = content.style.styleReferences
        for session in content.sessions.values {
            for version in session.versions {
                refs.append(version.image)
                if let p = version.provenance {
                    refs.append(contentsOf: p.referencesSent.map(\.image))
                    refs.append(contentsOf: p.referencesOmitted.map(\.image))
                    // Region edits (Phase 11): the mask and the raw provider output stay for Version details.
                    refs.append(contentsOf: [p.maskSent, p.rawOutput, p.intent.regionMask].compactMap { $0 })
                }
            }
        }
        return Set(refs.filter(\.isValid).map(\.fileName))
    }

    /// Removes unreferenced regular files in `<package>/images` whose modification date is more
    /// than `minimumAge` before `now`. Refuses if `images/` resolves outside the package.
    static func sweep(packageURL: URL, referenced: Set<String>, minimumAge: TimeInterval, now: Date) throws -> Int {
        let fm = FileManager.default
        let dir = packageURL.appending(path: "images", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { return 0 }
        let package = packageURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let images = dir.resolvingSymlinksInPath().path(percentEncoded: false)
        guard images.hasPrefix(package.hasSuffix("/") ? package : package + "/") else {
            throw StoreError.io("images folder is outside the package")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        let cutoff = now.addingTimeInterval(-minimumAge)
        var removed = 0
        for url in urls where !referenced.contains(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
