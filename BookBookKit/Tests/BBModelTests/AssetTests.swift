import Foundation
import Testing
@testable import BBModel

/// Phase 10: asset revision rules and legacy decoding, mention tokens, usage index, asset-changed flag.
struct AssetTests {
    static let now = Date(timeIntervalSince1970: 1)
    static let imageBoxA = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), content: .image)
    static let imageBoxB = Box(frame: NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5), content: .image)
    static let story = Template(name: "S", kind: .single, boxes: [imageBoxA, imageBoxB])
    static let cover = Template(name: "C", kind: .cover, boxes: [
        Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image),
    ])

    static func content(pages: Int = 2) -> BookContent {
        BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover, storyPageCount: pages, now: now)
    }

    static func sessionID(_ c: BookContent, page: PageID, box: BoxID) -> SessionID { c.pages[page]!.images[box]!.sessionID }

    static func message(_ text: String, epoch: Int = 0) -> Message { Message(epoch: epoch, role: .user, text: text, createdAt: now) }

    static func place(_ c: inout BookContent, page: PageID, box: BoxID, revisions: [AssetID: Int]?) {
        let sid = sessionID(c, page: page, box: box)
        var provenance: Provenance?
        if let revisions {
            let intent = GenerationIntent(messageText: "x", provider: .openai, model: "m", quality: .standard)
            provenance = Provenance(provider: .openai, model: "m", quality: .standard,
                                    outputSize: PixelSize(width: 8, height: 8), promptSent: "p", styleRevision: 0,
                                    assetRevisions: revisions, storyTextIncluded: false, intent: intent)
        }
        let v = Version(image: ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png"),
                        pixelSize: PixelSize(width: 8, height: 8), source: revisions == nil ? .imported : .generated,
                        createdAt: now, provenance: provenance)
        c.sessions[sid]?.versions.append(v)
        let template = c.template(for: c.pages[page]!)!
        let aspect = c.boxAspect(template.box(box)!, in: template)
        c.pages[page]?.images[box]?.placement = ImagePlacement(versionID: v.id, boxAspectWhenPlaced: aspect)
    }

    // MARK: revised

    @Test func revisedRules() {
        let old = Asset.makeNew(type: .character, name: "Fox")
        var e = old
        e.name = "Foxy"; e.tags = ["x"]
        #expect(e.revised(from: old).revision == 1)

        e = old
        e.description = "red"
        let r1 = e.revised(from: old)
        #expect(r1.revision == 2 && r1.revisionHighWater == 2)

        var chosen = old
        chosen.chosen = VersionID()
        #expect(chosen.revised(from: old).revision == 2)

        // After an undo (revision 1, high water 2) the next edit never reuses a number.
        var undone = old
        undone.revisionHighWater = 2
        var edited = undone
        edited.description = "again"
        #expect(edited.revised(from: undone).revision == 3)
    }

    // MARK: Mentions

    @Test func tokenRoundTripAndDisplay() {
        let fox = Asset.makeNew(type: .character, name: "Fox")
        let text = "Draw \(MentionText.token(for: fox.id)) near \(MentionText.token(for: fox.id)) and \(MentionText.token(for: AssetID()))"
        #expect(MentionText.mentionedAssets(in: text).count == 2)
        #expect(MentionText.mentionedAssets(in: text).first == fox.id)
        #expect(MentionText.displayText(text, assets: [fox.id: fox], fallback: "?") == "Draw Fox near Fox and ?")
        var renamed = fox
        renamed.name = "Reynard"
        #expect(MentionText.displayText(text, assets: [fox.id: renamed]).hasPrefix("Draw Reynard near Reynard"))
        #expect(MentionText.replacingMentions(of: fox.id, with: "Fox", in: text).hasPrefix("Draw Fox near Fox and ⟦asset:"))
        #expect(MentionText.mentionedAssets(in: "⟦asset:nope⟧ ⟦asset:") == [])
        #expect(MentionText.displayText("no tokens", assets: [:]) == "no tokens")
    }

    @Test func tokenizing() {
        let fox = Asset.makeNew(type: .character, name: "Fox")
        let granny = Asset.makeNew(type: .character, name: "Granny")
        let grannyOak = Asset.makeNew(type: .character, name: "Granny Oak")
        let all = [fox, granny, grannyOak]
        let t = { (a: Asset) in MentionText.token(for: a.id) }
        #expect(MentionText.tokenizing("hi @fox!", assets: all) == "hi \(t(fox))!")
        #expect(MentionText.tokenizing("@Granny Oak waves", assets: all) == "\(t(grannyOak)) waves")
        #expect(MentionText.tokenizing("@granny waves", assets: all) == "\(t(granny)) waves")
        #expect(MentionText.tokenizing("@Foxes run", assets: all) == "@Foxes run")
        #expect(MentionText.tokenizing("a@fox", assets: all) == "a@fox")
        #expect(MentionText.tokenizing("@Fox", assets: all) == t(fox))
        #expect(MentionText.tokenizing("@unknown @Fox", assets: all) == "@unknown \(t(fox))")
        #expect(MentionText.tokenizing("plain", assets: all) == "plain")
    }

    // MARK: Usage index

    @Test func usageIndexUnderEdits() {
        var c = Self.content()
        let fox = Asset.makeNew(type: .character, name: "Fox")
        c.assets[fox.id] = fox
        let p1 = c.book.pageOrder[0], p2 = c.book.pageOrder[1], cover = c.book.coverPageID
        var idx = UsageIndex(content: c)
        #expect(!idx.isUsed(fox.id))

        // Checklist add/remove.
        c.pages[p2]?.assetChecklist = [fox.id]
        idx.refresh(c, pages: [p2], sessions: [])
        #expect(idx.sites(for: fox.id, in: c) == [UsageSite(page: p2, box: nil, reasons: [.checklist])])
        c.pages[p2]?.assetChecklist = []
        idx.refresh(c, pages: [p2], sessions: [])
        #expect(!idx.isUsed(fox.id))

        // Mention in a message (refresh by session), merged with the page checklist.
        let sB = Self.sessionID(c, page: p1, box: Self.imageBoxB.id)
        let sA = Self.sessionID(c, page: p1, box: Self.imageBoxA.id)
        c.sessions[sB]?.messages.append(Self.message("draw \(MentionText.token(for: fox.id))"))
        c.sessions[sA]?.messages.append(Self.message("also \(MentionText.token(for: fox.id))"))
        c.pages[p1]?.assetChecklist = [fox.id]
        idx.refresh(c, pages: [], sessions: [sA, sB])
        #expect(idx.sites(for: fox.id, in: c) == [
            UsageSite(page: p1, box: nil, reasons: [.checklist]),
            UsageSite(page: p1, box: Self.imageBoxA.id, reasons: [.mention]),
            UsageSite(page: p1, box: Self.imageBoxB.id, reasons: [.mention]),
        ])
        #expect(idx == UsageIndex(content: c))

        // Epoch reset hides the mention.
        c.sessions[sB]?.resetEpoch = 1
        idx.refresh(c, pages: [], sessions: [sB])
        #expect(idx.sites(for: fox.id, in: c).map(\.box) == [nil, Self.imageBoxA.id])

        // Placed versions with the asset's revision add .placedImage; cover comes first.
        Self.place(&c, page: cover, box: c.templates[c.pages[cover]!.templateID]!.imageBoxes[0].id, revisions: [fox.id: 1])
        Self.place(&c, page: p1, box: Self.imageBoxA.id, revisions: [fox.id: 1])
        idx.refresh(c, pages: [cover, p1], sessions: [])
        let sites = idx.sites(for: fox.id, in: c)
        #expect(sites.map(\.page) == [cover, p1, p1])
        #expect(sites[2].reasons == [.mention, .placedImage])

        // Placing an imported version removes placedImage.
        Self.place(&c, page: p1, box: Self.imageBoxA.id, revisions: nil)
        idx.refresh(c, pages: [p1], sessions: [])
        #expect(idx.sites(for: fox.id, in: c)[2].reasons == [.mention])

        // Asset sessions never count.
        c.sessions[fox.sessionID] = Session(id: fox.sessionID, owner: fox.owner,
                                            messages: [Self.message(MentionText.token(for: fox.id))])
        idx.refresh(c, pages: [], sessions: [fox.sessionID])
        #expect(idx == UsageIndex(content: c))

        // Page deletion drops its sites.
        c.pages[p1] = nil
        c.book.pageOrder.removeAll { $0 == p1 }
        idx.refresh(c, pages: [p1], sessions: [])
        #expect(idx.sites(for: fox.id, in: c).map(\.page) == [cover])
        #expect(idx == UsageIndex(content: c))
    }

    // MARK: Asset changed flag

    @Test func assetChangedFlag() {
        var c = Self.content()
        let p = c.book.pageOrder[0], box = Self.imageBoxA.id
        var fox = Asset.makeNew(type: .character, name: "Fox")
        c.assets[fox.id] = fox
        Self.place(&c, page: p, box: box, revisions: [fox.id: 1])
        #expect(!c.imageFlags(page: p, box: box).contains(.assetChanged))

        fox.revision = 2
        fox.revisionHighWater = 2
        c.assets[fox.id] = fox
        #expect(c.imageFlags(page: p, box: box).contains(.assetChanged))
        #expect(c.imageFlags(of: c.pages[p]!).contains(.assetChanged))

        c.pages[p]?.images[box]?.acknowledged.assetRevisions[fox.id] = 2
        #expect(!c.imageFlags(page: p, box: box).contains(.assetChanged))

        fox.revision = 3
        fox.revisionHighWater = 3
        c.assets[fox.id] = fox
        #expect(c.imageFlags(page: p, box: box).contains(.assetChanged))

        c.assets[fox.id] = nil
        #expect(!c.imageFlags(page: p, box: box).contains(.assetChanged))

        // Imported versions never get it.
        c.assets[fox.id] = fox
        Self.place(&c, page: p, box: box, revisions: nil)
        #expect(c.imageFlags(page: p, box: box).isEmpty)
    }
}
