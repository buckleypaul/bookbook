import SwiftUI

/// The Queue window (A §6.1). Stub.
public struct QueueView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Queue Is Empty",
            systemImage: "tray",
            description: Text("Image generation jobs will appear here.")
        )
        .frame(minWidth: 360, minHeight: 240)
    }
}
