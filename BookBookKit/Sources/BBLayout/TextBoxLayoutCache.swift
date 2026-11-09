import BBModel
import CoreGraphics
import Foundation

/// Reuses `TextBoxLayout`s across canvas draws (Phase 4 contract; lane B implements the
/// cache itself). Keyed by text, resolved typography and container size; least-recently-used
/// entries are dropped past `capacity`.
@MainActor
public final class TextBoxLayoutCache {
    public let capacity: Int

    struct Key: Hashable {
        var text: RichText
        var typography: Typography
        var width: CGFloat
        var height: CGFloat
    }

    private struct Entry {
        var layout: TextBoxLayout
        /// The `clock` value at the last use; the smallest is least recently used.
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// Number of cached layouts.
    var count: Int { entries.count }

    public func layout(text: RichText, typography: Typography, containerSize: CGSize) -> TextBoxLayout {
        let key = Key(text: text, typography: typography,
                      width: max(0, containerSize.width), height: max(0, containerSize.height))
        clock += 1
        if let hit = entries[key]?.layout {
            entries[key]?.lastUse = clock
            return hit
        }
        let layout = TextBoxLayout(text: text, typography: typography, containerSize: containerSize)
        entries[key] = Entry(layout: layout, lastUse: clock)
        // Only one entry is added per call, so at most one needs evicting.
        if entries.count > capacity,
           let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
        return layout
    }

    public func removeAll() {
        entries.removeAll()
    }
}
