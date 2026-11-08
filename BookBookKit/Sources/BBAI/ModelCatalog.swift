import BBAICore
import BBModel
import Foundation

/// The bundled model catalog (A §7.1), with `copyCapabilitiesFrom` resolved.
public struct ModelCatalog: Sendable {
    public var asOf: String
    public var imageModels: [CatalogModel]

    public init(asOf: String, imageModels: [CatalogModel]) {
        self.asOf = asOf
        self.imageModels = imageModels
    }

    public enum CatalogError: Error, Equatable, Sendable {
        case missingResource
        case unknownCapabilitySource(model: String, source: String)
        case malformed(String)
    }

    /// Decodes `ModelCatalog.json` data. Non-image entries are skipped in Phase 2.
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
        self.init(asOf: file.asOf, imageModels: resolved)
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

    /// The default image model per provider (OpenAI: `gpt-image-2.5-sunburst`).
    public func defaultImageModel(for provider: ProviderID) -> CatalogModel? {
        let preferred: [ProviderID: String] = [.openai: "gpt-image-2.5-sunburst"]
        if let id = preferred[provider], let model = imageModel(provider: provider, id: id) { return model }
        return imageModels.first { $0.provider == provider && $0.status == .current }
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
