import BBAICore
import BBModel
import Foundation
@testable import BBAI

/// Builds assets with a real session and chosen version inside a `BookContent`.
/// Each asset's one image ref is named `<name>-image`.
enum Cast {
    struct Options {
        /// The asset's image is chosen (and so sent).
        var chosen = true
        var isRealPerson = false
    }

    static func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }

    static func ref(_ name: String, _ suffix: String = "image") -> ImageRef {
        ImageRef(sha256: "\(slug(name))-\(suffix)", contentType: "public.png")
    }

    @discardableResult
    static func add(_ type: AssetType, _ name: String, description: String = "", revision: Int = 1,
                    options: Options = Options(), to content: inout BookContent) -> Asset {
        var asset = Asset.makeNew(type: type, name: name)
        asset.description = description
        asset.revision = revision
        asset.revisionHighWater = revision
        var session = Session(id: asset.sessionID, owner: asset.owner)
        if options.chosen {
            let version = Version(image: ref(name), pixelSize: PixelSize(width: 1024, height: 1024),
                                  source: options.isRealPerson ? .imported : .generated,
                                  createdAt: Date(timeIntervalSince1970: 0),
                                  depictsRealPerson: options.isRealPerson ? true : nil)
            session.versions = [version]
            asset.chosen = version.id
        }
        content.sessions[session.id] = session
        content.assets[asset.id] = asset
        return asset
    }

    /// Bytes for every version image and style reference in the book.
    static func imageData(_ content: BookContent, size: Int = 8) -> [ImageRef: Data] {
        var data: [ImageRef: Data] = [:]
        for session in content.sessions.values { for version in session.versions { data[version.image] = Data(count: size) } }
        for ref in content.style.styleReferences { data[ref] = Data(count: size) }
        return data
    }
}

/// "@Name" in stored form.
func mention(_ asset: Asset) -> String { MentionText.token(for: asset.id) }

func assetIntent(_ message: String, story: Bool = false) -> GenerationIntent {
    intent(message, story: story)
}

func assemble(_ target: GenerationTarget, _ intent: GenerationIntent, content: BookContent, messageID: MessageID? = nil,
              model: CatalogModel? = nil, imageData: [ImageRef: Data]? = nil) throws -> (ImageRequest, AssemblyReport) {
    try ContextAssembler.assemble(intent: intent, target: target, messageID: messageID, content: content,
                                  model: model ?? testModel(), imageData: imageData ?? Cast.imageData(content))
}

func sentLabels(_ report: AssemblyReport) -> [String] { report.referencesSent.map(\.label) }
