import BBAI
import AppKit
import BBAICore
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// The session panel (PD §8.6) for a page image box: the thread, the version strip, Version
/// details, and the composer. Clicking a version puts it on the page (undoable) and selects it.
/// The composer has `@mention` autocomplete, the page's asset checklist, "Reference another
/// image…" and the story-text toggle. (Assets don't use it: the asset editor generates from the
/// description, see `AssetImageControls`.)
///
/// The panel keeps a selected version (default: the placed one); Details and refinement use it. Every generation checks the real-person notice, then the cost.
struct SessionPanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let pageID: PageID
    let boxID: BoxID

    private var owner: SessionOwner { .pageBox(pageID, boxID) }

    @State private var prompt = ""
    @State private var selectedVersion: VersionID?
    /// The `resetEpoch` of a reset that kept versions; the placed version isn't the base while it matches.
    @State private var freshEpoch: Int?
    @State private var detailsExpanded = false
    @State private var quality: QualityLevel?
    @State private var includeStoryText: Bool?
    @State private var attached: [VersionRef] = []
    @State private var showReferencePicker = false
    @State private var pendingDelete: VersionID?
    @State private var confirmReset = false
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var problem: String?
    @State private var estimate = CostEstimate.unknown
    /// The generation waiting on the real-person notice or the cost confirmation.
    @State private var confirmation: PendingConfirmation<PendingGeneration>?
    @State private var regionEditing: RegionEditSubject?

    private var target: GenerationTarget { GenerationTarget(owner: owner) }

    private var session: Session? { SessionPanelState.session(for: owner, in: content) }

    /// The version placed in the box.
    private var placedID: VersionID? { SessionPanelState.placedVersion(for: owner, in: content) }

    /// The version Details and refinement use: the selection if it still exists, else the placed one.
    private func baseID(_ session: Session) -> VersionID? {
        if let selectedVersion, session.version(selectedVersion) != nil { return selectedVersion }
        // After Reset Session → Keep Versions the thread starts fresh (PD §8.6): no refining the placed
        // version until the user clicks one.
        if freshEpoch == session.resetEpoch { return nil }
        return placedID.flatMap { session.version($0)?.id }
    }

    private var storyText: Bool { includeStoryText ?? app.defaults.includeStoryText }

    /// The attached references whose versions still exist.
    private var liveAttached: [VersionRef] {
        attached.filter { content.sessions[$0.sessionID]?.version($0.versionID) != nil }
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
                AssetChecklistView(document: document, content: content, pageID: pageID)
                    .padding(.horizontal)
                    .padding(.top, 10)
                composer(session)
                    .crayonCard(padding: 12)
                    .padding(12)
            } else {
                CrayonEmptyState("No Session", systemImage: "photo", color: Crayon.sky,
                                 message: "This image box has no session.")
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
                    .strokeBorder(Crayon.tomato, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(Crayon.tomato.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard document.isEditable else { return false }
            let files = urls.filter(\.isFileURL)
            importImages(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: placedID) {
            // An undo (or any other change) moved the placement: a stale selection would refine a
            // picture that isn't on the page.
            selectedVersion = nil
            freshEpoch = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): importImages([url])
            case let .failure(error): problem = error.localizedDescription
            }
        }
        .sheet(isPresented: $showReferencePicker) {
            ReferencePickerView(content: content, store: document.store, excluding: session?.id) { ref in
                if !attached.contains(ref) { attached.append(ref) }
            }
        }
        .sheet(item: $regionEditing) { subject in
            RegionEditorSheet(imageData: subject.imageData, pixelSize: subject.version.pixelSize,
                              modelName: app.defaultModelName,
                              onCancel: { regionEditing = nil },
                              onSubmit: { drawing, text in
                                  regionEditing = nil
                                  submitRegionEdit(subject.version, drawing: drawing, prompt: text)
                              })
        }
        .confirmationDialog("Delete this version?", isPresented: $pendingDelete.isPresent(), titleVisibility: .visible) {
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
        .generationConfirmation(confirmFlow) { $0.kind.buttonTitle }
        .problemAlert($problem)
    }

    private var deleteMessage: String {
        let placed = pendingDelete != nil && pendingDelete == placedID
        let note = "It is on the page, so the box will be empty. "
        return (placed ? note : "") + "This can't be undone."
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Crayon.sky)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1)
                .accessibilityHidden(true)
            Text("Session")
                .font(Crayon.font(.headline, weight: .heavy))
                .foregroundStyle(Crayon.ink)
            Spacer()
            Menu {
                Button("Choose Image…") { showImporter = true }
                    .disabled(!document.isEditable)
                Divider()
                Button("Reset Session…", role: .destructive) { confirmReset = true }
                    .disabled(!document.isEditable)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Crayon.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Crayon.paperDeep)
    }

    // MARK: Thread

    @ViewBuilder
    private func thread(_ session: Session) -> some View {
        let messages = session.visibleMessages.filter { $0.role == .user }
        if messages.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Crayon.sunflower)
                    .accessibilityHidden(true)
                Text("Describe the picture for this box, then press Generate. Or drop in your own image.")
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
        ForEach(messages) { message in
            VStack(alignment: .leading, spacing: 5) {
                if let refines = message.refines, let number = session.versionNumber(refines) {
                    Label("refined version \(number)", systemImage: "arrow.triangle.branch")
                        .font(Crayon.font(.caption, weight: .semibold)).foregroundStyle(Crayon.grape)
                }
                Text(MentionText.displayText(message.text, assets: content.assets,
                                             fallback: VersionDetailsContent.deletedAssetName))
                    .foregroundStyle(Crayon.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Crayon.sky.opacity(0.16), in: ThreadBubble.shape)
                    .overlay(ThreadBubble.shape.strokeBorder(Crayon.sky.opacity(0.35), lineWidth: 1))
                ForEach(message.attachedReferences, id: \.self) { ref in
                    if let label = ReferenceSources.chipLabel(ref, in: content) {
                        Label("With \(label)", systemImage: "paperclip")
                            .font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                    }
                }
                MessageStatusLine(message: message, session: session)
            }
        }
    }

    // MARK: Versions

    private func versions(_ session: Session) -> some View {
        let base = baseID(session)
        return VStack(alignment: .leading, spacing: 8) {
            CrayonHeader("Versions", color: Crayon.grape)
            VersionStrip(session: session, placedID: placedID, selectedID: base,
                         store: document.store,
                         onChoose: { choose($0) },
                         onToggleStar: { document.setStarred(!$0.starred, version: $0.id, owner: owner) },
                         onExport: { export($0, in: session) },
                         onEditRegion: { startRegionEdit($0) },
                         regionEditReason: { regionEditReason(for: $0) },
                         onDelete: { pendingDelete = $0.id },
                         isEditable: document.isEditable,
                         isChecking: { app.isConsistencyCheckPending(versionID: $0.id) })
            if let base, let version = session.version(base) {
                consistencySection(version, session: session)
                let reason = regionEditReason(for: version)
                WrappingRow(spacing: 8, lineSpacing: 6) {
                    Button("Export Image…") { export(version, in: session) }
                    Button("Edit Region…") { startRegionEdit(version) }
                        .disabled(reason != nil)
                        .help(reason ?? "Select an area of this picture and describe the change.")
                    Button("Delete Version…", role: .destructive) { pendingDelete = version.id }
                        .disabled(!document.isEditable)
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                if let reason, reason != panelBlocker {
                    Text(reason).font(.caption).foregroundStyle(Crayon.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let panelBlocker {
                    CrayonInlineMessage(panelBlocker, kind: .info)
                }
            }
        }
    }

    // MARK: Consistency (PD §8.9)

    @ViewBuilder
    private func consistencySection(_ version: Version, session: Session) -> some View {
        let checking = app.isConsistencyCheckPending(versionID: version.id)
        let reason = ConsistencyPresentation.checkUnavailableReason(
            canCheck: app.canCheckConsistency, isEditable: document.isEditable, isOnline: app.isOnline,
            hasKey: app.hasOpenAIKey, isPending: checking)
        VStack(alignment: .leading, spacing: 6) {
            if checking {
                StatusPill(color: Crayon.sky) {
                    ProgressView().controlSize(.small)
                } label: {
                    Text("Checking consistency…")
                }
            } else if let report = version.consistency, report.warns, !report.dismissed {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Consistency warning").foregroundStyle(Crayon.ink)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Crayon.onSunflower, Crayon.sunflower)
                    }
                    .font(Crayon.font(.caption, weight: .heavy))
                    ForEach(Array(ConsistencyPresentation.lines(report).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(Crayon.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Crayon.sunflower.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Crayon.mediumCornerRadius, style: .continuous)
                    .strokeBorder(Crayon.sunflower.opacity(0.7), lineWidth: 1.5))
            } else if let report = version.consistency {
                if report.differences.isEmpty {
                    StatusPill(color: Crayon.grass, systemImage: "checkmark.seal") {
                        Text(ConsistencyPresentation.resultText(report))
                    }
                } else {
                    // Differences the user dismissed (or that didn't warn): not a green "all clear".
                    StatusPill(color: Crayon.inkSoft, systemImage: "info.circle") {
                        Text(ConsistencyPresentation.resultText(report))
                    }
                }
            }
            if !checking, let entry = app.consistencyCheckEntry(versionID: version.id),
               case .failed = entry.state, let advice = app.advice(for: entry) {
                FailureAdviceView(advice: advice)
            }
            WrappingRow(spacing: 8, lineSpacing: 6) {
                if let report = version.consistency, report.showsWarning {
                    let fixEstimate = app.consistencyFixIntent(bookID: document.id, sessionID: session.id,
                                                               versionID: version.id)
                        .map { app.estimate(for: $0, target: target, in: document) }
                    Button("Fix") { startConsistencyFix(version, sessionID: session.id) }
                        .disabled(panelBlocker != nil)
                        .help(panelBlocker ?? Self.withEstimate("Refine this picture to match the references.",
                                                                fixEstimate))
                    Button("Dismiss") {
                        _ = app.setConsistencyWarningDismissed(true, sessionID: session.id, versionID: version.id,
                                                               in: document)
                    }
                    .disabled(!document.isEditable)
                } else if let report = version.consistency, report.warns, report.dismissed {
                    Button("Show Warning Again") {
                        _ = app.setConsistencyWarningDismissed(false, sessionID: session.id, versionID: version.id,
                                                               in: document)
                    }
                    .disabled(!document.isEditable)
                }
                Button(version.consistency == nil ? "Check Consistency" : "Check Again") {
                    checkThenPerform(.checkConsistency(session: session.id, version: version.id))
                }
                .disabled(reason != nil)
                .help(reason ?? Self.withEstimate(
                    "Compare this picture with the images of the assets in it.",
                    app.consistencyCheckEstimate(bookID: document.id, sessionID: session.id, versionID: version.id)))
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            // Read-only, offline and no key are said once for the panel (`panelBlocker`).
            if let reason, !checking, reason != panelBlocker {
                Text(reason).font(.caption).foregroundStyle(Crayon.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What stops every AI and editing action on this panel (read-only, offline, no key), said once
    /// under the version actions instead of under each one; nil when nothing does.
    private var panelBlocker: String? {
        if !document.isEditable { return UnavailableText.readOnly }
        if !app.isOnline { return UnavailableText.offline }
        if !app.hasOpenAIKey { return UnavailableText.noKey }
        return nil
    }

    /// A paid action's tooltip with its estimate (PD §5: the estimate is shown before sending).
    static func withEstimate(_ help: String, _ estimate: CostEstimate?) -> String {
        guard let estimate else { return help }
        return help + " Estimated cost: \(CostText.estimate(estimate))."
    }

    private func startConsistencyFix(_ version: Version, sessionID: SessionID) {
        guard let intent = app.consistencyFixIntent(bookID: document.id, sessionID: sessionID, versionID: version.id)
        else { return }
        checkThenPerform(.fixConsistency(intent))
    }

    /// Why "Edit Region…" is unavailable for `version`, or nil when it can run.
    private func regionEditReason(for version: Version) -> String? {
        RegionEditEntry.unavailableMessage(
            isEditable: document.isEditable, isOnline: app.isOnline, hasKey: app.hasOpenAIKey,
            refusal: app.regionEditUnavailableReason(refines: version.id, target: target, in: document))
    }

    private func startRegionEdit(_ version: Version) {
        guard regionEditReason(for: version) == nil else { return }
        guard let data = try? Data(contentsOf: document.store.imageURL(for: version.image)) else {
            problem = "The picture couldn't be opened."
            return
        }
        regionEditing = RegionEditSubject(version: version, imageData: data)
    }

    private func submitRegionEdit(_ version: Version, drawing: RegionMaskDrawing, prompt text: String) {
        let request = RegionEditRequest(version: version, drawing: drawing,
                                        intent: app.generationIntent(prompt: text, quality: quality ?? app.defaults.quality,
                                                                     includeStoryText: storyText, refines: version.id,
                                                                     attachedReferences: liveAttached))
        checkThenPerform(.regionEdit(request))
    }

    private func choose(_ version: Version) {
        selectedVersion = version.id
        freshEpoch = nil
        guard version.id != placedID else { return }
        document.perform(.chooseVersion(page: pageID, box: boxID, version: version.id))
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

    private func export(_ version: Version, in session: Session) {
        let number = session.versionNumber(version.id) ?? 1
        let name = VersionExport.suggestedName(book: content.book.title, page: pageID, in: content,
                                               number: number, ref: version.image)
        if let text = VersionExport.run(ref: version.image, from: document.store.imageURL(for: version.image),
                                        suggestedName: name) {
            problem = text
        }
    }

    private func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let document = document, pageID = pageID, boxID = boxID
        Task {
            for url in urls {
                do {
                    selectedVersion = try await document.importImage(from: url, page: pageID, box: boxID)
                } catch {
                    problem = ImageImportFailure.message(for: error)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ session: Session) -> some View {
        if let id = baseID(session) ?? session.versions.last?.id, let version = session.version(id) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VersionDetailsGrid(version: version, session: session, bookID: document.id, assets: content.assets)
                if version.provenance != nil {
                    WrappingRow(spacing: 8, lineSpacing: 6) {
                        Button("Regenerate with Same Settings") {
                            regenerate(version)
                        }
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        .disabled(panelBlocker != nil)
                        .help(panelBlocker ?? "Make a new picture from the same prompt, references and settings.")
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

    /// The prompt as stored: typed `@Name`s become mention tokens.
    private var storedPrompt: String {
        MentionText.tokenizing(prompt, assets: Array(content.assets.values))
    }

    private func composer(_ session: Session) -> some View {
        let base = baseID(session)
        let number = base.flatMap { session.versionNumber($0) }
        let query = MentionCompletion.activeQuery(in: prompt)
        let suggestions = query.map { MentionCompletion.suggestions(for: $0.text, assets: Array(content.assets.values)) }
            ?? []
        return VStack(alignment: .leading, spacing: 8) {
            TextField(number.map { "Describe the change to version \($0)" }
                      ?? "Describe the picture (type @ to mention an asset)",
                      text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .font(Crayon.font(.body, weight: .regular))
                .foregroundStyle(Crayon.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Crayon.paper, in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
                    .strokeBorder(Crayon.ink.opacity(0.12), lineWidth: 1.5))
                .onSubmit {
                    if let query, let first = suggestions.first {
                        prompt = MentionCompletion.insert(first, replacing: query, in: prompt)
                    } else {
                        generate(refining: base)
                    }
                }
                .onChange(of: EstimateKey(prompt: storedPrompt, quality: quality ?? app.defaults.quality,
                                          story: storyText, base: base, attached: liveAttached,
                                          model: app.defaults.model), initial: true) { _, key in
                    estimate = app.estimate(prompt: key.prompt, quality: key.quality, includeStoryText: key.story,
                                            refines: key.base, attachedReferences: key.attached, target: target,
                                            in: document)
                }
            if let query, !suggestions.isEmpty {
                MentionSuggestions(suggestions: suggestions) { asset in
                    prompt = MentionCompletion.insert(asset, replacing: query, in: prompt)
                }
            }
            attachments
            // The inspector is narrow (about 260 pt) and doesn't widen with the window: one control
            // per row wherever a label could otherwise wrap.
            HStack(spacing: 8) {
                QualityPicker(selection: Binding(get: { quality ?? app.defaults.quality }, set: { quality = $0 }),
                              showsLabel: false)
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonBorderShape(.capsule)
                .help("Choose an image file from your Mac as a version for this box.")
                .accessibilityLabel("Choose Image…")
                .disabled(!document.isEditable)
                Spacer(minLength: 0)
            }
            Toggle("Include story text", isOn: Binding(get: { includeStoryText ?? app.defaults.includeStoryText },
                                                       set: { includeStoryText = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
            ComposerSendRow(modelName: app.defaultModelName, estimate: app.isOnline ? estimate : nil) {
                Button(!app.isOnline ? "Offline" : (number.map { "Refine Version \($0)" } ?? "Generate")) {
                    generate(refining: base)
                }
                .buttonStyle(.crayon)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!document.isEditable || !app.isOnline || !app.hasOpenAIKey
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            GenerationSetupNotes()
        }
    }

    /// "Reference another image…" and the chips of what's attached to the next request.
    private var attachments: some View {
        WrappingRow(spacing: 6, lineSpacing: 6) {
            Button {
                showReferencePicker = true
            } label: {
                Label("Reference Another Image…", systemImage: "paperclip")
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .disabled(!document.isEditable)
            ForEach(liveAttached, id: \.self) { ref in
                HStack(spacing: 3) {
                    Text(ReferenceSources.chipLabel(ref, in: content) ?? "Image").lineLimit(1)
                        .foregroundStyle(Crayon.ink)
                    Button {
                        attached.removeAll { $0 == ref }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Crayon.sky)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove reference")
                }
                .font(Crayon.font(.caption, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Crayon.sky.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Crayon.sky.opacity(0.45), lineWidth: 1))
            }
        }
    }

    private struct EstimateKey: Equatable {
        var prompt: String
        var quality: QualityLevel
        var story: Bool
        var base: VersionID?
        var attached: [VersionRef]
        var model: String
    }

    private func generate(refining base: VersionID?) {
        guard document.isEditable, app.hasOpenAIKey, app.isOnline,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let intent = app.generationIntent(prompt: storedPrompt, quality: quality ?? app.defaults.quality,
                                          includeStoryText: storyText, refines: base,
                                          attachedReferences: liveAttached)
        checkThenPerform(.generate(intent))
    }

    /// "Regenerate with Same Settings" goes through the same checks as Generate.
    private func regenerate(_ version: Version) {
        guard document.isEditable, app.hasOpenAIKey, app.isOnline, version.provenance != nil else { return }
        checkThenPerform(.regenerate(version))
    }

    /// The real-person notice first (once per provider and book, A §11), then the cost decision.
    private func checkThenPerform(_ action: PendingGeneration) {
        confirmFlow.start(action)
    }

    private var confirmFlow: GenerationConfirmFlow<PendingGeneration> {
        GenerationConfirmFlow(app: app, document: document, pending: $confirmation,
                              notice: { noticeProvider(for: $0) },
                              estimate: { costEstimate(for: $0) }, perform: { perform($0) },
                              question: { $0.kind.question })
    }

    /// The provider whose real-person notice `action` needs first; nil = none.
    private func noticeProvider(for action: PendingGeneration) -> ProviderID? {
        switch action {
        case let .checkConsistency(_, versionID):
            app.realPersonNoticeNeededForCheck(bookID: document.id, versionID: versionID)
        case let .generate(intent), let .fixConsistency(intent):
            app.realPersonNoticeNeeded(intent: intent, target: target, in: document)
        case let .regionEdit(request):
            app.realPersonNoticeNeeded(intent: request.intent, target: target, in: document)
        case let .regenerate(version):
            version.provenance.flatMap { app.realPersonNoticeNeeded(intent: $0.intent, target: target, in: document) }
        }
    }

    /// The estimate the cost decision for `action` is made on.
    private func costEstimate(for action: PendingGeneration) -> CostEstimate {
        switch action {
        case let .generate(intent), let .fixConsistency(intent):
            app.estimate(for: intent, target: target, in: document)
        case let .regenerate(version):
            app.regenerateEstimate(version, target: target, in: document) ?? .unknown
        case let .regionEdit(request):
            app.estimate(for: request.intent, target: target, in: document)
        case let .checkConsistency(sessionID, versionID):
            app.consistencyCheckEstimate(bookID: document.id, sessionID: sessionID, versionID: versionID)
        }
    }

    private func perform(_ action: PendingGeneration) {
        guard app.hasOpenAIKey else { return }
        switch action {
        case let .generate(intent):
            if app.enqueueGeneration(intent, target: target, in: document) {
                prompt = ""
                attached = []
            }
        case let .regenerate(version):
            app.regenerate(version, target: target, in: document)
        case let .fixConsistency(intent):
            app.enqueueGeneration(intent, target: target, in: document)
        case let .checkConsistency(sessionID, versionID):
            app.checkConsistency(bookID: document.id, sessionID: sessionID, versionID: versionID)
        case let .regionEdit(request):
            let target = target
            let document = document
            Task {
                do throws(RegionEditRefusal) {
                    _ = try await app.generateRegionEdit(
                        prompt: request.intent.messageText, quality: request.intent.quality,
                        includeStoryText: request.intent.includeStoryText, refines: request.version.id,
                        drawing: request.drawing, attachedReferences: request.intent.attachedReferences,
                        target: target, in: document)
                } catch {
                    problem = error.message
                }
            }
        }
    }

    private struct RegionEditSubject: Identifiable {
        let id = UUID()
        var version: Version
        var imageData: Data
    }

    private struct RegionEditRequest: Sendable {
        var version: Version
        var drawing: RegionMaskDrawing
        /// The prompt and settings; `generateRegionEdit` adds the mask.
        var intent: GenerationIntent
    }

    private enum PendingGeneration: Sendable {
        var kind: CostConfirmKind {
            switch self {
            case .generate, .regenerate: .generate
            case .regionEdit: .regionEdit
            case .fixConsistency: .fixConsistency
            case .checkConsistency: .checkConsistency
            }
        }

        case generate(GenerationIntent)
        case regenerate(Version)
        case regionEdit(RegionEditRequest)
        /// Phase 12: the one-click consistency fix (a refinement with its correction message).
        case fixConsistency(GenerationIntent)
        /// Phase 12: an on-demand check of one version.
        case checkConsistency(session: SessionID, version: VersionID)
    }
}

/// The shape of a chat bubble in the session thread: rounded, with a small "tail" corner.
enum ThreadBubble {
    static let shape = UnevenRoundedRectangle(topLeadingRadius: Crayon.cornerRadius,
                                              bottomLeadingRadius: 4,
                                              bottomTrailingRadius: Crayon.cornerRadius,
                                              topTrailingRadius: Crayon.cornerRadius,
                                              style: .continuous)
}

/// The availability text for "Edit Region…" (PD §8.6: unavailable, with a short explanation).
enum RegionEditEntry {
    static func unavailableMessage(isEditable: Bool, isOnline: Bool, hasKey: Bool,
                                   refusal: RegionEditRefusal?) -> String? {
        if !isEditable { return RegionEditRefusal.readOnly.message }
        if let refusal { return refusal.message }
        if !isOnline { return UnavailableText.offline }
        if !hasKey { return UnavailableText.noKey }
        return nil
    }
}

/// Which request a cost confirmation guards, so its button names the action (not always "Generate").
enum CostConfirmKind: Equatable {
    case generate, regionEdit, fixConsistency, checkConsistency, textStyle, repaint

    var buttonTitle: String {
        switch self {
        case .generate: "Generate"
        case .regionEdit: "Edit Region"
        case .fixConsistency: "Fix"
        case .checkConsistency: "Check"
        case .textStyle: "Style"
        case .repaint: "Repaint"
        }
    }

    /// The cost alert's closing question, without its "?" (`CostText.requestAlert`).
    var question: String {
        switch self {
        case .generate: "Generate this picture"
        case .regionEdit: "Edit this region"
        case .fixConsistency: "Fix this picture"
        case .checkConsistency: "Check this picture"
        case .textStyle: "Style this text"
        case .repaint: "Repaint this decoration"
        }
    }
}

/// The panel's pure lookups (testable without a view).
enum SessionPanelState {
    /// The owner's session. An asset whose session file is missing (a legacy book) gets an
    /// empty stand-in, so the panel shows its composer; the first message or import creates
    /// the real one. Nil when the box or asset is gone.
    static func session(for owner: SessionOwner, in content: BookContent) -> Session? {
        guard let id = BookMutations.sessionID(for: owner, in: content) else { return nil }
        if let session = content.sessions[id] { return session }
        return owner.assetID == nil ? nil : Session(id: id, owner: owner)
    }

    /// The placed version (page boxes) or the asset's chosen image.
    static func placedVersion(for owner: SessionOwner, in content: BookContent) -> VersionID? {
        switch owner {
        case let .pageBox(page, box): content.pages[page]?.images[box]?.placement?.versionID
        case let .asset(asset): content.assets[asset]?.chosen
        case let .textBox(page, box): content.pages[page]?.textStyles[box]?.versionID
        }
    }
}
