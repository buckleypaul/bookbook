import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation

/// Why a region edit wasn't queued (A §7.6). Nothing was appended or enqueued.
public enum RegionEditRefusal: Error, Hashable, Sendable {
    case emptyPrompt
    /// Nothing is selected (the drawing rasterises to an all-keep mask).
    case emptyMask
    /// The drawing isn't at the base version's pixel size.
    case sizeMismatch(expected: PixelSize, actual: PixelSize)
    /// The chosen model can't edit a selected area (`supportsMask` is false). Holds its name.
    case maskUnsupported(model: String)
    /// The version to edit (or its box or asset) is gone.
    case baseVersionGone
    case readOnly
    /// The request would send a real-person photo to a provider whose notice the book hasn't
    /// acknowledged yet (A §11). Holds the provider.
    case realPersonNoticeNeeded(ProviderID)
    /// The mask couldn't be encoded or saved into the book.
    case store(String)

    public var message: String {
        switch self {
        case .emptyPrompt: "Describe the change you want in the selected area."
        case .emptyMask: "Select an area of the picture to change first."
        case let .sizeMismatch(expected, actual):
            "The selection (\(actual.width)x\(actual.height)) doesn't match the picture (\(expected.width)x\(expected.height)). Select the area again."
        case let .maskUnsupported(model):
            "\(model) can't edit part of a picture. Choose a model that supports region editing in Settings."
        case .baseVersionGone: "The picture you were editing is no longer there."
        case .readOnly: "This book is open in another BookBook window, so it can't be changed here."
        case .realPersonNoticeNeeded:
            "This request now includes a photo of a real person. Try again to review the notice before it's sent."
        case let .store(text): "The selected area couldn't be saved: \(text)"
        }
    }
}

extension AppModel {
    /// Region edit (A §7.6, PD §8.6): rasterises `drawing` at the base version's pixel size (off
    /// the main actor), stores the 8-bit mask in the book's `images/`, then appends the pending
    /// message and enqueues the request like `generate`, with `refines` and `regionMask` set.
    /// The model is the user's default, as for `generate`. Callers run the cost and real-person
    /// checks first, as for `generate`. Returns the queue item's ID.
    @discardableResult
    public func generateRegionEdit(prompt: String, quality: QualityLevel, includeStoryText: Bool, refines: VersionID,
                                   drawing: RegionMaskDrawing, attachedReferences: [VersionRef] = [],
                                   target: GenerationTarget,
                                   in document: BookDocument) async throws(RegionEditRefusal) -> QueueItemID {
        var intent = generationIntent(prompt: prompt, quality: quality, includeStoryText: includeStoryText,
                                      refines: refines, attachedReferences: attachedReferences)
        guard !intent.messageText.isEmpty else { throw .emptyPrompt }
        guard document.isEditable else { throw .readOnly }
        try checkRegionEdit(intent: intent, drawing: drawing, target: target, content: document.content)

        let png = try await Self.maskPNG(for: drawing).get()
        do {
            intent.regionMask = try await document.store.storeImage(png, contentType: "public.png")
        } catch {
            throw .store(StoreErrorText.message(for: error))
        }
        // Re-check after the awaits: the version, box or model may have changed meanwhile.
        try checkRegionEdit(intent: intent, drawing: drawing, target: target, content: document.content)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: document.id, target: target,
                                                           now: now())
        if let provider = realPersonNoticeNeeded(intent: intent, target: target, in: document) {
            throw .realPersonNoticeNeeded(provider)
        }
        guard enqueue(message, prepared(item, content: document.content), in: document) else {
            throw document.isEditable ? .baseVersionGone : .readOnly
        }
        return item.id
    }

    /// Whether a region edit could be queued for `refines` with the user's default model:
    /// nil when it can, else the reason (for disabling the tool with an explanation).
    public func regionEditUnavailableReason(refines: VersionID, target: GenerationTarget,
                                            in document: BookDocument) -> RegionEditRefusal? {
        let intent = generationIntent(prompt: "", quality: .draft, includeStoryText: false, refines: refines)
        do throws(RegionEditRefusal) {
            try checkModelSupportsMask(intent)
            guard baseVersion(refines, target: target, content: document.content) != nil else {
                throw .baseVersionGone
            }
            return nil
        } catch {
            return error
        }
    }

    /// The model, base version and drawing size checks (the empty-mask check needs the raster).
    func checkRegionEdit(intent: GenerationIntent, drawing: RegionMaskDrawing, target: GenerationTarget,
                         content: BookContent) throws(RegionEditRefusal) {
        try checkModelSupportsMask(intent)
        guard let refines = intent.refines, let base = baseVersion(refines, target: target, content: content) else {
            throw .baseVersionGone
        }
        guard drawing.pixelSize == base.pixelSize else {
            throw .sizeMismatch(expected: base.pixelSize, actual: drawing.pixelSize)
        }
        guard !drawing.isEmpty else { throw .emptyMask }
    }

    /// Rasterises and encodes the mask off the main actor (full pixel size can be large).
    nonisolated static func maskPNG(for drawing: RegionMaskDrawing) async -> Result<Data, RegionEditRefusal> {
        await Task.detached(priority: .userInitiated) { () -> Result<Data, RegionEditRefusal> in
            let mask = ImageOps.rasterize(drawing)
            // Empty = nothing the wire mask would mark for editing (it thresholds at 127), so
            // antialiased leftovers of an erased area don't count.
            guard mask.bytes.contains(where: { $0 > 127 }) else { return .failure(.emptyMask) }
            guard let png = try? ImageOps.grayscalePNG(mask) else {
                return .failure(.store("the mask couldn't be encoded."))
            }
            return .success(png)
        }.value
    }

    private func checkModelSupportsMask(_ intent: GenerationIntent) throws(RegionEditRefusal) {
        let model = catalog.imageModel(provider: intent.provider, id: intent.model)
        guard let model, model.image.supportsMask else {
            throw .maskUnsupported(model: model?.displayName ?? intent.model)
        }
    }

    private func baseVersion(_ id: VersionID, target: GenerationTarget, content: BookContent) -> Version? {
        BookMutations.sessionID(for: target.owner, in: content).flatMap { content.sessions[$0]?.version(id) }
    }
}
