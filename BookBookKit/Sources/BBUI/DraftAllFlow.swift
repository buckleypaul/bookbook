import BBAI
import BBModel
import SwiftUI

/// Draft All Empty Boxes (PD §8.5): plan, always confirm with count and cost, show the
/// real-person notice if needed, then enqueue.
private struct DraftAllFlow: ViewModifier {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    @Binding var trigger: Bool
    @State private var proposal: Proposal?
    @State private var showConfirm = false
    @State private var showNothing = false
    @State private var notice: ProviderID?

    /// A planned batch ready to confirm, with its alert text.
    private struct Proposal {
        var plan: DraftAllPlan
        var message: String
    }

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
            .sheet(isPresented: $notice.isPresent(), onDismiss: { if notice == nil { proposal = nil } }) {
                if let provider = notice {
                    RealPersonNoticeSheet(provider: provider,
                                          onContinue: {
                                              notice = nil
                                              app.acknowledgeRealPersonNotice(provider, in: document)
                                              checkNoticeThenEnqueue()
                                          },
                                          onCancel: { notice = nil; proposal = nil })
                }
            }
            .alert("Draft All Empty Boxes?", isPresented: $showConfirm) {
                Button("Draft All") {
                    checkNoticeThenEnqueue()
                }
                Button("Cancel", role: .cancel) { proposal = nil }
            } message: {
                Text(proposal?.message ?? "")
            }
    }

    /// The real-person notice (once per provider and book, A §11) comes after the cost
    /// confirmation and before anything is queued.
    private func checkNoticeThenEnqueue() {
        guard let proposal else { return }
        if let provider = app.realPersonNoticeNeeded(for: proposal.plan.items, in: document) {
            notice = provider
            return
        }
        _ = app.enqueueDraftAll(proposal.plan, in: document)
        self.proposal = nil
    }

    /// Plans the batch and its confirmation text (count, cost, budget and the confirmation
    /// limit), or says there's nothing to draft.
    private func start() async {
        let plan = app.draftAllPlan(in: document)
        guard !plan.items.isEmpty else {
            showNothing = true
            return
        }
        let coverIncluded = plan.targets.contains { $0.page == document.content.book.coverPageID }
        let (decision, spent) = await app.costDecisionAndSpent(for: plan.estimate, in: document)
        let message = CostText.batchAlert(count: plan.items.count, estimate: plan.estimate, decision: decision,
                                          spent: spent, budget: document.content.book.budget,
                                          coverIncluded: coverIncluded)
            + (decision.needsConfirmation ? " That is above your confirmation limit." : "")
            + " Draft quality, queued one after another."
        proposal = Proposal(plan: plan, message: message)
        showConfirm = true
    }
}

extension View {
    /// Draft All Empty Boxes… (PD §8.5).
    func draftAllFlow(document: BookDocument, trigger: Binding<Bool>) -> some View {
        modifier(DraftAllFlow(document: document, trigger: trigger))
    }
}
