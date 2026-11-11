import BBModel
import Foundation
import ImageIO

/// Load-time repair (2026-11-11): before style references went through `ImageImportNormalizer`,
/// they were stored as the file's raw bytes with a content type guessed from its extension, so an
/// older book can hold a reference that is HEIC, WebP, or whose bytes aren't what its
/// `contentType` says. Providers take only PNG/JPEG (and WebP), so every page request in such a
/// book failed. Each such reference is re-normalized like a new import (`normalizeReferencePhoto`).
///
/// Asset reference photos and imported versions always went through the normalizer, so only
/// style references need this.
public enum StyleReferenceRepair {
    /// True when the stored file for `ref` is a PNG or JPEG whose bytes match `ref.contentType`.
    /// Sniffs the bytes, never the file name.
    public static func isSound(_ data: Data, as ref: ImageRef) -> Bool {
        guard ref.contentType == "public.png" || ref.contentType == "public.jpeg",
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?
        else { return false }
        return type == ref.contentType
    }
}

extension BookStore {
    /// Re-normalizes every style reference whose stored file isn't a PNG or JPEG matching its
    /// `contentType` (same settings as a new style reference import), stores the new image and
    /// saves `style.json` pointing at it, as one journaled transaction. Not an edit: nothing is
    /// undoable. Returns the repaired content, or nil if nothing changed (or the save failed).
    ///
    /// A reference whose file is missing or undecodable is left as it is and never blocks the
    /// open. A sound book does no writes, so a repaired book isn't repaired again. The old file
    /// is left for the open-time orphan sweep (it may still be in a version's provenance).
    /// Call under the book's lock, after `load()`. A read-only store changes nothing (callers skip it).
    public func repairingStyleReferences(in content: BookContent) -> BookContent? {
        let fm = FileManager.default
        var changed = false
        var repaired: [ImageRef] = []
        for ref in content.style.styleReferences {
            let url = imageURL(for: ref)
            guard fm.fileExists(atPath: url.path(percentEncoded: false)),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !StyleReferenceRepair.isSound(data, as: ref),
                  let normalized = try? ImageImportNormalizer.normalizeReferencePhoto(data),
                  let newRef = try? storeImage(normalized.data, contentType: normalized.contentType)
            else {
                repaired.append(ref)
                continue
            }
            changed = true
            repaired.append(newRef)
        }
        guard changed else { return nil }
        // Two references can normalize to the same picture: keep the first.
        var seen: Set<ImageRef> = []
        var updated = content
        updated.style.styleReferences = repaired.filter { seen.insert($0).inserted }
        do {
            try save(updated, dirty: DirtySet(style: true))
        } catch {
            return nil
        }
        return updated
    }
}
