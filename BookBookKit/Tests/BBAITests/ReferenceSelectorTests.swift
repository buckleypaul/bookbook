import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct ReferenceSelectorTests {
    /// The Phase 10 hand check: "@Pip yawning by the fire" → primary, sleepy expression, three-quarter view.
    @Test func pipYawningByTheFire() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", description: "A small red fox.", to: &book.content)
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning by the fire"), content: book.content)
        #expect(sentLabels(report) == ["Pip – primary reference", "Pip – sleepy expression", "Pip – three-quarter view"])
        #expect(report.referencesSent.allSatisfy { $0.role == "asset" })
        #expect(report.referencesOmitted.isEmpty)
    }

    @Test func tiersFillInOrder() throws {
        var walk = RefinementBook.make()
        var content = walk.book.content
        let pip = Cast.add(.character, "Pip", to: &content)
        let granny = Cast.add(.character, "Granny Oak", to: &content)
        let mill = Cast.add(.place, "Old Mill", options: .init(extraSlots: ["Night"]), to: &content)
        content.pages[walk.book.pageID]?.assetChecklist = [mill.id, granny.id, pip.id]
        content.style.styleReferences = (1...3).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        walk.book.content = content
        let attached = VersionRef(sessionID: walk.book.sessionID, versionID: walk.versions[3].id)
        let intent = walk.refine(0, "\(mention(pip)) crying over her shoulder", attached: [attached])
        let (_, report) = try assemble(walk.book.target, intent, content: content, messageID: walk.pendingMessage)
        #expect(sentLabels(report) == [
            "Current illustration (v1)", "Reference v4",
            "Pip – primary reference",                                   // tier 3: mentioned
            "Old Mill – primary reference", "Granny Oak – primary reference", // tier 4: checklist order
            "Style reference 1", "Style reference 2",                    // tier 5
            "Pip – sad expression", "Pip – three-quarter view",          // tier 6
            "Granny Oak – sad expression", "Granny Oak – three-quarter view",
            "Old Mill – night",                                          // tier 7
            "Style reference 3",                                         // spare capacity
        ])
        #expect(report.referencesSent.map(\.role).prefix(3) == ["base", "reference", "asset"])
    }

    @Test func perAssetCaps() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(extraSlots: ["Winter coat"]), to: &book.content)
        let mill = Cast.add(.place, "Old Mill", options: .init(extraSlots: ["Day", "Night", "Storm"]), to: &book.content)
        let key = Cast.add(.object, "Brass Key", options: .init(extraSlots: ["Close-up"]), to: &book.content)
        let message = "\(mention(pip)) happy and sad and angry, from behind and in profile, at \(mention(mill)) at night with \(mention(key))"
        let (_, report) = try assemble(book.target, assetIntent(message), content: book.content)
        let labels = sentLabels(report)
        // Character: primary + 1 expression + 1 view, no other slots.
        #expect(labels.filter { $0.hasPrefix("Pip") } == ["Pip – primary reference", "Pip – happy expression", "Pip – back view"])
        // Place: primary + 1 other slot, the one the text names.
        #expect(labels.filter { $0.hasPrefix("Old Mill") } == ["Old Mill – primary reference", "Old Mill – night"])
        // Object: primary only.
        #expect(labels.filter { $0.hasPrefix("Brass Key") } == ["Brass Key – primary reference"])
    }

    @Test func placeWithoutNamedSlotGetsTheFirstChosenOne() throws {
        var book = SliceBook.make()
        let mill = Cast.add(.place, "Old Mill", options: .init(extraSlots: ["Day", "Night"]), to: &book.content)
        let (_, report) = try assemble(book.target, assetIntent("At \(mention(mill))"), content: book.content)
        #expect(sentLabels(report) == ["Old Mill – primary reference", "Old Mill – day"])
    }

    @Test func styleReferencesCappedAtTwoUnlessSpare() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        book.content.style.styleReferences = (1...4).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        // Plenty of room: all four styles, the extra two after the sheet items.
        let (_, roomy) = try assemble(book.target, assetIntent("\(mention(pip)) sleepy"), content: book.content)
        #expect(sentLabels(roomy) == ["Pip – primary reference", "Style reference 1", "Style reference 2",
                                      "Pip – sleepy expression", "Pip – three-quarter view",
                                      "Style reference 3", "Style reference 4"])
        // Five images: the spare styles are what gets cut.
        var model = try testModel()
        model.image.maxReferenceImages = 5
        let (_, tight) = try assemble(book.target, assetIntent("\(mention(pip)) sleepy"), content: book.content, model: model)
        #expect(sentLabels(tight).count == 5)
        #expect(tight.referencesOmitted.map(\.label) == ["Style reference 3 (over the limit)", "Style reference 4 (over the limit)"])
    }

    @Test func imageLimitStopsAndListsTheRest() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let granny = Cast.add(.character, "Granny Oak", to: &book.content)
        book.content.style.styleReferences = (1...3).map { ImageRef(sha256: "style\($0)", contentType: "public.png") }
        var model = try testModel()
        model.image.maxReferenceImages = 6
        let message = "\(mention(pip)) and \(mention(granny)), both yawning"
        let (_, report) = try assemble(book.target, assetIntent(message), content: book.content, model: model)
        #expect(sentLabels(report) == ["Pip – primary reference", "Granny Oak – primary reference",
                                       "Style reference 1", "Style reference 2",
                                       "Pip – sleepy expression", "Pip – three-quarter view"])
        #expect(ReferenceSelector.leftOutSummary(report.referencesOmitted)
            == "Left out: Granny Oak – sleepy expression; Granny Oak – three-quarter view; style reference 3.")
    }

    @Test func byteBudgetStopsAtTheFirstMisfit() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        var data = Cast.imageData(book.content, size: 30)
        data[Cast.ref("Pip", "expr-sleepy")] = Data(count: 50)
        data[Cast.ref("Pip", "view-threeQuarter")] = Data(count: 5)
        var model = try testModel()
        model.image.maxRequestBytes = 70
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning"), content: book.content,
                                       model: model, imageData: data)
        // 30 + 50 > 70 stops selection; the small view after it is not squeezed in.
        #expect(sentLabels(report) == ["Pip – primary reference"])
        #expect(report.referencesOmitted.map(\.label) == ["Pip – sleepy expression (over the limit)",
                                                          "Pip – three-quarter view (over the limit)"])
        #expect(report.estimatedInputBytes == report.promptText.utf8.count + 30)
    }

    @Test func leftOutWording() {
        let omitted = [
            SentReference(image: Cast.ref("Granny Oak", "expr-sleepy"), role: "asset", label: "Granny Oak – sleepy expression (over the limit)"),
            SentReference(image: ImageRef(sha256: "s3", contentType: "public.png"), role: "style", label: "Style reference 3 (file missing)"),
        ]
        #expect(ReferenceSelector.leftOutSummary(omitted) == "Left out: Granny Oak – sleepy expression; style reference 3.")
        #expect(ReferenceSelector.leftOutSummary([]) == nil)
    }

    @Test(arguments: [
        ("grinning at the moon", "happy"), ("a giggle", "happy"), ("beaming", "happy"), ("smiling", "happy"),
        ("tears on her cheeks", "sad"), ("crying", "sad"), ("sobbing", "sad"),
        ("a big yawn", "sleepy"), ("yawning", "sleepy"), ("drowsy", "sleepy"), ("fast asleep", "sleepy"),
        ("wide-eyed", "surprised"), ("gasps", "surprised"), ("scowling", "angry"), ("Angry!", "angry"),
    ])
    func expressionSynonyms(text: String, expected: String) {
        #expect(SheetSynonyms.bundled.matchExpression(in: text, among: CharacterSheet.defaultExpressions) == expected)
    }

    @Test(arguments: [
        ("seen from behind", SheetView.back), ("walking away down the lane", .back),
        ("in profile", .side), ("side-on", .side),
        ("turning to wave", .threeQuarter), ("looking over her shoulder", .threeQuarter),
        ("by the fire", .threeQuarter),  // no match: the default
    ])
    func viewSynonyms(text: String, expected: SheetView) {
        #expect(SheetSynonyms.bundled.matchView(in: text, among: SheetView.allCases) == expected)
    }

    @Test func noExpressionMatchSendsNone() {
        #expect(SheetSynonyms.bundled.matchExpression(in: "by the fire", among: CharacterSheet.defaultExpressions) == nil)
    }

    @Test(arguments: ["grumble", "grumbles", "grumbling", "grumbled", "grumbly", "GRUMBLE"])
    func customExpressionInflections(word: String) {
        #expect(SheetSynonyms.bundled.matchExpression(in: "Pip \(word) at the rain", among: ["Grumble"]) == "Grumble")
    }

    @Test(arguments: ["smirk", "smirks", "smirking", "smirked", "smirky"])
    func customExpressionWithoutFinalE(word: String) {
        #expect(SheetSynonyms.bundled.matchExpression(in: word, among: ["smirk"]) == "smirk")
    }

    @Test func customExpressionDoesNotMatchOtherWords() {
        #expect(SheetSynonyms.bundled.matchExpression(in: "grumpy smirks", among: ["grumble"]) == nil)
        #expect(SheetSynonyms.bundled.matchExpression(in: "a cheeky grin", among: ["cheeky", "happy"]) == "cheeky")
    }

    @Test func customExpressionGoesThroughTheAssembler() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(customExpressions: ["mischievous"]), to: &book.content)
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)), mischievous as ever"), content: book.content)
        #expect(sentLabels(report).contains("Pip – mischievous expression"))
    }

    @Test func earliestMatchWins() {
        #expect(SheetSynonyms.bundled.matchExpression(in: "sad at first, then happy", among: CharacterSheet.defaultExpressions) == "sad")
        #expect(SheetSynonyms.bundled.matchView(in: "in profile, then from behind", among: SheetView.allCases) == .side)
    }

    @Test func defaultViewIsThreeQuarterOnlyWhenChosen() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(chosenSheet: [.view(.side), .view(.back)]), to: &book.content)
        let (_, report) = try assemble(book.target, assetIntent("\(mention(pip)) by the fire"), content: book.content)
        #expect(sentLabels(report) == ["Pip – primary reference"])
        #expect(SheetSynonyms.bundled.matchView(in: "by the fire", among: [.side, .back]) == nil)
    }

    @Test func unchosenItemsAreSkippedAndLockedKept() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip",
                           options: .init(chosenSheet: [.view(.threeQuarter), .expression("happy")],
                                          lockedSheet: [.view(.threeQuarter), .expression("happy")]),
                           to: &book.content)
        // Sleepy isn't chosen: no expression is sent (the happy one doesn't match), not even as omitted.
        let (_, yawning) = try assemble(book.target, assetIntent("\(mention(pip)) yawning"), content: book.content)
        #expect(sentLabels(yawning) == ["Pip – primary reference", "Pip – three-quarter view"])
        #expect(yawning.referencesOmitted.isEmpty)
        // Locked and chosen: sent.
        let (_, grinning) = try assemble(book.target, assetIntent("\(mention(pip)) grinning"), content: book.content)
        #expect(sentLabels(grinning) == ["Pip – primary reference", "Pip – happy expression", "Pip – three-quarter view"])
    }

    @Test func unchosenPrimaryIsSkipped() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", options: .init(primaryChosen: false), to: &book.content)
        let (request, report) = try assemble(book.target, assetIntent("\(mention(pip)) yawning"), content: book.content)
        #expect(sentLabels(report) == ["Pip – sleepy expression", "Pip – three-quarter view"])
        // Still in the cast, without a primary image line.
        #expect(request.instruction.rendered.contains("- Pip (character)."))
    }

    @Test func storyTextMatchesOnlyWhenIncluded() throws {
        var book = SliceBook.make(text: "Pip gave an enormous yawn.")
        let pip = Cast.add(.character, "Pip", to: &book.content)
        book.content.pages[book.pageID]?.assetChecklist = [pip.id]
        let (_, withStory) = try assemble(book.target, assetIntent("By the fire", story: true), content: book.content)
        #expect(sentLabels(withStory).contains("Pip – sleepy expression"))
        let (_, without) = try assemble(book.target, assetIntent("By the fire", story: false), content: book.content)
        #expect(!sentLabels(without).contains("Pip – sleepy expression"))
    }

    @Test func duplicatesKeepTheHigherTier() throws {
        var book = SliceBook.make()
        let pip = Cast.add(.character, "Pip", to: &book.content)
        let primary = try #require(pip.primary)
        let attached = VersionRef(sessionID: primary.sessionID, versionID: try #require(primary.chosen))
        var value = assetIntent("\(mention(pip)) yawning")
        value.attachedReferences = [attached]
        let (_, report) = try assemble(book.target, value, content: book.content)
        #expect(sentLabels(report) == ["Reference v1", "Pip – sleepy expression", "Pip – three-quarter view"])
    }

    @Test func selectSkipsMissingAndTooLargeButStopsAtBudget() {
        func c(_ name: String) -> ReferenceSelector.Candidate {
            .init(ref: ImageRef(sha256: name, contentType: "public.png"), role: "style", label: name, tier: .style)
        }
        let candidates = ["a", "missing", "huge", "b", "c", "d"].map(c)
        let sizes: [ImageRef: Int] = [candidates[0].ref: 10, candidates[2].ref: 500, candidates[3].ref: 10,
                                      candidates[4].ref: 10, candidates[5].ref: 1]
        let selection = ReferenceSelector.select(candidates, byteCounts: sizes,
                                                 limits: .init(maxImages: 2, maxImageBytes: 100, maxTotalBytes: 1000))
        #expect(selection.sent.map(\.label) == ["a", "b"])
        #expect(selection.omitted.map(\.reason) == [.fileMissing, .tooLarge, .overLimit, .overLimit])
        #expect(selection.bytes == 20)
    }
}
