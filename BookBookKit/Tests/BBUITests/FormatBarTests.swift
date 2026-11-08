import BBModel
import Testing

@testable import BBUI

@MainActor
struct FormatBarTests {
    @Test func rgbaRoundTripsThroughSwiftUIColor() {
        let colour = RGBA(red: 0.2, green: 0.4, blue: 0.6)
        let back = RGBA(color: colour.swiftUIColor)
        #expect(abs(back.red - 0.2) < 0.01 && abs(back.green - 0.4) < 0.01 && abs(back.blue - 0.6) < 0.01)
    }

    @Test func fontFamilyLookup() {
        let face = FontFamilies.regularFace(of: "Helvetica")
        #expect(face != nil)
        #expect(FontFamilies.family(of: face ?? "") == "Helvetica")
        #expect(FontFamilies.family(of: "NoSuchFont-Regular") == nil)
    }

    @Test func formatControlsDisabledWithoutEditor() {
        let controller = TextFormatController()
        #expect(!controller.isEditing)
        controller.perform(.toggleBold) // no target: no crash
    }
}
