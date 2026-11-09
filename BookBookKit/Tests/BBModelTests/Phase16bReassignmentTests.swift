import Testing
@testable import BBModel

/// Phase 16b #70a/#70b: bound boxes (title, author, page-number slot) neither give nor receive
/// body text in the generic mapping (rules 2 and 3).
@Suite struct Phase16bReassignmentTests {
    private func rect(_ x: Double, _ y: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: 0.4, height: 0.4)
    }
    private func textBox(_ x: Double, _ y: Double, role: BoxRole? = nil) -> Box {
        Box(frame: rect(x, y), content: .text(TextBoxStyle()), role: role)
    }
    private func template(_ boxes: [Box]) -> Template { Template(name: "t", kind: .single, boxes: boxes) }

    /// #70a: an old title box with no title box in the new template doesn't land in a body box.
    @Test func boundTitleWithoutSameRoleTargetIsNotMovedIntoBody() {
        let title = textBox(0, 0, role: .title), author = textBox(0, 0.1, role: .author)
        let body = textBox(0, 0.5)
        let old = template([title, author, body])
        let nBody = textBox(0, 0.5), nBody2 = textBox(0.5, 0.5)
        let page = Page(kind: .story, templateID: old.id, text: [
            title.id: RichText(plain: "Title"), author.id: RichText(plain: "Author"),
            body.id: RichText(plain: "Story"),
        ])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nBody, nBody2]))
        #expect(r.page.text == [nBody.id: RichText(plain: "Story")])
    }

    /// #70a: bound text is also not appended as leftover to the last body box.
    @Test func boundTextIsNotAppendedAsLeftover() {
        let title = textBox(0, 0, role: .title), body = textBox(0, 0.5)
        let old = template([title, body])
        let nBody = textBox(0, 0.5)
        let page = Page(kind: .story, templateID: old.id, text: [
            title.id: RichText(plain: "Title"), body.id: RichText(plain: "Story"),
        ])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nBody]))
        #expect(r.page.text == [nBody.id: RichText(plain: "Story")])
    }

    /// #70a: a bound box with a same-role target still maps by role (rule 1).
    @Test func boundTextStillMapsByRole() {
        let title = textBox(0, 0, role: .title)
        let old = template([title])
        let nTitle = textBox(0, 0.3, role: .title), nBody = textBox(0, 0)
        let page = Page(kind: .story, templateID: old.id, text: [title.id: RichText(plain: "Title")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nBody, nTitle]))
        #expect(r.page.text == [nTitle.id: RichText(plain: "Title")])
    }

    /// #70b: body text never lands in a page-number slot.
    @Test func pageNumberSlotGetsNoBodyText() {
        let body = textBox(0, 0.5)
        let old = template([body])
        let nSlot = textBox(0, 0, role: .pageNumberSlot), nBody = textBox(0, 0.6)
        let page = Page(kind: .story, templateID: old.id, text: [body.id: RichText(plain: "Story")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nSlot, nBody]))
        #expect(r.page.text == [nBody.id: RichText(plain: "Story")])
    }

    /// #70b: with only a page-number slot left, body text is dropped rather than put there.
    @Test func onlyPageNumberSlotDropsBodyText() {
        let body = textBox(0, 0.5)
        let old = template([body])
        let nSlot = textBox(0, 0, role: .pageNumberSlot)
        let page = Page(kind: .story, templateID: old.id, text: [body.id: RichText(plain: "Story")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nSlot]))
        #expect(r.page.text.isEmpty)
    }

    /// #70b: a page-number slot's text with no slot in the new template doesn't become body text.
    @Test func oldPageNumberSlotTextIsNotMovedIntoBody() {
        let slotBox = textBox(0, 0, role: .pageNumberSlot)
        let old = template([slotBox])
        let nBody = textBox(0, 0.5)
        let page = Page(kind: .story, templateID: old.id, text: [slotBox.id: RichText(plain: "7")])
        let r = TemplateReassignment.reassign(page, from: old, to: template([nBody]))
        #expect(r.page.text.isEmpty)
    }
}
