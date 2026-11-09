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
                HStack(spacing: 6) {
                    if app.queueSnapshot.pause == nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "pause.circle") }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.title).font(.caption.weight(.medium))
                        if let running = model.running, case let .running(startedAt, _, _) = running.state {
                            let typical = app.typicalDuration(for: running.item)
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                Text(ElapsedTimeText.progress(elapsed: context.date.timeIntervalSince(startedAt),
                                                              typical: typical))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the queue")
            .accessibilityLabel("\(model.title). Open the queue")
        }
    }
}
