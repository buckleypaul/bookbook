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
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(commit)
                }
                if invalid {
                    CrayonInlineMessage("Enter an amount such as 0.50.", kind: .error)
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
        .onAppear { thresholdText = Self.money(app.preferences.confirmThreshold) }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onDisappear { commit() }
    }

    private var invalid: Bool { CostText.parse(thresholdText) == .invalid }

    private func commit() {
        switch CostText.parse(thresholdText) {
        case let .value(v): app.preferences.confirmThreshold = v
        case .empty, .invalid: thresholdText = Self.money(app.preferences.confirmThreshold)
        }
        if case .value = CostText.parse(thresholdText) { thresholdText = Self.money(app.preferences.confirmThreshold) }
    }

    /// The editable amount with at least two decimal places ("0.50"), keeping any extra precision.
    static func money(_ value: Decimal) -> String {
        let plain = CostText.field(value)
        let places = plain.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        if places >= 2 { return plain }
        return plain + (places == 0 ? "." : "") + String(repeating: "0", count: 2 - places)
    }
}
