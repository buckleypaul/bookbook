import BBAI
import BBStore
import Foundation
import os

/// `queue.json` in the app-support folder (A §5.5, §7.9). Rewritten on every queue change
/// (atomically, through `AppSupportFiles`). Holds no key and no request headers: only queue
/// items (intent, target, estimate, display labels) and failures (redacted provider errors).
public struct QueueFileStore: QueuePersistence {
    public let files: AppSupportFiles

    private static let log = Logger(subsystem: "app.bookbook", category: "QueueFileStore")

    public init(files: AppSupportFiles) {
        self.files = files
    }

    /// nil when there's no file, it can't be decoded, or it was written by a newer schema.
    public func load() async -> PersistedQueue? {
        guard let data = files.read(AppSupportFiles.queueFileName) else { return nil }
        do {
            let queue = try Self.decoder().decode(PersistedQueue.self, from: data)
            guard queue.schemaVersion <= PersistedQueue.currentSchemaVersion else {
                Self.log.error("queue.json has a newer schema (\(queue.schemaVersion)); ignored")
                return nil
            }
            return queue
        } catch {
            Self.log.error("Couldn't read queue.json: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func save(_ queue: PersistedQueue) async {
        do {
            let data = try Self.encoder().encode(queue)
            try files.write(data, to: AppSupportFiles.queueFileName)
        } catch {
            Self.log.error("Couldn't write queue.json: \(String(describing: error), privacy: .public)")
        }
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
