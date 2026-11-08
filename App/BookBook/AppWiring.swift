import BBAICore
import BBModel
import BBNet
import BBOpenAI
import BBStore
import BBUI

/// The one place the app wires concrete providers into BBUI (CLAUDE.md: providers depend on
/// BBAICore; the app wires them up).
@MainActor
enum AppWiring {
    static func makeModel() -> AppModel {
        let keychain = KeychainStore()
        return AppModel(providers: providers(keychain: keychain), keychainService: keychain.service)
    }

    /// The provider reads the app's own Keychain item at request time (never the dev item).
    static func providers(keychain: KeychainStore) -> [ProviderID: any ImageProvider] {
        [
            // TODO(main thread, after merging the Net+OpenAI lane): uncomment.
            // .openai: OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) }),
        :]
    }
}
