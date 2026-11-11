import BBAI
import BBModel
import SwiftUI

/// A planned batch ready to confirm: its queue items, the alert text, and how to enqueue it.
struct BatchProposal {
    var items: [QueueItem]
    var message: String
    var enqueue: @MainActor () -> Void

    /// The confirmation text for `items` (count, cost, budget and the confirmation limit), then
    /// `suffix`. Nil when there's nothing to queue.
    @MainActor
    static func make(items: [QueueItem], estimate: CostEstimate, coverIncluded: Bool = false,
                     app: AppModel, document: BookDocument, suffix: @MainActor () -> String,
                     enqueue: @escaping @MainActor () -> Void) async -> BatchProposal? {
        guard !items.isEmpty else { return nil }
        let (decision, spent) = await app.costDecisionAndSpent(for: estimate, in: document)
        let message = CostText.batchAlert(count: items.count, estimate: estimate, decision: decision, spent: spent,
                                          budget: document.content.book.budget, coverIncluded: coverIncluded)
            + (decision.needsConfirmation ? " That is above your confirmation limit." : "")
            + suffix()
        return BatchProposal(items: items, message: message, enqueue: enqueue)
    }
}

/// Draft All Empty Boxes (PD §8.5): plan, always confirm
/// with count and cost, show the real-person notice if needed, then enqueue.
struct BatchConfirmFlow<Trigger: Equatable>: ViewModifier {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    @Binding var trigger: Trigger
    /// The trigger's resting value; any other value starts the flow.
    let idle: Trigger
    let title: String
    let confirmLabel: String
    let nothingTitle: String
    let nothingMessage: String
    /// Plans the batch for a request; nil when there is nothing to queue.
    let propose: @MainActor (AppModel, Trigger) async -> BatchProposal?
    @State private var plan: BatchProposal?
    @State private var showConfirm = false
    @State private var showNothing = false
    @State private var notice: ProviderID?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, requested in
                guard requested != idle else { return }
                trigger = idle
                Task { await start(requested) }
            }
            .alert(nothingTitle, isPresented: $showNothing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(nothingMessage)
            }
            .sheet(isPresented: $notice.isPresent(), onDismiss: { if notice == nil { plan = nil } }) {
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
            .alert(title, isPresented: $showConfirm) {
                Button(confirmLabel) {
                    checkNoticeThenEnqueue()
                }
                Button("Cancel", role: .cancel) { plan = nil }
            } message: {
                Text(plan?.message ?? "")
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
        plan.enqueue()
        self.plan = nil
    }

    private func start(_ request: Trigger) async {
        guard let proposal = await propose(app, request) else {
            showNothing = true
            return
        }
        plan = proposal
        showConfirm = true
    }
}

extension View {
    /// Draft All Empty Boxes… (PD §8.5).
    func draftAllFlow(document: BookDocument, trigger: Binding<Bool>) -> some View {
        modifier(BatchConfirmFlow(document: document, trigger: trigger, idle: false,
                                  title: "Draft All Empty Boxes?", confirmLabel: "Draft All",
                                  nothingTitle: "Nothing to Draft",
                                  nothingMessage: "Every image box already has a picture.") { app, _ in
            let plan = app.draftAllPlan(in: document)
            return await BatchProposal.make(
                items: plan.items, estimate: plan.estimate,
                coverIncluded: plan.targets.contains { $0.page == document.content.book.coverPageID },
                app: app, document: document, suffix: { " Draft quality, queued one after another." },
                enqueue: { _ = app.enqueueDraftAll(plan, in: document) })
        })
    }
}
