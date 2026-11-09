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
            .alert("Generate Whole Sheet?", isPresented: $showConfirm) {
                Button("Generate") {
                    if let plan { app.enqueueSheetBatch(plan, in: document) }
                    plan = nil
                }
                Button("Cancel", role: .cancel) { plan = nil }
            } message: {
                Text(message)
            }
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
