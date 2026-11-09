import BBAI
import BBAICore
import BBModel
import SwiftUI

/// The Queue window (A §6.1, PD §5): every request across all books, with Pause/Resume,
/// reorder, Remove, Retry and Cancel.
public struct QueueView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmCancel = false

    public init() {}

    public var body: some View {
        let snapshot = app.queueSnapshot
        VStack(spacing: 0) {
            QueueResumeBanner(pause: snapshot.pause)
            if snapshot.entries.isEmpty {
                ContentUnavailableView(
                    "Queue Is Empty",
                    systemImage: "tray",
                    description: Text("Image generation jobs will appear here.")
                )
            } else {
                List {
                    ForEach(snapshot.entries) { entry in
                        QueueRowView(entry: entry, onCancel: { confirmCancel = true })
                            .moveDisabled(!QueueRowModel(entry: entry).canReorder)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let entries = snapshot.entries
                        guard entries.indices.contains(from) else { return }
                        app.moveQueueItem(entries[from].id, to: destination > from ? destination - 1 : destination)
                    }
                }
            }
            if let text = snapshot.undeliveredText {
                Divider()
                Label(text, systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem {
                if snapshot.pause == nil {
                    Button { app.pauseQueue() } label: { Label("Pause", systemImage: "pause") }
                        .help("Pause the queue after the current request")
                } else {
                    Button { app.resumeQueue() } label: { Label("Resume", systemImage: "play") }
                        .help("Resume the queue")
                        .disabled(!(QueueBannerModel(pause: snapshot.pause)?.offersResume ?? false))
                }
            }
        }
        .confirmationDialog("Cancel the running request?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Request", role: .destructive) { app.cancelRunningItem() }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text(QueueView.cancelNotice)
        }
    }

    /// Shown wherever a running request can be cancelled (PD §5).
    public static let cancelNotice = "The provider may still charge for a request cancelled partway through. "
        + "The estimated cost will be added to the book's total."
}

struct QueueRowView: View {
    @Environment(AppModel.self) private var app
    let entry: QueueEntry
    let onCancel: () -> Void

    var body: some View {
        let model = QueueRowModel(entry: entry)
        let advice: FailureAdvice? = model.isFailed ? app.advice(for: entry) : nil
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.headline)
                Text(model.location + (model.location.isEmpty ? "" : " · ") + model.estimateText)
                    .font(.caption).foregroundStyle(.secondary)
                stateLine(advice: advice)
                if let advice { FailureAdviceView(advice: advice).padding(.top, 2) }
            }
            Spacer()
            actions(model)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func stateLine(advice: FailureAdvice?) -> some View {
        let intent = entry.item.intent
        // Consistency checks (labelled "· Consistency check" through `display`) time against the vision model.
        let typical = entry.item.kind == .image
            ? app.catalog.imageModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds[intent.quality]
            : app.catalog.textModel(provider: intent.provider, id: intent.model)?.typicalDurationSeconds
        switch entry.state {
        case .running, .retrying:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(QueueRowModel.stateText(entry.state, now: context.date, typical: typical, headline: nil,
                                                  isConsistencyCheck: entry.item.kind != .image))
                    .font(.caption).monospacedDigit()
            }
        case .waiting:
            Text("Waiting").font(.caption)
        case .failed:
            if advice == nil { Text("Failed").font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private func actions(_ model: QueueRowModel) -> some View {
        HStack {
            if model.actions.contains(.retry) {
                Button("Retry") { app.retryQueueItem(entry.id) }
            }
            if model.actions.contains(.cancel) {
                Button("Cancel", action: onCancel)
            }
            if model.actions.contains(.remove) {
                Button("Remove", role: .destructive) { app.removeQueueItem(entry.id) }
            }
        }
        .controlSize(.small)
    }
}
