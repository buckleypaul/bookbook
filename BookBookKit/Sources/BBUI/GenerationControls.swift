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
    /// The user already confirmed the cost, and the notice became needed after that (the book
    /// changed while the alert was up), so continuing on the notice goes straight to the request.
    var costConfirmed = false

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
///
/// The notice is checked again right before `perform`, because the book can change while the
/// cost alert is up (e.g. a real-person reference photo is set, A §11): the flow then shows the
/// notice instead of performing, and continuing on it performs the same action. The enqueue
/// paths still refuse an unacknowledged photo on their own.
@MainActor
struct GenerationConfirmFlow<Action: Sendable> {
    let app: AppModel
    let document: BookDocument
    let pending: Binding<PendingConfirmation<Action>?>
    /// The provider whose real-person notice `action` needs first; nil = none.
    let notice: @MainActor (Action) -> ProviderID?
    /// The estimate the cost decision is made on.
    let estimate: @MainActor (Action) -> CostEstimate
    let perform: @MainActor (Action) -> Void

    /// The notice first when one is needed, then the cost decision.
    func start(_ action: Action) {
        proceed(action, costConfirmed: false)
    }

    /// The "Confirm Cost" button: performs `confirmation`'s action unless the notice became
    /// needed meanwhile, in which case the notice is shown instead.
    func confirmCost(_ confirmation: PendingConfirmation<Action>) {
        if pending.wrappedValue?.id == confirmation.id { pending.wrappedValue = nil }
        proceed(confirmation.action, costConfirmed: true)
    }

    /// Continue on the notice: records the acknowledgement, then the cost decision (or the
    /// action itself when its cost was already confirmed).
    func acknowledge(_ confirmation: PendingConfirmation<Action>) {
        guard let provider = confirmation.noticeProvider else { return }
        if pending.wrappedValue?.id == confirmation.id { pending.wrappedValue = nil }
        app.acknowledgeRealPersonNotice(provider, in: document)
        proceed(confirmation.action, costConfirmed: confirmation.costConfirmed)
    }

    /// The next step for `action`: the notice when it's needed now, else the action when its cost
    /// is settled, else the cost decision.
    func proceed(_ action: Action, costConfirmed: Bool) {
        if let provider = notice(action) {
            pending.wrappedValue = PendingConfirmation(action: action, step: .notice(provider),
                                                       costConfirmed: costConfirmed)
        } else if costConfirmed {
            perform(action)
        } else {
            confirmCostThenPerform(action)
        }
    }

    private func confirmCostThenPerform(_ action: Action) {
        let current = estimate(action)
        let flow = self
        Task {
            if let text = await flow.app.costAlertText(for: current, in: flow.document) {
                flow.pending.wrappedValue = PendingConfirmation(action: action, step: .cost(text))
            } else {
                // No alert: the cost is settled, but the book may have changed during the read.
                flow.proceed(action, costConfirmed: true)
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
                                          onContinue: { flow.acknowledge(notice) },
                                          onCancel: { pending.wrappedValue = nil })
                }
            }
            .alert("Confirm Cost",
                   isPresented: Binding(get: { pending.wrappedValue?.costMessage != nil },
                                        set: { if !$0, pending.wrappedValue?.costMessage != nil {
                                            pending.wrappedValue = nil
                                        } }),
                   presenting: pending.wrappedValue) { confirmation in
                Button(buttonTitle(confirmation.action)) { flow.confirmCost(confirmation) }
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
