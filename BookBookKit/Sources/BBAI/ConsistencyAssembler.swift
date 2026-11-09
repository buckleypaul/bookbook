import BBAICore
import BBModel
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a consistency check of one version needs, decided before any bytes are read (A §7.8).
public struct ConsistencyPlan: Hashable, Sendable {
    public var versionID: VersionID
    public var sessionID: SessionID
    /// The version being checked (sent first).
    public var checked: PlannedImage
    /// The assets' primary references and selected sheet images, then up to two style
    /// references, in send order.
    public var references: [PlannedImage]
    /// The assets in play, in play order.
    public var assets: [ConsistencyAssetContext]
    public var styleDescription: String

    /// Images the request sends when every file is present.
    public var imageCount: Int { 1 + references.count }
}

/// A built request plus what Version details shows of it.
public struct AssembledConsistency: Sendable {
    public var request: ConsistencyRequest
    /// The exact system and user text sent (`ConsistencySent.promptSent`).
    public var promptText: String
    /// The checked image first, then the references actually sent.
    public var imagesSent: [SentReference]
}

/// Builds consistency-check requests (A §7.8). Pure over a book snapshot, like
/// `ContextAssembler`, and in the same two steps: `plan` lists the images, `assemble` takes
/// their bytes.
///
/// The assets in play are found as for an image request (A §7.3 step 1) from the version's
/// stored intent (imported versions: the page checklist, or the asset that owns the session).
/// For each, the primary reference and the sheet images the §7.4 selector would pick (with its
/// per-asset caps); then at most two style references. The base image and attached references
/// are not sent, nor the checked image again. Photos of real people are left out unless the
/// book acknowledged the vision provider's notice (A §11).
public enum ConsistencyAssembler {
    /// Every image is downscaled to this long edge (A §7.8).
    public static let maxLongEdge = 1024
    public static let maxStyleReferences = 2
    /// Images assumed for an estimate when the target can't be resolved yet.
    public static let conservativeImageCount = 7
    public static let checkedLabel = "Image to check"

    /// The check of `version`: nil if the version (or the page, box, slot or sheet item its
    /// session belongs to) is gone. `provider` is the vision provider, for the real-person rule.
    public static func plan(version versionID: VersionID, content: BookContent,
                            provider: ProviderID? = nil) -> ConsistencyPlan? {
        guard let session = content.sessions.values.first(where: { $0.version(versionID) != nil }),
              let version = session.version(versionID),
              let target = target(for: session, in: content) else { return nil }
        let producing = session.messages.first { $0.producedVersion == versionID }?.id
        let intent = version.provenance?.intent
            ?? GenerationIntent(messageText: "", refines: version.parent, provider: provider ?? .openai, model: "",
                                quality: .draft, includeStoryText: true)
        guard let (references, assets) = references(intent: intent, target: target, messageID: producing,
                                                    content: content, provider: provider,
                                                    excluding: version.image) else { return nil }
        let checked = PlannedImage(ref: version.image, role: "checked", label: checkedLabel,
                                   pixelSize: version.pixelSize)
        return ConsistencyPlan(versionID: versionID, sessionID: session.id, checked: checked,
                               references: references, assets: assets,
                               styleDescription: content.style.visualDescription)
    }

    /// Images a check of the version this intent will produce would send (for the parent's
    /// estimate, before it exists): 1 + the references. nil if the target can't be resolved.
    public static func imageCount(intent: GenerationIntent, target: GenerationTarget, content: BookContent,
                                  provider: ProviderID? = nil) -> Int? {
        references(intent: intent, target: target, messageID: nil, content: content, provider: provider,
                   excluding: nil).map { 1 + $0.0.count }
    }

    /// The session's target: the box that holds it now (box IDs can move), or its asset owner.
    public static func target(for session: Session, in content: BookContent) -> GenerationTarget? {
        switch session.owner {
        case .pageBox:
            for (pageID, page) in content.pages {
                for (boxID, slot) in page.images where slot.sessionID == session.id { return .pageBox(pageID, boxID) }
            }
            return nil
        case let .assetReference(asset, slot): return .assetReference(asset, slot)
        case let .sheetItem(asset, item): return .sheetItem(asset, item)
        }
    }

    static func references(intent: GenerationIntent, target: GenerationTarget, messageID: MessageID?,
                           content: BookContent, provider: ProviderID?,
                           excluding checked: ImageRef?) -> ([PlannedImage], [ConsistencyAssetContext])? {
        guard let prepared = ContextAssembler.prepare(intent: intent, target: target, messageID: messageID,
                                                      content: content) else { return nil }
        let photosAllowed = provider.map { content.book.acknowledgements.realPersonPhotoNotice.contains($0) } ?? false
        let usable = prepared.candidates.filter { $0.ref != checked && (photosAllowed || !$0.depictsRealPerson) }
        let assetTiers: Set<ReferenceSelector.Tier> = [.mentionedPrimary, .checklistPrimary, .sheetItem, .otherSlot]
        let assetImages = usable.filter { assetTiers.contains($0.tier) }
        let style = usable.filter { $0.tier == .style }.prefix(maxStyleReferences)
        let planned = (assetImages + style).map {
            PlannedImage(ref: $0.ref, role: $0.role, label: $0.label, pixelSize: $0.pixelSize)
        }
        let assets = prepared.assets.map {
            ConsistencyAssetContext(name: $0.asset.name, description: $0.asset.description)
        }
        return (planned, assets)
    }

    /// Takes the bytes read for `plan`. References whose bytes are missing are left out (the
    /// labels then match what's sent); a missing checked image throws `.baseImageMissing`.
    /// `instructions` defaults to `ConsistencyPrompt.instructions` (tests inject a fake).
    public static func assemble(
        _ plan: ConsistencyPlan, model: CatalogTextModel, imageData: [ImageRef: Data],
        instructions: ConsistencyInstructions = ConsistencyPrompt.instructions
    ) throws(AssemblyError) -> AssembledConsistency {
        guard let checkedData = imageData[plan.checked.ref], !checkedData.isEmpty else { throw .baseImageMissing }
        let checked = LabeledImage(label: plan.checked.label,
                                   payload: downscaled(checkedData, contentType: plan.checked.ref.contentType,
                                                       ref: plan.checked.ref))
        var references: [LabeledImage] = []
        var sent = [SentReference(image: plan.checked.ref, role: plan.checked.role, label: plan.checked.label)]
        for image in plan.references {
            guard let data = imageData[image.ref], !data.isEmpty else { continue }
            references.append(LabeledImage(label: image.label,
                                           payload: downscaled(data, contentType: image.ref.contentType, ref: image.ref)))
            sent.append(SentReference(image: image.ref, role: image.role, label: image.label))
        }
        let text = instructions(plan.assets, plan.styleDescription, sent.map(\.label))
        let request = ConsistencyRequest(model: model, system: text.system, user: text.user, image: checked,
                                         references: references)
        return AssembledConsistency(request: request, promptText: text.system + "\n\n" + text.user, imagesSent: sent)
    }

    // MARK: Downscaling

    /// The image with its long edge at most `maxLongEdge`: unchanged if it already fits or can't
    /// be decoded, else re-encoded as JPEG (quality 0.9), or PNG when it has alpha (A §7.4).
    public static func downscaled(_ data: Data, contentType: String, ref: ImageRef? = nil) -> ImagePayload {
        let original = ImagePayload(data: data, contentType: contentType, ref: ref, pixelSize: ImageHeader.pixelSize(of: data))
        guard let size = original.pixelSize, max(size.width, size.height) > maxLongEdge,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return original }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return original }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)
        else { return original }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return original }
        return ImagePayload(data: out as Data, contentType: type.identifier, ref: ref,
                            pixelSize: PixelSize(width: image.width, height: image.height))
    }
}

/// How a consistency-check item reads in the Queue window ("Image 1 · Consistency check").
public enum ConsistencyQueueLabel {
    public static let suffix = "Consistency check"

    public static func label(for boxLabel: String) -> String {
        boxLabel.isEmpty ? suffix : "\(boxLabel) · \(suffix)"
    }
}

/// `ConsistencyPrompt.instructions`' shape: assets, style description, image labels in send
/// order → system and user text.
public typealias ConsistencyInstructions = @Sendable ([ConsistencyAssetContext], String, [String])
    -> (system: String, user: String)
