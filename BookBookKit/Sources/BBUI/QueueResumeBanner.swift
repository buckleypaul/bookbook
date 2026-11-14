import BBAI
import SwiftUI

/// The paused-queue banner (restored at launch, offline, or paused by the user). Shown in the
/// Queue window and, for a restored queue, in the Library window.
struct QueueResumeBanner: View {
    @Environment(AppModel.self) private var app
    let pause: QueuePause?

    var body: some View {
        if let model = QueueBannerModel(pause: pause) {
            let color = pause == .offline ? Crayon.grape : Crayon.sky
            CrayonBanner(model.text, systemImage: pause == .offline ? "wifi.slash" : "pause.fill", color: color) {
                if model.offersResume {
                    Button("Resume") { app.resumeQueue() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.crayon(color))
                }
            }
            // Keeps this banner's original 8 pt vertical inset (CrayonBanner's is 6) and its paper strip.
            .padding(.vertical, 2)
            .background(Crayon.paper)
        }
    }
}
