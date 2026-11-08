import AppKit
import BBModel
import BBStore
import Foundation
import SwiftUI
import Testing
@testable import BBUI

/// Hosts the book editor (split view, format bar, inspector) in a real window, as `BookWindow`
/// does, and lets AppKit run its layout and update-constraints passes. When the split view's
/// columns can't fit (a rigid format bar wider than the detail column, or a window narrower than
/// the editor's minimum), AppKit raises "more Update Constraints in Window passes than there are
/// views in the window", which aborts this test process, so CI catches it (Phase 4 crash on
/// opening a book).
@MainActor
struct BookEditorLayoutTests {
    @Test func bookEditorSettlesInAWindow() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suiteName = "bbui-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = AppModel(providers: [:], libraryRoot: dir.appending(path: "Library", directoryHint: .isDirectory),
                           keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                           thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")))
        let content = Fixtures.book()
        let url = dir.appending(path: "Editor.bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url))

        // The size a new book window opens at, and the smallest the window allows.
        for width in [900, BookWindow.minimumWidth] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 572),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: BookEditor(document: document)
                .frame(minWidth: BookWindow.minimumWidth, minHeight: 520)
                .environment(app))
            window.contentViewController = controller
            window.toolbar = NSToolbar()
            window.setContentSize(NSSize(width: width, height: 572))
            window.orderFront(nil)
            for _ in 0..<10 {
                window.layoutIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            // The window minimum covers what the editor needs (the format bar adds nothing).
            #expect(controller.view.fittingSize.width <= BookWindow.minimumWidth)
            #expect(window.isVisible)
            window.close()
        }
    }
}
