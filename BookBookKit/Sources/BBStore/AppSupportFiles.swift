import Foundation

/// App-level files under `~/Library/Application Support/BookBook/` (A §5.5): `queue.json` and
/// the user's `pricelist.json`. Writes are atomic (temp file, then rename).
public struct AppSupportFiles: Sendable {
    public static let queueFileName = "queue.json"
    public static let priceListFileName = "pricelist.json"
    /// Phase 16b: spool folder for finished pictures whose book was locked (listed in `queue.json`).
    public static let undeliveredFolderName = "undelivered"

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

    /// `name` may include a subfolder (`undelivered/x.png`); missing folders are created.
    public func write(_ data: Data, to name: String) throws(StoreError) {
        do {
            try FileManager.default.createDirectory(at: url(for: name).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url(for: name), options: .atomic)
        } catch {
            throw StoreError.io(String(describing: error))
        }
    }

    /// Whether the file exists.
    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path(percentEncoded: false))
    }

    /// The names of the regular files in `folder` (a subfolder name); empty if it doesn't exist.
    public func fileNames(in folder: String) -> [String] {
        let dir = folderURL.appending(path: folder, directoryHint: .isDirectory)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
            ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent).sorted()
    }

    /// Renames an unreadable file to `<stem>-unreadable-<timestamp>.<ext>` beside it (a number is
    /// added if that name is taken), so a later write can't overwrite it. Returns the new name.
    @discardableResult
    public func moveAside(_ name: String, now: Date = Date()) throws(StoreError) -> String {
        let source = url(for: name)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "\(stem)-unreadable-\(formatter.string(from: now))"
        let folder = (name as NSString).deletingLastPathComponent
        var candidate = base
        var n = 1
        func fullName(_ stem: String) -> String {
            let file = ext.isEmpty ? stem : "\(stem).\(ext)"
            return folder.isEmpty ? file : "\(folder)/\(file)"
        }
        while exists(fullName(candidate)) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        do {
            try FileManager.default.moveItem(at: source, to: url(for: fullName(candidate)))
        } catch {
            throw StoreError.io(String(describing: error))
        }
        return fullName(candidate)
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
