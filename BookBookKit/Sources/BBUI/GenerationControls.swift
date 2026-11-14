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
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Crayon.grass.opacity(0.18), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Estimated cost: \(CostText.estimate(estimate))")
    }
}

/// The Quality menu of a generation composer. `showsLabel: false` hides the "Quality" label
/// where the row is narrow (VoiceOver and the tooltip still say it).
struct QualityPicker: View {
    @Binding var selection: QualityLevel
    var showsLabel = true

    var body: some View {
        Picker("Quality", selection: $selection) {
            ForEach(QualityLevel.allCases, id: \.self) {
                Text(VersionDetailsContent.qualityName($0)).tag($0)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden(!showsLabel)
        .fixedSize()
        .help("Quality")
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// A composer's last row: the model name (truncates first), the estimate pill and the send
/// button. When they don't fit on one line (the inspector is about 260 pt wide), the button
/// moves to its own line so neither it nor the pill wraps.
struct ComposerSendRow<SendButton: View>: View {
    let modelName: String
    /// Nil hides the pill (offline).
    let estimate: CostEstimate?
    @ViewBuilder let button: SendButton

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name
                Spacer(minLength: 4)
                pill
                send
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 4)
                    pill
                }
                send
            }
        }
    }

    private var name: some View {
        Text(modelName)
            .font(Crayon.font(.caption, weight: .medium))
            .foregroundStyle(Crayon.inkSoft)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(modelName)
    }

    @ViewBuilder
    private var pill: some View {
        if let estimate { CostEstimatePill(estimate: estimate) }
    }

    private var send: some View {
        button.lineLimit(1).fixedSize()
    }
}

/// Lays its children out left to right, starting a new line when the next one doesn't fit
/// (reference chips in a narrow composer). A child wider than the row is offered the row's width.
struct WrappingRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each child's frame (centred vertically in its line) and the total size.
    private func arrange(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let limit = width ?? .infinity
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > limit {
                size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if x > 0, x + size.width > limit {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for item in line {
                frames[item.index] = CGRect(x: x, y: y + (height - item.size.height) / 2,
                                            width: item.size.width, height: item.size.height)
                x += item.size.width + spacing
            }
            maxWidth = max(maxWidth, x - spacing)
            y += height + lineSpacing
        }
        return (frames, CGSize(width: maxWidth, height: max(0, y - lineSpacing)))
    }
}

/// What stops Generate working until Settings changes: the default model missing from the
/// account, or no OpenAI key.
struct GenerationSetupNotes: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.missingDefaultModel != nil {
            // Text that can wrap, so a rounded rectangle rather than a capsule.
            VStack(alignment: .leading, spacing: 2) {
                Text("The default model isn't available to your account.").foregroundStyle(Crayon.ink)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Pick Another in Settings…") }.buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Crayon.sunflower.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
        }
        if !app.hasOpenAIKey {
            VStack(alignment: .leading, spacing: 2) {
                Text(UnavailableText.noKey)
                    .fixedSize(horizontal: false, vertical: true)
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
