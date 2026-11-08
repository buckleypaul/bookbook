import Foundation

/// App-level files under `~/Library/Application Support/BookBook/` (A §5.5): `queue.json` and
/// the user's `pricelist.json`. Writes are atomic (temp file, then rename).
public struct AppSupportFiles: Sendable {
    public static let queueFileName = "queue.json"
    public static let priceListFileName = "pricelist.json"

    public let folderURL: URL

    /// `folderURL` defaults to `~/Library/Application Support/BookBook`. Tests pass a temp folder.
    public init(folderURL: URL? = nil) {
        self.folderURL = folderURL ?? URL.applicationSupportDirectory.appending(path: "BookBook", directoryHint: .isDirectory)
    }

    public func url(for name: String) -> URL { folderURL.appending(path: name, directoryHint: .notDirectory) }

    /// nil if the file doesn't exist or can't be read.
    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: url(for: name))
    }

    public func write(_ data: Data, to name: String) throws(StoreError) {
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try data.write(to: url(for: name), options: .atomic)
        } catch {
            throw StoreError.io(String(describing: error))
        }
    }

    /// Removes the file; a missing file is not an error.
    public func remove(_ name: String) throws(StoreError) {
        do {
            try FileManager.default.removeItem(at: url(for: name))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw StoreError.io(String(describing: error))
        }
    }
}
