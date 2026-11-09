import BBAICore
import BBModel
import Foundation

/// Raw error codes for region edits that the queue rejects after the provider call (A §7.6,
/// §7.11). They travel in `ProviderErrorRaw.code`; `RefusalAdvisor` keys plain advice off them.
public enum RegionEditFailure {
    /// The edit area came back (mostly) black: SP-4's "black hole". Kept as a safety net.
    public static let blankAreaCode = "region_blank"
    /// The provider's picture couldn't be decoded or blended into the original.
    public static let compositeFailedCode = "region_composite_failed"

    /// True when `error` is a region edit whose area came back blank.
    public static func isBlankArea(_ error: ProviderError) -> Bool {
        if case let .noImage(raw) = error { return raw?.code == blankAreaCode }
        return false
    }
}

/// The local half of a region edit (A §7.6): black-fill detection, then the feathered composite
/// of the provider's output into the original through the user's mask. Runs off the caller's
/// executor (a detached task), since it touches every pixel.
enum RegionEditCompositor {
    /// Fraction of the edit area that may come back near-black before the edit counts as blank.
    static let blackFillLimit = 0.6

    struct Edit: Sendable {
        /// PNG at the base image's pixel size.
        var png: Data
        var pixelSize: PixelSize
        var featherPixels: Double
    }

    /// Fails with `.noImage` (no version is made) when the area came back blank or the images
    /// can't be used.
    static func composite(raw: Data, base: Data?, storedMask: Data?,
                          featherPixels: Double = ImageOps.defaultFeatherPixels) async -> Result<Edit, ProviderError> {
        await Task.detached(priority: .userInitiated) { () -> Result<Edit, ProviderError> in
            compositeNow(raw: raw, base: base, storedMask: storedMask, featherPixels: featherPixels)
        }.value
    }

    static func compositeNow(raw: Data, base: Data?, storedMask: Data?, featherPixels: Double) -> Result<Edit, ProviderError> {
        guard let base, let storedMask else {
            return .failure(failure(RegionEditFailure.compositeFailedCode,
                                    "The edit's base picture or selected area wasn't available to blend the result."))
        }
        do throws(ImageOpsError) {
            let mask = try ImageOps.decodeMask(storedMask)
            // Decoded once for both the black-fill check and the composite.
            let edited = try ImageOps.decodeImage(raw)
            if try ImageOps.blackFillFraction(of: edited, in: mask) > blackFillLimit {
                return .failure(failure(RegionEditFailure.blankAreaCode,
                                        "The model returned a blank (black) area inside the selected area instead of an edit."))
            }
            let png = try ImageOps.composite(original: base, decodingEdited: { edited }, mask: mask,
                                             featherPixels: featherPixels)
            return .success(Edit(png: png, pixelSize: mask.pixelSize, featherPixels: featherPixels))
        } catch {
            return .failure(failure(RegionEditFailure.compositeFailedCode,
                                    "The model's picture couldn't be blended into the original (\(error))."))
        }
    }

    private static func failure(_ code: String, _ body: String) -> ProviderError {
        .noImage(ProviderErrorRaw(status: nil, code: code, body: body))
    }
}
