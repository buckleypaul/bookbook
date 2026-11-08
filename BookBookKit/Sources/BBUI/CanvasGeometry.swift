import BBModel
import CoreGraphics

/// Fit-to-view transform between the canvas (flipped view space) and the page's trim space
/// (points, top-left origin, y down).
struct CanvasTransform: Equatable {
    /// View points per page point.
    var scale: CGFloat
    /// Where the trim's top-left sits in the view.
    var origin: CGPoint

    init(viewSize: CGSize, pageSize: CGSize, margin: CGFloat = 24) {
        let available = CGSize(width: max(1, viewSize.width - 2 * margin), height: max(1, viewSize.height - 2 * margin))
        let scale = (pageSize.width > 0 && pageSize.height > 0)
            ? min(available.width / pageSize.width, available.height / pageSize.height) : 1
        self.scale = max(scale, 0.01)
        self.origin = CGPoint(x: ((viewSize.width - pageSize.width * self.scale) / 2).rounded(),
                              y: ((viewSize.height - pageSize.height * self.scale) / 2).rounded())
    }

    func toPage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}

enum CanvasHitTest {
    /// The topmost box containing `point` (boxes are in layer order, first drawn first).
    static func box(at point: CGPoint, in boxes: [(box: Box, rect: CGRect)]) -> Box? {
        boxes.last { $0.rect.contains(point) }?.box
    }

    /// A text box's rect inset by its padding (the text container's area).
    static func textRect(_ rect: CGRect, box: Box) -> CGRect {
        guard case let .text(style) = box.content else { return rect }
        let inset = rect.insetBy(dx: style.padding, dy: style.padding)
        return inset.width > 0 && inset.height > 0 ? inset : rect
    }
}
