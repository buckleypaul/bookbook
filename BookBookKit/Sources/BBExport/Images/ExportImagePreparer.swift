import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A §9.2: crop → resample to required pixels → JPEG/PNG encode, cached on disk.
/// Preparations run one at a time so only one source image is in memory at once.
public actor ExportImagePreparer: ImagePreparing {
    public static let jpegQuality: Double = 0.92

    private let cacheDirectory: URL
    private let upscaler: any Upscaler
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(cacheDirectory: URL, upscaler: any Upscaler = CoreImageUpscaler()) {
        self.cacheDirectory = cacheDirectory
        self.upscaler = upscaler
    }

    public func assess(_ request: ImagePreparationRequest) -> ImageAssessment {
        let available = request.cropPixels.size
        let required = request.requiredPixels
        let fx = available.width > 0 ? Double(required.width / available.width) : .infinity
        let fy = available.height > 0 ? Double(required.height / available.height) : .infinity
        let factor = max(fx, fy)
        let shortSide = Int(min(available.width, available.height).rounded())
        return ImageAssessment(key: request.key, image: request.image, availablePixels: available,
                               requiredPixels: required, upscaleFactor: factor,
                               isSoft: PrintResolution.isSoft(upscaleFactor: factor, cropShortSidePixels: shortSide))
    }

    public func prepare(_ request: ImagePreparationRequest) async throws -> CGImage {
        // The full decode is the validity check here, so a cache hit skips the header read.
        var url = try await cachedFileURL(request, checksHeader: false)
        if let image = ImageFiles.decode(url: url) { return image }
        // A cached file that won't decode (e.g. truncated by an older build) is dropped and rebuilt.
        try? FileManager.default.removeItem(at: url)
        url = try await cachedFileURL(request, checksHeader: true)
        guard let image = ImageFiles.decode(url: url) else { throw ExportError.imageUnreadable(request.image) }
        return image
    }

    /// The prepared file for `request`, built if needed. A cached file must have a readable
    /// header, since callers of this never decode it.
    public func preparedFileURL(_ request: ImagePreparationRequest) async throws -> URL {
        try await cachedFileURL(request, checksHeader: true)
    }

    private func cachedFileURL(_ request: ImagePreparationRequest, checksHeader: Bool) async throws -> URL {
        await acquire()
        defer { release() }
        let stem = Self.stem(for: request)
        for ext in ["jpg", "png"] {
            let url = cacheDirectory.appendingPathComponent("\(stem).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if !checksHeader || ImagePixelSize.of(url: url) != nil {
                // A hit counts as use, so `pruneCache` keeps what recent exports needed.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                return url
            }
            try? FileManager.default.removeItem(at: url)
        }

        let (cropped, hasAlpha) = try Self.loadCrop(request)
        let output = try await upscaler.upscale(cropped, to: request.requiredPixels)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let url = cacheDirectory.appendingPathComponent("\(stem).\(hasAlpha ? "png" : "jpg")")
        try Self.write(output, hasAlpha: hasAlpha, to: url)
        return url
    }

    /// Deletes cache files not used (written or hit) for `maxAge`, and leftover temp files.
    public func pruneCache(maxAge: TimeInterval = 14 * 24 * 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let isTemp = file.lastPathComponent.hasPrefix(".tmp-")
            if isTemp ? (modified.map { now.timeIntervalSince($0) > 3600 } ?? true)
                      : (modified.map { now.timeIntervalSince($0) > maxAge } ?? false) {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Serialising

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Helpers

    static func stem(for request: ImagePreparationRequest) -> String {
        let c = request.cropPixels, r = request.requiredPixels
        let key = "\(request.image.sha256)|\(Int(c.minX)),\(Int(c.minY)),\(Int(c.width)),\(Int(c.height))|\(Int(r.width))x\(Int(r.height))"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hash)-\(Int(r.width))x\(Int(r.height))"
    }

    /// Decodes the source, crops it and lets the source go; reports whether it has alpha.
    private static func loadCrop(_ request: ImagePreparationRequest) throws -> (CGImage, Bool) {
        guard let source = ImageFiles.decodeOriented(url: request.sourceURL) else {
            throw ExportError.imageUnreadable(request.image)
        }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let crop = request.cropPixels.integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cropped = source.cropping(to: crop) else {
            throw ExportError.imageUnreadable(request.image)
        }
        return (cropped, hasAlpha(source))
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func write(_ image: CGImage, hasAlpha: Bool, to url: URL) throws {
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let toWrite = hasAlpha ? image : try flattened(image)
        // Written beside the final path and renamed, so a crash never leaves a truncated cache hit.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, toWrite, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw ExportError.encodingFailed
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Drops the alpha channel (onto white) so JPEG encoding is clean.
    static func flattened(_ image: CGImage) throws -> CGImage {
        guard hasAlpha(image) else { return image }
        let space = renderingColorSpace(for: image)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.contextCreationFailed }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let result = ctx.makeImage() else { throw ExportError.contextCreationFailed }
        return result
    }
}
