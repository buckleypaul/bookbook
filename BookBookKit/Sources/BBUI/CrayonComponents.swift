import SwiftUI

// Shared Crayon pieces built on the tokens in Theme.swift: banners, sheet scaffolding, inline
// status lines and the AI composer field. Use these instead of hand-copying the look.

// MARK: - Banner

/// The in-window banner: an inset rounded card tinted with `color`, the symbol in a coloured
/// circle, the message, then optional trailing actions. Use for every window-level notice
/// (read-only, save errors, missing fonts, a paused queue) instead of a flat strip.
public struct CrayonBanner<Trailing: View>: View {
    let text: String
    let systemImage: String
    let color: Color
    let glyphColor: Color
    let trailing: Trailing

    /// `glyphColor` is the symbol's colour on the `color` circle; pass `Crayon.onSunflower` for a
    /// sunflower banner. `trailing` sits at the end, e.g. a `.crayon(color)` button.
    public init(_ text: String, systemImage: String, color: Color, glyphColor: Color = .white,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.glyphColor = glyphColor
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(glyphColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 2)
            Text(text)
                .font(Crayon.font(.callout, weight: .semibold))
                .foregroundStyle(Crayon.ink)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CrayonBannerFill(color: color))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The banner's background: a soft `color` tint on a card, a coloured rim and the chunky
/// shadow. Use directly only for a custom banner layout that `CrayonBanner` can't express.
public struct CrayonBannerFill: View {
    let color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
        shape.fill(Crayon.card)
            .overlay(shape.fill(color.opacity(0.16)))
            .overlay(shape.strokeBorder(color.opacity(0.55), lineWidth: 1.5))
            .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
    }
}

// MARK: - Sheets

public extension View {
    /// The house sheet body: 20 pt padding, an optional fixed or minimum size, then paper behind
    /// it. Apply once to a sheet's root `VStack` (which starts with a `CrayonHeader` and ends
    /// with a `CrayonSheetFooter`); pass the sizes here rather than in a separate `.frame`.
    func crayonSheet(width: CGFloat? = nil, height: CGFloat? = nil,
                     minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> some View {
        padding(20)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .frame(width: width, height: height)
            .crayonPaper()
    }
}

/// A sheet's bottom row: optional leading content (a ProgressView, a hint or a side action),
/// a spacer, Cancel (Escape), optional secondary buttons, then the crayon primary (Return).
/// Use for every sheet that confirms or cancels. Cancel dismisses the sheet unless `onCancel`
/// is given. To restyle Cancel and the secondary buttons, apply e.g. `.buttonStyle(.bordered)`
/// to the footer; the primary keeps its crayon style.
public struct CrayonSheetFooter<Leading: View, Secondary: View>: View {
    let primaryTitle: String
    let color: Color
    let isDisabled: Bool
    let cancelTitle: String
    let onCancel: (() -> Void)?
    let action: () -> Void
    let leading: Leading
    let secondary: Secondary
    @Environment(\.dismiss) private var dismiss

    /// `isDisabled` disables only the primary button; `secondary` goes between Cancel and it.
    public init(_ primaryTitle: String, color: Color = Crayon.tomato, isDisabled: Bool = false,
                cancelTitle: String = "Cancel", onCancel: (() -> Void)? = nil,
                action: @escaping () -> Void,
                @ViewBuilder leading: () -> Leading = { EmptyView() },
                @ViewBuilder secondary: () -> Secondary = { EmptyView() }) {
        self.primaryTitle = primaryTitle
        self.color = color
        self.isDisabled = isDisabled
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.action = action
        self.leading = leading()
        self.secondary = secondary()
    }

    public var body: some View {
        HStack {
            leading
            Spacer()
            Button(cancelTitle, role: .cancel) { if let onCancel { onCancel() } else { dismiss() } }
                .keyboardShortcut(.cancelAction)
            secondary
            Button(primaryTitle, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.crayon(color))
                .disabled(isDisabled)
        }
    }
}

/// The bottom row of a sheet with nothing to cancel: optional leading content, a spacer, then
/// one crayon "Done" button (Return). Use for informational or apply-as-you-go sheets. Done
/// dismisses the sheet unless `action` is given.
public struct CrayonSheetDoneFooter<Leading: View>: View {
    let title: String
    let color: Color
    let isDisabled: Bool
    let action: (() -> Void)?
    let leading: Leading
    @Environment(\.dismiss) private var dismiss

    /// `action` replaces the default dismiss (call `dismiss()` yourself in it if needed).
    public init(_ title: String = "Done", color: Color = Crayon.tomato, isDisabled: Bool = false,
                action: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading = { EmptyView() }) {
        self.title = title
        self.color = color
        self.isDisabled = isDisabled
        self.action = action
        self.leading = leading()
    }

    public var body: some View {
        HStack {
            leading
            Spacer()
            Button(title) { if let action { action() } else { dismiss() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.crayon(color))
                .disabled(isDisabled)
        }
    }
}

// MARK: - Inline status messages

/// A one-line (wrapping) status message under a field or in a footer: a kind icon and text in
/// the kind's Crayon colour, in rounded semibold caption type. Use instead of `.red`, `.orange`
/// or `.green` text and labels.
public struct CrayonInlineMessage: View {
    /// What the message reports; picks the icon and colour.
    public enum Kind: Sendable, CaseIterable {
        case error, warning, success, info

        /// The kind's colour: `Crayon.danger`, `.warning`, `.success` or `.inkSoft`.
        public var color: Color {
            switch self {
            case .error: Crayon.danger
            case .warning: Crayon.warning
            case .success: Crayon.success
            case .info: Crayon.inkSoft
            }
        }

        /// The kind's SF Symbol.
        public var systemImage: String {
            switch self {
            case .error: "exclamationmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    let text: String
    let kind: Kind
    let textStyle: Font.TextStyle

    /// `textStyle` defaults to caption (field-level lines); pass `.callout` for a sheet- or
    /// pane-level message.
    public init(_ text: String, kind: Kind, textStyle: Font.TextStyle = .caption) {
        self.text = text
        self.kind = kind
        self.textStyle = textStyle
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Crayon.font(textStyle, weight: .semibold))
        .foregroundStyle(kind.color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Composer field

public extension View {
    /// The AI composer's prompt field: plain style, rounded body type in ink, a paper fill and a
    /// soft 1.5 pt rim at the small radius. Apply to a vertical-axis `TextField`; keep `.focused`,
    /// `.onSubmit` and friends at the call site.
    func crayonComposerField(lineLimit: ClosedRange<Int> = 2...6) -> some View {
        modifier(CrayonComposerFieldModifier(lineLimit: lineLimit))
    }
}

struct CrayonComposerFieldModifier: ViewModifier {
    let lineLimit: ClosedRange<Int>

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.smallCornerRadius, style: .continuous)
        content
            .lineLimit(lineLimit)
            .textFieldStyle(.plain)
            .font(Crayon.font(.body, weight: .regular))
            .foregroundStyle(Crayon.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Crayon.paper, in: shape)
            .overlay(shape.strokeBorder(Crayon.ink.opacity(0.12), lineWidth: 1.5))
    }
}
