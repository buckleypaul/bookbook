import BBModel
import BBStore
import Foundation

/// Why an import didn't happen.
public enum ImageImportFailure: Error, Hashable, Sendable {
    case notAFileURL
    case unreadable
    case notAnImage
    case boxGone
    /// Phase 10: the asset, reference slot or sheet item is gone.
    case assetGone
    case readOnly
    case store(String)

    public var message: String {
        switch self {
        case .notAFileURL: "BookBook can only use pictures from files on this Mac."
        case .unreadable: "BookBook couldn't read that file."
        case .notAnImage: "That file isn't a picture BookBook can use."
        case .boxGone: "That image box is no longer on the page."
        case .assetGone: "That asset or sheet item no longer exists."
        case .readOnly: "This book is open in another BookBook window, so it can't be changed here."
        case let .store(text): "The picture couldn't be saved: \(text)"
        }
    }

    /// The plain-language line for any error an image import throws.
    public static func message(for error: any Error) -> String {
        (error as? ImageImportFailure)?.message ?? error.localizedDescription
    }
}

extension BookDocument {
    /// "Use your own image" (PD §8.6): reads and normalizes the file off the main actor (EXIF
    /// rotation applied, HEIC/TIFF → PNG), stores it, and appends an `.imported` version to the
    /// box's session, placing it only if the box is empty. Not undoable. Returns the new version.
    @discardableResult
    public func importImage(from url: URL, page: PageID, box: BoxID) async throws -> VersionID {
        guard url.isFileURL else { throw ImageImportFailure.notAFileURL }
        guard isEditable else { throw ImageImportFailure.readOnly }
        guard content.pages[page]?.images[box] != nil else { throw ImageImportFailure.boxGone }

        let (ref, normalized) = try await readAndStore(url)
        // Re-check after the awaits: the box may have gone, or the book closed.
        let versionID = VersionID()
        var appended = false
        let stamp = Date()
        performIrreversible { content in
            let dirty = BookMutations.appendImportedVersion(image: ref, pixelSize: normalized.pixelSize, page: page,
                                                            box: box, to: &content, versionID: versionID, now: stamp)
            appended = !dirty.isEmpty
            return dirty
        }
        guard appended else { throw ImageImportFailure.boxGone }
        return versionID
    }

    /// Reads and normalizes the file off the main actor, then stores it in the package.
    func readAndStore(_ url: URL) async throws -> (ImageRef, ImageImportNormalizer.Result) {
        let normalized = try await Task.detached(priority: .userInitiated) { () throws -> ImageImportNormalizer.Result in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw ImageImportFailure.unreadable
            }
            do {
                return try ImageImportNormalizer.normalize(data)
            } catch {
                throw ImageImportFailure.notAnImage
            }
        }.value

        let ref: ImageRef
        do {
            ref = try await store.storeImage(normalized.data, contentType: normalized.contentType)
        } catch {
            throw ImageImportFailure.store(StoreErrorText.message(for: error))
        }
        return (ref, normalized)
    }
}
