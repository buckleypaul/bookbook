import SwiftUI

/// The Library window (A §6.1). Stub: shows the empty state.
public struct LibraryView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "No Books Yet",
            systemImage: "books.vertical",
            description: Text("Your books will appear here.")
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}
