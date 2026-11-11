import CoreGraphics

/// Crop-mark geometry for print-shop output (A §9.1). Media space: origin top-left, y down.
extension CropMarks {
    /// Line segments in media space for a media box laid out as mark area + bleed + trim.
    /// Eight segments, two per trim corner, on the extensions of the trim lines, running from
    /// `offsetFromBleed` past the bleed edge out to the media edge (`markArea` beyond the bleed).
    public static func segments(trim: CGRect, bleed: CGFloat) -> [CropMarkSegment] {
        let inner = max(0, bleed) + offsetFromBleed
        let outer = max(0, bleed) + markArea
        var result: [CropMarkSegment] = []
        for y in [trim.minY, trim.maxY] {
            // Horizontal marks, left then right of the trim.
            result.append(CropMarkSegment(start: CGPoint(x: trim.minX - outer, y: y),
                                          end: CGPoint(x: trim.minX - inner, y: y)))
            result.append(CropMarkSegment(start: CGPoint(x: trim.maxX + inner, y: y),
                                          end: CGPoint(x: trim.maxX + outer, y: y)))
        }
        for x in [trim.minX, trim.maxX] {
            // Vertical marks, above then below the trim.
            result.append(CropMarkSegment(start: CGPoint(x: x, y: trim.minY - outer),
                                          end: CGPoint(x: x, y: trim.minY - inner)))
            result.append(CropMarkSegment(start: CGPoint(x: x, y: trim.maxY + inner),
                                          end: CGPoint(x: x, y: trim.maxY + outer)))
        }
        return result
    }
}
