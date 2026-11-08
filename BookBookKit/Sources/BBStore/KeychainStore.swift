import BBModel
import Foundation
import Security

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

    private func query(_ provider: ProviderID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: provider.rawValue,
         kSecAttrSynchronizable: false]
    }

    public func read(_ provider: ProviderID) -> APIKey? {
        var q = query(provider)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let string = String(data: data, encoding: .utf8) else { return nil }
        return APIKey(string)
    }

    /// True if an item exists, without reading the secret.
    public func hasKey(_ provider: ProviderID) -> Bool {
        SecItemCopyMatching(query(provider) as CFDictionary, nil) == errSecSuccess
    }

    /// Adds or replaces the item.
    public func save(_ key: APIKey, for provider: ProviderID) throws(StoreError) {
        let data = Data(key.revealForTransport().utf8)
        var status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public func delete(_ provider: ProviderID) throws(StoreError) {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
