import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import Observation

// Phase 9 contract (main thread). App-wide preferences (PD §8.11, A §5.5) and the effective
// price list. Keys and secrets never go here: the API key lives only in the Keychain.

/// Default model and quality, the confirmation threshold and custom model IDs, in `UserDefaults`.
@MainActor @Observable
public final class AppPreferences {
    public enum Key {
        public static let defaultImageModel = "defaultImageModel"
        public static let defaultQuality = "defaultQuality"
        public static let confirmThreshold = "costConfirmThreshold"
        public static let customModels = "customModels"
        public static let consistencyCheckEnabled = "consistencyCheckEnabled"
        public static let defaultTemplateModel = "defaultTemplateModel"
        public static let defaultConsistencyModel = "defaultConsistencyModel"
    }

    /// Phase 12 (PD §8.9, §8.11): the global consistency-check switch. On by default.
    public var consistencyCheckEnabled: Bool {
        didSet { defaults.set(consistencyCheckEnabled, forKey: Key.consistencyCheckEnabled) }
    }
    /// Phase 12 (PD §8.11): default model for AI templates (a catalog `kind: text` ID; the
    /// provider is the catalog entry's).
    public var defaultTemplateModelID: String {
        didSet { defaults.set(defaultTemplateModelID, forKey: Key.defaultTemplateModel) }
    }
    /// Phase 12 (PD §8.11): default model for the consistency check (a catalog `kind: vision` ID).
    public var defaultConsistencyModelID: String {
        didSet { defaults.set(defaultConsistencyModelID, forKey: Key.defaultConsistencyModel) }
    }

    /// The default image model ID for OpenAI (the only image provider until Phase 13).
    public var defaultImageModelID: String {
        didSet {
            defaults.set(defaultImageModelID, forKey: Key.defaultImageModel)
            onDefaultModelChange()
        }
    }
    public var defaultQuality: QualityLevel { didSet { defaults.set(defaultQuality.rawValue, forKey: Key.defaultQuality) } }
    /// Ask before enqueueing when a request or batch estimate is above this (USD).
    public var confirmThreshold: Decimal {
        didSet { defaults.set(NSDecimalNumber(decimal: confirmThreshold).stringValue, forKey: Key.confirmThreshold) }
    }
    public var customModels: [CustomModelSpec] {
        didSet {
            defaults.set(try? JSONEncoder().encode(customModels), forKey: Key.customModels)
            onCustomModelsChange()
        }
    }

    /// `AppModel` rebuilds the effective catalog and pushes it to the queue.
    @ObservationIgnored var onCustomModelsChange: () -> Void = {}
    /// `AppModel` re-checks `missingDefaultModel`.
    @ObservationIgnored var onDefaultModelChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults, fallbackModelID: String, fallbackTemplateModelID: String = "gpt-6-luna",
                fallbackConsistencyModelID: String = "gpt-6.1-terra") {
        self.defaults = defaults
        consistencyCheckEnabled = defaults.object(forKey: Key.consistencyCheckEnabled) as? Bool ?? true
        defaultTemplateModelID = defaults.string(forKey: Key.defaultTemplateModel) ?? fallbackTemplateModelID
        defaultConsistencyModelID = defaults.string(forKey: Key.defaultConsistencyModel) ?? fallbackConsistencyModelID
        defaultImageModelID = defaults.string(forKey: Key.defaultImageModel) ?? fallbackModelID
        defaultQuality = defaults.string(forKey: Key.defaultQuality).flatMap(QualityLevel.init(rawValue:)) ?? .standard
        confirmThreshold = defaults.string(forKey: Key.confirmThreshold).flatMap { Decimal(string: $0) }
            ?? CostPolicy.defaultThreshold
        customModels = defaults.data(forKey: Key.customModels)
            .flatMap { try? JSONDecoder().decode([CustomModelSpec].self, from: $0) } ?? []
    }
}

/// The effective price list: the user's `pricelist.json` when valid, else the bundled list
/// (A §7.10). The Settings editor edits a copy and saves it here.
@MainActor @Observable
public final class PriceBook {
    public private(set) var bundled: PriceList
    public private(set) var current: PriceList
    /// True when the user's copy is in use.
    public private(set) var isUserCopy: Bool
    /// Why the user's copy was ignored (unreadable or malformed), if it was.
    public private(set) var userCopyError: String?

    /// `AppModel` pushes the new prices to the queue (`setPricing`).
    @ObservationIgnored var onChange: (PriceList) -> Void = { _ in }
    @ObservationIgnored private let files: AppSupportFiles

    public init(files: AppSupportFiles, bundled: PriceList? = nil) {
        self.files = files
        let bundled = bundled ?? ((try? PriceList.bundled()) ?? PriceList(asOf: "", entries: []))
        self.bundled = bundled
        let userData = files.read(AppSupportFiles.priceListFileName)
        let resolved = PriceList.resolved(bundled: bundled, userData: userData)
        current = resolved.list
        isUserCopy = userData != nil && resolved.userOverrideError == nil
        userCopyError = resolved.userOverrideError
    }

    public var calculator: CostCalculator { CostCalculator(priceList: current) }

    /// Saves `list` as the user's copy and makes it current.
    public func save(_ list: PriceList) throws {
        try files.write(list.encoded(), to: AppSupportFiles.priceListFileName)
        current = list
        isUserCopy = true
        userCopyError = nil
        onChange(list)
    }

    /// "Reset to built-in": removes the user's copy.
    public func resetToBuiltIn() throws {
        try files.remove(AppSupportFiles.priceListFileName)
        current = bundled
        isUserCopy = false
        userCopyError = nil
        onChange(bundled)
    }
}
