import BBAI
import BBAICore
import BBModel
import SwiftUI

/// "New with AI…" (PD §8.4): describe a layout, see the cost, send, and open the result in the
/// visual editor. All logic is in `TemplateGenerationFlow`.
struct TemplateGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: TemplateGenerationFlow
    @State private var estimate: CostEstimate?
    @State private var task: Task<Void, Never>?

    init(app: AppModel, document: BookDocument, editor: TemplateEditorModel) {
        _flow = State(initialValue: TemplateGenerationFlow(app: app, document: document, editor: editor))
    }

    var body: some View {
        @Bindable var flow = flow
        VStack(alignment: .leading, spacing: 12) {
            Text("New Layout with AI").font(.headline)
            TextField("Describe the layout", text: $flow.description,
                      prompt: Text("Big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box"),
                      axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .disabled(flow.isRunning)
            Picker("Page", selection: $flow.kind) {
                Text("Single page").tag(TemplateKind.single)
                Text("Two-page spread").tag(TemplateKind.spread)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(flow.isRunning)

            Group {
                if let model = flow.model {
                    Text("Model: \(model.displayName)")
                } else {
                    Text("No layout model is set. Choose one in Settings.")
                }
                Text(costText).help("An estimate; the actual cost is recorded in the book's cost ledger.")
            }
            .font(.caption).foregroundStyle(.secondary)

            stateView
            sentView

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: flow.description) { refreshEstimate() }
        .onChange(of: flow.kind) { refreshEstimate() }
        .onChange(of: flow.state) { _, state in if case .finished = state { dismiss() } }
        .onDisappear { task?.cancel() }
    }

    private var costText: String {
        guard !flow.trimmedDescription.isEmpty else { return "Cost: enter a description to see an estimate." }
        guard let amount = estimate?.amount else { return "Cost: unknown for this model." }
        return "Estimated cost: about \(CostText.amount(amount))"
    }

    @ViewBuilder private var stateView: some View {
        switch flow.state {
        case .running:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Designing the layout…") }
        case let .confirming(estimate, overBudget):
            VStack(alignment: .leading, spacing: 4) {
                Text(estimate.amount.map { "This will cost about \(CostText.amount($0)). Send it?" }
                     ?? "The cost of this request is unknown. Send it?")
                if overBudget { Text("This book is already over its budget.").foregroundStyle(.orange) }
            }
            .font(.callout)
        case let .failed(advice):
            FailureAdviceView(advice: advice)
        case .idle, .finished:
            EmptyView()
        }
    }

    @ViewBuilder private var sentView: some View {
        if let sent = flow.sent {
            DisclosureGroup("What was sent") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model: \(sent.model)")
                        ForEach(sent.parametersSent.sorted(by: { $0.key < $1.key }), id: \.key) {
                            Text("\($0.key): \($0.value)")
                        }
                        Text("System").bold()
                        Text(sent.system)
                        Text("Request").bold()
                        Text(sent.user)
                    }
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch flow.state {
        case .running:
            Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        case .confirming:
            Button("Back") { flow.cancelConfirmation() }.keyboardShortcut(.cancelAction)
            Button("Send") { start(confirmed: true) }.keyboardShortcut(.defaultAction)
        case .idle, .failed, .finished:
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(flow.state == .idle ? "Generate" : "Try Again") { start(confirmed: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(flow.trimmedDescription.isEmpty || flow.model == nil)
        }
    }

    private func start(confirmed: Bool) {
        task = Task { await flow.generate(confirmed: confirmed) }
    }

    private func refreshEstimate() {
        estimate = flow.estimate()
        flow.reset()
    }
}
