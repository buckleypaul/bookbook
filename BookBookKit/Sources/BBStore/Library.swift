import BBModel
import Foundation

/// The library folder: a scan plus create (Phase 2; the index and FSEvents come in Phase 3).
public struct Library: Sendable {
    public var root: URL

    public init(root: URL = Library.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/BookBook/Library/` (A §5.4).
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "BookBook/Library", directoryHint: .isDirectory)
    }

    /// Every readable `*.bookbook` in `root`, newest first. Unreadable packages are skipped.
    public func scan() -> [LibraryEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var entries: [LibraryEntry] = []
        for url in urls where url.pathExtension == "bookbook" {
            guard let data = try? Data(contentsOf: url.appending(path: PackageCoding.bookPath)),
                  let book = try? PackageCoding.decoder().decode(Book.self, from: data) else { continue }
            entries.append(LibraryEntry(id: book.id, title: book.title, url: url, modifiedAt: book.modifiedAt))
        }
        return entries.sorted {
            $0.modifiedAt != $1.modifiedAt
                ? $0.modifiedAt > $1.modifiedAt
                : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    /// Creates `<title>.bookbook` (a unique name if taken) from the built-in presets, with one
    /// story page (decided 2026-11-08), creating `root` if needed.
    public func createBook(title: String, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        let fm = FileManager.default
        try PackageCoding.io("create library") { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let story = try Presets.storyTemplate()
        let cover = try Presets.coverTemplate()
        let content = BookContent.makeNew(title: title, storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 1, now: now)
        var base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Untitled" }
        var url = root.appending(path: "\(base).bookbook", directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: url.path(percentEncoded: false)) {
            url = root.appending(path: "\(base) \(n).bookbook", directoryHint: .isDirectory)
            n += 1
        }
        try BookStore.create(content, at: url)
        return LibraryEntry(id: content.book.id, title: title, url: url, modifiedAt: now)
    }
}
