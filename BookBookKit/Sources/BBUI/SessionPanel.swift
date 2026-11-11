import BBAI
import AppKit
import BBAICore
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// The session panel (PD §8.6) for any session owner: an image box, an asset reference slot or
/// a character-sheet item. The thread, the version strip, Version details, and the composer.
///
/// - Page boxes: clicking a version puts it on the page (undoable) and selects it. The composer
///   has `@mention` autocomplete, the page's asset checklist, "Reference another image…" and the
///   story-text toggle.
/// - Asset owners (through `AssetSessionHost`): clicking a version makes it the slot's or
///   item's reference ("Choose Reference", undoable). Imports ask the real-person question.
///
/// The panel keeps a selected version (default: the placed or chosen one); Details and
/// refinement use it. Every generation checks the real-person notice, then the cost.
struct SessionPanel: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let owner: SessionOwner
    let images: ImageCache
    /// Asset sessions: a request (from the asset editor's Import button) to open the file picker.
    let importRequest: Binding<SessionOwner?>?

    init(document: BookDocument, content: BookContent, pageID: PageID, boxID: BoxID, images: ImageCache) {
        self.init(document: document, content: content, owner: .pageBox(pageID, boxID), images: images)
    }

    init(document: BookDocument, content: BookContent, owner: SessionOwner, images: ImageCache,
         importRequest: Binding<SessionOwner?>? = nil) {
        self.document = document
        self.content = content
        self.owner = owner
        self.images = images
        self.importRequest = importRequest
    }

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
    @State private var costAlert: String?
    @State private var pendingAction: PendingGeneration?
    @State private var regionEditing: RegionEditSubject?
    /// The real-person notice waiting for Continue/Cancel, and the action it guards.
    @State private var notice: PendingNotice?
    /// The import waiting for the real-person answer, and the ones queued behind it.
    @State private var question: PendingQuestion?
    @State private var laterQuestions: [PendingQuestion] = []

    private var target: GenerationTarget {
        switch owner {
        case let .pageBox(page, box): .pageBox(page, box)
        case let .assetReference(asset, slot): .assetReference(asset, slot)
        case let .sheetItem(asset, item): .sheetItem(asset, item)
        }
    }

    private var pageBox: (page: PageID, box: BoxID)? {
        if case let .pageBox(page, box) = owner { return (page, box) }
        return nil
    }

    private var isAsset: Bool { owner.assetID != nil }

    private var session: Session? {
        BookMutations.sessionID(for: owner, in: content).flatMap { content.sessions[$0] }
    }

    /// The placed version (page boxes) or the chosen reference (asset owners).
    private var placedID: VersionID? {
        switch owner {
        case let .pageBox(page, box): content.pages[page]?.images[box]?.placement?.versionID
        case let .assetReference(asset, slot): content.assets[asset]?.references.first { $0.id == slot }?.chosen
        case let .sheetItem(asset, item): content.assets[asset]?.sheet?.items.first { $0.id == item }?.chosen
        }
    }

    /// The version Details and refinement use: the selection if it still exists, else the placed one.
    private func baseID(_ session: Session) -> VersionID? {
        if let selectedVersion, session.version(selectedVersion) != nil { return selectedVersion }
        // After Reset Session → Keep Versions the thread starts fresh (PD §8.6): no refining the placed
        // version until the user clicks one.
        if freshEpoch == session.resetEpoch { return nil }
        return placedID.flatMap { session.version($0)?.id }
    }

    private var storyText: Bool { isAsset ? false : (includeStoryText ?? app.defaults.includeStoryText) }

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
                if let pageBox {
                    AssetChecklistView(document: document, content: content, pageID: pageBox.page)
                        .padding(.horizontal)
                        .padding(.top, 10)
                }
                composer(session)
                    .crayonCard(padding: 12)
                    .padding(12)
            } else {
                CrayonEmptyState("No Session", systemImage: "photo", color: Crayon.sky,
                                 message: isAsset ? "This reference has no session."
                                     : "This image box has no session.")
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
        .onAppear(perform: takeImportRequest)
        .onChange(of: importRequest?.wrappedValue) { takeImportRequest() }
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
        .sheet(item: $question, onDismiss: nextQuestion) { pending in
            RealPersonQuestionSheet(fileName: pending.url.lastPathComponent, defaultAnswer: pending.defaultAnswer,
                                    onAnswer: { answer in
                                        question = nil
                                        importAsset(pending.url, depictsRealPerson: answer)
                                    },
                                    onCancel: { question = nil })
        }
        .sheet(item: $notice) { pending in
            RealPersonNoticeSheet(provider: pending.provider,
                                  onContinue: {
                                      notice = nil
                                      app.acknowledgeRealPersonNotice(pending.provider, in: document)
                                      confirmCostThenPerform(pending.action)
                                  },
                                  onCancel: { notice = nil })
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
            Text(isAsset ? "The chat clears. Discarding versions also clears the chosen image. This can't be undone."
                 : "The chat clears. Discarding versions also empties this box. This can't be undone.")
        }
        .alert("Confirm Cost", isPresented: $costAlert.isPresent()) {
            Button(pendingAction?.kind.buttonTitle ?? "Generate") {
                if let pending = pendingAction { perform(pending) }
                pendingAction = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(costAlert ?? "")
        }
        .alert("Couldn't Complete That", isPresented: $problem.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// Opens the file picker when the asset editor asked to import into this owner.
    private func takeImportRequest() {
        guard let request = importRequest, request.wrappedValue == owner else { return }
        request.wrappedValue = nil
        if document.isEditable, session != nil { showImporter = true }
    }

    private var deleteMessage: String {
        let placed = pendingDelete != nil && pendingDelete == placedID
        let note = isAsset ? "It is the chosen image, so nothing will be chosen. "
            : "It is on the page, so the box will be empty. "
        return (placed ? note : "") + "This can't be undone."
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(headerColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1)
                .accessibilityHidden(true)
            Text(isAsset ? document.ownerLabel(owner) : "Session")
                .font(Crayon.font(.headline, weight: .heavy))
                .foregroundStyle(Crayon.ink)
            Spacer()
            Menu {
                Button("Choose Image…") { showImporter = true }
                Divider()
                Button("Reset Session…", role: .destructive) { confirmReset = true }
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

    /// The header dot: the asset's own colour, or sky for a page box.
    private var headerColor: Color {
        owner.assetID.map { Crayon.color(forKey: $0.rawValue.uuidString) } ?? Crayon.sky
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
                Text(isAsset ? "Describe the picture, then press Generate. Or drop in your own image."
                     : "Describe the picture for this box, then press Generate. Or drop in your own image.")
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
                statusLine(app.status(of: message), message: message, session: session)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: MessageStatus, message: Message, session: Session) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .waiting:
            StatusPill(color: Crayon.sunflower) {
                ProgressView().controlSize(.small)
            } label: {
                Text("Waiting in the queue…")
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
            if let advice = failedEntry(for: message).flatMap({ app.advice(for: $0) }) {
                FailureAdviceView(advice: advice)
            } else {
                StatusPill(color: Crayon.tomato, systemImage: "exclamationmark.triangle.fill") {
                    Text(ProviderErrorText.message(for: error))
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
            if let number = session.versionNumber(versionID) {
                StatusPill(color: Crayon.grass, systemImage: "photo") {
                    Text("Version \(number)")
                }
            }
        }
    }

    private func failedEntry(for message: Message) -> QueueEntry? {
        let snapshot = app.queueSnapshot
        if let id = message.queueItemID, let entry = snapshot.entry(for: id) { return entry }
        return snapshot.entries.first { $0.item.messageID == message.id }
    }

    // MARK: Versions

    private func versions(_ session: Session) -> some View {
        let base = baseID(session)
        return VStack(alignment: .leading, spacing: 8) {
            CrayonHeader("Versions", color: Crayon.grape)
            VersionStrip(session: session, placedID: placedID,
                         placedHelp: owner.assetID == nil ? "On the page" : "Chosen", selectedID: base,
                         store: document.store,
                         onChoose: { choose($0) },
                         onToggleStar: { document.setStarred(!$0.starred, version: $0.id, owner: owner) },
                         onExport: { export($0, in: session) },
                         onEditRegion: { startRegionEdit($0) },
                         regionEditReason: { regionEditReason(for: $0) },
                         onDelete: { pendingDelete = $0.id },
                         isChecking: { app.isConsistencyCheckPending(versionID: $0.id) })
            if let base, let version = session.version(base) {
                consistencySection(version, session: session)
                let reason = regionEditReason(for: version)
                HStack {
                    Button("Export Image…") { export(version, in: session) }
                    Button("Edit Region…") { startRegionEdit(version) }
                        .disabled(reason != nil)
                        .help(reason ?? "Select an area of this picture and describe the change.")
                    Button("Delete…", role: .destructive) { pendingDelete = version.id }
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(Crayon.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
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
                            .foregroundStyle(Crayon.ink, Crayon.sunflower)
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
                            in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius + 2, style: .continuous)
                    .strokeBorder(Crayon.sunflower.opacity(0.7), lineWidth: 1.5))
            } else if let report = version.consistency {
                StatusPill(color: Crayon.grass, systemImage: "checkmark.seal") {
                    Text(ConsistencyPresentation.resultText(report))
                }
            }
            if !checking, let entry = app.consistencyCheckEntry(versionID: version.id),
               case .failed = entry.state, let advice = app.advice(for: entry) {
                FailureAdviceView(advice: advice)
            }
            HStack {
                if let report = version.consistency, report.showsWarning {
                    Button("Fix") { startConsistencyFix(version, sessionID: session.id) }
                        .disabled(!document.isEditable || !app.hasOpenAIKey || !app.isOnline)
                        .help("Refine this picture to match the references.")
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
                .help(reason ?? "Compare this picture with the references of the assets in it.")
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            if let reason, !checking {
                Text(reason).font(.caption).foregroundStyle(Crayon.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
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
        switch owner {
        case let .pageBox(page, box): document.perform(.chooseVersion(page: page, box: box, version: version.id))
        case .assetReference, .sheetItem: document.chooseReference(version.id, for: owner)
        }
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
        let name: String
        if let pageBox {
            name = VersionExport.suggestedName(book: content.book.title, page: pageBox.page, in: content,
                                               number: number, ref: version.image)
        } else {
            let label = document.ownerLabel(owner).replacingOccurrences(of: " · ", with: " ")
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            name = "\(label) v\(number).\(version.image.fileExtension)"
        }
        if let text = VersionExport.run(ref: version.image, from: document.store.imageURL(for: version.image),
                                        suggestedName: name) {
            problem = text
        }
    }

    private func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let document = document
        if isAsset {
            // Ask "Is this a photo of a real person?" for each file, defaulting from EXIF.
            Task {
                for url in urls {
                    let pending = PendingQuestion(url: url, defaultAnswer: await BookDocument.looksCameraOriginated(url))
                    if question == nil { question = pending } else { laterQuestions.append(pending) }
                }
            }
            return
        }
        guard let pageBox else { return }
        Task {
            for url in urls {
                do {
                    selectedVersion = try await document.importImage(from: url, page: pageBox.page, box: pageBox.box)
                } catch {
                    problem = ImageImportFailure.message(for: error)
                }
            }
        }
    }

    private func nextQuestion() {
        if question == nil, !laterQuestions.isEmpty { question = laterQuestions.removeFirst() }
    }

    private func importAsset(_ url: URL, depictsRealPerson: Bool) {
        let document = document, owner = owner
        Task {
            do {
                selectedVersion = try await document.importAssetImage(from: url, owner: owner,
                                                                      depictsRealPerson: depictsRealPerson)
            } catch {
                problem = ImageImportFailure.message(for: error)
            }
        }
    }

    @ViewBuilder
    private func details(_ session: Session) -> some View {
        if let id = baseID(session) ?? session.versions.last?.id, let version = session.version(id) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VersionDetailsGrid(version: version, session: session, bookID: document.id, assets: content.assets)
                if version.provenance != nil {
                    Button("Regenerate with Same Settings") {
                        regenerate(version)
                    }
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                    .disabled(!app.hasOpenAIKey || !app.isOnline)
                    .padding(.top, 6)
                }
            } label: {
                Text("Version details")
                    .font(Crayon.font(.subheadline, weight: .bold))
                    .foregroundStyle(Crayon.ink)
            }
            .padding(12)
            .background(Crayon.paperDeep,
                        in: RoundedRectangle(cornerRadius: Crayon.smallCornerRadius + 2, style: .continuous))
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
        let query = isAsset ? nil : MentionCompletion.activeQuery(in: prompt)
        let suggestions = query.map { MentionCompletion.suggestions(for: $0.text, assets: Array(content.assets.values)) }
            ?? []
        return VStack(alignment: .leading, spacing: 8) {
            TextField(number.map { "Describe the change to version \($0)" }
                      ?? (isAsset ? "Describe the picture" : "Describe the picture (type @ to mention an asset)"),
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
            if !isAsset {
                attachments
            }
            HStack {
                Picker("Quality", selection: Binding(get: { quality ?? app.defaults.quality },
                                                     set: { quality = $0 })) {
                    ForEach(QualityLevel.allCases, id: \.self) {
                        Text(VersionDetailsContent.qualityName($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Button {
                    showImporter = true
                } label: {
                    Label("Choose Image…", systemImage: "photo.badge.plus")
                }
                .buttonBorderShape(.capsule)
                .help(isAsset ? "Use an image file from your Mac as a version of this reference"
                      : "Use an image file from your Mac as a version for this box")
                .disabled(!document.isEditable)
                Spacer()
                if !isAsset {
                    Toggle("Include story text", isOn: Binding(get: { includeStoryText ?? app.defaults.includeStoryText },
                                                               set: { includeStoryText = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            HStack {
                Text(app.defaultModelName).font(Crayon.font(.caption, weight: .medium)).foregroundStyle(Crayon.inkSoft)
                Spacer()
                if app.isOnline {
                    Text(CostText.estimate(estimate))
                        .font(Crayon.font(.caption, weight: .bold))
                        .foregroundStyle(Crayon.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Crayon.grass.opacity(0.18), in: Capsule())
                        .accessibilityLabel("Estimated cost: \(CostText.estimate(estimate))")
                }
                Button(!app.isOnline ? "Offline" : (number.map { "Refine Version \($0)" } ?? "Generate")) {
                    generate(refining: base)
                }
                    .buttonStyle(.crayon)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.isOnline || !app.hasOpenAIKey
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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

    /// "Reference another image…" and the chips of what's attached to the next request.
    private var attachments: some View {
        HStack(spacing: 6) {
            Button {
                showReferencePicker = true
            } label: {
                Label("Reference Another Image…", systemImage: "paperclip")
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
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
        guard app.hasOpenAIKey, app.isOnline,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let intent = app.generationIntent(prompt: storedPrompt, quality: quality ?? app.defaults.quality,
                                          includeStoryText: storyText, refines: base,
                                          attachedReferences: liveAttached)
        checkThenPerform(.generate(intent))
    }

    /// "Regenerate with Same Settings" goes through the same checks as Generate.
    private func regenerate(_ version: Version) {
        guard app.hasOpenAIKey, app.isOnline, version.provenance != nil else { return }
        checkThenPerform(.regenerate(version))
    }

    /// The real-person notice first (once per provider and book, A §11), then the cost decision.
    private func checkThenPerform(_ action: PendingGeneration) {
        if case let .checkConsistency(_, versionID) = action {
            if let provider = app.realPersonNoticeNeededForCheck(bookID: document.id, versionID: versionID) {
                notice = PendingNotice(provider: provider, action: action)
            } else {
                confirmCostThenPerform(action)
            }
        } else if let provider = app.realPersonNoticeNeeded(intent: action.intent, target: target, in: document) {
            notice = PendingNotice(provider: provider, action: action)
        } else {
            confirmCostThenPerform(action)
        }
    }

    /// Asks `costDecision` first; a confirmation or budget warning is shown but never blocks (A §7.10).
    private func confirmCostThenPerform(_ action: PendingGeneration) {
        let current: CostEstimate
        switch action {
        case let .generate(intent), let .fixConsistency(intent):
            current = app.estimate(for: intent, target: target, in: document)
        case let .regenerate(version):
            current = app.regenerateEstimate(version, target: target, in: document) ?? .unknown
        case let .regionEdit(request):
            current = app.estimate(for: request.intent, target: target, in: document)
        case let .checkConsistency(sessionID, versionID):
            current = app.consistencyCheckEstimate(bookID: document.id, sessionID: sessionID, versionID: versionID)
        }
        Task {
            let (decision, spent) = await app.costDecisionAndSpent(for: current, in: document)
            guard decision.needsConfirmation || decision.overBudget else {
                perform(action)
                return
            }
            if let text = CostText.requestAlert(estimate: current, decision: decision, spent: spent,
                                                budget: document.content.book.budget) {
                pendingAction = action
                costAlert = text
            } else {
                perform(action)
            }
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

    private struct RegionEditRequest {
        var version: Version
        var drawing: RegionMaskDrawing
        /// The prompt and settings; `generateRegionEdit` adds the mask.
        var intent: GenerationIntent
    }

    private enum PendingGeneration {
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

        var intent: GenerationIntent {
            switch self {
            case let .generate(intent): intent
            case let .regionEdit(request):
                request.intent
            case let .fixConsistency(intent):
                intent
            case .checkConsistency:
                GenerationIntent(messageText: "", provider: .openai, model: "", quality: .standard)
            case let .regenerate(version):
                version.provenance?.intent ?? GenerationIntent(messageText: "", provider: .openai, model: "",
                                                               quality: .standard)
            }
        }
    }

    private struct PendingNotice: Identifiable {
        let id = UUID()
        var provider: ProviderID
        var action: PendingGeneration
    }

    private struct PendingQuestion: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var defaultAnswer: Bool
    }
}

/// Version details rows, with the Cost row loaded from the book's ledger (`Provenance.cost`).
private struct VersionDetailsGrid: View {
    @Environment(AppModel.self) private var app
    let version: Version
    let session: Session
    let bookID: BookID
    let assets: [AssetID: Asset]
    @State private var cost: CostRecord?
    @State private var checkCost: CostRecord?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(VersionDetailsContent.rows(for: version, in: session, cost: cost, assets: assets, checkCost: checkCost), id: \.self) { row in
                GridRow {
                    Text(row.label).fontWeight(.semibold).foregroundStyle(Crayon.inkSoft).gridColumnAlignment(.trailing)
                    Text(row.value).foregroundStyle(Crayon.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
        .padding(.top, 6)
        .task(id: [version.provenance?.cost, version.consistency?.cost]) {
            let records = await app.costRecords([version.provenance?.cost, version.consistency?.cost], in: bookID)
            cost = records[0]
            checkCost = records[1]
        }
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

/// A status line in the thread: a soft colour wash with a coloured symbol and ink text, so the
/// state reads at a glance and the text stays legible in both appearances.
private struct StatusPill<Icon: View, Content: View>: View {
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
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.4), lineWidth: 1))
    }
}

private extension StatusPill where Icon == StatusSymbol {
    init(color: Color, systemImage: String, @ViewBuilder label: () -> Content) {
        self.init(color: color, icon: { StatusSymbol(name: systemImage) }, label: label)
    }
}

/// A status symbol that VoiceOver skips, as a `Label`'s icon is.
private struct StatusSymbol: View {
    let name: String
    var body: some View { Image(systemName: name).accessibilityHidden(true) }
}

/// The availability text for "Edit Region…" (PD §8.6: unavailable, with a short explanation).
enum RegionEditEntry {
    static func unavailableMessage(isEditable: Bool, isOnline: Bool, hasKey: Bool,
                                   refusal: RegionEditRefusal?) -> String? {
        if !isEditable { return RegionEditRefusal.readOnly.message }
        if let refusal { return refusal.message }
        if !isOnline { return "Region editing needs an internet connection." }
        if !hasKey { return "Add your OpenAI API key in Settings to edit a region." }
        return nil
    }
}

/// Which request a cost confirmation guards, so its button names the action (not always "Generate").
enum CostConfirmKind: Equatable {
    case generate, regionEdit, fixConsistency, checkConsistency

    var buttonTitle: String {
        switch self {
        case .generate: "Generate"
        case .regionEdit: "Edit"
        case .fixConsistency: "Fix"
        case .checkConsistency: "Check"
        }
    }
}
