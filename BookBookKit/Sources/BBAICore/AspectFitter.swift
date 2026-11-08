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

    /// The edit size for an existing image of `size`: its own size if the model accepts it, otherwise the
    /// nearest valid size with the closest aspect ratio and a similar pixel count. Nil for fixed-ratio
    /// models (they have no free sizes).
    public static func snap(_ size: PixelSize, model: CatalogModel, quality: QualityLevel) -> PixelSize? {
        guard case let .free(minRatio, maxRatio, multipleOf, minPixels, maxPixels, experimentalAbove) = model.image.aspect,
              size.width > 0, size.height > 0 else { return nil }
        let ceiling = min(maxPixels, experimentalAbove ?? maxPixels)
        let ratio = Double(size.width) / Double(size.height)
        let pixels = size.width * size.height
        if size.width % multipleOf == 0, size.height % multipleOf == 0, pixels >= minPixels, pixels <= ceiling,
           ratio >= minRatio, ratio <= maxRatio { return size }
        return freeSize(boxAspect: ratio, targetPixels: pixels, minRatio: minRatio, maxRatio: maxRatio,
                        multipleOf: multipleOf, minPixels: minPixels, maxPixels: ceiling)
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
        // Rounding can push the ratio just outside the model's limits: step a side until it is inside,
        // preferring the step that keeps the pixel count in bounds.
        var guardSteps = 0
        while guardSteps < 64, Double(w) / Double(h) > maxRatio || Double(w) / Double(h) < minRatio {
            guardSteps += 1
            if Double(w) / Double(h) > maxRatio {
                if (w - m) * h >= minPixels { w -= m } else { h += m }
            } else {
                if w * (h - m) >= minPixels { h -= m } else { w += m }
            }
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
