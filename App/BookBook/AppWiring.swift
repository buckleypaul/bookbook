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
        return AppModel(providers: providers(keychain: keychain), libraryRoot: libraryRoot(),
                        keychainService: keychain.service)
    }

    /// The default library, or a throwaway one for development runs: launch with
    /// `-BookBookLibraryRoot /path` (argument domain only; nothing is persisted).
    static func libraryRoot() -> URL {
        guard let path = UserDefaults.standard.string(forKey: "BookBookLibraryRoot"), !path.isEmpty else {
            return Library.defaultRoot
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The provider reads the app's own Keychain item at request time (never the dev item).
    static func providers(keychain: KeychainStore) -> [ProviderID: any ImageProvider] {
        [.openai: OpenAIImageProvider(http: URLSessionHTTPClient(), apiKey: { keychain.read(.openai) })]
    }
}
