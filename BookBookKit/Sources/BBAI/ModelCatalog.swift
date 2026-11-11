import BBAICore
import BBModel
import Foundation

/// The bundled model catalog (A §7.1), with `copyCapabilitiesFrom` resolved.
public struct ModelCatalog: Sendable {
    public var asOf: String
    public var imageModels: [CatalogModel]
    /// Phase 12: text (`kind: text`) and vision (`kind: vision`) models.
    public var textModels: [CatalogTextModel]

    public init(asOf: String, imageModels: [CatalogModel], textModels: [CatalogTextModel] = []) {
        self.asOf = asOf
        self.imageModels = imageModels
        self.textModels = textModels
    }

    /// Phase 12: models usable for templates (`kind: text`) or the consistency check (`kind: vision`).
    public func textModels(kind: TextModelKind) -> [CatalogTextModel] { textModels.filter { $0.kind == kind } }
    public func textModel(provider: ProviderID, id: String) -> CatalogTextModel? {
        textModels.first { $0.provider == provider && $0.id == id }
    }

    public enum CatalogError: Error, Equatable, Sendable {
        case missingResource
        case unknownCapabilitySource(model: String, source: String)
        case malformed(String)
    }

    /// Decodes `ModelCatalog.json` data. Image entries become `imageModels`; text and vision entries become `textModels` (Phase 12).
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(RawCatalog.self, from: data)
        let images = file.models.filter { $0.kind == "image" }
        var resolved: [CatalogModel] = []
        for raw in images {
            var capabilities = raw.image
            var hops = 0
            // Follow `copyCapabilitiesFrom` (bounded, so a cycle cannot loop forever).
            while let source = capabilities?.copyCapabilitiesFrom {
                guard hops < 8, let next = images.first(where: { $0.provider == raw.provider && $0.id == source }) else {
                    throw CatalogError.unknownCapabilitySource(model: raw.id, source: source)
                }
                capabilities = next.image
                hops += 1
            }
            guard let caps = capabilities, let image = try caps.resolved(model: raw.id) else {
                throw CatalogError.malformed("image model \(raw.id) has no capabilities")
            }
            var durations: [QualityLevel: Double] = [:]
            for (key, value) in raw.typicalDurationSeconds ?? [:] {
                if let level = QualityLevel(rawValue: key) { durations[level] = value }
            }
            resolved.append(CatalogModel(
                provider: ProviderID(rawValue: raw.provider), id: raw.id, displayName: raw.displayName,
                status: ModelStatus(rawValue: raw.status ?? "current") ?? .current, successor: raw.successor,
                typicalDurationSeconds: durations, image: image))
        }
        var texts: [CatalogTextModel] = []
        for raw in file.models {
            guard let kind = TextModelKind(rawValue: raw.kind) else { continue }
            texts.append(CatalogTextModel(
                provider: ProviderID(rawValue: raw.provider), id: raw.id, displayName: raw.displayName, kind: kind,
                status: ModelStatus(rawValue: raw.status ?? "current") ?? .current, successor: raw.successor,
                typicalDurationSeconds: raw.typicalDurationSeconds?["default"],
                imageDetail: kind == .vision ? raw.vision?.detail : nil,
                consistency: kind == .vision
                    ? raw.consistency.map { ConsistencyThresholds(warnOnMajor: $0.warnOnMajor ?? 1, warnOnMinor: $0.warnOnMinor ?? 3) }
                    : nil))
        }
        self.init(asOf: file.asOf, imageModels: resolved, textModels: texts)
    }

    /// The catalog bundled in BBAI's resources.
    public static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try ModelCatalog(data: Data(contentsOf: url))
    }

    public func imageModel(provider: ProviderID, id: String) -> CatalogModel? {
        imageModels.first { $0.provider == provider && $0.id == id }
    }

    /// OpenAI's default image model.
    public static let defaultOpenAIImageModelID = "gpt-image-2.5-sunburst"

    /// The default image model per provider (OpenAI: `defaultOpenAIImageModelID`).
    public func defaultImageModel(for provider: ProviderID) -> CatalogModel? {
        let preferred: [ProviderID: String] = [.openai: Self.defaultOpenAIImageModelID]
        if let id = preferred[provider], let model = imageModel(provider: provider, id: id) { return model }
        return imageModels.first { $0.provider == provider && $0.status == .current }
    }

    // MARK: Phase 9 additions (A §7.1 items 1-3)

    /// Appends custom models that copy a bundled family. Specs with an unknown family (or an
    /// already-used id) are skipped; use `addingReporting` to see which.
    public func adding(_ specs: [CustomModelSpec]) -> ModelCatalog {
        addingReporting(specs).catalog
    }

    public func addingReporting(_ specs: [CustomModelSpec]) -> (catalog: ModelCatalog, skipped: [CustomModelSpec]) {
        var result = self
        var skipped: [CustomModelSpec] = []
        for spec in specs {
            guard let family = imageModel(provider: spec.provider, id: spec.copiesFrom), family.copiesFrom == nil,
                  result.imageModel(provider: spec.provider, id: spec.id) == nil else {
                skipped.append(spec)
                continue
            }
            result.imageModels.append(CatalogModel(
                provider: spec.provider, id: spec.id, displayName: "\(spec.id) (custom)", status: .current,
                typicalDurationSeconds: family.typicalDurationSeconds, image: family.image, copiesFrom: family.id))
        }
        return (result, skipped)
    }

    /// The model, or (when retired) its successor. Follows `successor` links with a loop guard.
    public func resolve(provider: ProviderID, id: String) -> CatalogModel? {
        guard var model = imageModel(provider: provider, id: id) else { return nil }
        var seen: Set<String> = [model.id]
        while model.status == .retired, let next = model.successor,
              let successor = imageModel(provider: provider, id: next), seen.insert(successor.id).inserted {
            model = successor
        }
        return model
    }

    public func imageModels(for provider: ProviderID) -> [CatalogModel] {
        imageModels.filter { $0.provider == provider }
    }

    /// `listed` is the set of model IDs from the provider's list-models call (nil: not checked).
    public func availability(of model: CatalogModel, listed: Set<String>?) -> ModelAvailability {
        guard let listed else { return .unknown }
        if listed.contains(model.id) { return .available }
        return .unavailable(successor: model.successor)
    }
}

// MARK: - JSON shape

private struct RawCatalog: Decodable {
    var asOf: String
    var models: [RawModel]
}

private struct RawModel: Decodable {
    var provider: String
    var id: String
    var displayName: String
    var kind: String
    var status: String?
    var successor: String?
    var typicalDurationSeconds: [String: Double]?
    var image: RawImage?
    var vision: RawVision?
    var consistency: RawConsistency?
}

private struct RawVision: Decodable {
    var detail: String?
}

private struct RawConsistency: Decodable {
    var warnOnMajor: Int?
    var warnOnMinor: Int?
}

private struct RawImage: Decodable {
    var copyCapabilitiesFrom: String?
    var maxReferenceImages: Int?
    var maxImageBytes: Int?
    var maxRequestBytes: Int?
    var supportsMask: Bool?
    var nativeMultiTurn: Bool?
    var aspect: RawAspect?
    var quality: [String: QualityMapping]?

    struct RawAspect: Decodable {
        var mode: String
        var minRatio: Double?
        var maxRatio: Double?
        var multipleOf: Int?
        var minPixels: Int?
        var maxPixels: Int?
        var experimentalAbovePixels: Int?
        var ratios: [String]?
    }

    func resolved(model: String) throws -> ImageCapabilities? {
        guard let aspect, let quality else { return nil }
        let rule: AspectRule
        switch aspect.mode {
        case "free":
            guard let minRatio = aspect.minRatio, let maxRatio = aspect.maxRatio, let multiple = aspect.multipleOf,
                  let minPixels = aspect.minPixels, let maxPixels = aspect.maxPixels else {
                throw ModelCatalog.CatalogError.malformed("free aspect of \(model) is incomplete")
            }
            rule = .free(minRatio: minRatio, maxRatio: maxRatio, multipleOf: multiple, minPixels: minPixels,
                         maxPixels: maxPixels, experimentalAbovePixels: aspect.experimentalAbovePixels)
        case "fixed":
            guard let ratios = aspect.ratios, !ratios.isEmpty else {
                throw ModelCatalog.CatalogError.malformed("fixed aspect of \(model) has no ratios")
            }
            rule = .fixed(ratios: ratios)
        default:
            throw ModelCatalog.CatalogError.malformed("unknown aspect mode \(aspect.mode) in \(model)")
        }
        var levels: [QualityLevel: QualityMapping] = [:]
        for (key, mapping) in quality {
            if let level = QualityLevel(rawValue: key) { levels[level] = mapping }
        }
        return ImageCapabilities(
            maxReferenceImages: maxReferenceImages ?? 0, maxImageBytes: maxImageBytes ?? 0,
            maxRequestBytes: maxRequestBytes ?? 0, supportsMask: supportsMask ?? false,
            nativeMultiTurn: nativeMultiTurn ?? false, aspect: rule, quality: levels)
    }
}
