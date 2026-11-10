import BBAI
import SwiftUI

/// The sidebar's bottom badge: how many requests are queued app-wide, and the running one's
/// elapsed time. Click opens the Queue window. Hidden when the queue is empty.
struct QueueBadge: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = QueueBadgeModel(snapshot: app.queueSnapshot)
        if !model.isHidden {
            Button { openWindow(id: SceneID.queue) } label: {
                HStack(spacing: 8) {
                    if app.queueSnapshot.pause == nil {
                        ProgressView().controlSize(.mini)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Crayon.sky.opacity(0.2)))
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Crayon.sunflower))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.title).font(Crayon.font(.caption, weight: .bold)).foregroundStyle(Crayon.ink)
                        if let running = model.running, case let .running(startedAt, _, _) = running.state {
                            let typical = app.typicalDuration(for: running.item)
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                Text(ElapsedTimeText.progress(elapsed: context.date.timeIntervalSince(startedAt),
                                                              typical: typical))
                                    .font(Crayon.font(.caption2, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(Crayon.inkSoft)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .crayonCard(cornerRadius: Crayon.smallCornerRadius + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .crayonHover(tilt: -1, scale: 1.02)
            .help("Open the queue")
            .accessibilityLabel("\(model.title). Open the queue")
        }
    }
}
