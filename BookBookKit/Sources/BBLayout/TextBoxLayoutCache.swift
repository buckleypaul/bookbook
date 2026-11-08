import BBModel
import CoreGraphics
import Foundation

/// Reuses `TextBoxLayout`s across canvas draws (Phase 4 contract; lane B implements the
/// cache itself). Keyed by text, resolved typography and container size; least-recently-used
/// entries are dropped past `capacity`.
@MainActor
public final class TextBoxLayoutCache {
    public let capacity: Int

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    public func layout(text: RichText, typography: Typography, containerSize: CGSize) -> TextBoxLayout {
        TextBoxLayout(text: text, typography: typography, containerSize: containerSize)
    }

    public func removeAll() {}
}
