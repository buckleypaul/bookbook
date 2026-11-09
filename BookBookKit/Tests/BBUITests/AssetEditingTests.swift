import BBModel
import Foundation
import Testing
@testable import BBUI

struct AssetEditingTests {
    @Test func slotRules() {
        var a = Asset.makeNew(type: .object, name: "Lamp")
        let primary = a.references[0].id
        #expect(!AssetEditing.canRemoveSlot(primary, from: a))
        AssetEditing.addSlot(to: &a)
        #expect(a.references.count == 2)
        let second = a.references[1].id
        #expect(!AssetEditing.canRemoveSlot(primary, from: a))
        AssetEditing.makePrimary(second, in: &a)
        #expect(a.primary?.id == second)
        #expect(a.references.filter(\.isPrimary).count == 1)
        AssetEditing.removeSlot(primary, from: &a)
        #expect(a.references.count == 1)
        AssetEditing.removeSlot(second, from: &a)
        #expect(a.references.count == 1)
        AssetEditing.renameSlot(second, to: "  Side  ", in: &a)
        #expect(a.references[0].label == "Side")
        AssetEditing.renameSlot(second, to: " ", in: &a)
        #expect(a.references[0].label == "Side")
    }

    @Test func sheetEdits() {
        var a = Asset.makeNew(type: .character, name: "Pip")
        #expect(a.sheet?.items.count == 8)
        AssetEditing.addExpression("  Grumpy ", to: &a)
        AssetEditing.addExpression("HAPPY", to: &a)
        AssetEditing.addExpression("", to: &a)
        #expect(a.sheet?.items.count == 9)
        let item = a.sheet!.items.last!
        #expect(AssetEditing.title(of: item.kind) == "Grumpy")
        AssetEditing.setLocked(true, item: item.id, in: &a)
        #expect(a.sheet?.items.last?.locked == true)
        AssetEditing.removeSheetItem(item.id, from: &a)
        #expect(a.sheet?.items.count == 8)
        var obj = Asset.makeNew(type: .object, name: "Hat")
        AssetEditing.addExpression("sad", to: &obj)
        #expect(obj.sheet == nil)
    }

    @Test func titlesAndTags() {
        #expect(AssetEditing.title(of: .view(.threeQuarter)) == "Three-quarter view")
        #expect(AssetEditing.parseTags(" fox, red ,, Fox,small") == ["fox", "red", "small"])
        #expect(AssetEditing.tagsText(["a", "b"]) == "a, b")
    }

    @Test func listSortedAndFiltered() {
        var content = Fixtures.book(pages: 1)
        for (t, n) in [(AssetType.place, "Wood"), (.character, "pip"), (.character, "Ann")] {
            let a = Asset.makeNew(type: t, name: n)
            content.assets[a.id] = a
        }
        #expect(AssetEditing.list(content, type: nil).map(\.name) == ["Ann", "pip", "Wood"])
        #expect(AssetEditing.list(content, type: .character).map(\.name) == ["Ann", "pip"])
    }

    @Test func whereUsedLabels() {
        let content = Fixtures.book(pages: 2)
        let cover = content.book.coverPageID
        let p2 = content.book.pageOrder[1]
        #expect(WhereUsedText.pageLabel(cover, in: content) == "Cover")
        #expect(WhereUsedText.pageLabel(p2, in: content) == "Page 2")
        let box = content.pages[p2]!.images.keys.first!
        let site = UsageSite(page: p2, box: box, reasons: [.mention, .checklist])
        #expect(WhereUsedText.siteLabel(site, in: content) == "Page 2, image box")
        #expect(WhereUsedText.reasons(site.reasons) == "in the page's asset list, mentioned in a prompt")
        #expect(WhereUsedText.summary([], in: content) == "Not used on any page.")
        #expect(WhereUsedText.summary([site, UsageSite(page: p2, box: nil, reasons: [.checklist])], in: content)
            == "Used on Page 2.")
    }
}
