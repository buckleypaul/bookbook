import AppKit
import BBAICore
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// The session panel for one image box (PD §8.6): the thread, the version strip, Version
/// details, and the composer. The panel keeps a selected version (default: the one on the page);
/// Details and refinement use it. Clicking a version puts it on the page (undoable) and selects it.
struct SessionPanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let pageID: PageID
    let boxID: BoxID
    let images: ImageCache

    @State private var prompt = ""
    @State private var selectedVersion: VersionID?
    @State private var detailsExpanded = false
    @State private var quality: QualityLevel?
    @State private var includeStoryText: Bool?
    @State private var pendingDelete: VersionID?
    @State private var confirmReset = false
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var problem: String?

    private var slot: ImageSlot? { content.pages[pageID]?.images[boxID] }
    private var session: Session? { slot.flatMap { content.sessions[$0.sessionID] } }
    private var placedID: VersionID? { slot?.placement?.versionID }

    /// The version Details and refinement use: the selection if it still exists, else the placed one.
    private func baseID(_ session: Session) -> VersionID? {
        if let selectedVersion, session.version(selectedVersion) != nil { return selectedVersion }
        return placedID.flatMap { session.version($0)?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        thread(session)
                        if !session.versions.isEmpty {
                            versions(session)
                            details(session)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                composer(session)
                    .padding()
            } else {
                ContentUnavailableView("No Session", systemImage: "photo",
                                       description: Text("This image box has no session."))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard document.isEditable else { return false }
            importImages(urls.filter(\.isFileURL))
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): importImages([url])
            case let .failure(error): problem = error.localizedDescription
            }
        }
        .confirmationDialog("Delete this version?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Version", role: .destructive) {
                if let id = pendingDelete { delete(id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog("Reset this session?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Keep Versions") { reset(keepVersions: true) }.keyboardShortcut(.defaultAction)
            Button("Discard Versions", role: .destructive) { reset(keepVersions: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The chat clears. Discarding versions also empties this box. This can't be undone.")
        }
        .alert("Couldn't Complete That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var deleteMessage: String {
        let placed = pendingDelete != nil && pendingDelete == placedID
        return (placed ? "It is on the page, so the box will be empty. " : "") + "This can't be undone."
    }

    private var header: some View {
        HStack {
            Text("Session").font(.headline)
            Spacer()
            Menu {
                Button("Choose Image…") { showImporter = true }
                Divider()
                Button("Reset Session…", role: .destructive) { confirmReset = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ session: Session) -> some View {
        let messages = session.visibleMessages.filter { $0.role == .user }
        if messages.isEmpty {
            Text("Describe the picture for this box, then press Generate. Or drop in your own image.")
                .foregroundStyle(.secondary)
        }
        ForEach(messages) { message in
            VStack(alignment: .leading, spacing: 4) {
                if let refines = message.refines, let number = session.versionNumber(refines) {
                    Label("refined version \(number)", systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        case let .notSaved(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .interrupted:
            Label("Not finished: BookBook quit before the picture arrived.", systemImage: "clock.badge.xmark")
                .font(.caption).foregroundStyle(.secondary)
        case let .produced(versionID):
            if let number = session.versionNumber(versionID) {
                Label("Version \(number)", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Versions

    private func versions(_ session: Session) -> some View {
        let base = baseID(session)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Versions").font(.headline)
            VersionStrip(session: session, placedID: placedID, selectedID: base, store: document.store,
                         onChoose: { choose($0) },
                         onToggleStar: { document.setStarred(!$0.starred, version: $0.id, page: pageID, box: boxID) },
                         onExport: { export($0, in: session) },
                         onDelete: { pendingDelete = $0.id })
            if let base, let version = session.version(base) {
                HStack {
                    Button("Export Image…") { export(version, in: session) }
                    Button("Delete…", role: .destructive) { pendingDelete = version.id }
                }
                .controlSize(.small)
            }
        }
    }

    private func choose(_ version: Version) {
        selectedVersion = version.id
        guard version.id != placedID else { return }
        document.perform(.chooseVersion(page: pageID, box: boxID, version: version.id))
    }

    private func delete(_ id: VersionID) {
        if selectedVersion == id { selectedVersion = nil }
        document.deleteVersion(id, page: pageID, box: boxID)
    }

    private func reset(keepVersions: Bool) {
        selectedVersion = nil
        document.resetSession(page: pageID, box: boxID, keepVersions: keepVersions)
    }

    private func export(_ version: Version, in session: Session) {
        let name = VersionExport.suggestedName(book: content.book.title, page: pageID, in: content,
                                               number: session.versionNumber(version.id) ?? 1, ref: version.image)
        if let text = VersionExport.run(ref: version.image, from: document.store.imageURL(for: version.image),
                                        suggestedName: name) {
            problem = text
        }
    }

    private func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let document = document, page = pageID, box = boxID
        Task {
            for url in urls {
                do {
                    selectedVersion = try await document.importImage(from: url, page: page, box: box)
                } catch let failure as ImageImportFailure {
                    problem = failure.message
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ session: Session) -> some View {
        if let id = baseID(session) ?? session.versions.last?.id, let version = session.version(id) {
            DisclosureGroup("Version details", isExpanded: $detailsExpanded) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(VersionDetailsContent.rows(for: version, in: session), id: \.self) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 6)
                if version.provenance != nil {
                    Button("Regenerate with Same Settings") {
                        app.regenerate(version, page: pageID, box: boxID, in: document)
                    }
                    .controlSize(.small)
                    .disabled(!app.hasOpenAIKey)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: Composer

    private func composer(_ session: Session) -> some View {
        let base = baseID(session)
        let number = base.flatMap { session.versionNumber($0) }
        return VStack(alignment: .leading, spacing: 8) {
            TextField(number.map { "Describe the change to version \($0)" } ?? "Describe the picture",
                      text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit { generate(refining: base) }
            HStack {
                Picker("Quality", selection: Binding(get: { quality ?? app.defaults.quality },
                                                     set: { quality = $0 })) {
                    ForEach([QualityLevel.draft, .standard, .high], id: \.self) {
                        Text(VersionDetailsContent.qualityName($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Toggle("Include story text", isOn: Binding(get: { includeStoryText ?? app.defaults.includeStoryText },
                                                           set: { includeStoryText = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            HStack {
                Text(app.defaultModelName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(number.map { "Refine Version \($0)" } ?? "Generate") { generate(refining: base) }
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

    private func generate(refining base: VersionID?) {
        guard app.hasOpenAIKey else { return }
        if app.generate(prompt: prompt, quality: quality ?? app.defaults.quality,
                        includeStoryText: includeStoryText ?? app.defaults.includeStoryText, refines: base,
                        page: pageID, box: boxID, in: document) {
            prompt = ""
        }
    }
}
