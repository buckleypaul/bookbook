import BBAICore
import BBModel
import Foundation
import ImageIO
import Synchronization

/// An image the assembler needs bytes for, in send order (A §7.3, §7.9).
public struct PlannedImage: Hashable, Sendable {
    public var ref: ImageRef
    /// `base`, `reference` (attached), `asset` or `style`.
    public var role: String
    public var label: String
    /// Known for versions; nil for style references until the bytes are read.
    public var pixelSize: PixelSize?
}

/// Why assembly could not produce a request.
public enum AssemblyError: Error, Hashable, Sendable {
    /// The page, box, template, asset or session is gone.
    case targetGone
    /// The version to refine no longer exists.
    case baseVersionGone
    /// The base image's bytes are missing from the image store.
    case baseImageMissing
    /// The base image is larger than the model accepts.
    case baseImageTooLarge
    /// Region edit (Phase 11): the stored mask image is missing or unreadable.
    case maskImageMissing
    /// Region edit: the stored mask isn't the base image's pixel size (or there's no base).
    case maskSizeMismatch

    /// What a failed queue item reports.
    public var providerError: ProviderError {
        switch self {
        case .targetGone: .unknown(nil)
        case .baseVersionGone, .baseImageMissing, .baseImageTooLarge: .invalidRequest(param: "image", nil)
        case .maskImageMissing:
            .invalidRequest(param: "mask", ProviderErrorRaw(
                status: nil, code: "mask_missing",
                body: "The selected area for this edit is missing from the book. Select the area again."))
        case .maskSizeMismatch:
            .invalidRequest(param: "mask", ProviderErrorRaw(
                status: nil, code: "mask_size_mismatch",
                body: "The selected area doesn't match the picture's size. Select the area again."))
        }
    }
}

/// Builds the provider-neutral request from a book snapshot (A §7.3). Pure; snapshot-tested.
/// Two steps so the queue can load bytes in between: `plan` lists the images needed, `assemble`
/// takes their bytes.
public enum ContextAssembler {
    struct Resolved {
        var page: Page
        var template: Template
        var box: Box
        var session: Session
    }

    /// An asset session's target, resolved (Phase 10).
    struct AssetResolved {
        enum Kind {
            case slot(ReferenceSlot)
            case sheetItem(SheetItem)
        }

        var asset: Asset
        var kind: Kind
        var session: Session
    }

    /// What the request is for.
    enum Context {
        case page(Resolved)
        case asset(AssetResolved)

        var session: Session {
            switch self {
            case let .page(resolved): resolved.session
            case let .asset(resolved): resolved.session
            }
        }
    }

    /// Resolves the session by the queue item's message first (box IDs can move), then by the
    /// target's slot. Page-box targets only.
    static func resolve(target: GenerationTarget, messageID: MessageID?, content: BookContent) -> Resolved? {
        guard case let .pageBox(targetPage, targetBox) = target else { return nil }
        var pageID = targetPage, boxID = targetBox
        let session: Session
        if let messageID, let owner = content.session(containing: messageID) {
            // The message's session owns the geometry: find the slot that holds it now, since the
            // target's box ID may have moved or been reused by another box.
            if content.pages[targetPage]?.images[targetBox]?.sessionID != owner.id {
                // No slot holds the session any more. If the target box now belongs to another session,
                // its shape is not this session's: resolve to nothing rather than use it.
                guard case let .pageBox(home, box) = ConsistencyAssembler.target(for: owner, in: content)
                else { return nil }
                (pageID, boxID) = (home, box)
            }
            session = owner
        } else {
            guard let slot = content.pages[pageID]?.images[boxID], let found = content.sessions[slot.sessionID]
            else { return nil }
            session = found
        }
        guard let page = content.pages[pageID], let template = content.template(for: page),
              let box = template.box(boxID), box.content == .image else { return nil }
        return Resolved(page: page, template: template, box: box, session: session)
    }

    /// Asset-session targets: the session holding the message (if it's an asset session) decides
    /// the owner, else the target does; the session is the slot's / item's `sessionID`.
    static func resolveAsset(target: GenerationTarget, messageID: MessageID?, content: BookContent) -> AssetResolved? {
        let messageSession = messageID.flatMap { content.session(containing: $0) }.flatMap { session in
            session.owner.assetID == nil ? nil : session
        }
        let owner = messageSession?.owner ?? target.owner
        switch owner {
        case .pageBox:
            return nil
        case let .assetReference(assetID, slotID):
            guard let asset = content.assets[assetID], let slot = asset.references.first(where: { $0.id == slotID }),
                  let session = messageSession ?? content.sessions[slot.sessionID] else { return nil }
            return AssetResolved(asset: asset, kind: .slot(slot), session: session)
        case let .sheetItem(assetID, itemID):
            guard let asset = content.assets[assetID], let item = asset.sheet?.items.first(where: { $0.id == itemID }),
                  let session = messageSession ?? content.sessions[item.sessionID] else { return nil }
            return AssetResolved(asset: asset, kind: .sheetItem(item), session: session)
        }
    }

    static func context(target: GenerationTarget, messageID: MessageID?, content: BookContent) -> Context? {
        switch target {
        case .pageBox: resolve(target: target, messageID: messageID, content: content).map(Context.page)
        case .assetReference, .sheetItem: resolveAsset(target: target, messageID: messageID, content: content).map(Context.asset)
        }
    }

    // MARK: Assets in play (A §7.3 step 1)

    /// The assets in play, in order: an asset session's owner, then assets mentioned in the
    /// current message, then mentions in earlier current-epoch messages along the refined
    /// version's lineage, then the page's checklist. Deleted or unknown IDs are ignored. Empty if
    /// the target is gone.
    public static func assetsInPlay(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID? = nil,
                                    content: BookContent) -> [AssetID] {
        guard let context = context(target: target, messageID: messageID, content: content) else { return [] }
        return assetsInPlay(intent: intent, context: context, content: content).map(\.asset.id)
    }

    static func assetsInPlay(intent: GenerationIntent, context: Context,
                             content: BookContent) -> [ReferenceSelector.AssetInPlay] {
        var out: [ReferenceSelector.AssetInPlay] = []
        var seen = Set<AssetID>()
        func add(_ id: AssetID, mentioned: Bool, primaryOnly: Bool = false, excludedSlot: UUID? = nil) {
            guard let asset = content.assets[id], seen.insert(id).inserted else { return }
            out.append(.init(asset: asset, mentioned: mentioned, primaryOnly: primaryOnly, excludedSlot: excludedSlot))
        }
        if case let .asset(resolved) = context {
            switch resolved.kind {
            case let .slot(slot): add(resolved.asset.id, mentioned: true, primaryOnly: true, excludedSlot: slot.id)
            case .sheetItem: add(resolved.asset.id, mentioned: true, primaryOnly: true)
            }
        }
        for id in MentionText.mentionedAssets(in: intent.messageText) { add(id, mentioned: true) }
        if let refines = intent.refines {
            for message in context.session.lineageInstructions(of: refines) {
                for id in MentionText.mentionedAssets(in: message.text) { add(id, mentioned: true) }
            }
        }
        if case let .page(resolved) = context {
            for id in resolved.page.assetChecklist { add(id, mentioned: false) }
        }
        return out
    }

    // MARK: Planning

    /// Everything decided before bytes are loaded.
    struct Prepared {
        var context: Context
        var assets: [ReferenceSelector.AssetInPlay]
        var candidates: [ReferenceSelector.Candidate]
        var storyText: String
        var includeStory: Bool
        /// `requestDisplayText` for the intent (untrimmed).
        var requestText: String
    }

    /// The request with mention tokens shown as asset names. A token whose asset was deleted
    /// after the item was queued no longer resolves; the answered message's text was rewritten
    /// to plain names at delete, so that text is used and the name is not dropped (A §4.3).
    public static func requestDisplayText(intent: GenerationIntent, messageID: MessageID?, content: BookContent) -> String {
        var text = intent.messageText
        if MentionText.mentionedAssets(in: text).contains(where: { content.assets[$0] == nil }),
           let messageID, let message = content.session(containing: messageID)?.messages.first(where: { $0.id == messageID }) {
            text = message.text
        }
        return MentionText.displayText(text, assets: content.assets)
    }

    static func prepare(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID?,
                        content: BookContent) -> Prepared? {
        guard let context = context(target: target, messageID: messageID, content: content) else { return nil }
        let session = context.session
        var storyText = ""
        if case let .page(resolved) = context { storyText = resolved.page.storyText(in: resolved.template) }
        let includeStory = intent.includeStoryText && !storyText.isEmpty

        var base: ReferenceSelector.Candidate?
        if let refines = intent.refines, let version = session.version(refines) {
            let number = session.versionNumber(refines).map { " (v\($0))" } ?? ""
            base = .init(ref: version.image, role: "base", label: "Current illustration\(number)", tier: .base,
                         pixelSize: version.pixelSize, depictsRealPerson: version.depictsRealPerson == true)
        }
        let attached = intent.attachedReferences.compactMap { attached -> ReferenceSelector.Candidate? in
            guard let other = content.sessions[attached.sessionID],
                  let version = other.version(attached.versionID) else { return nil }
            let number = other.versionNumber(attached.versionID).map { " v\($0)" } ?? ""
            return .init(ref: version.image, role: "reference", label: "Reference\(number)", tier: .attached,
                         pixelSize: version.pixelSize, depictsRealPerson: version.depictsRealPerson == true)
        }
        let assets = assetsInPlay(intent: intent, context: context, content: content)
        let request = requestDisplayText(intent: intent, messageID: messageID, content: content)
        let matchText = includeStory ? request + "\n" + storyText : request
        let candidates = ReferenceSelector.candidates(.init(
            base: base, attached: attached, assets: assets, styleReferences: content.style.styleReferences,
            matchText: matchText, sessions: content.sessions))
        return Prepared(context: context, assets: assets, candidates: candidates, storyText: storyText,
                        includeStory: includeStory, requestText: request)
    }

    /// The images this request needs, in send order (A §7.4 tiers). Not yet capped by the
    /// model's budget; `assemble` applies it. Nil if the target is gone.
    public static func plan(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID? = nil,
                            content: BookContent) -> [PlannedImage]? {
        prepare(intent: intent, target: target, messageID: messageID, content: content).map(plan)
    }

    /// `plan` for an already prepared request, so callers that go on to `assemble` prepare once.
    static func plan(_ prepared: Prepared) -> [PlannedImage] {
        prepared.candidates.map { PlannedImage(ref: $0.ref, role: $0.role, label: $0.label, pixelSize: $0.pixelSize) }
    }

    static func limits(_ model: CatalogModel) -> ReferenceSelector.Limits {
        .init(maxImages: model.image.maxReferenceImages, maxImageBytes: model.image.maxImageBytes,
              maxTotalBytes: model.image.maxRequestBytes)
    }

    // MARK: Assembly

    /// `imageData` holds the bytes the queue managed to load for `plan`'s refs.
    public static func assemble(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID? = nil,
                                content: BookContent, model: CatalogModel,
                                imageData: [ImageRef: Data] = [:]) throws(AssemblyError) -> (ImageRequest, AssemblyReport) {
        guard let prepared = prepare(intent: intent, target: target, messageID: messageID, content: content)
        else { throw .targetGone }
        return try assemble(prepared: prepared, intent: intent, content: content, model: model, imageData: imageData)
    }

    /// `assemble` for an already prepared request (the same `intent` and `content`).
    static func assemble(prepared: Prepared, intent: GenerationIntent, content: BookContent, model: CatalogModel,
                         imageData: [ImageRef: Data]) throws(AssemblyError) -> (ImageRequest, AssemblyReport) {
        let session = prepared.context.session
        if let refines = intent.refines, session.version(refines) == nil { throw .baseVersionGone }
        let style = content.style
        let includeStory = prepared.includeStory

        // Pick what fits. The base goes first; overflow and missing bytes are omitted, never dropped silently.
        let selection = ReferenceSelector.select(prepared.candidates, byteCounts: imageData.mapValues(\.count),
                                                 limits: limits(model))
        if let base = selection.omitted.first(where: { $0.candidate.role == "base" }) {
            throw base.reason == .fileMissing ? .baseImageMissing : .baseImageTooLarge
        }
        let sent: [(plan: ReferenceSelector.Candidate, payload: ImagePayload)] = selection.sent.map { candidate in
            var entry = candidate
            let data = imageData[candidate.ref] ?? Data()
            entry.pixelSize = candidate.pixelSize ?? ImageHeader.pixelSize(of: data)
            return (entry, ImagePayload(data: data, contentType: candidate.ref.contentType, ref: candidate.ref,
                                        pixelSize: entry.pixelSize))
        }
        let numbers = Dictionary(sent.enumerated().map { ($0.element.plan.ref, $0.offset + 1) },
                                 uniquingKeysWith: { first, _ in first })

        // Prompt sections (A §7.3).
        let styleIndexes = sent.enumerated().filter { $0.element.plan.role == "style" }.map { $0.offset + 1 }
        var styleText = style.visualDescription.trimmed
        if let first = styleIndexes.first, let last = styleIndexes.last {
            let range = first == last ? "Image \(first) is a style reference" : "Images \(first)–\(last) are style references"
            let note = PromptTemplates.render(PromptTemplates.text(for: "style-references") ?? "{{range}}.", ["range": range])
            styleText = styleText.isEmpty ? note : styleText + " " + note
        }
        let isRefinement = sent.first?.plan.role == "base"
        var earlier: [String] = []
        if isRefinement, let refines = intent.refines {
            earlier = session.lineageInstructions(of: refines)
                .map { MentionText.displayText($0.text, assets: content.assets).trimmed }.filter { !$0.isEmpty }
        }
        let history = earlier.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "; ")
        let requestText = prepared.requestText.trimmed
        let legend = sent.enumerated().map { index, entry in
            let name = entry.plan.asset.flatMap { content.assets[$0]?.name } ?? ""
            return PromptTemplates.render(PromptTemplates.text(for: "legend-\(entry.plan.role)") ?? "Image {{n}}.",
                                          ["n": "\(index + 1)", "name": name, "detail": entry.plan.detail ?? ""])
        }.joined(separator: "\n")
        let cast = castLines(prepared.assets, sent: sent.map(\.plan), numbers: numbers)

        var composition: [String: String] = [:]
        var subject = ""
        let aspect: Double
        switch prepared.context {
        case let .page(resolved):
            aspect = content.boxAspect(resolved.box, in: resolved.template)
            composition = ["aspect": describeAspect(aspect),
                           "calm": calmGuidance(box: resolved.box, template: resolved.template),
                           "fold": foldGuidance(box: resolved.box, template: resolved.template),
                           "safe": safeAreaGuidance(box: resolved.box, template: resolved.template, content: content)]
        case let .asset(resolved):
            // Asset images have no page geometry: square by default (the fitter snaps it per model).
            aspect = 1
            subject = assetSubject(resolved, numbers: numbers, sent: sent.map(\.plan))
        }
        let isPage = !composition.isEmpty

        let values: [(key: String, placeholders: [String: String], required: Bool)] = [
            ("role", [:], true),
            ("style", ["style": styleText], !styleText.isEmpty),
            ("avoid", ["avoid": style.negativeGuidance.trimmed], !style.negativeGuidance.trimmed.isEmpty),
            ("cast", ["entries": cast], !cast.isEmpty),
            ("subject", ["subject": subject], !subject.isEmpty),
            ("composition", composition, isPage),
            ("story", ["story": prepared.storyText], includeStory),
            ("history", ["earlier": history], !history.isEmpty),
            ("region", [:], intent.regionMask != nil),
            ("request", ["request": requestText], !requestText.isEmpty),
            ("legend", ["lines": legend], !legend.isEmpty),
        ]
        let sections = values.compactMap { entry -> ComposedPrompt.Section? in
            guard entry.required, let template = PromptTemplates.text(for: entry.key) else { return nil }
            return .init(key: entry.key, text: PromptTemplates.render(template, entry.placeholders))
        }
        let prompt = ComposedPrompt(sections: sections)

        // Refinements keep the base image's shape (A §7.6), snapped to the model's size rules so imported
        // images (scans, photos) stay valid; new images use §7.5 fitting.
        let exactSize = isRefinement
            ? sent.first?.plan.pixelSize.flatMap { AspectFitter.snap($0, model: model, quality: intent.quality) } : nil
        let baseImage = isRefinement ? sent.first?.payload : nil
        let references = sent.dropFirst(isRefinement ? 1 : 0).map {
            ReferenceImage(payload: $0.payload, sent: SentReference(image: $0.plan.ref, role: $0.plan.role, label: $0.plan.label))
        }
        let mask = try regionMask(intent: intent, baseImage: baseImage, imageData: imageData)
        let request = ImageRequest(model: model, quality: intent.quality,
                                   output: OutputShape(boxAspect: aspect, exactSize: exactSize),
                                   instruction: prompt, baseImage: baseImage, references: references, mask: mask)
        var report = AssemblyReport(
            promptText: prompt.rendered,
            referencesSent: sent.map { SentReference(image: $0.plan.ref, role: $0.plan.role, label: $0.plan.label) },
            referencesOmitted: selection.omitted.map(\.sentReference), storyTextIncluded: includeStory,
            styleRevision: style.visualRevision,
            estimatedInputBytes: prompt.rendered.utf8.count + selection.bytes + (mask?.pngData.count ?? 0),
            storyText: includeStory ? prepared.storyText : nil)
        report.assetRevisions = Dictionary(prepared.assets.map { ($0.asset.id, $0.asset.revision) },
                                           uniquingKeysWith: { first, _ in first })
        return (request, report)
    }

    /// Region edit (A §7.6): the stored 8-bit mask, checked against the base payload's pixel size
    /// and encoded for the wire (alpha 0 = edit area). Nil when the intent has no mask.
    static func regionMask(intent: GenerationIntent, baseImage: ImagePayload?,
                           imageData: [ImageRef: Data]) throws(AssemblyError) -> MaskPayload? {
        guard let ref = intent.regionMask else { return nil }
        guard let data = imageData[ref], !data.isEmpty else { throw .maskImageMissing }
        let mask: RegionMask
        do { mask = try ImageOps.decodeMask(data) } catch { throw .maskImageMissing }
        guard let baseImage, let size = baseImage.pixelSize, size == mask.pixelSize else { throw .maskSizeMismatch }
        guard let png = try? ImageOps.providerMaskPNG(mask) else { throw .maskImageMissing }
        return MaskPayload(pngData: png, pixelSize: size, ref: ref)
    }

    // MARK: Cast and subject wording

    /// One "- Pip (character): … Image 2 shows Pip (primary reference)." line per asset in play.
    static func castLines(_ assets: [ReferenceSelector.AssetInPlay], sent: [ReferenceSelector.Candidate],
                          numbers: [ImageRef: Int]) -> String {
        let entryTemplate = PromptTemplates.text(for: "cast-entry") ?? "- {{name}} ({{type}}){{description}}{{images}}"
        let imageTemplate = PromptTemplates.text(for: "cast-image") ?? "Image {{n}} shows {{name}} ({{detail}})."
        return assets.map { entry in
            let asset = entry.asset
            let description = asset.description.trimmed
            var describing = description.isEmpty ? "." : ": " + description
            if let last = describing.last, !".!?".contains(last) { describing += "." }
            let images = sent.filter { $0.asset == asset.id }.compactMap { candidate -> String? in
                guard let n = numbers[candidate.ref] else { return nil }
                return " " + PromptTemplates.render(imageTemplate, ["n": "\(n)", "name": asset.name,
                                                                    "detail": candidate.detail ?? ""])
            }.joined()
            return PromptTemplates.render(entryTemplate, ["name": asset.name, "type": asset.type.rawValue,
                                                          "description": describing, "images": images])
        }.joined(separator: "\n")
    }

    /// What to draw in an asset session: a reference image of the asset, or a sheet item drawn
    /// from the asset's primary reference.
    static func assetSubject(_ resolved: AssetResolved, numbers: [ImageRef: Int],
                             sent: [ReferenceSelector.Candidate]) -> String {
        let asset = resolved.asset
        var values = ["name": asset.name, "type": asset.type.rawValue]
        let template: String
        switch resolved.kind {
        case let .slot(slot) where slot.isPrimary:
            template = PromptTemplates.text(for: "asset-reference-\(asset.type.rawValue)") ?? "A reference image of {{name}}."
        case let .slot(slot):
            template = PromptTemplates.text(for: "asset-reference-slot") ?? "{{label}}"
            values["label"] = slot.label.trimmed
        case let .sheetItem(item):
            switch item.kind {
            case let .view(view):
                template = PromptTemplates.text(for: "sheet-view-\(view.rawValue)") ?? "{{name}}, \(view.rawValue) view."
            case let .expression(name):
                template = PromptTemplates.text(for: "sheet-expression") ?? "{{name}}, {{expression}}."
                values["expression"] = ReferenceSelector.displayName(expression: name)
            }
        }
        // One pass over the template, so a label or name containing `{{...}}` is never expanded.
        var text = PromptTemplates.render(template, values)
        // The primary reference, when it's sent, anchors the look.
        if let primary = sent.first(where: { $0.asset == asset.id && $0.tier == .mentionedPrimary }),
           let n = numbers[primary.ref], let same = PromptTemplates.text(for: "asset-same") {
            text += " " + PromptTemplates.render(same, values.merging(["n": "\(n)"]) { $1 })
        }
        return text
    }

    // MARK: Composition wording

    private static let commonRatios: [(label: String, value: Double)] = [
        ("1:1", 1), ("5:4", 1.25), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("3:1", 3),
        ("4:5", 0.8), ("3:4", 0.75), ("2:3", 2.0 / 3), ("9:16", 9.0 / 16), ("1:2", 0.5), ("1:3", 1.0 / 3),
    ]

    /// e.g. "landscape, about 3:2".
    static func describeAspect(_ aspect: Double) -> String {
        guard aspect.isFinite, aspect > 0 else { return "square, about 1:1" }
        let orientation = aspect > 1.05 ? "landscape" : aspect < 0.95 ? "portrait" : "square"
        let nearest = commonRatios.min { abs(log(aspect / $0.value)) < abs(log(aspect / $1.value)) }
        return "\(orientation), about \(nearest?.label ?? "1:1")"
    }

    /// Leading-space sentence naming the part of the image that text boxes cover, or "".
    static func calmGuidance(box: Box, template: Template) -> String {
        let frame = box.frame
        guard frame.width > 0, frame.height > 0 else { return "" }
        var phrases: [String] = []
        for textBox in template.textBoxes {
            guard let overlap = frame.intersection(textBox.frame) else { continue }
            let local = NormalizedRect(x: (overlap.x - frame.x) / frame.width, y: (overlap.y - frame.y) / frame.height,
                                       width: overlap.width / frame.width, height: overlap.height / frame.height)
            guard local.width * local.height >= 0.02 else { continue }
            phrases.append(describeRegion(local))
        }
        guard !phrases.isEmpty else { return "" }
        var seen = Set<String>()
        let unique = phrases.filter { seen.insert($0).inserted }
        return " Leave " + unique.joined(separator: " and ") + " calm and low-detail for text."
    }

    /// Leading-space sentence about a spread's fold crossing the image, or "".
    static func foldGuidance(box: Box, template: Template) -> String {
        guard template.kind == .spread, box.frame.width > 0 else { return "" }
        let position = (0.5 - box.frame.x) / box.frame.width
        guard position > 0.03, position < 0.97 else { return "" }
        let percent = Int((position * 100).rounded())
        return " " + PromptTemplates.render(PromptTemplates.text(for: "fold") ?? "{{percent}}%",
                                            ["percent": "\(percent)"])
    }

    /// Leading-space sentence about the trimmed outer edge when the box bleeds, or "". Geometry follows
    /// `BookContent.boxAspect`: bleed pushes out the box's `bleedEdges` (not at a spread's fold), and
    /// the page margin counts as unsafe on top of the bleed.
    static func safeAreaGuidance(box: Box, template: Template, content: BookContent) -> String {
        let setup = content.style.pageSetup
        let bleed = setup.bleedEnabled ? max(0, setup.bleedAmount) : 0
        guard bleed > 0 else { return "" }
        let spread = template.kind == .spread
        let trimW = setup.trimSize.width * (spread ? 2 : 1), trimH = setup.trimSize.height
        var edges = box.bleedEdges
        if spread {
            let fold = trimW / 2
            if abs(box.frame.x * trimW - fold) <= 0.5 { edges.remove(.leading) }
            if abs(box.frame.maxX * trimW - fold) <= 0.5 { edges.remove(.trailing) }
        }
        guard !edges.isEmpty else { return "" }
        let m = setup.margins
        func inset(_ edge: EdgeSet, _ margin: Double) -> Double { edges.contains(edge) ? bleed + max(0, margin) : 0 }
        func extra(_ edge: EdgeSet) -> Double { edges.contains(edge) ? bleed : 0 }
        let imageW = box.frame.width * trimW + extra(.leading) + extra(.trailing)
        let imageH = box.frame.height * trimH + extra(.top) + extra(.bottom)
        guard imageW > 0, imageH > 0 else { return "" }
        func percent(_ value: Double) -> Int { max(10, min(99, Int((value * 100 / 5).rounded(.down)) * 5)) }
        let safeW = (imageW - inset(.leading, m.leading) - inset(.trailing, m.trailing)) / imageW
        let safeH = (imageH - inset(.top, m.top) - inset(.bottom, m.bottom)) / imageH
        let horizontal = !edges.isDisjoint(with: [.leading, .trailing])
        let vertical = !edges.isDisjoint(with: [.top, .bottom])
        let area: String
        switch (horizontal, vertical) {
        case (true, true):
            let w = percent(safeW), h = percent(safeH)
            area = w == h ? "the central \(w)% of the image" : "the central \(w)% horizontally and \(h)% vertically"
        case (true, false): area = "the central \(percent(safeW))% horizontally"
        default: area = "the central \(percent(safeH))% vertically"
        }
        return " " + PromptTemplates.render(PromptTemplates.text(for: "safe-area") ?? "{{area}}", ["area": area])
    }

    private static func describeRegion(_ r: NormalizedRect) -> String {
        let wide = r.width >= 0.7, tall = r.height >= 0.7
        if wide && tall { return "the whole image" }
        let midX = r.x + r.width / 2, midY = r.y + r.height / 2
        let horizontal = midX < 0.4 ? "left" : midX > 0.6 ? "right" : "center"
        let vertical = midY < 0.4 ? "top" : midY > 0.6 ? "bottom" : "middle"
        if wide {
            return "the \(vertical) \(fraction(r.height))"
        }
        if tall {
            return "the \(horizontal) \(fraction(r.width))"
        }
        return "the \(vertical) \(horizontal) area"
    }

    private static func fraction(_ f: Double) -> String {
        let options: [(String, Double)] = [("quarter", 0.25), ("third", 1.0 / 3), ("half", 0.5), ("two thirds", 2.0 / 3),
                                           ("three quarters", 0.75)]
        return options.min { abs($0.1 - f) < abs($1.1 - f) }?.0 ?? "half"
    }
}

extension Page {
    /// The page's text boxes' plain text, in template order, joined by a blank line.
    fileprivate func storyText(in template: Template) -> String {
        template.textBoxes
            .compactMap { text[$0.id] }
            .map(\.plainText)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Reads pixel dimensions from an image header (ImageIO), without decoding.
enum ImageHeader {
    static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return PixelSize(width: w, height: h)
    }
}

/// Versioned prompt text files in `Resources/Prompts/<version>/<key>.txt` with `{{name}}` substitution.
enum PromptTemplates {
    static let version = "image-v1"

    /// Loaded files by `set/key`, misses included. The bundle is read-only, so entries never go stale.
    private static let cache = Mutex<[String: String?]>([:])

    /// The trimmed text of `Prompts/<set>/<key>.txt`, or nil if the file is missing. Cached.
    static func text(for key: String, set: String = version) -> String? {
        let path = "\(set)/\(key)"
        if let cached = cache.withLock({ $0[path] }) { return cached }
        var text: String?
        if let url = Bundle.module.resourceURL?.appendingPathComponent("Prompts/\(path).txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents.trimmingCharacters(in: .newlines)
        }
        cache.withLock { $0[path] = .some(text) }
        return text
    }

    /// One left-to-right scan, so substituted text (a slot label with `{{name}}`) is never re-expanded.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            if let close = afterOpen.range(of: "}}"), let value = values[String(afterOpen[..<close.lowerBound])] {
                out += value
                rest = afterOpen[close.upperBound...]
            } else {
                out += "{{"
                rest = afterOpen
            }
        }
        return out + rest
    }
}
