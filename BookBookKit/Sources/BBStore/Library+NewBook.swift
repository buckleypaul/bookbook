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
        let sourceData = try PackageCoding.io("read sample") {
            try Data(contentsOf: source.appending(path: PackageCoding.bookPath))
        }
        let book = try PackageCoding.decode(Book.self, from: sourceData, what: "book.json")
        // A bundled copy can be read-only; the library copy must be writable.
        return try copyPackage(from: source, book: book, title: book.title, what: "copy sample",
                               makeWritable: true) {
            $0.id = BookID()
            $0.modifiedAt = now
        }
    }
}

/// The bundled sample book (A §5.4): a read-only package that "Open Sample Book" copies into the library.
public enum SampleBook {
    /// `Resources/SampleBook/Sample.bookbook` in the BBStore bundle; nil if it is missing.
    public static func bundledURL() -> URL? {
        Bundle.module.url(forResource: "Sample", withExtension: "bookbook", subdirectory: "SampleBook")
    }
}
