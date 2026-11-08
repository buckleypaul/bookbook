import AppKit
import BBModel
import BBUI
import SwiftUI

@main
struct BookBookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model

        Window("Library", id: SceneID.library) {
            LibraryView()
                .environment(model)
        }
        .commands { BookBookCommands(app: model) }

        WindowGroup(for: BookID.self) { $bookID in
            if let bookID {
                BookWindow(bookID: bookID)
                    .environment(model)
            }
        }

        Window("Queue", id: SceneID.queue) {
            QueueView()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Owns the app model and flushes open books on hide and quit (A §5.3).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppWiring.makeModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = model
        Task {
            await model.flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidHide(_ notification: Notification) {
        let model = model
        Task { await model.flushAll() }
    }
}
