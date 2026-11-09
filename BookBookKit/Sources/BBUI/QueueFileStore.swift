import BBAI
import BBModel
import BBStore
import Foundation
import os
import Synchronization

/// `queue.json` in the app-support folder (A §5.5, §7.9). Rewritten on every queue change
/// (atomically, through `AppSupportFiles`). Holds no key and no request headers: only queue
/// items (intent, target, estimate, display labels), failures (redacted provider errors) and,
/// from Phase 16b, the deliveries still waiting for a locked book.
///
/// Phase 16b:
/// - The image bytes of undelivered pictures are spool files in `undelivered/` (written before
///   `queue.json`, which lists them; a file no longer listed is deleted after the save).
/// - A newer-schema or undecodable `queue.json` is moved aside (`queue-unreadable-<time>.json`)
///   so the next save doesn't overwrite it (#34b).
/// - Every load and save tells `SweepProtection` which image files each book's queued work
///   still needs (#29a).
public struct QueueFileStore: QueuePersistence {
    public let files: AppSupportFiles
    private let protection: SweepProtection
    /// Books this store has protected files for, so a book whose work is gone is cleared.
    private let protectedBooks = ProtectedBooks()

    private static let log = Logger(subsystem: "app.bookbook", category: "QueueFileStore")
    private static let spool = AppSupportFiles.undeliveredFolderName

    public init(files: AppSupportFiles, protection: SweepProtection = .shared) {
        self.files = files
        self.protection = protection
    }

    /// nil when there's no file, it can't be decoded, or it was written by a newer schema (the
    /// last two are moved aside first). An undelivered picture whose spool file is missing is
    /// dropped.
    public func load() async -> PersistedQueue? {
        guard let data = files.read(AppSupportFiles.queueFileName) else { return nil }
        var queue: PersistedQueue
        do {
            queue = try Self.decoder().decode(PersistedQueue.self, from: data)
        } catch {
            Self.log.error("Couldn't read queue.json: \(String(describing: error), privacy: .public)")
            moveAside()
            return nil
        }
        guard queue.schemaVersion <= PersistedQueue.currentSchemaVersion else {
            Self.log.error("queue.json has a newer schema (\(queue.schemaVersion)); moved aside")
            moveAside()
            return nil
        }
        queue.undelivered = queue.undelivered.compactMap { delivery in
            var delivery = delivery
            for index in delivery.images.indices {
                guard let bytes = files.read("\(Self.spool)/\(delivery.images[index].fileName)"), !bytes.isEmpty else {
                    Self.log.error("An undelivered picture's file is missing; dropped")
                    return nil
                }
                delivery.images[index].data = bytes
            }
            return delivery
        }
        protect(queue)
        return queue
    }

    public func save(_ queue: PersistedQueue) async {
        protect(queue)
        do {
            // Spool files first, so queue.json never lists a file that isn't there.
            for image in queue.undelivered.flatMap(\.images) {
                let name = "\(Self.spool)/\(image.fileName)"
                if !files.exists(name) { try files.write(image.data, to: name) }
            }
            let data = try Self.encoder().encode(queue)
            try files.write(data, to: AppSupportFiles.queueFileName)
        } catch {
            Self.log.error("Couldn't write queue.json: \(String(describing: error), privacy: .public)")
            return
        }
        // Delivered (or dropped) pictures' spool files go once queue.json no longer lists them.
        let listed = Set(queue.undelivered.flatMap(\.images).map(\.fileName))
        for name in files.fileNames(in: Self.spool) where !listed.contains(name) {
            try? files.remove("\(Self.spool)/\(name)")
        }
    }

    private func moveAside() {
        do {
            let name = try files.moveAside(AppSupportFiles.queueFileName)
            Self.log.error("Kept the unreadable queue file as \(name, privacy: .public)")
        } catch {
            Self.log.error("Couldn't move queue.json aside: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the sweep protection for every book this queue has (or had) work for.
    private func protect(_ queue: PersistedQueue) {
        let names = queue.protectedImageFileNames.filter { !$0.value.isEmpty }
        let previous = protectedBooks.state.withLock { books in
            defer { books = Set(names.keys) }
            return books
        }
        for book in previous where names[book] == nil { protection.set([], for: book) }
        for (book, set) in names { protection.set(set, for: book) }
    }

    /// Dates use the default (seconds since 2001) so they round-trip exactly.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// The books a `QueueFileStore` has set sweep protection for.
private final class ProtectedBooks: Sendable {
    let state = Mutex<Set<BookID>>([])
}
