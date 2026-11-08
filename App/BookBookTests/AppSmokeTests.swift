import Foundation
import Testing
@testable import BookBook

/// Phase 1b smoke test: the app module loads and the host app has the expected bundle ID.
@Test func app_moduleLoadsWithExpectedBundleID() {
    _ = BookBookApp.self
    #expect(Bundle.main.bundleIdentifier == "app.bookbook.BookBook")
}

/// The built app declares the BookBook package type and opens it as its owner (architecture.md §5.1).
@Test func app_declaresBookPackageType() throws {
    let info = try #require(Bundle.main.infoDictionary)
    let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
    let book = try #require(exported.first { $0["UTTypeIdentifier"] as? String == "app.bookbook.book" })
    let conforms = book["UTTypeConformsTo"] as? [String] ?? []
    #expect(conforms.contains("com.apple.package"))
    let tags = book["UTTypeTagSpecification"] as? [String: Any]
    let extensions = tags?["public.filename-extension"] as? [String] ?? []
    #expect(extensions == ["bookbook"])
    let docTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
    let doc = try #require(docTypes.first { ($0["LSItemContentTypes"] as? [String])?.contains("app.bookbook.book") == true })
    #expect(doc["LSTypeIsPackage"] as? Bool == true)
}
