import BBAI
import SwiftUI

/// The paused-queue banner (restored at launch, offline, or paused by the user). Shown in the
/// Queue window and, for a restored queue, in the Library window.
struct QueueResumeBanner: View {
    @Environment(AppModel.self) private var app
    let pause: QueuePause?

    var body: some View {
        if let model = QueueBannerModel(pause: pause) {
            HStack(spacing: 8) {
                Image(systemName: pause == .offline ? "wifi.slash" : "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text(model.text).font(.callout)
                Spacer()
                if model.offersResume {
                    Button("Resume") { app.resumeQueue() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(10)
            .background(.quaternary)
            .accessibilityElement(children: .combine)
        }
    }
}
