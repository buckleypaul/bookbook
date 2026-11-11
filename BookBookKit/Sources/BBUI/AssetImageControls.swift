import BBAI
import BBAICore
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// Pure rules behind the asset editor's Generate controls (testable without a view).
enum AssetGeneration {
    /// "Generate" until the asset has an image, then "Regenerate".
    static func buttonTitle(hasImage: Bool) -> String { hasImage ? "Regenerate" : "Generate" }

    /// The request text: the description, trimmed. Empty means Generate is unavailable.
    static func prompt(from description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The request text when the asset may have a reference photo (PD §8.3): the description, or,
    /// when that's empty and there's a photo, a short request to draw the asset from the photo.
    static func prompt(from description: String, name: String, hasReferencePhoto: Bool) -> String {
        let text = prompt(from: description)
        guard text.isEmpty, hasReferencePhoto else { return text }
        return "Draw \(name) from the reference photo."
    }

    /// Generate's tooltip.
    static func generateHelp(prompt: String, hasReferencePhoto: Bool) -> String {
        if prompt.isEmpty { return "Write a description or add a reference photo first" }
        return hasReferencePhoto ? "Make a new picture from the description and the reference photo"
            : "Make a new picture from the description"
    }

    /// The reference photo row's explanation.
    static func referencePhotoHelp(name: String, hasPhoto: Bool) -> String {
        hasPhoto
            ? "Generate draws \(name) from this photo, in the book's style. The photo is sent only when you press "
            + "Generate here; pages get the picture it makes."
            : "Optional: add a photo (of a real person, a pet or a toy) and Generate draws \(name) from it, "
            + "in the book's style."
    }

    /// A fresh image of the asset from its description (PD §8.3): never a refinement of the
    /// current image, no story text and no consistency check.
    static func intent(_ base: GenerationIntent) -> GenerationIntent {
        var intent = base
        intent.refines = nil
        intent.attachedReferences = []
        intent.includeStoryText = false
        intent.checkConsistency = false
        return intent
    }

    /// The newest request in the asset's session: its status is the one the editor shows.
    static func latestRequest(in session: Session?) -> Message? {
        session?.visibleMessages.last { $0.role == .user }
    }

    /// True while the newest request is waiting or running (Generate is unavailable meanwhile).
    static func isBusy(_ status: MessageStatus) -> Bool {
        switch status {
        case .waiting, .running: true
        default: false
        }
    }
}

/// The asset editor's Generate row (PD §8.3): the optional reference photo, quality, model, cost
/// estimate, Import Image… and Generate / Regenerate, which makes a fresh picture from the
/// description (and the reference photo, when there is one). The newest
/// request's status shows below. Each generation checks the real-person notice, then the cost.
/// The new picture becomes the asset's image when it arrives.
struct AssetImageControls: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let asset: Asset
    let images: ImageCache
    /// The description as typed (it may not be committed yet).
    let description: String
    /// Commits the typed description (one undo step) before a generation uses it.
    let commitDescription: () -> Void

    @State private var quality: QualityLevel?
    @State private var estimate = CostEstimate.unknown
    @State private var costAlert: String?
    @State private var pendingIntent: GenerationIntent?
    @State private var notice: PendingNotice?
    @State private var showImporter = false
    @State private var showPhotoImporter = false
    @State private var question: PendingQuestion?
    @State private var laterQuestions: [PendingQuestion] = []
    @State private var problem: String?

    private var target: GenerationTarget { GenerationTarget(owner: asset.owner) }
    private var session: Session? { SessionPanelState.session(for: asset.owner, in: content) }
    private var prompt: String {
        AssetGeneration.prompt(from: description, name: asset.name, hasReferencePhoto: asset.referencePhoto != nil)
    }
    private var chosenQuality: QualityLevel { quality ?? app.defaults.quality }

    var body: some View {
        let latest = AssetGeneration.latestRequest(in: session)
        let busy = latest.map { AssetGeneration.isBusy(app.status(of: $0)) } ?? false
        VStack(alignment: .leading, spacing: 8) {
            referencePhotoRow
            HStack(spacing: 8) {
                Picker("Quality", selection: Binding(get: { chosenQuality }, set: { quality = $0 })) {
                    ForEach(QualityLevel.allCases, id: \.self) {
                        Text(VersionDetailsContent.qualityName($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Text(app.defaultModelName)
                    .font(Crayon.font(.caption, weight: .medium))
                    .foregroundStyle(Crayon.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    showImporter = true
                } label: {
                    Label("Import Image…", systemImage: "photo.badge.plus")
                }
                .buttonBorderShape(.capsule)
                .help("Use an image file from your Mac as \(asset.name)'s image")
                .disabled(!document.isEditable)
                if app.isOnline {
                    Text(CostText.estimate(estimate))
                        .font(Crayon.font(.caption, weight: .bold))
                        .foregroundStyle(Crayon.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Crayon.grass.opacity(0.18), in: Capsule())
                        .accessibilityLabel("Estimated cost: \(CostText.estimate(estimate))")
                }
                Button(app.isOnline ? AssetGeneration.buttonTitle(hasImage: asset.chosen != nil) : "Offline") {
                    generate()
                }
                .buttonStyle(.crayon)
                .keyboardShortcut(.return, modifiers: .command)
                .help(AssetGeneration.generateHelp(prompt: prompt, hasReferencePhoto: asset.referencePhoto != nil))
                .disabled(!document.isEditable || !app.isOnline || !app.hasOpenAIKey || prompt.isEmpty || busy)
            }
            if let latest, let session {
                MessageStatusLine(message: latest, session: session, showsProduced: false)
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
        .onChange(of: EstimateKey(prompt: prompt, quality: chosenQuality, model: app.defaults.model,
                                  photo: asset.referencePhoto),
                  initial: true) { _, key in
            estimate = app.estimate(for: makeIntent(prompt: key.prompt, quality: key.quality), target: target,
                                    in: document)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): ask(about: [url], forPhoto: false)
            case let .failure(error): problem = error.localizedDescription
            }
        }
        .background {
            // A second importer on its own view: SwiftUI keeps one `fileImporter` per view.
            Color.clear.fileImporter(isPresented: $showPhotoImporter, allowedContentTypes: [.image]) { result in
                switch result {
                case let .success(url): ask(about: [url], forPhoto: true)
                case let .failure(error): problem = error.localizedDescription
                }
            }
        }
        .sheet(item: $question, onDismiss: nextQuestion) { pending in
            RealPersonQuestionSheet(fileName: pending.url.lastPathComponent, defaultAnswer: pending.defaultAnswer,
                                    onAnswer: { answer in
                                        question = nil
                                        if pending.forPhoto {
                                            setReferencePhoto(pending.url, depictsRealPerson: answer)
                                        } else {
                                            importImage(pending.url, depictsRealPerson: answer)
                                        }
                                    },
                                    onCancel: { question = nil })
        }
        .sheet(item: $notice) { pending in
            RealPersonNoticeSheet(provider: pending.provider,
                                  onContinue: {
                                      notice = nil
                                      app.acknowledgeRealPersonNotice(pending.provider, in: document)
                                      confirmCostThenEnqueue(pending.intent)
                                  },
                                  onCancel: { notice = nil })
        }
        .alert("Confirm Cost", isPresented: $costAlert.isPresent()) {
            Button(CostConfirmKind.generate.buttonTitle) {
                if let intent = pendingIntent { enqueue(intent) }
                pendingIntent = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingIntent = nil }
        } message: {
            Text(costAlert ?? "")
        }
        .alert("Couldn't Complete That", isPresented: $problem.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Reference photo

    /// The optional photo Generate bases the picture on (PD §8.3): a thumbnail with Replace and
    /// Remove, or an Add button.
    private var referencePhotoRow: some View {
        let photo = asset.referencePhoto
        return HStack(alignment: .center, spacing: 10) {
            if let photo {
                Group {
                    if let cg = images.image(for: photo.image) {
                        Image(decorative: cg, scale: 1).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(Crayon.inkSoft)
                    }
                }
                .frame(width: 56, height: 56)
                .background(Crayon.paperDeep)
                .clipShape(RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous))
                .accessibilityLabel("\(asset.name)'s reference photo")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reference Photo")
                    .font(Crayon.font(.subheadline, weight: .bold))
                    .foregroundStyle(Crayon.ink)
                Text(AssetGeneration.referencePhotoHelp(name: asset.name, hasPhoto: photo != nil))
                    .font(Crayon.font(.caption, weight: .medium))
                    .foregroundStyle(Crayon.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                showPhotoImporter = true
            } label: {
                Label(photo == nil ? "Add Photo…" : "Replace…", systemImage: "person.crop.square.badge.camera")
            }
            .buttonBorderShape(.capsule)
            .help("Choose a photo for Generate to base \(asset.name) on")
            .disabled(!document.isEditable)
            if photo != nil {
                Button("Remove", systemImage: "xmark.circle") {
                    document.removeAssetReferencePhoto(for: asset.id)
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .help("Stop basing Generate on this photo")
                .disabled(!document.isEditable)
            }
        }
    }

    private func setReferencePhoto(_ url: URL, depictsRealPerson: Bool) {
        let document = document, id = asset.id
        Task {
            do {
                _ = try await document.setAssetReferencePhoto(from: url, for: id, depictsRealPerson: depictsRealPerson)
            } catch {
                problem = ImageImportFailure.message(for: error)
            }
        }
    }

    // MARK: Generate

    private func makeIntent(prompt: String, quality: QualityLevel) -> GenerationIntent {
        AssetGeneration.intent(app.generationIntent(prompt: prompt, quality: quality, includeStoryText: false,
                                                    refines: nil))
    }

    private func generate() {
        guard document.isEditable, app.hasOpenAIKey, app.isOnline, !prompt.isEmpty else { return }
        commitDescription()
        let intent = makeIntent(prompt: prompt, quality: chosenQuality)
        if let provider = app.realPersonNoticeNeeded(intent: intent, target: target, in: document) {
            notice = PendingNotice(provider: provider, intent: intent)
        } else {
            confirmCostThenEnqueue(intent)
        }
    }

    /// Asks `costDecision` first; a confirmation or budget warning is shown but never blocks (A §7.10).
    private func confirmCostThenEnqueue(_ intent: GenerationIntent) {
        let current = app.estimate(for: intent, target: target, in: document)
        Task {
            let (decision, spent) = await app.costDecisionAndSpent(for: current, in: document)
            if decision.needsConfirmation || decision.overBudget,
               let text = CostText.requestAlert(estimate: current, decision: decision, spent: spent,
                                                budget: document.content.book.budget) {
                pendingIntent = intent
                costAlert = text
            } else {
                enqueue(intent)
            }
        }
    }

    private func enqueue(_ intent: GenerationIntent) {
        guard app.hasOpenAIKey else { return }
        app.enqueueGeneration(intent, target: target, in: document)
    }

    // MARK: Import

    /// Asks "Is this a photo of a real person?" for each file, defaulting from EXIF.
    private func ask(about urls: [URL], forPhoto: Bool) {
        Task {
            for url in urls {
                let pending = PendingQuestion(url: url, defaultAnswer: await BookDocument.looksCameraOriginated(url),
                                              forPhoto: forPhoto)
                if question == nil { question = pending } else { laterQuestions.append(pending) }
            }
        }
    }

    private func nextQuestion() {
        if question == nil, !laterQuestions.isEmpty { question = laterQuestions.removeFirst() }
    }

    private func importImage(_ url: URL, depictsRealPerson: Bool) {
        let document = document, owner = asset.owner
        Task {
            do {
                _ = try await document.importAssetImage(from: url, owner: owner, depictsRealPerson: depictsRealPerson)
            } catch {
                problem = ImageImportFailure.message(for: error)
            }
        }
    }

    private struct EstimateKey: Equatable {
        var prompt: String
        var quality: QualityLevel
        var model: String
        var photo: AssetReferencePhoto?
    }

    private struct PendingNotice: Identifiable {
        let id = UUID()
        var provider: ProviderID
        var intent: GenerationIntent
    }

    private struct PendingQuestion: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var defaultAnswer: Bool
        /// The file is for the reference photo rather than the asset's image.
        var forPhoto: Bool
    }
}
