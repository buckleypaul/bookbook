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
            HStack(spacing: 10) {
                Image(systemName: pause == .offline ? "wifi.slash" : "pause.fill")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(color))
                    .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
                Text(model.text)
                    .font(Crayon.font(.callout, weight: .semibold))
                    .foregroundStyle(Crayon.ink)
                Spacer()
                if model.offersResume {
                    Button("Resume") { app.resumeQueue() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.crayon(color))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(BannerFill(color: color))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Crayon.paper)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A soft coloured fill on a card, with a coloured rim and the chunky shadow.
private struct BannerFill: View {
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
        shape.fill(Crayon.card)
            .overlay(shape.fill(color.opacity(0.16)))
            .overlay(shape.strokeBorder(color.opacity(0.55), lineWidth: 1.5))
            .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
    }
}
