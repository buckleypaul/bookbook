import BBModel
import SwiftUI

/// The session panel for one image box (PD §8.6, minimal for the slice): the thread, the
/// version strip, Version details, and the prompt field with Generate.
struct SessionPanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let pageID: PageID
    let boxID: BoxID
    let images: ImageCache

    @State private var prompt = ""
    @State private var inspectedVersion: VersionID?
    @State private var detailsExpanded = false

    private var slot: ImageSlot? { content.pages[pageID]?.images[boxID] }
    private var session: Session? { slot.flatMap { content.sessions[$0.sessionID] } }
    private var placedID: VersionID? { slot?.placement?.versionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        thread(session)
                        if !session.versions.isEmpty {
                            versionStrip(session)
                            details(session)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                composer
                    .padding()
            } else {
                ContentUnavailableView("No Session", systemImage: "photo",
                                       description: Text("This image box has no session."))
            }
        }
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ session: Session) -> some View {
        let messages = session.messages.filter { $0.epoch == session.resetEpoch && $0.role == .user }
        if messages.isEmpty {
            Text("Describe the picture for this box, then press Generate.")
                .foregroundStyle(.secondary)
        }
        ForEach(messages) { message in
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                statusLine(app.status(of: message), session: session)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: MessageStatus, session: Session) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting in the queue…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case let .running(startedAt, typical):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Generating… " + ElapsedTimeText.progress(elapsed: context.date.timeIntervalSince(startedAt),
                                                                     typical: typical))
                        .monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        case let .failed(error):
            Label(ProviderErrorText.message(for: error), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .interrupted:
            Label("Not finished: BookBook quit before the picture arrived.", systemImage: "clock.badge.xmark")
                .font(.caption).foregroundStyle(.secondary)
        case let .produced(versionID):
            if let index = session.versions.firstIndex(where: { $0.id == versionID }) {
                Label("Version \(index + 1)", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Versions

    private func versionStrip(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Versions").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(session.versions.enumerated()), id: \.element.id) { index, version in
                        Button {
                            inspectedVersion = version.id
                            guard version.id != placedID else { return }
                            document.perform(.chooseVersion(page: pageID, box: boxID, version: version.id))
                        } label: {
                            thumbnail(version)
                        }
                        .buttonStyle(.plain)
                        .help(version.id == placedID ? "Version \(index + 1) (on the page)" : "Put version \(index + 1) on the page")
                        .accessibilityLabel("Version \(index + 1)")
                    }
                }
                .padding(2)
            }
        }
    }

    private func thumbnail(_ version: Version) -> some View {
        let placed = version.id == placedID
        return Group {
            if let image = images.image(for: version.image) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(placed ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: placed ? 3 : 1))
    }

    @ViewBuilder
    private func details(_ session: Session) -> some View {
        let id = inspectedVersion.flatMap { session.version($0)?.id } ?? placedID ?? session.versions.last?.id
        if let id, let version = session.version(id) {
            DisclosureGroup("Version details", isExpanded: $detailsExpanded) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(VersionDetailsContent.rows(for: version), id: \.self) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 6)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Describe the picture", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(generate)
            HStack {
                Text("\(app.defaultModelName) · \(VersionDetailsContent.qualityName(app.defaults.quality))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Generate", action: generate)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.hasOpenAIKey || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !app.hasOpenAIKey {
                HStack(spacing: 4) {
                    Text("Add your OpenAI key in Settings ▸ API Keys to generate.")
                    SettingsLink { Text("Open Settings…") }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        guard app.hasOpenAIKey else { return }
        if app.generate(prompt: prompt, page: pageID, box: boxID, in: document) {
            prompt = ""
        }
    }
}
