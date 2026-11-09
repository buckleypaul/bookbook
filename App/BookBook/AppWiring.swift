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
        let support = appSupportFolder(arguments: launchArguments())
        let model = AppModel(providers: providers(keychain: keychain), libraryRoot: libraryRoot(),
                             keychainService: keychain.service,
                             indexCacheURL: support.map(indexCacheURL(in:)) ?? LibraryIndex.defaultCacheURL,
                             appSupport: AppSupportFiles(folderURL: support),
                             listers: listers(keychain: keychain),
                             network: NetworkMonitor(), visionProviders: [.openai: chat])
        model.layoutProvider = chat
        return model
    }

    /// The argument domain (`-Key value` launch arguments; never saved).
    static func launchArguments() -> [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    /// With `-BookBookLibraryRoot /path`, the app-level files (`queue.json`, `pricelist.json`,
    /// the index cache) live in `<root>/.bookbook-support/`, so a throwaway library never sees
    /// or adds to the real queue (#26, #32a). nil = the default app-support folder.
    static func appSupportFolder(arguments: [String: Any]) -> URL? {
        LibraryLocation.argumentRoot(arguments: arguments)?
            .appending(path: ".bookbook-support", directoryHint: .isDirectory)
    }

    /// The library index cache inside a per-library support folder.
    static func indexCacheURL(in folder: URL) -> URL {
        folder.appending(path: "library-index.json", directoryHint: .notDirectory)
    }

    /// Phase 12: OpenAI Chat Completions for templates (layout) and the consistency check
    /// (vision); the app's own Keychain item, read at request time.
    static func chatProvider(keychain: KeychainStore) -> OpenAIChatProvider {
        OpenAIChatProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })
    }

    /// The library folder: the `-BookBookLibraryRoot /path` launch argument (argument domain
    /// only; never saved), then the `libraryPath` setting, then the default.
    static func libraryRoot() -> URL {
        LibraryLocation.resolve(arguments: launchArguments(), defaults: UserDefaults.standard)
    }

    /// The provider reads the app's own Keychain item at request time (never the dev item).
    static func providers(keychain: KeychainStore) -> [ProviderID: any ImageProvider] {
        [.openai: OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })]
    }

    /// List-models for Test connection and availability; the same app Keychain item, read at
    /// call time (never the dev item). None while the app is a test host, so a saved in-app key
    /// never triggers a `/models` call during `scripts/test.sh app` (#44).
    static func listers(keychain: KeychainStore,
                        underTests: Bool = OnboardingState.runningUnderTests) -> [ProviderID: any ModelLister] {
        guard !underTests else { return [:] }
        return [.openai: OpenAIModelLister(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })]
    }
}
