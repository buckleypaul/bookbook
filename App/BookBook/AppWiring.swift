import BBAICore
import BBModel
import BBNet
import BBOpenAI
import BBStore
import BBUI
import Foundation

/// The one place the app wires concrete providers into BBUI (CLAUDE.md: providers depend on
/// BBAICore; the app wires them up).
@MainActor
enum AppWiring {
    static func makeModel() -> AppModel {
        let keychain = KeychainStore()
        let chat = chatProvider(keychain: keychain)
        let model = AppModel(providers: providers(keychain: keychain), libraryRoot: libraryRoot(),
                             keychainService: keychain.service, listers: listers(keychain: keychain),
                             network: NetworkMonitor(), visionProviders: [.openai: chat])
        model.layoutProvider = chat
        return model
    }

    /// Phase 12: OpenAI Chat Completions for templates (layout) and the consistency check
    /// (vision); the app's own Keychain item, read at request time.
    static func chatProvider(keychain: KeychainStore) -> OpenAIChatProvider {
        OpenAIChatProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })
    }

    /// The library folder: the `-BookBookLibraryRoot /path` launch argument (argument domain
    /// only; never saved), then the `libraryPath` setting, then the default.
    static func libraryRoot() -> URL {
        let defaults = UserDefaults.standard
        return LibraryLocation.resolve(arguments: defaults.volatileDomain(forName: UserDefaults.argumentDomain),
                                       defaults: defaults)
    }

    /// The provider reads the app's own Keychain item at request time (never the dev item).
    static func providers(keychain: KeychainStore) -> [ProviderID: any ImageProvider] {
        [.openai: OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })]
    }

    /// List-models for Test connection and availability; the same app Keychain item, read at
    /// call time (never the dev item).
    static func listers(keychain: KeychainStore) -> [ProviderID: any ModelLister] {
        [.openai: OpenAIModelLister(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })]
    }
}
