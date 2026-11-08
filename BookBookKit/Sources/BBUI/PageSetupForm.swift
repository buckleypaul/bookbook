import BBModel
import SwiftUI

/// The Style tab's page setup section: size preset, custom size, orientation, margins, bleed.
/// Lengths are in inches. Each edit is one `.setPageSetup`.
struct PageSetupForm: View {
    let model: StyleTabModel

    var body: some View {
        let setup = model.pageSetup
        Section("Page setup") {
            Picker("Size", selection: Binding(get: { setup.sizePreset }, set: { model.setSizePreset($0) })) {
                ForEach(PageSizePreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if setup.sizePreset.isBookletSize {
                Text("Prints as a booklet on Letter/A4.").font(.caption).foregroundStyle(.secondary)
            }
            if setup.sizePreset == .custom {
                LabeledContent("Width (in)") {
                    CommitField(title: "Width", value: StyleTabModel.inches(setup.trimSize.width), fractionDigits: 3) {
                        model.setCustomSize(widthInches: $0)
                    }.frame(width: 80)
                }
                LabeledContent("Height (in)") {
                    CommitField(title: "Height", value: StyleTabModel.inches(setup.trimSize.height), fractionDigits: 3) {
                        model.setCustomSize(heightInches: $0)
                    }.frame(width: 80)
                }
            }
            Picker("Orientation", selection: Binding(get: { setup.orientation }, set: { model.setOrientation($0) })) {
                Text("Portrait").tag(Orientation.portrait)
                Text("Landscape").tag(Orientation.landscape)
                if model.isSquare { Text("Square").tag(Orientation.square) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isSquare || setup.sizePreset == .custom)

            LabeledContent("Margins (in)") {
                CommitField(title: "Margins", value: StyleTabModel.inches(setup.margins.top), fractionDigits: 3) {
                    model.setMargins(inches: $0)
                }.frame(width: 80)
            }
            Toggle("Bleed", isOn: Binding(get: { setup.bleedEnabled }, set: { model.setBleedEnabled($0) }))
            if setup.bleedEnabled {
                LabeledContent("Bleed amount (in)") {
                    CommitField(title: "Bleed amount", value: StyleTabModel.inches(setup.bleedAmount), fractionDigits: 3) {
                        model.setBleedAmount(inches: $0)
                    }.frame(width: 80)
                }
            }
        }
    }
}
