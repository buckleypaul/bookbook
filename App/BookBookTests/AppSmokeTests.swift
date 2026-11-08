import Foundation
import Testing
@testable import BookBook

/// Phase 1b smoke test: the app module loads and the host app has the expected bundle ID.
@Test func app_moduleLoadsWithExpectedBundleID() {
    _ = BookBookApp.self
    #expect(Bundle.main.bundleIdentifier == "app.bookbook.BookBook")
}
