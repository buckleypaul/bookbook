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

/// The asset editor's Generate row (PD §8.3): quality, model, cost estimate, Import Image… and
/// Generate / Regenerate, which makes a fresh picture from the description. The newest
/// request's status shows below. Each generation checks the real-person notice, then the cost.
/// The new picture becomes the asset's image when it arrives.
struct AssetImageControls: View {
    @Environment(AppModel.self) private var app
    let document: BookDocument
    let content: BookContent
    let asset: Asset
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
    @State private var question: PendingQuestion?
    @State private var laterQuestions: [PendingQuestion] = []
    @State private var problem: String?

    private var target: GenerationTarget { GenerationTarget(owner: asset.owner) }
    private var session: Session? { SessionPanelState.session(for: asset.owner, in: content) }
    private var prompt: String { AssetGeneration.prompt(from: description) }
    private var chosenQuality: QualityLevel { quality ?? app.defaults.quality }

    var body: some View {
        let latest = AssetGeneration.latestRequest(in: session)
        let busy = latest.map { AssetGeneration.isBusy(app.status(of: $0)) } ?? false
        VStack(alignment: .leading, spacing: 8) {
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
                .help(prompt.isEmpty ? "Write a description first" : "Make a new picture from the description")
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
        .onChange(of: EstimateKey(prompt: prompt, quality: chosenQuality, model: app.defaults.model),
                  initial: true) { _, key in
            estimate = app.estimate(for: makeIntent(prompt: key.prompt, quality: key.quality), target: target,
                                    in: document)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): ask(about: [url])
            case let .failure(error): problem = error.localizedDescription
            }
        }
        .sheet(item: $question, onDismiss: nextQuestion) { pending in
            RealPersonQuestionSheet(fileName: pending.url.lastPathComponent, defaultAnswer: pending.defaultAnswer,
                                    onAnswer: { answer in
                                        question = nil
                                        importImage(pending.url, depictsRealPerson: answer)
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
    private func ask(about urls: [URL]) {
        Task {
            for url in urls {
                let pending = PendingQuestion(url: url, defaultAnswer: await BookDocument.looksCameraOriginated(url))
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
    }
}
