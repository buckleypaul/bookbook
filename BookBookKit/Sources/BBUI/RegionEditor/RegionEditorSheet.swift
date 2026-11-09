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
    private let onCancel: () -> Void
    private let onSubmit: (RegionMaskDrawing, String) -> Void

    @State private var model: RegionEditorModel
    @State private var displayImage: CGImage?

    public init(imageData: Data, pixelSize: PixelSize, modelName: String,
                onCancel: @escaping () -> Void,
                onSubmit: @escaping (RegionMaskDrawing, String) -> Void) {
        self.imageData = imageData
        self.modelName = modelName
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _model = State(initialValue: RegionEditorModel(pixelSize: pixelSize))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            RegionEditorCanvas(model: model, image: displayImage)
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 600, idealHeight: 760)
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
                        .foregroundStyle(.secondary)
                    Slider(value: $model.brushDiameter, in: RegionEditorModel.brushDiameterRange)
                        .frame(width: 140)
                        .accessibilityLabel("Brush size")
                        .accessibilityValue("\(Int(model.brushDiameter.rounded())) pixels")
                        .accessibilityIdentifier("regionEditor.size")
                    Text("\(Int(model.brushDiameter.rounded())) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
            .help("Undo the last stroke (⌘Z)")
            .disabled(!model.canUndo)
            .accessibilityIdentifier("regionEditor.undo")

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
            TextField("Describe the change", text: $model.prompt, prompt: Text("Describe the change"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .accessibilityLabel("Describe the change")
                .accessibilityIdentifier("regionEditor.prompt")
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("regionEditor.cancel")
                Button("Edit Region", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("regionEditor.submit")
            }
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
