import Foundation
import Testing
@testable import BBModel

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try d.decode(T.self, from: e.encode(value))
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func sampleTemplates() -> (story: Template, cover: Template) {
    let story = Template(name: "Story", kind: .single, boxes: [
        Box(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.5), rotationDegrees: 3, cornerRadius: 4,
            bleedEdges: [.top, .leading], content: .image),
        Box(frame: NormalizedRect(x: 0.1, y: 0.7, width: 0.8, height: 0.2),
            content: .text(TextBoxStyle(padding: 6, background: RGBA(red: 1, green: 1, blue: 0.5, alpha: 0.5))),
            role: .title),
    ])
    let cover = Template(name: "Cover", kind: .cover, boxes: [
        Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image),
    ])
    return (story, cover)
}

@Test func templatesRoundTripWithBothBoxKinds() throws {
    let (story, cover) = sampleTemplates()
    #expect(try roundTrip(story) == story)
    #expect(try roundTrip(cover) == cover)
    #expect(story.imageBoxes.count == 1 && story.textBoxes.count == 1)
}

@Test func bookAndStyleRoundTrip() throws {
    let book = Book(title: "T", author: "A", createdAt: t0, modifiedAt: t0, pageOrder: [PageID(), PageID()],
                    coverPageID: PageID(), budget: Decimal(string: "12.5"),
                    acknowledgements: Acknowledgements(realPersonPhotoNotice: [.openai, .gemini]))
    #expect(try roundTrip(book) == book)
    let style = StyleGuide(presetID: "p", visualDescription: "soft", styleReferences: [ImageRef(sha256: "ab", contentType: "public.png")],
                           visualRevision: 3)
    #expect(try roundTrip(style) == style)
}

@Test func pageAndSessionRoundTrip() throws {
    let (story, _) = sampleTemplates()
    var sessions: [SessionID: Session] = [:]
    var page = BookContent.makePage(kind: .story, template: story, sessions: &sessions)
    let imageBox = story.imageBoxes[0].id
    let textBox = story.textBoxes[0].id
    var session = sessions[page.images[imageBox]!.sessionID]!

    let ref = ImageRef(sha256: "abc123", contentType: "public.png")
    let intent = GenerationIntent(messageText: "a fox", refines: VersionID(),
                                  attachedReferences: [VersionRef(sessionID: SessionID(), versionID: VersionID())],
                                  provider: .openai, model: "m", quality: .high, includeStoryText: false)
    let prov = Provenance(
        provider: .openai, model: "m", quality: .draft, outputSize: PixelSize(width: 1024, height: 1536),
        promptSent: "p", referencesSent: [SentReference(image: ref, role: "base", label: "L")],
        referencesOmitted: [SentReference(image: ref, role: "style", label: "S")], styleRevision: 2,
        assetRevisions: [AssetID(): 4], storyTextIncluded: true, intent: intent, cost: CostRecordID(),
        usage: TokenUsage(inputTextTokens: 1, inputImageTokens: 2, cachedInputTokens: 3, outputTextTokens: 4, outputImageTokens: 5),
        revisedPrompt: "rp", parametersSent: ["size": "1024x1536", "n": "1"])
    let version = Version(image: ref, pixelSize: PixelSize(width: 1024, height: 1536), source: .generated,
                          parent: VersionID(), createdAt: t0, starred: true, provenance: prov)
    session.versions = [version]
    session.messages = [Message(role: .user, text: "hi", refines: version.id,
                                attachedReferences: [VersionRef(sessionID: session.id, versionID: version.id)],
                                producedVersion: version.id, queueItemID: QueueItemID(), createdAt: t0)]
    session.resetEpoch = 1
    page.text[textBox] = RichText(paragraphs: [Paragraph(runs: [Run(text: "x", bold: true, italic: true, underline: true,
                                                                   fontFamily: "F", size: 12, color: .black)],
                                                         alignment: .center)])
    page.images[imageBox]?.placement = ImagePlacement(versionID: version.id, zoom: 1.5,
                                                      center: NormalizedPoint(x: 0.2, y: 0.8), boxAspectWhenPlaced: 1.3)
    page.images[imageBox]?.acknowledged = FlagBaseline(styleRevision: 1, assetRevisions: [AssetID(): 2], boxAspect: 1.2)
    page.assetChecklist = [AssetID()]

    #expect(try roundTrip(page) == page)
    #expect(try roundTrip(session) == session)
    #expect(try roundTrip(version) == version)
    #expect(try roundTrip(prov) == prov)
    #expect(try roundTrip(intent) == intent)
    #expect(try roundTrip(GenerationTarget.pageBox(page.id, imageBox)) == .pageBox(page.id, imageBox))
    #expect(try roundTrip(SessionOwner.pageBox(page.id, imageBox)) == .pageBox(page.id, imageBox))
}

@Test func typedIDDictionaryKeysEncodeAsObject() throws {
    let id = BoxID()
    let page = Page(kind: .story, templateID: TemplateID(), text: [id: RichText(plain: "hello")])
    let data = try JSONEncoder().encode(page)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let text = try #require(object["text"] as? [String: Any])
    #expect(Array(text.keys) == [id.rawValue.uuidString])
}

/// Review fix: `SentReference.depictsRealPerson` is additive. Books and queue files written
/// before it existed decode it as false; it's written only when true, so they stay byte-identical.
@Test func sentReferenceRealPersonFlagIsAdditive() throws {
    let sha = String(repeating: "ab", count: 32)
    let old = Data(#"{"image":{"contentType":"public.png","sha256":"\#(sha)"},"label":"Pip","role":"asset"}"#.utf8)
    let decoded = try JSONDecoder().decode(SentReference.self, from: old)
    let image = ImageRef(sha256: sha, contentType: "public.png")
    #expect(decoded == SentReference(image: image, role: "asset", label: "Pip"))
    #expect(!decoded.depictsRealPerson)

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(decoded) == old, "false is omitted")
    let real = SentReference(image: image, role: "photo", label: "Reference photo", depictsRealPerson: true)
    #expect(String(decoding: try encoder.encode(real), as: UTF8.self).contains(#""depictsRealPerson":true"#))
    #expect(try roundTrip(real) == real)
}

@Test func makeNewBuildsCoverStoryPageAndSessions() throws {
    let (story, cover) = sampleTemplates()
    let content = BookContent.makeNew(title: "B", storyTemplate: story, coverTemplate: cover, storyPageCount: 1, now: t0)
    #expect(content.book.pageOrder.count == 1)
    #expect(content.pages.count == 2)
    #expect(content.coverPage?.kind == .cover)
    #expect(content.sessions.count == 2)
    for page in content.pages.values {
        let template = try #require(content.template(for: page))
        #expect(Set(page.images.keys) == Set(template.imageBoxes.map(\.id)))
        for (boxID, slot) in page.images {
            #expect(content.sessions[slot.sessionID]?.owner == .pageBox(page.id, boxID))
        }
    }
    #expect(try roundTrip(content.book) == content.book)
}
