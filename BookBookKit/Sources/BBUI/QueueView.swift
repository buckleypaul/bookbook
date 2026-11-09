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
                Text(QueueRowModel.stateText(entry.state, now: context.date, typical: typical, headline: nil))
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

/// Draft All Empty Boxes… (PD §8.5): plan, always confirm with count and cost, then enqueue.
struct DraftAllFlow: ViewModifier {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    @Binding var trigger: Bool
    @State private var plan: DraftAllPlan?
    @State private var message = ""
    @State private var showConfirm = false
    @State private var showNothing = false
    @State private var notice: ProviderID?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, requested in
                guard requested else { return }
                trigger = false
                Task { await start() }
            }
            .alert("Nothing to Draft", isPresented: $showNothing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every image box already has a picture.")
            }
            .sheet(isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                   onDismiss: { if notice == nil { plan = nil } }) {
                if let provider = notice {
                    RealPersonNoticeSheet(provider: provider,
                                          onContinue: {
                                              notice = nil
                                              app.acknowledgeRealPersonNotice(provider, in: document)
                                              checkNoticeThenEnqueue()
                                          },
                                          onCancel: { notice = nil; plan = nil })
                }
            }
            .alert("Draft All Empty Boxes?", isPresented: $showConfirm) {
                Button("Draft All") {
                    checkNoticeThenEnqueue()
                }
                Button("Cancel", role: .cancel) { plan = nil }
            } message: {
                Text(message)
            }
    }

    /// The real-person notice (once per provider and book, A §11) comes after the cost
    /// confirmation and before anything is queued.
    private func checkNoticeThenEnqueue() {
        guard let plan else { return }
        if let provider = app.realPersonNoticeNeeded(for: plan.items, in: document) {
            notice = provider
            return
        }
        app.enqueueDraftAll(plan, in: document)
        self.plan = nil
    }

    private func start() async {
        let plan = app.draftAllPlan(in: document)
        guard plan.count > 0 else {
            showNothing = true
            return
        }
        let decision = await app.costDecision(for: plan.estimate, in: document)
        let spent = await app.ledgerSummary(for: document.id).total
        message = CostText.batchAlert(count: plan.count, estimate: plan.estimate, decision: decision, spent: spent,
                                      budget: document.content.book.budget)
            + (decision.needsConfirmation ? " That is above your confirmation limit." : "")
            + " Draft quality, queued one after another."
        self.plan = plan
        showConfirm = true
    }
}

extension View {
    func draftAllFlow(document: BookDocument, trigger: Binding<Bool>) -> some View {
        modifier(DraftAllFlow(document: document, trigger: trigger))
    }
}
