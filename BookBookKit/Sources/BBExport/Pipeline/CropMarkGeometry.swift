import CoreGraphics

/// Crop-mark geometry for print-shop output (A §9.1). Media space: origin top-left, y down.
enum CropMarkGeometry {
    /// Two marks per trim corner, on the extensions of the trim lines, running from
    /// `CropMarks.offsetFromBleed` past the bleed edge out to the media edge
    /// (`CropMarks.markArea` beyond the bleed).
    static func segments(trim: CGRect, bleed: CGFloat) -> [CropMarkSegment] {
        let inner = max(0, bleed) + CropMarks.offsetFromBleed
        let outer = max(0, bleed) + CropMarks.markArea
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
