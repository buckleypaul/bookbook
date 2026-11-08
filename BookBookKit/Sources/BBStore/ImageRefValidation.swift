import BBModel
import Foundation

// Image refs in a book on disk are untrusted (a shared book may be crafted). On load, a ref is
// kept only if its sha256 is 64 lowercase hex digits and its content type is one the app
// writes. Invalid versions are dropped from their session, invalid provenance refs from the
// version, and invalid style references from the style guide; the rest of the book still loads.
// Placements or messages that pointed at a dropped version are left as is and resolve to nil.

extension ImageRef {
    static let knownContentTypes: Set<String> = ["public.png", "public.jpeg", "org.webmproject.webp", "public.heic"]

    var isValid: Bool {
        Self.knownContentTypes.contains(contentType)
            && sha256.utf8.count == 64
            && sha256.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

extension Session {
    func droppingInvalidImageRefs() -> Session {
        var copy = self
        copy.versions = versions.compactMap { version in
            guard version.image.isValid else { return nil }
            var v = version
            v.provenance?.referencesSent.removeAll { !$0.image.isValid }
            v.provenance?.referencesOmitted.removeAll { !$0.image.isValid }
            return v
        }
        return copy
    }
}
