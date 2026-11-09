import BBModel
import Foundation

extension BookStore {
    /// Size in bytes of `images/<fileName>` on disk (nil when missing). For `CleanUp.plan`.
    public nonisolated func imageFileSize(_ fileName: String) -> Int64? {
        guard !fileName.contains("/"), !fileName.isEmpty else { return nil }
        let url = packageURL.appending(path: "images", directoryHint: .isDirectory).appending(path: fileName)
        guard let v = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]),
              let size = v.fileAllocatedSize ?? v.fileSize else { return nil }
        return Int64(size)
    }

    /// Deletes the named files from `images/` now (not via the 24 h sweep). Call after the cleaned
    /// content has been saved, so no saved JSON refers to them. Names with a path separator or a
    /// leading dot are ignored; an `images/` that resolves outside the package is refused.
    /// Returns the number removed.
    @discardableResult
    public func deleteImages(named fileNames: Set<String>) throws(StoreError) -> Int {
        if isReadOnly { throw StoreError.readOnly }
        let fm = FileManager.default
        let dir = packageURL.appending(path: "images", directoryHint: .isDirectory)
        return try PackageCoding.io("delete images") {
            let package = packageURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let images = dir.resolvingSymlinksInPath().path(percentEncoded: false)
            guard images.hasPrefix(package.hasSuffix("/") ? package : package + "/") else {
                throw StoreError.io("images folder is outside the package")
            }
            var removed = 0
            for name in fileNames where !name.contains("/") && !name.isEmpty && !name.hasPrefix(".") {
                let url = dir.appending(path: name)
                guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                try fm.removeItem(at: url)
                removed += 1
            }
            return removed
        }
    }

    /// Allocated size in bytes of the whole package folder, recursive (includes hidden files).
    public nonisolated func sizeOnDisk() -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: packageURL, includingPropertiesForKeys: Array(keys),
                                                          options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }
}
