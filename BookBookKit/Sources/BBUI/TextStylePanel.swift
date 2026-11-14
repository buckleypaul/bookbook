import BBAI
import BBAICore
import BBModel
import SwiftUI

/// The session panel for a page text box (PD §8.6 "Styling a text box", A §7.13): describe a
/// look ("a gold storybook frame with vines, playful font"), and AI picks the typography and
/// paints a decoration behind the text. The thread, version strip and Version details work as
/// for pictures; clicking a version shows that style on the page (undoable), and Remove Style
/// goes back to the layout's own look.
struct TextStylePanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let model: TextStyleModel
    let pageID: PageID
    let boxID: BoxID

    @State private var prompt = ""
    @State private var selectedVersion: VersionID?
    @State private var freshEpoch: Int?
    @State private var detailsExpanded = false
    @State private var quality: QualityLevel?
    @State private var estimate = CostEstimate.unknown
    @State private var pendingDelete: VersionID?
    @State private var confirmReset = false
    @State private var confirmStop = false
    @State private var problem: String?
    @State private var confirmation: PendingConfirmation<PendingStyle>?

    private var key: TextBoxKey { TextBoxKey(page: pageID, box: boxID) }
    private var owner: SessionOwner { .textBox(pageID, boxID) }
    private var target: GenerationTarget { .textBox(pageID, boxID) }
    private var session: Session? { SessionPanelState.session(for: owner, in: content) }
    private var shownID: VersionID? { SessionPanelState.placedVersion(for: owner, in: content) }
    private var boxLabel: String { TextStyleLabels.boxLabel(page: pageID, box: boxID, in: content) }

    /// The version refinement and Details use: the selection, else the shown one.
    private func baseID(_ session: Session?) -> VersionID? {
        guard let session else { return nil }
        if let selectedVersion, session.version(selectedVersion) != nil { return selectedVersion }
        if freshEpoch == session.resetEpoch { return nil }
        return shownID.flatMap { session.version($0)?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    thread
                    runState
                    if let session, !session.versions.isEmpty {
                        versions(session)
                        details(session)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            composer
                .crayonCard(padding: 12)
                .padding(12)
        }
        .onChange(of: shownID) {
            selectedVersion = nil
            freshEpoch = nil
        }
        .confirmationDialog(deleteTitle, isPresented: $pendingDelete.isPresent(), titleVisibility: .visible) {
            Button("Delete Version", role: .destructive) {
                if let id = pendingDelete { delete(id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete != nil && pendingDelete == shownID
                 ? "It's on the page, so the text goes back to the layout's look. This can't be undone."
                 : "This can't be undone.")
        }
        .confirmationDialog("Reset this session?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Keep Versions") { reset(keepVersions: true) }.keyboardShortcut(.defaultAction)
            Button("Discard Versions", role: .destructive) { reset(keepVersions: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chat clears. Discarding versions also removes this box's style. This can't be undone.")
        }
        .confirmationDialog("Stop designing this style?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { model.cancel(key) }
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text(QueueView.cancelNotice)
        }
        .generationConfirmation(confirmFlow) { $0.kind.buttonTitle }
        .problemAlert($problem)
    }

    /// "Delete version 2?"
    private var deleteTitle: String {
        let number = pendingDelete.flatMap { id in session?.versionNumber(id) }
        return number.map { "Delete version \($0)?" } ?? "Delete this version?"
    }

    private var header: some View {
        HStack(spacing: 8) {
            CrayonHeader("\(boxLabel) Style", color: Crayon.grape)
            Spacer()
            Menu {
                Button("Remove Style") { removeStyle() }
                    .disabled(shownID == nil || !document.isEditable)
                Divider()
                Button("Reset Session…", role: .destructive) { confirmReset = true }
                    .disabled(session == nil || !document.isEditable)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Crayon.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Session actions")
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Crayon.paperDeep)
    }

    // MARK: Thread

    @ViewBuilder
    private var thread: some View {
        let messages = session?.visibleMessages.filter { $0.role == .user } ?? []
        if messages.isEmpty, !model.isDesigning(key) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "textformat")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Crayon.grape)
                    .accessibilityHidden(true)
                Text("Describe a look for this text: a font, colours, a frame, a banner or flourishes around it. The words stay editable.")
                    .font(Crayon.font(.callout, weight: .medium))
                    .foregroundStyle(Crayon.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Crayon.grape.opacity(0.10), in: ThreadBubble.shape)
            .overlay(ThreadBubble.shape.strokeBorder(Crayon.grape.opacity(0.45),
                                                     style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        if let session {
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 5) {
                    if let refines = message.refines, let number = session.versionNumber(refines) {
                        Label("Restyled version \(number)", systemImage: "arrow.triangle.branch")
                            .font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.grape)
                    }
                    bubble(message.text)
                    if let produced = message.producedVersion, let summary = session.version(produced)?.textStyle?.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(Crayon.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if message.producedVersion == nil, message.queueItemID != nil,
                              let summary = pendingSummary(message) {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(Crayon.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    MessageStatusLine(message: message, session: session)
                }
            }
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Crayon.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Crayon.grape.opacity(0.14), in: ThreadBubble.shape)
            .overlay(ThreadBubble.shape.strokeBorder(Crayon.grape.opacity(0.35), lineWidth: 1))
    }

    /// The design summary of a message whose decoration is still queued.
    private func pendingSummary(_ message: Message) -> String? {
        guard let id = message.queueItemID, let entry = app.queueSnapshot.entry(for: id) else { return nil }
        return entry.item.intent.textStyle?.summary
    }

    /// The design step: "Designing…" with Stop, or its failure with Try Again.
    @ViewBuilder
    private var runState: some View {
        switch model.state(for: key) {
        case .idle:
            EmptyView()
        case let .designing(instruction):
            VStack(alignment: .leading, spacing: 5) {
                bubble(instruction)
                HStack {
                    StatusPill(color: Crayon.grape) {
                        ProgressView().controlSize(.small)
                    } label: {
                        Text("Designing the style…")
                    }
                    // The design request may already be billed (PD §5), so say so first, as the queue does.
                    Button("Stop") { confirmStop = true }
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                }
            }
        case let .failed(instruction, advice, _):
            VStack(alignment: .leading, spacing: 6) {
                bubble(instruction)
                FailureAdviceView(advice: advice)
                HStack {
                    Button("Try Again") {
                        model.dismissFailure(key)
                        prompt = instruction
                        style()
                    }
                    .disabled(!app.isOnline || !app.hasOpenAIKey || !document.isEditable)
                    Button("Dismiss") { model.dismissFailure(key) }
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            }
        }
    }

    // MARK: Versions

    private func versions(_ session: Session) -> some View {
        let base = baseID(session)
        return VStack(alignment: .leading, spacing: 8) {
            CrayonHeader("Versions", color: Crayon.grape)
            VersionStrip(session: session, placedID: shownID, selectedID: base, store: document.store,
                         onChoose: { choose($0) },
                         onToggleStar: { document.setStarred(!$0.starred, version: $0.id, owner: owner) },
                         onDelete: { pendingDelete = $0.id },
                         isEditable: document.isEditable)
            HStack {
                if shownID != nil {
                    Button("Remove Style") { removeStyle() }
                        .disabled(!document.isEditable)
                        .help("Go back to the layout's own look for this text.")
                }
                if let base {
                    Button("Delete Version…", role: .destructive) { pendingDelete = base }
                        .disabled(!document.isEditable)
                }
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private func details(_ session: Session) -> some View {
        if let id = baseID(session) ?? session.versions.last?.id, let version = session.version(id) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VersionDetailsGrid(version: version, session: session, bookID: document.id, assets: content.assets)
                if version.textStyle?.decorationPrompt != nil {
                    WrappingRow(spacing: 8, lineSpacing: 6) {
                        Button("Repaint with Same Settings") {
                            confirmFlow.start(.repaint(version))
                        }
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        .disabled(!app.hasOpenAIKey || !app.isOnline || !document.isEditable)
                        .help("Paint the decoration again with the same design.")
                        if app.isOnline, let estimate = app.regenerateEstimate(version, target: target, in: document) {
                            CostEstimatePill(estimate: estimate)
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Text("Version details")
                    .font(Crayon.font(.subheadline, weight: .bold))
                    .foregroundStyle(Crayon.ink)
            }
            .padding(12)
            .background(Crayon.paperDeep,
                        in: RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous))
        }
    }

    // MARK: Composer

    private var composer: some View {
        let base = baseID(session)
        let number = base.flatMap { session?.versionNumber($0) }
        let designing = model.isDesigning(key)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(number.map { "Describe the change to version \($0)" }
                      ?? "Describe a look, e.g. “gold storybook frame with vines, playful font”",
                      text: $prompt, axis: .vertical)
                .crayonComposerField()
                .onSubmit { style() }
                .onChange(of: EstimateKey(prompt: prompt, quality: quality ?? app.defaults.quality, base: base,
                                          model: app.defaults.model, shown: shownID), initial: true) { _, key in
                    estimate = model.estimate(key.prompt.isEmpty ? "style" : key.prompt, quality: key.quality,
                                              refines: key.base, for: self.key, app: app)
                }
            HStack {
                QualityPicker(selection: Binding(get: { quality ?? app.defaults.quality }, set: { quality = $0 }),
                              showsLabel: false)
                Spacer(minLength: 0)
            }
            ComposerSendRow(modelName: app.defaultModelName, estimate: app.isOnline ? estimate : nil) {
                Button(!app.isOnline ? "Offline" : (number.map { "Restyle Version \($0)" } ?? "Style")) { style() }
                    .buttonStyle(.crayon)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.isOnline || !app.hasOpenAIKey || designing || !document.isEditable
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            GenerationSetupNotes()
        }
    }

    private struct EstimateKey: Equatable {
        var prompt: String
        var quality: QualityLevel
        var base: VersionID?
        var model: String
        var shown: VersionID?
    }

    // MARK: Actions

    private func style() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document.isEditable, app.hasOpenAIKey, app.isOnline, !text.isEmpty, !model.isDesigning(key) else { return }
        confirmFlow.start(.style(text, quality: quality ?? app.defaults.quality, refines: baseID(session)))
    }

    private var confirmFlow: GenerationConfirmFlow<PendingStyle> {
        GenerationConfirmFlow(app: app, document: document, pending: $confirmation,
                              notice: { notice(for: $0) }, estimate: { cost(of: $0) }, perform: { perform($0) },
                              question: { $0.kind.question })
    }

    private func notice(for action: PendingStyle) -> ProviderID? {
        switch action {
        case let .style(text, quality, refines):
            model.noticeNeeded(text, quality: quality, refines: refines, for: key, app: app)
        case let .repaint(version):
            version.provenance.flatMap { app.realPersonNoticeNeeded(intent: $0.intent, target: target, in: document) }
        }
    }

    private func cost(of action: PendingStyle) -> CostEstimate {
        switch action {
        case let .style(text, quality, refines):
            model.estimate(text, quality: quality, refines: refines, for: key, app: app)
        case let .repaint(version):
            app.regenerateEstimate(version, target: target, in: document) ?? .unknown
        }
    }

    private func perform(_ action: PendingStyle) {
        guard app.hasOpenAIKey else { return }
        switch action {
        case let .style(text, quality, refines):
            model.start(text, quality: quality, refines: refines, for: key, app: app)
            prompt = ""
        case let .repaint(version):
            app.regenerate(version, target: target, in: document)
        }
    }

    private func choose(_ version: Version) {
        selectedVersion = version.id
        freshEpoch = nil
        guard version.id != shownID else { return }
        document.perform(.chooseTextStyle(page: pageID, box: boxID, version: version.id))
    }

    private func removeStyle() {
        selectedVersion = nil
        document.perform(.chooseTextStyle(page: pageID, box: boxID, version: nil))
    }

    private func delete(_ id: VersionID) {
        if selectedVersion == id { selectedVersion = nil }
        document.deleteVersion(id, owner: owner)
    }

    private func reset(keepVersions: Bool) {
        selectedVersion = nil
        freshEpoch = keepVersions ? session.map { $0.resetEpoch + 1 } : nil
        document.resetSession(owner: owner, keepVersions: keepVersions)
    }

    private enum PendingStyle: Sendable {
        var kind: CostConfirmKind {
            switch self {
            case .style: .textStyle
            case .repaint: .repaint
            }
        }

        case style(String, quality: QualityLevel, refines: VersionID?)
        /// Paint the decoration again with the version's stored design.
        case repaint(Version)
    }
}
