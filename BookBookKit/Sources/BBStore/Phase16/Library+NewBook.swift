import BBModel
import Foundation

extension Library {
    /// Creates a book from the wizard's `spec` (PD §8.13): the default new book with the spec
    /// applied, written as `<title>.bookbook` (unique name if taken).
    public func createBook(spec: NewBookSpec, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        let fm = FileManager.default
        try PackageCoding.io("create library") { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let story = try Presets.storyTemplate()
        let cover = try Presets.coverTemplate()
        let base = BookContent.makeNew(title: spec.resolvedTitle, storyTemplate: story, coverTemplate: cover,
                                       storyPageCount: 1, now: now)
        let content = spec.apply(to: base)
        let url = Self.uniquePackageURL(in: root, title: content.book.title)
        try BookStore.create(content, at: url)
        return LibraryEntry(id: content.book.id, title: content.book.title, url: url, modifiedAt: now)
    }

    /// Copies a read-only sample package (`SampleBook.bundledURL`) into the library under a new
    /// `Book.id`, keeping its title. Needs no API key.
    public func installSample(from source: URL, now: Date = Date()) throws(StoreError) -> LibraryEntry {
        let fm = FileManager.default
        let sourceData = try PackageCoding.io("read sample") {
            try Data(contentsOf: source.appending(path: PackageCoding.bookPath))
        }
        var book = try PackageCoding.decode(Book.self, from: sourceData, what: "book.json")
        try PackageCoding.io("create library") { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let dest = Self.uniquePackageURL(in: root, title: book.title)
        do {
            try PackageCoding.io("copy sample") {
                try fm.copyItem(at: source, to: dest)
                for skipped in [".lock", ".journal"] {
                    let item = dest.appending(path: skipped)
                    if fm.fileExists(atPath: item.path(percentEncoded: false)) { try fm.removeItem(at: item) }
                }
                // A bundled copy can be read-only; the library copy must be writable.
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path(percentEncoded: false))
                if let walker = fm.enumerator(atPath: dest.path(percentEncoded: false)) {
                    for case let rel as String in walker {
                        let p = dest.appending(path: rel).path(percentEncoded: false)
                        var isDir: ObjCBool = false
                        fm.fileExists(atPath: p, isDirectory: &isDir)
                        try fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o755 : 0o644], ofItemAtPath: p)
                    }
                }
            }
            book.id = BookID()
            book.modifiedAt = now
            let data = try PackageCoding.encode(book)
            try PackageCoding.io("write book.json") {
                try data.write(to: dest.appending(path: PackageCoding.bookPath), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        let thumb = dest.appending(path: "thumbnail.png", directoryHint: .notDirectory)
        let hasThumb = fm.fileExists(atPath: thumb.path(percentEncoded: false))
        return LibraryEntry(id: book.id, title: book.title, url: dest, modifiedAt: now,
                            thumbnailURL: hasThumb ? thumb : nil)
    }
}

/// The bundled sample book (A §5.4): a read-only package that "Open Sample Book" copies into the library.
public enum SampleBook {
    /// `Resources/SampleBook/Sample.bookbook` in the BBStore bundle; nil if it is missing.
    public static func bundledURL() -> URL? {
        Bundle.module.url(forResource: "Sample", withExtension: "bookbook", subdirectory: "SampleBook")
    }
}
