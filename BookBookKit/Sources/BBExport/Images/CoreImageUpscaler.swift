import CoreGraphics
import CoreImage
import Foundation

/// A §9.2 step 3: Lanczos resample to exactly `size`, plus a light luminance sharpen when
/// enlarging. Downsampling is Lanczos only.
public struct CoreImageUpscaler: Upscaler {
    /// `CISharpenLuminance` sharpness used after enlarging.
    public static let sharpness: Double = 0.4

    public init() {}

    public func upscale(_ image: CGImage, to size: CGSize) async throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        if image.width == width && image.height == height { return image }

        let source = CIImage(cgImage: image)
        let scaleX = Double(width) / Double(image.width)
        let scaleY = Double(height) / Double(image.height)

        let lanczos = CIFilter(name: "CILanczosScaleTransform")
        lanczos?.setValue(source, forKey: kCIInputImageKey)
        lanczos?.setValue(scaleY, forKey: kCIInputScaleKey)
        lanczos?.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        guard var output = lanczos?.outputImage else { throw ExportError.encodingFailed }

        if scaleX > 1 || scaleY > 1, let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(Self.sharpness, forKey: kCIInputSharpnessKey)
            if let sharpened = sharpen.outputImage { output = sharpened }
        }

        // Lanczos output can be a pixel off the target; clamp and crop to exactly `size`.
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        output = output.clampedToExtent().cropped(to: target)

        let colorSpace = renderingColorSpace(for: image)
        let context = CoreImageContexts.context(workingIn: colorSpace)
        guard let result = context.createCGImage(output, from: target, format: .RGBA8, colorSpace: colorSpace) else {
            throw ExportError.encodingFailed
        }
        return result
    }
}
