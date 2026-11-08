import BBModel
import Foundation

// Owned by the Store lane. Contract stub: signatures are frozen, bodies are placeholders.

/// Built-in presets bundled in `Resources/Presets/` (A §3, §10).
public enum Presets {
    /// Every bundled template. Phase 2 ships two with fixed IDs: the story template
    /// "Image above text" and a cover template.
    public static func templates() throws(StoreError) -> [Template] {
        fatalError("Phase 2 Store lane: not implemented")
    }

    /// "Image on top, text below" (Phase 2's one story template).
    public static func storyTemplate() throws(StoreError) -> Template {
        fatalError("Phase 2 Store lane: not implemented")
    }

    public static func coverTemplate() throws(StoreError) -> Template {
        fatalError("Phase 2 Store lane: not implemented")
    }
}
