import BBAI
import BBAICore
import BBModel
import SwiftUI

/// A message's generation status as a pill (waiting, running, failed with advice, produced):
/// shared by the session thread and the asset editor.
struct MessageStatusLine: View {
    @Environment(AppModel.self) private var app
    let message: Message
    let session: Session
    /// Show "Version N" once the picture arrived (off in the asset editor, which shows only the newest).
    var showsProduced = true

    var body: some View {
        switch app.status(of: message) {
        case .none:
            if message.producedVersion == nil {
                StatusPill(color: Crayon.inkSoft, systemImage: "xmark.circle") {
                    Text("No picture: the request was cancelled or removed.")
                }
            }
        case .waiting:
            if let entry = liveEntry(for: message), case .retrying = entry.state {
                // The queue is waiting to try again after a temporary error (as the Queue window says).
                let state = entry.state
                StatusPill(color: Crayon.sunflower, systemImage: "arrow.clockwise") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(QueueRowModel.stateText(state, now: context.date, typical: nil, headline: nil))
                            .monospacedDigit()
                    }
                }
            } else {
                StatusPill(color: Crayon.sunflower) {
                    ProgressView().controlSize(.small)
                } label: {
                    Text("Waiting in the queue…")
                }
            }
        case let .running(startedAt, typical):
            StatusPill(color: Crayon.sky) {
                ProgressView().controlSize(.small)
            } label: {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Generating… " + ElapsedTimeText.progress(elapsed: context.date.timeIntervalSince(startedAt),
                                                                     typical: typical))
                        .monospacedDigit()
                }
            }
        case let .failed(error):
            let entry = failedEntry(for: message)
            VStack(alignment: .leading, spacing: 6) {
                if let advice = entry.flatMap({ app.advice(for: $0) }) {
                    FailureAdviceView(advice: advice)
                } else {
                    StatusPill(color: Crayon.tomato, systemImage: "exclamationmark.triangle.fill") {
                        Text(ProviderErrorText.message(for: error))
                    }
                }
                if let entry {
                    // The same actions as the Queue window's failed row.
                    HStack {
                        Button("Try Again") { app.retryQueueItem(entry.id) }
                            .disabled(!app.isOnline || !app.hasOpenAIKey)
                            .help(!app.isOnline ? UnavailableText.offline
                                  : !app.hasOpenAIKey ? UnavailableText.noKey : "Send this request again.")
                        Button("Dismiss") { app.removeQueueItem(entry.id) }
                            .help("Remove this failed request from the queue.")
                    }
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                }
            }
        case let .notSaved(text):
            StatusPill(color: Crayon.tomato, systemImage: "exclamationmark.triangle.fill") {
                Text(text)
            }
        case .interrupted:
            StatusPill(color: Crayon.inkSoft, systemImage: "clock.badge.xmark") {
                Text("Not finished: BookBook quit before the picture arrived.")
            }
        case let .produced(versionID):
            if showsProduced, let number = session.versionNumber(versionID) {
                StatusPill(color: Crayon.grass, systemImage: "photo") {
                    Text("Version \(number)")
                }
            }
        }
    }

    private func failedEntry(for message: Message) -> QueueEntry? {
        liveEntry(for: message)
    }

    /// The queue entry for the message's request, if the queue still has it.
    private func liveEntry(for message: Message) -> QueueEntry? {
        let snapshot = app.queueSnapshot
        if let id = message.queueItemID, let entry = snapshot.entry(for: id) { return entry }
        return snapshot.entries.first { $0.item.messageID == message.id }
    }
}

/// Version details rows, with the Cost row loaded from the book's ledger (`Provenance.cost`).
struct VersionDetailsGrid: View {
    @Environment(AppModel.self) private var app
    let version: Version
    let session: Session
    let bookID: BookID
    let assets: [AssetID: Asset]
    @State private var cost: CostRecord?
    @State private var checkCost: CostRecord?
    @State private var designCost: CostRecord?

    var body: some View {
        let catalog = app.catalog
        let rows = VersionDetailsContent.rows(
            for: version, in: session, cost: cost, assets: assets, checkCost: checkCost, designCost: designCost,
            modelName: { provider, id in
                catalog.imageModel(provider: provider, id: id)?.displayName
                    ?? catalog.textModel(provider: provider, id: id)?.displayName
            })
        // Labels above values: the panel is narrow, and a label column as wide as the longest
        // label ("Design system prompt") would squeeze every value.
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).fontWeight(.semibold).foregroundStyle(Crayon.inkSoft)
                    Text(row.value).foregroundStyle(Crayon.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
        .padding(.top, 6)
        .task(id: [version.provenance?.cost, version.consistency?.cost, version.textStyle?.call.cost]) {
            let records = await app.costRecords([version.provenance?.cost, version.consistency?.cost,
                                                 version.textStyle?.call.cost], in: bookID)
            cost = records[0]
            checkCost = records[1]
            // A typography-only version's own cost is the design request: don't list it twice.
            designCost = version.textStyle?.call.cost == version.provenance?.cost ? nil : records[2]
        }
    }
}

/// A status line in the thread: a soft colour wash with a coloured symbol and ink text, so the
/// state reads at a glance and the text stays legible in both appearances.
struct StatusPill<Icon: View, Content: View>: View {
    let color: Color
    let icon: Icon
    let content: Content

    init(color: Color, @ViewBuilder icon: () -> Icon, @ViewBuilder label: () -> Content) {
        self.color = color
        self.icon = icon()
        self.content = label()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            icon.foregroundStyle(color)
            content
                .foregroundStyle(Crayon.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Crayon.font(.caption, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous).strokeBorder(color.opacity(0.4), lineWidth: 1))
    }
}

extension StatusPill where Icon == StatusSymbol {
    init(color: Color, systemImage: String, @ViewBuilder label: () -> Content) {
        self.init(color: color, icon: { StatusSymbol(name: systemImage) }, label: label)
    }
}

/// A status symbol that VoiceOver skips, as a `Label`'s icon is.
struct StatusSymbol: View {
    let name: String
    var body: some View { Image(systemName: name).accessibilityHidden(true) }
}

