import BBModel
import SwiftUI

/// Generate whole sheet (PD §8.3): the estimate is always shown first, like Draft all.
struct SheetBatchFlow: ViewModifier {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    @Binding var trigger: AssetID?
    @State private var plan: SheetBatchPlan?
    @State private var message = ""
    @State private var showConfirm = false
    @State private var showNothing = false
    @State private var notice: ProviderID?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, requested in
                guard let requested else { return }
                trigger = nil
                Task { await start(requested) }
            }
            .alert("Nothing to Generate", isPresented: $showNothing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every item on this sheet is locked or already being generated.")
            }
            .sheet(isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
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
            .alert("Generate Whole Sheet?", isPresented: $showConfirm) {
                Button("Generate") {
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
        app.enqueueSheetBatch(plan, in: document)
        self.plan = nil
    }

    private func start(_ asset: AssetID) async {
        let plan = app.sheetBatchPlan(asset: asset, in: document)
        guard plan.count > 0 else {
            showNothing = true
            return
        }
        let decision = await app.costDecision(for: plan.estimate, in: document)
        let spent = await app.ledgerSummary(for: document.id).total
        message = CostText.batchAlert(count: plan.count, estimate: plan.estimate, decision: decision, spent: spent,
                                      budget: document.content.book.budget)
            + (decision.needsConfirmation ? " That is above your confirmation limit." : "")
            + " Locked items are skipped. Queued one after another."
        self.plan = plan
        showConfirm = true
    }
}

extension View {
    func sheetBatchFlow(document: BookDocument, trigger: Binding<AssetID?>) -> some View {
        modifier(SheetBatchFlow(document: document, trigger: trigger))
    }
}
