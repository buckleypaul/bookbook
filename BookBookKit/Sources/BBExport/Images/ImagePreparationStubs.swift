import BBModel
import CoreGraphics
import Foundation

// Phase 14 image lane: replace these stubs (keep the public signatures).

public struct CoreImageUpscaler: Upscaler {
    public init() {}
    public func upscale(_ image: CGImage, to size: CGSize) async throws -> CGImage {
        fatalError("CoreImageUpscaler not implemented")
    }
}

public enum ImagePreparationPlanner {
    public static func requests(page: Page, in content: BookContent,
                                imageURL: (ImageRef) -> URL,
                                pixelSize: (ImageRef) -> CGSize?) -> [ImagePreparationRequest] {
        fatalError("ImagePreparationPlanner not implemented")
    }
}

public enum ImagePixelSize {
    public static func of(url: URL) -> CGSize? {
        fatalError("ImagePixelSize not implemented")
    }
}

public actor ExportImagePreparer: ImagePreparing {
    public init(cacheDirectory: URL, upscaler: any Upscaler = CoreImageUpscaler()) {}
    public func assess(_ request: ImagePreparationRequest) -> ImageAssessment {
        fatalError("ExportImagePreparer.assess not implemented")
    }
    public func prepare(_ request: ImagePreparationRequest) async throws -> CGImage {
        fatalError("ExportImagePreparer.prepare not implemented")
    }
    public func preparedFileURL(_ request: ImagePreparationRequest) async throws -> URL {
        fatalError("ExportImagePreparer.preparedFileURL not implemented")
    }
}
