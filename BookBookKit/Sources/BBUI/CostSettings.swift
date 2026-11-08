import BBAI
import SwiftUI

/// Settings ▸ Cost: the confirmation threshold and the price list (PD §5, §8.11).
struct CostSettings: View {
    @Environment(AppModel.self) private var app
    @State private var thresholdText = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Ask before spending more than $")
                    TextField("Amount", text: $thresholdText, prompt: Text("0.50"))
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(commit)
                }
                if invalid {
                    Text("Enter an amount such as 0.50.").font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Confirmation")
            } footer: {
                Text("A request, or Draft All Empty Boxes, estimated above this amount asks you first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { PriceListEditor() }
        }
        .formStyle(.grouped)
        .onAppear { thresholdText = CostText.field(app.preferences.confirmThreshold) }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onDisappear { commit() }
    }

    private var invalid: Bool { CostText.parse(thresholdText) == .invalid }

    private func commit() {
        switch CostText.parse(thresholdText) {
        case let .value(v): app.preferences.confirmThreshold = v
        case .empty, .invalid: thresholdText = CostText.field(app.preferences.confirmThreshold)
        }
    }
}
