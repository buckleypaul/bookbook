import BBAI
import BBAICore
import BBModel
import SwiftUI

/// The estimate capsule next to Generate and Send (PD §5).
struct CostEstimatePill: View {
    let estimate: CostEstimate

    var body: some View {
        Text(CostText.estimate(estimate))
            .font(Crayon.font(.caption, weight: .bold))
            .foregroundStyle(Crayon.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Crayon.grass.opacity(0.18), in: Capsule())
            .accessibilityLabel("Estimated cost: \(CostText.estimate(estimate))")
    }
}

/// The Quality menu of a generation composer.
struct QualityPicker: View {
    @Binding var selection: QualityLevel

    var body: some View {
        Picker("Quality", selection: $selection) {
            ForEach(QualityLevel.allCases, id: \.self) {
                Text(VersionDetailsContent.qualityName($0)).tag($0)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// What stops Generate working until Settings changes: the default model missing from the
/// account, or no OpenAI key.
struct GenerationSetupNotes: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.missingDefaultModel != nil {
            HStack(spacing: 4) {
                Text("The default model isn't available to your account.").foregroundStyle(Crayon.ink)
                SettingsLink { Text("Pick another in Settings…") }.buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Crayon.sunflower.opacity(0.2), in: Capsule())
        }
        if !app.hasOpenAIKey {
            HStack(spacing: 4) {
                Text("Add your OpenAI key in Settings ▸ API Keys to generate.")
                SettingsLink { Text("Open Settings…") }.buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(Crayon.inkSoft)
        }
    }
}

/// A generation waiting on the real-person notice or on the cost confirmation.
struct PendingConfirmation<Action: Sendable>: Identifiable, Sendable {
    enum Step: Sendable {
        /// The real-person notice for this provider (once per provider and book, A §11).
        case notice(ProviderID)
        /// The "Confirm Cost" alert with this text (A §7.10).
        case cost(String)
    }

    let id = UUID()
    var action: Action
    var step: Step

    var noticeProvider: ProviderID? {
        if case let .notice(provider) = step { provider } else { nil }
    }

    var costMessage: String? {
        if case let .cost(text) = step { text } else { nil }
    }
}

/// Runs a generation through the real-person notice (when one is needed), then the cost
/// decision: a confirmation or budget warning is shown but never blocks (A §7.10). The state is
/// the one `pending` optional; `generationConfirmation(_:buttonTitle:)` presents it.
@MainActor
struct GenerationConfirmFlow<Action: Sendable> {
    let app: AppModel
    let document: BookDocument
    let pending: Binding<PendingConfirmation<Action>?>
    /// The estimate the cost decision is made on.
    let estimate: @MainActor (Action) -> CostEstimate
    let perform: @MainActor (Action) -> Void

    /// Shows the notice for `provider` first when there is one, else goes straight to the cost.
    func start(_ action: Action, notice provider: ProviderID?) {
        if let provider {
            pending.wrappedValue = PendingConfirmation(action: action, step: .notice(provider))
        } else {
            confirmCostThenPerform(action)
        }
    }

    /// Continue on the notice: records the acknowledgement, then the cost decision.
    func acknowledge(_ provider: ProviderID, then action: Action) {
        app.acknowledgeRealPersonNotice(provider, in: document)
        confirmCostThenPerform(action)
    }

    func confirmCostThenPerform(_ action: Action) {
        let current = estimate(action)
        let app = app, document = document, pending = pending, perform = perform
        Task {
            if let text = await app.costAlertText(for: current, in: document) {
                pending.wrappedValue = PendingConfirmation(action: action, step: .cost(text))
            } else {
                perform(action)
            }
        }
    }
}

private struct GenerationConfirmModifier<Action: Sendable>: ViewModifier {
    let flow: GenerationConfirmFlow<Action>
    let buttonTitle: (Action) -> String

    func body(content: Content) -> some View {
        let pending = flow.pending
        content
            .sheet(item: Binding(get: { pending.wrappedValue?.noticeProvider == nil ? nil : pending.wrappedValue },
                                 set: { if $0 == nil, pending.wrappedValue?.noticeProvider != nil {
                                     pending.wrappedValue = nil
                                 } })) { notice in
                if let provider = notice.noticeProvider {
                    RealPersonNoticeSheet(provider: provider,
                                          onContinue: {
                                              pending.wrappedValue = nil
                                              flow.acknowledge(provider, then: notice.action)
                                          },
                                          onCancel: { pending.wrappedValue = nil })
                }
            }
            .alert("Confirm Cost",
                   isPresented: Binding(get: { pending.wrappedValue?.costMessage != nil },
                                        set: { if !$0, pending.wrappedValue?.costMessage != nil {
                                            pending.wrappedValue = nil
                                        } }),
                   presenting: pending.wrappedValue) { confirmation in
                Button(buttonTitle(confirmation.action)) {
                    flow.perform(confirmation.action)
                    if pending.wrappedValue?.id == confirmation.id { pending.wrappedValue = nil }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
            } message: { confirmation in
                Text(confirmation.costMessage ?? "")
            }
    }
}

extension View {
    /// The real-person notice sheet and the "Confirm Cost" alert for `flow`.
    func generationConfirmation<Action: Sendable>(_ flow: GenerationConfirmFlow<Action>,
                                                  buttonTitle: @escaping (Action) -> String) -> some View {
        modifier(GenerationConfirmModifier(flow: flow, buttonTitle: buttonTitle))
    }

    /// "Couldn't Complete That" with `problem` as the message.
    func problemAlert(_ problem: Binding<String?>) -> some View {
        alert("Couldn't Complete That", isPresented: problem.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem.wrappedValue ?? "")
        }
    }
}
