import BBModel
import SwiftUI

/// A book window (A §6.1). Stub.
public struct BookWindow: View {
    private let bookID: BookID

    public init(bookID: BookID) {
        self.bookID = bookID
    }

    public var body: some View {
        ContentUnavailableView(
            "Book",
            systemImage: "book",
            description: Text(bookID.rawValue.uuidString)
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}
