import Testing
@testable import BBModel

@Suite struct TemplateReassignmentTests {
    private func rect(_ x: Double, _ y: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: 0.4, height: 0.4)
    }
    private func textBox(_ x: Double, _ y: Double, role: BoxRole? = nil) -> Box {
        Box(frame: rect(x, y), content: .text(TextBoxStyle()), role: role)
    }
    private func imageBox(_ x: Double, _ y: Double, role: BoxRole? = nil) -> Box {
        Box(frame: rect(x, y), content: .image, role: role)
    }
    private func slot() -> ImageSlot { ImageSlot(sessionID: SessionID()) }
    private func template(_ boxes: [Box]) -> Template { Template(name: "t", kind: .single, boxes: boxes) }

    @Test func imageOnTopToTextLeftImageRight() {
        let img = imageBox(0, 0), txt = textBox(0, 0.6)
        let old = template([img, txt])
        let nTxt = textBox(0, 0), nImg = imageBox(0.5, 0)
        let new = template([nImg, nTxt])
        let s = slot()
        let page = Page(kind: .story, templateID: old.id, text: [txt.id: RichText(plain: "Hi")], images: [img.id: s])
        let r = TemplateReassignment.reassign(page, from: old, to: new)
        #expect(r.page.templateID == new.id)
        #expect(r.page.text == [nTxt.id: RichText(plain: "Hi")])
        #expect(r.page.images == [nImg.id: s])
        #expect(r.unassignedImageBoxes.isEmpty)
        #expect(r.page.id == page.id)
    }

    @Test func rolesMatchedFirst() {
        let title = textBox(0, 0.8, role: .title), body = textBox(0, 0.1)
        let old = template([body, title])
        let nBody = textBox(0, 0), nTitle = textBox(0, 0.9, role: .title)
        let new = template([nBody, nTitle])
        let page = Page(kind: .story, templateID: old.id, text: [
            title.id: RichText(plain: "T"), body.id: RichText(plain: "B")])
        let r = TemplateReassignment.reassign(page, from: old, to: new)
        #expect(r.page.text[nTitle.id]?.plainText == "T")
        #expect(r.page.text[nBody.id]?.plainText == "B")
    }

    @Test func leftoverTextAppendedToLastMapped() {
        let a = textBox(0, 0), b = textBox(0, 0.3), c = textBox(0, 0.6)
        let old = template([a, b, c])
        let n1 = textBox(0, 0), n2 = textBox(0, 0.5)
        let new = template([n1, n2])
        let page = Page(kind: .story, templateID: old.id, text: [
            a.id: RichText(plain: "A"), b.id: RichText(plain: "B"), c.id: RichText(plain: "C")])
        let r = TemplateReassignment.reassign(page, from: old, to: new)
        #expect(r.page.text[n1.id]?.plainText == "A")
        #expect(r.page.text[n2.id]?.plainText == "B\nC")
    }

    @Test func noNewTextBoxDropsText() {
        let a = textBox(0, 0)
        let old = template([a])
        let new = template([imageBox(0, 0)])
        let page = Page(kind: .story, templateID: old.id, text: [a.id: RichText(plain: "A")])
        let r = TemplateReassignment.reassign(page, from: old, to: new)
        #expect(r.page.text.isEmpty)
    }

    @Test func leftoverImagesDroppedAndUnassignedListed() {
        let i1 = imageBox(0, 0), i2 = imageBox(0.5, 0)
        let old = template([i1, i2])
        let page = Page(kind: .story, templateID: old.id, images: [i1.id: slot(), i2.id: slot()])

        let n1 = imageBox(0, 0)
        let fewer = TemplateReassignment.reassign(page, from: old, to: template([n1]))
        #expect(fewer.page.images.count == 1)
        #expect(fewer.page.images[n1.id] == page.images[i1.id])
        #expect(fewer.unassignedImageBoxes.isEmpty)

        let m1 = imageBox(0, 0), m2 = imageBox(0.5, 0), m3 = imageBox(0, 0.5)
        let more = TemplateReassignment.reassign(page, from: old, to: template([m3, m2, m1]))
        #expect(more.page.images[m1.id] == page.images[i1.id])
        #expect(more.page.images[m2.id] == page.images[i2.id])
        #expect(more.unassignedImageBoxes == [m3.id])
    }

    @Test func otherFieldsKept() {
        let i = imageBox(0, 0)
        let old = template([i])
        var page = Page(kind: .story, templateID: old.id, images: [i.id: slot()], assetChecklist: [AssetID()], isDone: true)
        page.kind = .story
        let r = TemplateReassignment.reassign(page, from: old, to: template([imageBox(0, 0)]))
        #expect(r.page.assetChecklist == page.assetChecklist)
        #expect(r.page.isDone)
    }

    @Test func boundTitleAndAuthorBoxesGetNoBodyText() {
        let body = textBox(0, 0.5)
        let old = template([body])
        let nTitle = textBox(0, 0, role: .title), nAuthor = textBox(0, 0.1, role: .author)
        let nBody = textBox(0, 0.6)
        let page = Page(kind: .story, templateID: old.id, text: [body.id: RichText(plain: "Story")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nTitle, nAuthor, nBody]))
        #expect(r.page.text == [nBody.id: RichText(plain: "Story")])
    }

    @Test func noFreeTextBoxDropsTextRatherThanFillingBoundBoxes() {
        let body = textBox(0, 0.5)
        let old = template([body])
        let nTitle = textBox(0, 0, role: .title), nAuthor = textBox(0, 0.5, role: .author)
        let page = Page(kind: .story, templateID: old.id, text: [body.id: RichText(plain: "Story")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nTitle, nAuthor]))
        #expect(r.page.text.isEmpty)
    }
}
