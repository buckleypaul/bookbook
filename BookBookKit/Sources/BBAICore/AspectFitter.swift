import BBModel
import Foundation

/// Picks a concrete output size for a box aspect (architecture.md §7.5).
public enum AspectFitter {
    public enum Fit: Hashable, Sendable {
        /// Free-size models: exact pixels to send as `size`.
        case pixels(PixelSize)
        /// Fixed-ratio models: the ratio string to send (e.g. "2:3").
        case ratio(String)
    }

    public static func fit(boxAspect: Double, model: CatalogModel, quality: QualityLevel) -> Fit {
        switch model.image.aspect {
        case let .free(minRatio, maxRatio, multipleOf, minPixels, maxPixels, experimentalAbove):
            let target = model.image.quality[quality]?.targetPixels ?? 1_048_576
            let ceiling = min(maxPixels, experimentalAbove ?? maxPixels)
            return .pixels(freeSize(boxAspect: boxAspect, targetPixels: target, minRatio: minRatio, maxRatio: maxRatio,
                                    multipleOf: multipleOf, minPixels: minPixels, maxPixels: ceiling))
        case let .fixed(ratios):
            return .ratio(nearestRatio(boxAspect: boxAspect, ratios: ratios) ?? "1:1")
        }
    }

    /// Free-size fit: clamp the ratio, solve `w·h ≈ target` with `w/h = r`, round to
    /// multiples, then keep the pixel count inside `[minPixels, maxPixels]`.
    public static func freeSize(boxAspect: Double, targetPixels: Int, minRatio: Double, maxRatio: Double,
                                multipleOf m: Int, minPixels: Int, maxPixels: Int) -> PixelSize {
        let ratio = min(max(boxAspect.isFinite && boxAspect > 0 ? boxAspect : 1, minRatio), maxRatio)
        let target = Double(min(max(targetPixels, minPixels), maxPixels))
        let height = (target / ratio).squareRoot()
        var w = roundTo(height * ratio, m), h = roundTo(height, m)
        // Nudge by one step at a time to stay inside the pixel bounds, keeping the ratio close.
        while w * h > maxPixels {
            if Double(w) / Double(h) > ratio { w -= m } else { h -= m }
        }
        while w * h < minPixels {
            if Double(w) / Double(h) < ratio { w += m } else { h += m }
        }
        return PixelSize(width: w, height: h)
    }

    /// The supported ratio minimizing |log(r_box) − log(r_model)|.
    public static func nearestRatio(boxAspect: Double, ratios: [String]) -> String? {
        ratios.min { abs(log(boxAspect) - log(value($0))) < abs(log(boxAspect) - log(value($1))) }
    }

    private static func value(_ ratio: String) -> Double {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 1 }
        return parts[0] / parts[1]
    }

    private static func roundTo(_ x: Double, _ m: Int) -> Int {
        max(m, Int((x / Double(m)).rounded()) * m)
    }
}
