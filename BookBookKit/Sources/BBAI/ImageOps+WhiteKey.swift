import BBModel
import CoreGraphics
import Foundation

// AI text styling (A §7.13): a text-box decoration is asked for on plain white when the model
// can't return a transparent background, and the white is keyed out here.

extension ImageOps {
    /// Deviation from white (0…1, the largest channel's distance from 255) at or below which a
    /// pixel becomes fully transparent: every channel ≥ 245.
    static let whiteKeyLow = 10.0 / 255
    /// Deviation at or above which a pixel stays fully opaque, so saturated and dark ornament
    /// keeps its colour; between the two, alpha ramps and the colour is un-blended from white.
    static let whiteKeyHigh = 0.3

    /// Colour-to-alpha against white: near-white becomes transparent, ink stays opaque, and the
    /// soft edges in between are un-blended from white (c' = (c − (1 − a)·255) / a) so they don't
    /// leave a white halo. Returns a PNG with alpha at the same pixel size, or nil when the bytes
    /// can't be decoded or encoded.
    public static func keyOutWhite(pngData: Data) -> Data? {
        guard let image = try? decodeImage(pngData) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, var bytes = try? rgba(of: image, width: width, height: height) else { return nil }
        let span = whiteKeyHigh - whiteKeyLow
        bytes.withUnsafeMutableBufferPointer { px in
            for i in stride(from: 0, to: px.count, by: 4) {
                let sourceAlpha = Double(px[i + 3])
                guard sourceAlpha > 0 else { continue }
                // Un-premultiply (the decoded bytes are premultiplied).
                let scale = 255 / sourceAlpha
                let r = min(255, Double(px[i]) * scale)
                let g = min(255, Double(px[i + 1]) * scale)
                let b = min(255, Double(px[i + 2]) * scale)
                let deviation = (255 - min(r, g, b)) / 255
                let a = min(1, max(0, (deviation - whiteKeyLow) / span))
                let outAlpha = a * sourceAlpha / 255
                // Premultiplied un-blended colour: c'·a = c − (1 − a)·255, kept within [0, a·255].
                func channel(_ c: Double) -> UInt8 {
                    let premultiplied = min(max(c - (1 - a) * 255, 0), a * 255) * sourceAlpha / 255
                    return UInt8(premultiplied.rounded())
                }
                px[i] = channel(r)
                px[i + 1] = channel(g)
                px[i + 2] = channel(b)
                px[i + 3] = UInt8((outAlpha * 255).rounded())
            }
        }
        return try? encodeRGBA(bytes, width: width, height: height)
    }

    /// True when the image has at least one pixel that isn't fully opaque; nil when it can't be
    /// decoded. A decoration that already has transparency (the provider honoured a transparent
    /// background) is not keyed again.
    public static func hasTransparentPixels(_ data: Data) -> Bool? {
        guard let image = try? decodeImage(data) else { return nil }
        guard hasAlpha(image) else { return false }
        guard let bytes = try? rgba(of: image, width: image.width, height: image.height) else { return nil }
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] < 255 }
    }
}
