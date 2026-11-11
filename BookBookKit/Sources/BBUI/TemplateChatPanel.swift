import BBAI
import BBAICore
import BBModel
import BBStore
import SwiftUI

/// The Layouts tab's trailing panel: a Chat / Box switch over the AI chat for the open template
/// and the box inspector. Clicking a box on the canvas switches to Box.
struct LayoutsInspector: View {
    let document: BookDocument
    let editor: TemplateEditorModel
    let chat: TemplateChatModel

    var body: some View {
        @Bindable var chat = chat
        VStack(spacing: 0) {
            Picker("Panel", selection: $chat.pane) {
                Label("Chat", systemImage: "sparkles").tag(TemplateChatModel.Pane.chat)
                Label("Box", systemImage: "slider.horizontal.3").tag(TemplateChatModel.Pane.box)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .help("Chat with AI about this layout, or edit the selected box")
            Divider()
            switch chat.pane {
            case .chat:
                TemplateChatPanel(document: document, editor: editor, chat: chat)
            case .box:
                BoxInspector(model: editor)
                    .disabled(!document.isEditable)
            }
        }
        .onChange(of: editor.selection) { _, selection in
            if !selection.isEmpty { chat.pane = .box }
        }
    }
}

/// The chat thread for the open template (PD §8.4): describe a layout or a change, see the
/// estimate, send; each reply changes the template as one undo step and can be restored later.
struct TemplateChatPanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let editor: TemplateEditorModel
    let chat: TemplateChatModel

    var body: some View {
        if let template = editor.template {
            TemplateChatThread(document: document, chat: chat, template: template)
                .id(template.id)
        } else {
            CrayonEmptyState("No Layout Open", systemImage: "rectangle.3.group", color: Crayon.sky,
                             message: "Choose a layout, or use New › New Layout with AI.")
        }
    }
}

private struct TemplateChatThread: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let chat: TemplateChatModel
    let template: Template
    @State private var estimate: CostEstimate?
    @FocusState private var composerFocused: Bool

    private var id: TemplateID { template.id }

    private var text: Binding<String> {
        Binding(get: { chat.drafts[id] ?? "" }, set: { chat.drafts[id] = $0 })
    }

    private var trimmed: String { (chat.drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let messages = chat.messages(for: id)
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        intro
                        ForEach(messages) { message in
                            row(message).id(message.id)
                        }
                        if chat.isRunning(id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(template.boxes.isEmpty ? "Designing the layout…" : "Changing the layout…")
                                    .font(Crayon.font(.callout, weight: .medium))
                                    .foregroundStyle(Crayon.inkSoft)
                                Spacer()
                                Button("Stop") { chat.cancel(id) }
                                    .controlSize(.small)
                            }
                            .id("running")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: messages.count) {
                    withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: chat.isRunning(id)) { _, running in
                    if running { withAnimation { proxy.scrollTo("running", anchor: .bottom) } }
                }
            }
            Divider()
            composer
                .crayonCard(padding: 12)
                .padding(12)
        }
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: chat.wantsComposerFocus) { takeFocusIfAsked() }
    }

    @ViewBuilder private var intro: some View {
        if chat.messages(for: id).isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Crayon.sunflower)
                    .accessibilityHidden(true)
                Text(template.boxes.isEmpty
                     ? "Describe the layout, for example “big picture across the top two-thirds, two lines of text at the bottom in a rounded cream box”."
                     : "Describe a change to this layout, for example “make the picture full-bleed” or “move the text to the left page”.")
                    .font(Crayon.font(.callout, weight: .medium))
                    .foregroundStyle(Crayon.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Crayon.sunflower.opacity(0.12), in: ThreadBubble.shape)
            .overlay(ThreadBubble.shape.strokeBorder(Crayon.sunflower.opacity(0.5),
                                                     style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }

    @ViewBuilder private func row(_ message: TemplateChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .foregroundStyle(Crayon.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Crayon.sky.opacity(0.16), in: ThreadBubble.shape)
                .overlay(ThreadBubble.shape.strokeBorder(Crayon.sky.opacity(0.35), lineWidth: 1))
        case .assistant:
            reply(message)
        }
    }

    private func reply(_ message: TemplateChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = message.failure {
                FailureAdviceView(advice: failure)
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(Crayon.font(.callout, weight: .medium))
                    .foregroundStyle(Crayon.ink)
                    .textSelection(.enabled)
            }
            if let snapshot = message.snapshot {
                HStack(alignment: .bottom, spacing: 10) {
                    diagram(snapshot)
                    Spacer(minLength: 0)
                    Button("Restore This") { chat.restore(message, in: id) }
                        .controlSize(.small)
                        .disabled(!document.isEditable || !chat.canRestore(message, in: id))
                        .help("Put the layout back the way this reply left it (undoable)")
                }
            }
            if let retry = message.retryInstruction {
                Button("Try Again") { chat.submit(retry, to: id, app: app, isRetry: true) }
                .controlSize(.small)
                .disabled(!document.isEditable || chat.isRunning(id) || !app.isOnline)
            }
            if let sent = message.sent { sentView(sent) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Crayon.grape.opacity(0.08), in: ThreadBubble.shape)
        .overlay(ThreadBubble.shape.strokeBorder(Crayon.grape.opacity(0.3), lineWidth: 1))
    }

    private func diagram(_ snapshot: Template) -> some View {
        let trim = document.content.style.pageSetup.trimSize
        let aspect = trim.width / max(1, trim.height) * (snapshot.kind == .spread ? 2 : 1)
        let height: CGFloat = snapshot.kind == .spread ? 60 : 90
        return TemplateDiagram(template: snapshot)
            .frame(width: height * aspect, height: height)
            .accessibilityLabel("Layout preview")
    }

    private func sentView(_ sent: TemplateSentRecord) -> some View {
        DisclosureGroup("What was sent") {
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
        .font(Crayon.font(.caption, weight: .semibold))
        .foregroundStyle(Crayon.inkSoft)
    }

    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case let .confirming(estimate, overBudget, instruction, isRetry) = chat.state(for: id) {
                confirmation(estimate, overBudget: overBudget, instruction: instruction, isRetry: isRetry)
            } else {
                field
                footer
            }
        }
        .disabled(!document.isEditable)
    }

    private var field: some View {
        TextField(template.boxes.isEmpty ? "Describe the layout" : "Describe a change", text: text, axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.plain)
            .font(Crayon.font(.body, weight: .regular))
            .foregroundStyle(Crayon.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Crayon.paper, in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
                .strokeBorder(Crayon.ink.opacity(0.12), lineWidth: 1.5))
            .focused($composerFocused)
            .onSubmit(send)
            .onChange(of: EstimateKey(text: trimmed, boxes: template.boxes, messages: chat.messages(for: id).count),
                      initial: true) {
                estimate = chat.estimate(trimmed, for: id, app: app)
            }
    }

    private var footer: some View {
        HStack {
            Text(chat.model(app)?.displayName ?? "No layout model is set. Choose one in Settings.")
                .font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                .lineLimit(1)
            Spacer()
            if app.isOnline, let estimate {
                Text(CostText.estimate(estimate))
                    .font(Crayon.font(.caption, weight: .bold))
                    .foregroundStyle(Crayon.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Crayon.grass.opacity(0.18), in: Capsule())
                    .help("An estimate; the actual cost is recorded in the book's cost ledger.")
                    .accessibilityLabel("Estimated cost: \(CostText.estimate(estimate))")
            }
            Button(!app.isOnline ? "Offline" : "Send", action: send)
                .buttonStyle(.crayon)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmed.isEmpty || chat.isRunning(id) || chat.model(app) == nil || !app.isOnline)
        }
    }

    private func confirmation(_ estimate: CostEstimate, overBudget: Bool, instruction: String,
                              isRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(estimate.amount.map { "This will cost about \(CostText.amount($0)). Send it?" }
                 ?? "The cost of this request is unknown. Send it?")
                .font(Crayon.font(.callout, weight: .semibold))
                .foregroundStyle(Crayon.ink)
            if overBudget {
                Text("This book is already over its budget.")
                    .font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Back") { chat.cancelConfirmation(id) }.keyboardShortcut(.cancelAction)
                Button("Send") { chat.submit(instruction, to: id, app: app, confirmed: true, isRetry: isRetry) }
                    .buttonStyle(.crayon)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func takeFocusIfAsked() {
        guard chat.wantsComposerFocus else { return }
        chat.wantsComposerFocus = false
        composerFocused = true
    }

    private func send() {
        guard !trimmed.isEmpty, !chat.isRunning(id), app.isOnline else { return }
        chat.submit(trimmed, to: id, app: app)
    }

    private struct EstimateKey: Equatable {
        var text: String
        var boxes: [Box]
        var messages: Int
    }
}
