import BBAICore
import BBModel
import Foundation

/// Loading and saving `PriceList.json` (A §7.10). The bundled list is the default; a user-edited
/// copy (`pricelist.json` in Application Support) takes precedence as a whole.
extension PriceList {
    public static func bundled() throws(PriceListError) -> PriceList {
        guard let url = Bundle.module.url(forResource: "PriceList", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { throw .missingResource }
        return try PriceList(data: data)
    }

    public init(data: Data) throws(PriceListError) {
        do {
            self = try JSONDecoder().decode(PriceList.self, from: data)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// Pretty-printed with sorted keys, so the user's copy diffs cleanly.
    public func encoded() throws(PriceListError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(self)
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// A valid user copy wins as a whole; an invalid one falls back to `bundled` and says why.
    public static func resolved(bundled: PriceList, userData: Data?) -> (list: PriceList, userOverrideError: String?) {
        guard let userData else { return (bundled, nil) }
        do {
            return (try PriceList(data: userData), nil)
        } catch {
            if case let .malformed(reason) = error { return (bundled, reason) }
            return (bundled, "The price list could not be read.")
        }
    }
}
