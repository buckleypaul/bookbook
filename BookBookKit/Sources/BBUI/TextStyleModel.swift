import AppKit
import BBAI
import BBAICore
import BBLayout
import BBModel
import BBStore
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One page text box, as the styling UI addresses it.
public struct TextBoxKey: Hashable, Sendable {
    public var page: PageID
    public var box: BoxID
    public init(page: PageID, box: BoxID) {
        self.page = page
        self.box = box
    }
}

/// Where a text box's styling request is (shown in the panel until the decoration is queued).
public enum TextStyleRunState: Equatable, Sendable {
    case idle
    /// The text model is designing the style for this instruction.
    case designing(String)
    /// The design step failed; nothing was queued. `instruction` can be tried again.
    case failed(instruction: String, advice: FailureAdvice, sent: TextStyleCall?)
}

/// The text model call of AI text styling, injectable for tests.
struct TextStyleBackend: Sendable {
    var buildRequest: @Sendable (_ instruction: String, _ boxText: String, _ role: BoxRole?, _ size: PointSize,
                                 _ current: TextStyleSnapshot, _ history: [String], _ styleDescription: String,
                                 _ fonts: [String], _ model: CatalogTextModel) -> TextStyleRequest
    var estimate: @Sendable (TextStyleRequest, PriceList) -> CostEstimate
    var normalize: @Sendable (TextStyleDraft, [String: String], TextStyleSnapshot)
        -> (styling: TextStyling, decorationPrompt: String?, summary: String)

    static let live = TextStyleBackend(
        buildRequest: { instruction, text, role, size, current, history, style, fonts, model in
            TextStylePrompt.request(instruction: instruction, boxText: text, boxRole: role, boxSizePoints: size,
                                    current: current, history: history, styleDescription: style, fonts: fonts,
                                    model: model)
        },
        estimate: { CostEstimator.estimate(textStyle: $0, priceList: $1) },
        normalize: { TextStyleNormalizer.styling(from: $0, fonts: $1, current: $2) })
}

/// AI text styling (PD §8.6, A §7.13), one per book window. A request is two steps: the text
/// model designs the typography and describes a decoration (run here, like the layouts chat),
/// then the decoration is painted by an ordinary queued image request into the box's styling
/// session; a typography-only design makes its version right away.
@MainActor
@Observable
public final class TextStyleModel {
    public let document: BookDocument
    let backend: TextStyleBackend
    private var states: [TextBoxKey: TextStyleRunState] = [:]
    @ObservationIgnored private var tasks: [TextBoxKey: Task<Void, Never>] = [:]

    init(document: BookDocument, backend: TextStyleBackend = .live) {
        self.document = document
        self.backend = backend
    }

    public convenience init(document: BookDocument) {
        self.init(document: document, backend: .live)
    }

    public func state(for key: TextBoxKey) -> TextStyleRunState { states[key] ?? .idle }

    public func isDesigning(_ key: TextBoxKey) -> Bool {
        if case .designing = state(for: key) { true } else { false }
    }

    public func dismissFailure(_ key: TextBoxKey) {
        if case .failed = state(for: key) { states[key] = .idle }
    }

    /// The Settings layout model (text styling uses the same text model).
    public func model(_ app: AppModel) -> CatalogTextModel? {
        app.catalog.textModel(provider: app.textStyleProvider?.id ?? .openai, id: app.preferences.defaultTemplateModelID)
    }

    // MARK: Requests and estimates

    /// The rendered text-model request for `instruction` on the box as it looks now; nil without
    /// an instruction, a model or the box.
    func request(_ instruction: String, for key: TextBoxKey, app: AppModel) -> TextStyleRequest? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = document.content
        guard !text.isEmpty, let model = model(app), let page = content.pages[key.page],
              let template = content.template(for: page), let box = template.box(key.box),
              case .text = box.content else { return nil }
        let rect = PageGeometry(setup: content.style.pageSetup, kind: template.kind).renderRect(for: box)
        let current = snapshot(for: key)
        let boxText = content.displayedText(page: page, box: box)?.plainText ?? ""
        return backend.buildRequest(text, boxText, box.role, PointSize(width: rect.width, height: rect.height),
                                    current, history(key), content.style.visualDescription,
                                    TextStyleFonts.allowed(in: content), model)
    }

    /// The decoration's image request as an intent, for estimates and the real-person check
    /// before the design exists: the instruction stands in for the decoration description.
    func decorationIntent(_ instruction: String, quality: QualityLevel, refines: VersionID?, app: AppModel)
        -> GenerationIntent {
        let settings = app.defaults
        return GenerationIntent(messageText: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                                refines: refines, provider: settings.provider, model: settings.model,
                                quality: quality, includeStoryText: false, checkConsistency: false)
    }

    /// What a Style press costs: the text model's request plus the decoration (which the design
    /// may turn out not to need).
    public func estimate(_ instruction: String, quality: QualityLevel, refines: VersionID?, for key: TextBoxKey,
                         app: AppModel) -> CostEstimate {
        guard let request = request(instruction, for: key, app: app) else { return .unknown }
        let text = backend.estimate(request, app.prices.current)
        let image = app.ownEstimate(decorationIntent(instruction, quality: quality,
                                                     refines: decorationBase(refines, key: key), app: app),
                                    target: .textBox(key.page, key.box), content: document.content)
        return CostEstimate.total([text, image])
    }

    /// The real-person notice the decoration would need (style references), or nil.
    public func noticeNeeded(_ instruction: String, quality: QualityLevel, refines: VersionID?, for key: TextBoxKey,
                             app: AppModel) -> ProviderID? {
        app.realPersonNoticeNeeded(intent: decorationIntent(instruction, quality: quality,
                                                            refines: decorationBase(refines, key: key), app: app),
                                   target: .textBox(key.page, key.box), in: document)
    }

    // MARK: Running

    /// Starts a styling request (after the panel's notice and cost checks). `refines` is the
    /// selected style version (nil = a new style).
    public func start(_ instruction: String, quality: QualityLevel, refines: VersionID?, for key: TextBoxKey,
                      app: AppModel) {
        guard !isDesigning(key) else { return }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        states[key] = .designing(text)
        tasks[key] = Task { [weak self] in
            await self?.run(text, quality: quality, refines: refines, for: key, app: app)
            self?.tasks[key] = nil
        }
    }

    /// Stop: cancels the design step.
    public func cancel(_ key: TextBoxKey) {
        tasks[key]?.cancel()
    }

    /// Runs one request to the end; awaitable for tests.
    func run(_ instruction: String, quality: QualityLevel, refines: VersionID?, for key: TextBoxKey,
             app: AppModel) async {
        states[key] = .designing(instruction)
        func fail(_ advice: FailureAdvice, sent: TextStyleCall? = nil) {
            states[key] = .failed(instruction: instruction, advice: advice, sent: sent)
        }
        guard let provider = app.textStyleProvider else {
            return fail(FailureAdvice(headline: "AI text styling isn't available",
                                      explanation: "No provider is set up for text styling. Add your API key in Settings."))
        }
        guard let model = model(app) else {
            return fail(FailureAdvice(
                headline: "The text model isn't available",
                explanation: "“\(app.preferences.defaultTemplateModelID)” isn't in the model list. Choose another layout model in Settings."))
        }
        guard document.isEditable else {
            return fail(FailureAdvice(headline: "Couldn't style the text",
                                      explanation: "The book can't be edited right now."))
        }
        guard let request = request(instruction, for: key, app: app) else {
            return fail(FailureAdvice(headline: "The text box is gone",
                                      explanation: "This text box is no longer on the page."))
        }
        let fonts = TextStyleFonts.faces(in: document.content)
        let current = snapshot(for: key)
        let estimate = backend.estimate(request, app.prices.current)
        let target = GenerationTarget.textBox(key.page, key.box)

        let result: TextStyleResult
        do throws(ProviderError) {
            result = try await provider.styleText(request)
        } catch {
            let rule = QueueLedgerRule.forFailure(error)
            var call: TextStyleCall?
            if rule != QueueLedgerRule.none {
                call = TextStyleCall(provider: provider.id, model: model.id, system: request.system, user: request.user)
            }
            if let charge = rule.charge {
                call?.cost = await recordCost(app, model: model, provider: provider.id, target: target,
                                              estimate: estimate, charge)
            }
            if error == .cancelled {
                states[key] = .idle
            } else {
                fail(RefusalAdvisor.advise(error, context: AdviceContext(provider: provider.id, report: nil)), sent: call)
            }
            return
        }
        let costID = await recordCost(app, model: model, provider: provider.id, target: target, estimate: estimate,
                                      .completed(usage: result.usage, provider: provider.id, model: model.id,
                                                 pricing: app.prices.calculator))
        let call = TextStyleCall(provider: provider.id, model: model.id, system: request.system, user: request.user,
                                 parametersSent: result.parametersSent, usage: result.usage, cost: costID)
        let normalized = backend.normalize(result.draft, fonts, current)
        // A restyle starts from the refined version: "keep" (null) fields keep its values, not the
        // layout's, and a null decoration keeps its painted decoration ("none" removes it).
        let base = refines.flatMap { id in
            document.content.pages[key.page]?.textStyles[key.box].flatMap { document.content.sessions[$0.sessionID] }?
                .version(id)
        }
        var styling = normalized.styling
        var decorationPrompt = normalized.decorationPrompt
        var keptDecoration: ImageRef?
        if let baseStyle = base?.textStyle {
            styling = Self.merged(styling, over: baseStyle.styling)
            if result.draft.decoration == nil, let kept = baseStyle.decorationPrompt, let image = base?.image {
                decorationPrompt = kept
                keptDecoration = image
            }
        }
        let styleIntent = TextStyleIntent(styling: styling, decorationPrompt: decorationPrompt,
                                          summary: normalized.summary, call: call)
        var intent = decorationIntent(instruction, quality: quality, refines: nil, app: app)
        intent.textStyle = styleIntent

        // The box needs its styling session before anything is written into it.
        _ = document.performIrreversible {
            BookMutations.ensureTextStyleSlot(page: key.page, box: key.box, to: &$0)
        }
        guard document.content.pages[key.page]?.textStyles[key.box] != nil else {
            return fail(FailureAdvice(headline: "The text box is gone",
                                      explanation: "This text box is no longer on the page."), sent: call)
        }

        if styleIntent.decorationPrompt == nil || keptDecoration != nil {
            // Typography only, or the refined version's decoration kept as it is: no image
            // request, so the version is made now.
            intent.refines = refines
            let message = Message(role: .user, text: intent.messageText, refines: refines, createdAt: app.now())
            do {
                let placeholder: ImageRef
                if let keptDecoration {
                    placeholder = keptDecoration
                } else {
                    placeholder = try await document.store.storeImage(TextStylePlaceholder.png,
                                                                      contentType: UTType.png.identifier)
                }
                let stamp = app.now()
                guard document.performIrreversible({
                    BookMutations.appendTypographyOnlyStyle(message: message, intent: intent, placeholder: placeholder,
                                                            page: key.page, box: key.box, to: &$0, now: stamp)
                }) else {
                    return fail(FailureAdvice(headline: "Couldn't style the text",
                                              explanation: "The book can't be edited right now."), sent: call)
                }
            } catch {
                return fail(FailureAdvice(headline: "Couldn't save the style",
                                          explanation: StoreErrorText.message(for: error)), sent: call)
            }
            states[key] = .idle
            return
        }

        // A decoration refines the selected version's decoration only when it has one.
        intent.refines = decorationBase(refines, key: key)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: app.now())
        if app.enqueue(message, app.prepared(item, content: document.content), in: document) {
            states[key] = .idle
        } else {
            fail(FailureAdvice(headline: "Couldn't queue the decoration",
                               explanation: "The book changed before the decoration could be queued. Try again."),
                 sent: call)
        }
    }

    /// `styling` with each "keep" (nil) field taken from `base`.
    static func merged(_ styling: TextStyling, over base: TextStyling) -> TextStyling {
        var result = styling
        result.font = styling.font ?? base.font
        result.fontSize = styling.fontSize ?? base.fontSize
        result.color = styling.color ?? base.color
        result.alignment = styling.alignment ?? base.alignment
        return result
    }

    // MARK: Private

    /// `refines` if that version has a painted decoration (a typography-only version's image is a
    /// placeholder that mustn't be sent as a base image), else nil.
    private func decorationBase(_ refines: VersionID?, key: TextBoxKey) -> VersionID? {
        guard let refines, let slot = document.content.pages[key.page]?.textStyles[key.box],
              let version = document.content.sessions[slot.sessionID]?.version(refines),
              version.textStyle?.decorationPrompt != nil else { return nil }
        return refines
    }

    /// The box's earlier styling instructions (current epoch, oldest first).
    private func history(_ key: TextBoxKey) -> [String] {
        guard let id = document.content.pages[key.page]?.textStyles[key.box]?.sessionID,
              let session = document.content.sessions[id] else { return [] }
        return session.visibleMessages.filter { $0.role == .user }.map(\.text)
    }

    private func snapshot(for key: TextBoxKey) -> TextStyleSnapshot {
        let content = document.content
        guard let page = content.pages[key.page], let template = content.template(for: page),
              let box = template.box(key.box), case let .text(style) = box.content else {
            let t = content.style.typography
            return TextStyleSnapshot(fontFamily: t.bodyFont.postScriptName, fontSize: t.bodySize, textColor: t.color,
                                     alignment: t.alignment, textInset: 0, panelColor: nil, decoration: nil)
        }
        let rect = PageGeometry(setup: content.style.pageSetup, kind: template.kind).renderRect(for: box)
        let appearance = TextBoxAppearance.resolve(box: box, style: style, pageID: key.page, content: content,
                                                   renderSize: rect.size)
        let applied = content.appliedTextStyle(page: key.page, box: key.box)
        return TextStyleSnapshot(
            fontFamily: FontFamilies.family(of: appearance.typography.bodyFont.postScriptName)
                ?? appearance.typography.bodyFont.postScriptName,
            fontSize: appearance.typography.bodySize, textColor: appearance.typography.color,
            alignment: appearance.typography.alignment, textInset: applied?.styling.insetFraction ?? 0,
            panelColor: appearance.background, decoration: applied?.version.textStyle?.decorationPrompt)
    }

    private func recordCost(_ app: AppModel, model: CatalogTextModel, provider: ProviderID, target: GenerationTarget,
                            estimate: CostEstimate, _ charge: LedgerCharge) async -> CostRecordID {
        let record = CostRecord(at: app.now(), kind: .textStyle, provider: provider, model: model.id, quality: nil,
                                target: target, charge: charge, estimate: estimate,
                                currentPriceListAsOf: app.prices.current.asOf)
        await app.openBooks.recordCost(record, in: document.id)
        return record.id
    }
}

/// The fonts a text style may choose from: a curated set of friendly macOS families that are
/// installed, plus every family the book already uses or has imported.
@MainActor
enum TextStyleFonts {
    static let curated = [
        "Avenir Next", "American Typewriter", "Baskerville", "Big Caslon", "Bodoni 72", "Bradley Hand",
        "Chalkboard SE", "Chalkduster", "Charter", "Cochin", "Comic Sans MS", "Copperplate", "Didot", "Futura",
        "Georgia", "Gill Sans", "Herculanum", "Hoefler Text", "Luminari", "Marker Felt", "Noteworthy", "Optima",
        "Palatino", "Papyrus", "Party LET", "Phosphate", "Rockwell", "Savoye LET", "Snell Roundhand",
        "Superclarendon", "Trattatello", "Zapfino",
    ]

    /// Family names, sorted, each with a regular face.
    static func allowed(in content: BookContent) -> [String] {
        let installed = Set(FontFamilies.all)
        var families = Set(curated.filter(installed.contains))
        let used = [content.style.typography.bodyFont, content.style.typography.titleFont]
        for font in used { if let family = FontFamilies.family(of: font.postScriptName) { families.insert(family) } }
        return families.filter { FontFamilies.regularFace(of: $0) != nil }.sorted()
    }

    /// Family → PostScript name of its regular face, for the families the request offered.
    static func faces(in content: BookContent) -> [String: String] {
        var faces: [String: String] = [:]
        for family in allowed(in: content) { faces[family] = FontFamilies.regularFace(of: family) }
        return faces
    }
}

/// The image of a typography-only style version: one transparent pixel.
enum TextStylePlaceholder {
    static let png: Data = {
        let data = NSMutableData()
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
}
