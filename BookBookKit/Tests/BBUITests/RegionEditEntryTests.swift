import Testing
@testable import BBUI

@Suite struct RegionEditEntryTests {
    @Test func availableWhenNothingBlocks() {
        #expect(RegionEditEntry.unavailableMessage(isEditable: true, isOnline: true, hasKey: true, refusal: nil) == nil)
    }

    @Test func readOnlyWins() {
        let text = RegionEditEntry.unavailableMessage(isEditable: false, isOnline: true, hasKey: true,
                                                      refusal: .maskUnsupported(model: "M"))
        #expect(text == RegionEditRefusal.readOnly.message)
    }

    @Test func modelRefusalExplained() {
        let text = RegionEditEntry.unavailableMessage(isEditable: true, isOnline: true, hasKey: true,
                                                      refusal: .maskUnsupported(model: "M"))
        #expect(text?.contains("M") == true)
    }

    @Test func offlineAndNoKey() {
        #expect(RegionEditEntry.unavailableMessage(isEditable: true, isOnline: false, hasKey: true, refusal: nil) != nil)
        #expect(RegionEditEntry.unavailableMessage(isEditable: true, isOnline: true, hasKey: false, refusal: nil) != nil)
    }
}
