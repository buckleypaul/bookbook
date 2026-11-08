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

    private var entries: [Key: TextBoxLayout] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// Number of cached layouts.
    var count: Int { entries.count }

    public func layout(text: RichText, typography: Typography, containerSize: CGSize) -> TextBoxLayout {
        let key = Key(text: text, typography: typography,
                      width: max(0, containerSize.width), height: max(0, containerSize.height))
        if let hit = entries[key] {
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
            order.append(key)
            return hit
        }
        let layout = TextBoxLayout(text: text, typography: typography, containerSize: containerSize)
        entries[key] = layout
        order.append(key)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        return layout
    }

    public func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}
