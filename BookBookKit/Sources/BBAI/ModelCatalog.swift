import BBAICore
import BBModel
import Foundation

// Owned by the AI lane. Contract stub: signatures are frozen, bodies are placeholders.

/// The bundled model catalog (A §7.1), with `copyCapabilitiesFrom` resolved.
public struct ModelCatalog: Sendable {
    public var asOf: String
    public var imageModels: [CatalogModel]

    public init(asOf: String, imageModels: [CatalogModel]) {
        self.asOf = asOf
        self.imageModels = imageModels
    }

    /// Decodes `ModelCatalog.json` data. Non-image entries are skipped in Phase 2.
    public init(data: Data) throws {
        fatalError("Phase 2 AI lane: not implemented")
    }

    /// The catalog bundled in BBAI's resources.
    public static func bundled() throws -> ModelCatalog {
        fatalError("Phase 2 AI lane: not implemented")
    }

    public func imageModel(provider: ProviderID, id: String) -> CatalogModel? {
        imageModels.first { $0.provider == provider && $0.id == id }
    }

    /// The default image model per provider (OpenAI: `gpt-image-2.5-sunburst`).
    public func defaultImageModel(for provider: ProviderID) -> CatalogModel? {
        fatalError("Phase 2 AI lane: not implemented")
    }
}
