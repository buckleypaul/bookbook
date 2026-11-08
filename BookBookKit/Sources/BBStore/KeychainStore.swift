import BBModel
import Foundation

// Owned by the Store lane. Contract stub: signatures are frozen, bodies are placeholders.

/// The app's own API keys (A §5.5): generic-password items, service `app.bookbook.api-key`,
/// account = provider ID, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable.
/// Never reads the dev item (`openai-api-key`).
public struct KeychainStore: Sendable {
    public static let appService = "app.bookbook.api-key"
    public var service: String

    /// Tests pass a throwaway service name.
    public init(service: String = KeychainStore.appService) {
        self.service = service
    }

    public func read(_ provider: ProviderID) -> APIKey? {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// True if an item exists, without reading the secret.
    public func hasKey(_ provider: ProviderID) -> Bool {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// Adds or replaces the item.
    public func save(_ key: APIKey, for provider: ProviderID) throws(StoreError) {
        fatalError("Phase 2 Store lane: not implemented")
    }

    public func delete(_ provider: ProviderID) throws(StoreError) {
        fatalError("Phase 2 Store lane: not implemented")
    }
}
