import AppKit
import BBAI
import BBAICore
import BBModel
import CoreGraphics
import ImageIO
import SwiftUI

/// Phase 11: the region editor sheet (A §6.2). Mark an area of the selected version with the brush or
/// lasso, describe the change, then "Edit Region" hands back the drawing (image px) and the prompt.
/// Undo, redo and Clear are local to the sheet: nothing here is a book edit.
public struct RegionEditorSheet: View {
    private let imageData: Data
    private let modelName: String
    private let estimate: CostEstimate?
    private let onCancel: () -> Void
    private let onSubmit: (RegionMaskDrawing, String) -> Void

    @State private var model: RegionEditorModel
    @State private var displayImage: CGImage?

    /// `estimate` is the cost of the edit, shown beside the button (PD §5, §8.9); the caller computes it.
    public init(imageData: Data, pixelSize: PixelSize, modelName: String,
                estimate: CostEstimate? = nil,
                onCancel: @escaping () -> Void,
                onSubmit: @escaping (RegionMaskDrawing, String) -> Void) {
        self.imageData = imageData
        self.modelName = modelName
        self.estimate = estimate
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _model = State(initialValue: RegionEditorModel(pixelSize: pixelSize))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CrayonHeader("Edit Region", color: Crayon.bubblegum)
            toolbar
            RegionEditorCanvas(model: model, image: displayImage)
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Crayon.thumbCornerRadius, style: .continuous))
            footer
        }
        .frame(idealWidth: 920, idealHeight: 720)
        .crayonSheet(minWidth: 720, minHeight: 600)
        .background(localUndoShortcuts)
        .task(id: imageData) {
            let data = imageData
            let maxSide = Self.displayMaxPixels(for: model.pixelSize)
            displayImage = await Task.detached(priority: .userInitiated) {
                Self.decodeForDisplay(data, maxPixels: maxSide)
            }.value
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tool", selection: $model.tool) {
                Label("Brush", systemImage: "paintbrush.pointed").tag(RegionEditorModel.Tool.brush)
                    .accessibilityIdentifier("regionEditor.brush")
                Label("Lasso", systemImage: "lasso").tag(RegionEditorModel.Tool.lasso)
                    .accessibilityIdentifier("regionEditor.lasso")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Selection tool")
            .accessibilityIdentifier("regionEditor.tool")

            Toggle(isOn: $model.isErasing) {
                Label("Erase", systemImage: "eraser")
            }
            .toggleStyle(.button)
            .help("Erase from the selection. Hold Option while dragging to erase once.")
            .accessibilityIdentifier("regionEditor.erase")

            if model.tool == .brush {
                HStack(spacing: 6) {
                    Text("Size")
                        .foregroundStyle(Crayon.inkSoft)
                    Slider(value: $model.brushDiameter, in: RegionEditorModel.brushDiameterRange)
                        .frame(width: 140)
                        .accessibilityLabel("Brush size")
                        .accessibilityValue("\(Int(model.brushDiameter.rounded())) pixels")
                        .accessibilityIdentifier("regionEditor.size")
                    Text("\(Int(model.brushDiameter.rounded())) px")
                        .monospacedDigit()
                        .foregroundStyle(Crayon.inkSoft)
                        .frame(width: 52, alignment: .leading)
                }
            }

            Spacer(minLength: 8)

            Button { model.invert() } label: {
                Label("Invert", systemImage: "circle.lefthalf.filled")
            }
            .help("Swap the selected and unselected areas")
            .disabled(model.drawing.isEmpty)
            .accessibilityIdentifier("regionEditor.invert")

            Button { model.undoLast() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!model.canUndo)
            .accessibilityIdentifier("regionEditor.undo")

            Button { model.redoLast() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .help("Redo (⇧⌘Z)")
            .disabled(!model.canRedo)
            .accessibilityIdentifier("regionEditor.redo")

            Button(role: .destructive) { model.clear() } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Remove the whole selection")
            .disabled(model.drawing.isEmpty)
            .accessibilityIdentifier("regionEditor.clear")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
    }

    /// ⌘Z / ⇧⌘Z act on the drawing while the sheet is open, never on the book (always enabled, so the
    /// shortcut can't fall through to the book's Edit menu when there's nothing to undo here).
    private var localUndoShortcuts: some View {
        ZStack {
            Button("Undo Stroke") { model.undoLast() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo Stroke") { model.redoLast() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Describe the change (e.g. add a red kite in the sky)", text: $model.prompt, axis: .vertical)
                .crayonComposerField()
                .onSubmit(submit)
                .accessibilityLabel("Describe the change")
                .accessibilityIdentifier("regionEditor.prompt")
            Text(statusText)
                .font(Crayon.font(.caption, weight: .medium))
                .foregroundStyle(Crayon.inkSoft)
                .lineLimit(1)
            CrayonSheetFooter("Edit Region", color: Crayon.bubblegum, isDisabled: !model.canSubmit,
                              onCancel: onCancel, action: submit,
                              leading: { if let estimate { CostEstimatePill(estimate: estimate) } })
        }
    }

    private var statusText: String {
        let size = "\(model.pixelSize.width) × \(model.pixelSize.height)"
        let hint = model.drawing.isEmpty ? "Paint or lasso the area to change." : "Only the marked area will change."
        return "\(modelName) · \(size) · \(hint)"
    }

    private func submit() {
        guard model.canSubmit else { return }
        onSubmit(model.drawing, model.trimmedPrompt)
    }

    // MARK: Display decoding

    /// The longest side to decode for display: the screen's backing size at most, never the full image.
    @MainActor
    static func displayMaxPixels(for pixelSize: PixelSize) -> Int {
        let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
        return max(1, min(max(pixelSize.width, pixelSize.height), Int(screen)))
    }

    /// Decodes `data` downsampled so its longest side is at most `maxPixels` (CGImageSource thumbnail).
    nonisolated static func decodeForDisplay(_ data: Data, maxPixels: Int) -> CGImage? {
        ImageCache.load(data, maxPixelSize: maxPixels)
    }
}
