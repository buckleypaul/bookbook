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
                CrayonEmptyState("Queue Is Empty", systemImage: "tray", color: Crayon.sky,
                                 message: "Image generation jobs will appear here.")
            } else {
                List {
                    ForEach(snapshot.entries) { entry in
                        QueueRowView(entry: entry, onCancel: { confirmCancel = true })
                            .crayonCard(cornerRadius: Crayon.cornerRadius, padding: 12)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .moveDisabled(!QueueRowModel(entry: entry).canReorder)
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let entries = snapshot.entries
                        guard entries.indices.contains(from) else { return }
                        app.moveQueueItem(entries[from].id, to: destination > from ? destination - 1 : destination)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            if let text = snapshot.undeliveredText {
                Rectangle().fill(Crayon.ink.opacity(0.08)).frame(height: 1)
                Label(text, systemImage: "lock")
                    .font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.inkSoft)
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
            Circle()
                .fill(stateColor)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(Crayon.font(.headline, weight: .bold)).foregroundStyle(Crayon.ink)
                Text(model.location + (model.location.isEmpty ? "" : " · ") + model.estimateText)
                    .font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                stateLine(advice: advice)
                if let advice { FailureAdviceView(advice: advice).padding(.top, 2) }
            }
            Spacer()
            actions(model)
        }
        .accessibilityElement(children: .contain)
    }

    /// The row's crayon: grape waiting, sky running, sunflower retrying, tomato failed.
    private var stateColor: Color {
        switch entry.state {
        case .waiting: Crayon.grape
        case .running: Crayon.sky
        case .retrying: Crayon.sunflower
        case .failed: Crayon.tomato
        }
    }

    @ViewBuilder
    private func stateLine(advice: FailureAdvice?) -> some View {
        let typical = app.typicalDuration(for: entry.item)
        switch entry.state {
        case .running, .retrying:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(QueueRowModel.stateText(entry.state, now: context.date, typical: typical, headline: nil,
                                                  isConsistencyCheck: entry.item.kind != .image))
                    .font(Crayon.font(.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Crayon.ink)
            }
        case .waiting:
            Text("Waiting").font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.ink)
        case .failed:
            if advice == nil { Text("Failed").font(Crayon.font(.caption, weight: .bold)).foregroundStyle(Crayon.tomato) }
        }
    }

    @ViewBuilder
    private func actions(_ model: QueueRowModel) -> some View {
        HStack {
            if model.actions.contains(.retry) {
                Button("Retry") { app.retryQueueItem(entry.id) }
                    .buttonStyle(.borderedProminent)
                    .tint(Crayon.grass)
            }
            if model.actions.contains(.cancel) {
                Button("Cancel", action: onCancel)
            }
            if model.actions.contains(.remove) {
                Button("Remove", role: .destructive) { app.removeQueueItem(entry.id) }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .font(Crayon.font(.callout, weight: .semibold))
        .controlSize(.small)
    }
}
