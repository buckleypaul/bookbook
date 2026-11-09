import BBModel
import Foundation

// Phase 16 shared contracts (A §5.4, §10; PD §8.1, §8.12, §8.13). Lanes implement against
// these unchanged. Implementations live in sibling files in this folder (see each lane brief).

// MARK: - Import from another book (A §5.4 BookImporter)

/// What the user picked in the source book.
public struct BookImportSelection: Hashable, Sendable {
    public var assets: Set<AssetID>
    public var templates: Set<TemplateID>
    public var styleGuide: Bool

    public init(assets: Set<AssetID> = [], templates: Set<TemplateID> = [], styleGuide: Bool = false) {
        self.assets = assets
        self.templates = templates
        self.styleGuide = styleGuide
    }

    public var isEmpty: Bool { assets.isEmpty && templates.isEmpty && !styleGuide }
}

/// An imported item, keyed by its ID in the *source* book.
public enum BookImportItem: Hashable, Sendable {
    case asset(AssetID)
    case template(TemplateID)
}

/// A selected item whose name matches (case- and whitespace-insensitive) an existing item of the
/// same kind in the target book, or another selected item. Resolved by a rename before writing.
public struct BookImportClash: Hashable, Sendable, Identifiable {
    public var item: BookImportItem
    public var name: String
    public var id: BookImportItem { item }

    public init(item: BookImportItem, name: String) {
        self.item = item
        self.name = name
    }
}

/// The finished, ID-remapped content to merge into the target book. Built by
/// `BookImporter.build`; applied by the `.importFromBook` BookCommand (undoable; undo removes the
/// added assets, sessions and templates and restores the previous style guide). Image files are
/// copied into the target package by `BookImporter.copyImages` *before* the command runs.
public struct BookImport: Hashable, Sendable {
    /// New assets (new `AssetID`s, new slot/sheet-item UUIDs).
    public var assets: [Asset]
    /// One new session per chosen reference slot / sheet item, owned by the new asset, holding a
    /// single `.imported` version that the slot's/item's `chosen` points at.
    public var sessions: [Session]
    /// Deep copies with new `TemplateID`s (and new box IDs).
    public var templates: [Template]
    /// The source style guide when selected (replaces the target's), else nil.
    public var styleGuide: StyleGuide?
    /// Every image file the above refers to (version images, style references).
    public var images: Set<ImageRef>

    public init(assets: [Asset] = [], sessions: [Session] = [], templates: [Template] = [],
                styleGuide: StyleGuide? = nil, images: Set<ImageRef> = []) {
        self.assets = assets
        self.sessions = sessions
        self.templates = templates
        self.styleGuide = styleGuide
        self.images = images
    }
}

public enum BookImportError: Error, Hashable, Sendable {
    /// `build` was called while a clash is still unresolved (or a rename itself clashes).
    case unresolvedClashes([BookImportClash])
    /// A selected item no longer exists in the source.
    case missingSourceItem(BookImportItem)
}

/// Copy-count report from `BookImporter.copyImages`.
public struct BookImportCopyReport: Hashable, Sendable {
    public var copied: Int
    /// Already present in the target (same SHA-256), so skipped.
    public var skippedDuplicates: Int
    public init(copied: Int, skippedDuplicates: Int) {
        self.copied = copied
        self.skippedDuplicates = skippedDuplicates
    }
}

// MARK: - Clean up (A §10, PD §8.12)

/// What Clean up would delete. Deletable = unstarred versions not referenced by any page
/// placement (cover included), reference slot `chosen` or sheet item `chosen`.
/// `fileNames`/`bytesFreed` cover only image files that no remaining version, provenance,
/// style reference or other reference still uses (`ImageSweep.referencedFileNames`).
public struct CleanUpPlan: Hashable, Sendable {
    public var versionIDs: Set<VersionID>
    public var fileNames: Set<String>
    public var bytesFreed: Int64

    public init(versionIDs: Set<VersionID>, fileNames: Set<String>, bytesFreed: Int64) {
        self.versionIDs = versionIDs
        self.fileNames = fileNames
        self.bytesFreed = bytesFreed
    }

    public var isEmpty: Bool { versionIDs.isEmpty }
}

// MARK: - New-book wizard (PD §8.13)

/// The wizard's output. Every field is optional/skippable; nil means "keep the default".
public struct NewBookSpec: Hashable, Sendable {
    public var title: String
    public var author: String
    /// Page size and orientation; nil = default (Letter portrait).
    public var pageSize: PageSizePreset?
    public var orientation: Orientation?
    /// `StylePreset.id`; nil = no preset.
    public var stylePresetID: String?
    /// Optional main character: becomes a `.character` asset with this name and description.
    public var mainCharacter: MainCharacter?
    /// Ask to import story text once the book opens.
    public var importStoryAfter: Bool

    public struct MainCharacter: Hashable, Sendable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public init(title: String, author: String = "", pageSize: PageSizePreset? = nil,
                orientation: Orientation? = nil, stylePresetID: String? = nil,
                mainCharacter: MainCharacter? = nil, importStoryAfter: Bool = false) {
        self.title = title
        self.author = author
        self.pageSize = pageSize
        self.orientation = orientation
        self.stylePresetID = stylePresetID
        self.mainCharacter = mainCharacter
        self.importStoryAfter = importStoryAfter
    }
}
