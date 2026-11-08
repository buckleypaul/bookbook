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
        // Wide enough that the format bar fits beside the sidebar and session panel (~1130 pt).
        .defaultSize(width: 1200, height: 780)

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

/// Owns the app model and flushes open books on hide and quit (A §5.3). At quit it marks the app
/// as terminating first, so the open-books list survives the windows closing (A §6.1).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppWiring.makeModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = model
        model.beginTermination()
        Task {
            await model.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidHide(_ notification: Notification) {
        let model = model
        Task { await model.flushAll() }
    }
}
