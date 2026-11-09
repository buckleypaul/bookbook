import AppKit
import BBExport
import BBModel
import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Export… (PD §8.8): output options, the preflight list, then a save panel and export.
struct ExportSheet: View {
    @State var model: ExportSheetModel
    let onOpenPage: (PageID) -> Void
    let onClose: () -> Void
    @State private var preview: UpscalePreview?
    @State private var previewError: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text("Export").font(.title2.bold()).padding([.horizontal, .top], 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    options(model)
                    preflight(model)
                }
                .padding(20)
            }
            Divider()
            footer(model)
        }
        .frame(width: 520, height: 600)
        .task { await model.runPreflight() }
        .onAppear { model.chooseDestination = Self.runSavePanel }
        .interactiveDismissDisabled(model.isExporting)
        .alert("Couldn't export", isPresented: Binding(get: { model.errorMessage != nil },
                                                       set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Couldn't preview the image", isPresented: Binding(get: { previewError != nil },
                                                                  set: { if !$0 { previewError = nil } })) {
            Button("OK") { previewError = nil }
        } message: { Text(previewError ?? "") }
        .sheet(item: $preview) { UpscalePreviewSheet(preview: $0) }
    }

    // MARK: Options

    @ViewBuilder
    private func options(_ model: ExportSheetModel) -> some View {
        @Bindable var model = model
        Picker("Output", selection: $model.outputType) {
            ForEach(ExportSheetModel.OutputType.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(model.isExporting)
        switch model.outputType {
        case .standard:
            note("Home printing: pages at trim size, no bleed.")
        case .printShop:
            note("Bleed, crop marks and trim boxes, for a print shop.")
            if model.needsBleed {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Print shop export needs bleed. This book has bleed turned off, so the pages have nothing to print past the trim edge.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Turn On Bleed") { model.turnOnBleed() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .booklet:
            Picker("Sheet size", selection: $model.sheetSize) {
                ForEach(SheetSize.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if let blanks = model.result?.blanksAdded ?? model.predictedBlanks {
                note(blanks == 0 ? "No blank pages needed."
                     : "\(blanks) blank \(blanks == 1 ? "page" : "pages") will be added so pages fall on the right side and fill the last sheet.")
            }
            if model.bookletBindsAtTop {
                note("These landscape pages are stacked two to a sheet, so the booklet binds at the top.")
            }
            if let result = model.result {
                if result.scaledToFit {
                    note("Pages were scaled to \(Int((result.scale * 100).rounded())) percent to fit two to a sheet.")
                }
                if let instructions = result.printingInstructions { Text(instructions).font(.callout) }
            } else {
                note("Pages are scaled to fit two to a sheet if the sheet is too small.")
            }
        }
        Toggle("Include cover", isOn: $model.includeCover)
        if model.offersSeparateCover {
            Button("Export Cover Separately…") { model.exportCoverSeparately() }
        }
        Toggle("Only some pages", isOn: $model.limitsRange)
        if model.limitsRange {
            HStack {
                Stepper("From \(model.rangeFrom)", value: $model.rangeFrom, in: 1...max(1, model.totalPositions))
                Stepper("to \(model.rangeTo)", value: $model.rangeTo, in: 1...max(1, model.totalPositions))
                Text("of \(model.totalPositions)").foregroundStyle(.secondary)
            }
            if !model.isRangeValid { Text("The first page must come before the last.").foregroundStyle(.red) }
        }
        if model.showsSpreadsOption, model.hasSpreads {
            Picker("Spreads", selection: $model.spreads) {
                Text("Single pages").tag(SpreadOutput.singlePages)
                Text("Spread pages").tag(SpreadOutput.doubleWidth)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Preflight

    @ViewBuilder
    private func preflight(_ model: ExportSheetModel) -> some View {
        Divider()
        if model.isCheckingPreflight {
            HStack { ProgressView().controlSize(.small); Text("Checking the book…") }
        } else if model.issues.isEmpty {
            Label("No problems found.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            ForEach(model.issueGroups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.kind.groupTitle).font(.headline)
                    ForEach(group.issues) { issue in
                        HStack {
                            Button { onOpenPage(issue.page) } label: {
                                Text("\(model.pageLabel(for: issue)): \(issue.detail)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.link)
                            .help("Go to this page")
                            if issue.kind == .softImage {
                                Button("Preview Upscaled") { showPreview(issue) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func showPreview(_ issue: PreflightIssue) {
        let services = model.services
        Task {
            do {
                guard let url = try await services.upscaledPreviewURL(for: issue),
                      let image = NSImage(contentsOf: url) else {
                    previewError = "There is no upscaled image for this issue."
                    return
                }
                preview = UpscalePreview(title: issue.detail, image: image)
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ model: ExportSheetModel) -> some View {
        HStack {
            if model.isExporting, let progress = model.progress {
                ProgressView(value: progress.fraction).frame(maxWidth: 220)
                Button("Cancel") { model.cancelExport() }
            } else if let result = model.result {
                Label("Exported \(result.pageCount) \(result.pageCount == 1 ? "page" : "pages").",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExporting)
            Button(model.printTitle) { model.startPrint() }
                .disabled(!model.canExport)
            Button(model.primaryTitle) { model.startExport() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
        }
        .padding(16)
    }

    private static func runSavePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        ExportPanel.configure(panel)
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        ExportPanel.remember(url)
        return url
    }
}

struct UpscalePreview: Identifiable {
    let id = UUID()
    let title: String
    let image: NSImage
}

/// The prepared image at 100 percent: actual pixels, so one image pixel is one screen pixel.
struct UpscalePreviewSheet: View {
    let preview: UpscalePreview
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(preview.title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: preview.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: pixels.width / scale, height: pixels.height / scale)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var pixels: CGSize {
        if let rep = preview.image.representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return preview.image.size
    }
}
