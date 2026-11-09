import BBLayout
import BBModel
import CoreGraphics
import Foundation

public enum ImagePreparationPlanner {
    /// One request per placed image box on `page` (A §9.2 steps 1–2). Boxes with no placed
    /// version, or whose image size is unknown, are skipped. Box rotation is ignored: the crop
    /// is the unrotated render rect's footprint on the image, as `PageRenderer` fills it.
    public static func requests(page: Page, in content: BookContent,
                                imageURL: (ImageRef) -> URL,
                                pixelSize: (ImageRef) -> CGSize?) -> [ImagePreparationRequest] {
        guard let template = content.template(for: page) else { return [] }
        let geometry = PageGeometry(setup: content.style.pageSetup, kind: template.kind)
        var result: [ImagePreparationRequest] = []
        for box in template.boxes where box.content == .image {
            guard let placement = page.images[box.id]?.placement,
                  let version = content.placedVersion(page: page.id, box: box.id),
                  let imageSize = pixelSize(version.image),
                  imageSize.width > 0, imageSize.height > 0 else { continue }
            let boxRect = geometry.renderRect(for: box)
            guard boxRect.width > 0, boxRect.height > 0 else { continue }
            let target = PageGeometry.imageRect(imageSize: imageSize, boxRect: boxRect, placement: placement)
            guard target.width > 0, target.height > 0 else { continue }

            let sx = imageSize.width / target.width
            let sy = imageSize.height / target.height
            let visible = CGRect(x: (boxRect.minX - target.minX) * sx, y: (boxRect.minY - target.minY) * sy,
                                 width: boxRect.width * sx, height: boxRect.height * sy)
            let bounds = CGRect(origin: .zero, size: imageSize)
            // Whole source pixels, covering the visible area, inside the image.
            let crop = visible.integral.intersection(bounds)
            guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { continue }

            let required = CGSize(width: (boxRect.width / 72 * PrintResolution.dpi).rounded(.up),
                                  height: (boxRect.height / 72 * PrintResolution.dpi).rounded(.up))
            result.append(ImagePreparationRequest(
                key: BoxImageKey(page: page.id, box: box.id), image: version.image,
                sourceURL: imageURL(version.image), cropPixels: crop, requiredPixels: required))
        }
        return result
    }
}
