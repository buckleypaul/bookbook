import BBModel
import BBUI
import SwiftUI

@main
struct BookBookApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
                .environment(model)
        }

        WindowGroup(for: BookID.self) { $bookID in
            if let bookID {
                BookWindow(bookID: bookID)
                    .environment(model)
            }
        }

        Window("Queue", id: "queue") {
            QueueView()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
