import AppKit
import SwiftUI

/// BookBook's "crayon box" look: cream paper, bold friendly primaries, rounded type and chunky
/// soft shadows, with a night-time storybook variant in Dark Mode. App chrome only: the book's
/// own pages, thumbnails' page art and exports never use these colours.
public enum Crayon {
    // MARK: Palette (each adapts to light and dark)

    /// The accent: buttons, selection, focus.
    public static let tomato = Swatch.tomato.color
    public static let sunflower = Swatch.sunflower.color
    public static let sky = Swatch.sky.color
    public static let grass = Swatch.grass.color
    public static let grape = Swatch.grape.color
    public static let bubblegum = Swatch.bubblegum.color

    /// Window and sidebar backgrounds.
    public static let paper = Swatch.paper.color
    /// A slightly deeper paper for wells, insets and the sidebar.
    public static let paperDeep = Swatch.paperDeep.color
    /// The desk under the book window's panel cards: a cooler taupe than `paperDeep`, so the
    /// white cards stand out.
    public static let desk = Swatch.desk.color
    /// Raised cards.
    public static let card = Swatch.card.color
    /// Primary text on paper.
    public static let ink = Swatch.ink.color
    /// Secondary text on paper.
    public static let inkSoft = Swatch.inkSoft.color
    /// The chunky shadow under cards and buttons.
    public static let shadow = adaptive(light: 0x2B2340, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.45)

    // MARK: Semantic colours

    // Text tokens reach WCAG AA (4.5:1) on `paper` and `card` in both appearances; the
    // `CrayonContrastTests` suite checks it.

    /// Errors and failures (text, icons, rims): a deeper tomato in light mode (tomato itself is
    /// 2.7:1 on paper), tomato in dark mode. Use `tomato` for error fills.
    public static let danger = Swatch.danger.color
    /// Warnings: a deep amber in light mode (sunflower itself is unreadable as text on paper),
    /// sunflower in dark mode. Use for warning text and icons; use `sunflower` for warning fills.
    public static let warning = Swatch.warning.color
    /// Success and "done" confirmations: a deeper grass in light mode (grass itself is 2.1:1 on
    /// paper), grass in dark mode. Use `grass` for success fills.
    public static let success = Swatch.success.color
    /// Glyphs and text drawn on a `sunflower` fill: a dark ink in both appearances (`ink` turns
    /// cream in Dark Mode, and white has no contrast on sunflower).
    public static let onSunflower = Swatch.onSunflower.color
    /// Labels on a crayon fill where white doesn't reach the contrast it needs: a deep ink in
    /// both appearances, a touch darker than `ink` so it also reads on light-mode grape.
    /// `CrayonButtonStyle`, `CrayonSticker` and `CrayonBanner` switch to it automatically.
    public static let onFill = Swatch.onFill.color

    /// The fun colours in a fixed order, for decorating things by index (book covers, tabs).
    public static let rainbow: [Color] = [tomato, sunflower, sky, grass, grape, bubblegum]

    /// A stable colour for any hashable value (the same book always gets the same colour).
    public static func color(for index: Int) -> Color { rainbow[((index % rainbow.count) + rainbow.count) % rainbow.count] }

    public static func color(forKey key: String) -> Color {
        // FNV-1a: `hashValue` is seeded per launch, and the colour should be stable.
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return color(for: Int(hash % UInt32(rainbow.count)))
    }

    // MARK: Shape and type

    public static let cornerRadius: CGFloat = 16
    public static let smallCornerRadius: CGFloat = 10
    /// Between small and full: tiles, wells and thumbnail frames that sit inside a card
    /// (replaces `smallCornerRadius + 2`).
    public static let mediumCornerRadius: CGFloat = smallCornerRadius + 2
    /// Small thumbnails, swatches and images nested inside a small-radius frame
    /// (replaces `smallCornerRadius - 2`).
    public static let thumbCornerRadius: CGFloat = smallCornerRadius - 2

    /// Rounded system type for display text.
    public static func font(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    // MARK: Swatches

    /// The raw sRGB values behind the opaque palette and text tokens, so contrast can be worked
    /// out without resolving a dynamic `NSColor` (see `CrayonContrast`).
    enum Swatch {
        static let tomato = CrayonSwatch(light: 0xFF6B4A, dark: 0xFF8466)
        static let sunflower = CrayonSwatch(light: 0xFFC93C, dark: 0xFFD45E)
        static let sky = CrayonSwatch(light: 0x3DA5F4, dark: 0x5DB6FF)
        static let grass = CrayonSwatch(light: 0x4CC38A, dark: 0x5FD49B)
        static let grape = CrayonSwatch(light: 0x9B6BFF, dark: 0xB08CFF)
        static let bubblegum = CrayonSwatch(light: 0xFF7EB6, dark: 0xFF97C6)
        static let paper = CrayonSwatch(light: 0xFFF8EC, dark: 0x1E1B2E)
        static let paperDeep = CrayonSwatch(light: 0xFCEFD9, dark: 0x171425)
        static let desk = CrayonSwatch(light: 0xE2D6CA, dark: 0x110E1C)
        static let card = CrayonSwatch(light: 0xFFFFFF, dark: 0x2A2640)
        static let ink = CrayonSwatch(light: 0x2B2340, dark: 0xF5EEDC)
        static let inkSoft = CrayonSwatch(light: 0x7A6F8A, dark: 0xB3A9C4)
        static let danger = CrayonSwatch(light: 0xC8371A, dark: 0xFF8466)
        static let warning = CrayonSwatch(light: 0xA35F00, dark: 0xFFD45E)
        static let success = CrayonSwatch(light: 0x287A53, dark: 0x5FD49B)
        static let onSunflower = CrayonSwatch(light: 0x2B2340, dark: 0x2B2340)
        static let onFill = CrayonSwatch(light: 0x221A35, dark: 0x221A35)
    }

    /// The token colours that `CrayonContrast` can measure, paired with their values. Lookup is
    /// by `Color` equality, so it matches the tokens themselves (not e.g. `tomato.opacity(0.5)`).
    static let swatches: [(color: Color, swatch: CrayonSwatch)] = [
        (tomato, Swatch.tomato),
        (sunflower, Swatch.sunflower),
        (sky, Swatch.sky),
        (grass, Swatch.grass),
        (grape, Swatch.grape),
        (bubblegum, Swatch.bubblegum),
        (paper, Swatch.paper),
        (paperDeep, Swatch.paperDeep),
        (desk, Swatch.desk),
        (card, Swatch.card),
        (ink, Swatch.ink),
        (inkSoft, Swatch.inkSoft),
        (danger, Swatch.danger),
        (warning, Swatch.warning),
        (success, Swatch.success),
        (onSunflower, Swatch.onSunflower),
        (onFill, Swatch.onFill),
        (.white, CrayonSwatch(light: 0xFFFFFF, dark: 0xFFFFFF)),
        (.black, CrayonSwatch(light: 0x000000, dark: 0x000000)),
    ]

    /// The raw values behind a token colour, or nil for any other colour.
    static func swatch(for color: Color) -> CrayonSwatch? {
        swatches.first { $0.color == color }?.swatch
    }

    // MARK: Helpers

    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// One opaque Crayon colour as raw sRGB hex, for light and dark appearances.
struct CrayonSwatch: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32

    /// The adaptive SwiftUI colour.
    var color: Color { Crayon.adaptive(light: light, dark: dark) }

    func hex(in colorScheme: ColorScheme) -> UInt32 { colorScheme == .dark ? dark : light }
}

/// WCAG 2 contrast, used to pick a readable label colour for a crayon fill. Works from the
/// palette's raw hex values (`Crayon.swatch(for:)`), never by resolving a dynamic colour, so it's
/// pure and safe on any thread.
enum CrayonContrast {
    /// Normal-size text (WCAG AA).
    static let text: Double = 4.5
    /// Icons and other meaningful non-text graphics (WCAG 1.4.11).
    static let graphics: Double = 3

    /// WCAG relative luminance of an sRGB hex colour.
    static func luminance(_ hex: UInt32) -> Double {
        func linear(_ component: UInt32) -> Double {
            let value = Double(component & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }

    /// The WCAG contrast ratio of two sRGB hex colours, from 1 to 21.
    static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The contrast of two swatches in one appearance.
    static func ratio(_ first: CrayonSwatch, _ second: CrayonSwatch, in colorScheme: ColorScheme) -> Double {
        ratio(first.hex(in: colorScheme), second.hex(in: colorScheme))
    }

    /// `preferred` if it reaches `minimum` on `fill`; otherwise white or `Crayon.onFill`,
    /// whichever contrasts more. A fill or preferred colour that isn't a Crayon token (or white
    /// or black) can't be measured, so `preferred` is kept.
    static func label(on fill: Color, preferring preferred: Color, minimum: Double,
                      in colorScheme: ColorScheme) -> Color {
        guard let background = Crayon.swatch(for: fill),
              let wanted = Crayon.swatch(for: preferred) else { return preferred }
        if ratio(wanted, background, in: colorScheme) >= minimum { return preferred }
        let white = ratio(CrayonSwatch(light: 0xFFFFFF, dark: 0xFFFFFF), background, in: colorScheme)
        let ink = ratio(Crayon.Swatch.onFill, background, in: colorScheme)
        return white >= ink ? .white : Crayon.onFill
    }
}

// MARK: - View modifiers

public extension View {
    /// Applies the crayon look to a window's content: rounded type, the tomato tint and the
    /// paper background. Every scene root calls this once.
    func crayonTheme() -> some View {
        modifier(CrayonThemeModifier())
    }

    /// A raised card: white (or night-indigo) fill, 16 pt corners, a soft chunky shadow and an
    /// optional coloured selection ring.
    func crayonCard(selected: Bool = false, tint: Color = Crayon.tomato,
                    cornerRadius: CGFloat = Crayon.cornerRadius, padding: CGFloat = 0) -> some View {
        modifier(CrayonCardModifier(selected: selected, tint: tint, cornerRadius: cornerRadius, padding: padding))
    }

    /// A playful hover: lifts, grows a little and tilts. Off with Reduce Motion.
    func crayonHover(tilt: Double = -1.5, scale: CGFloat = 1.04) -> some View {
        modifier(CrayonHoverModifier(tilt: tilt, scale: scale))
    }

    /// Paper behind the view, edge to edge.
    func crayonPaper(deep: Bool = false) -> some View {
        background((deep ? Crayon.paperDeep : Crayon.paper).ignoresSafeArea())
    }
}

struct CrayonThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .fontDesign(.rounded)
            .tint(Crayon.tomato)
            .crayonPaper()
    }
}

struct CrayonCardModifier: ViewModifier {
    let selected: Bool
    let tint: Color
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            // Shadows go on the background shape only: on the whole view they'd ghost the text.
            .background(
                shape.fill(Crayon.card)
                    .shadow(color: Crayon.shadow, radius: 0, x: 0, y: selected ? 5 : 3)
                    .shadow(color: Crayon.shadow.opacity(0.5), radius: 10, x: 0, y: 6)
            )
            .overlay(shape.strokeBorder(selected ? tint : Crayon.ink.opacity(0.06), lineWidth: selected ? 3 : 1))
    }
}

struct CrayonHoverModifier: ViewModifier {
    let tilt: Double
    let scale: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = hovering && !reduceMotion
        content
            .scaleEffect(active ? scale : 1)
            .rotationEffect(.degrees(active ? tilt : 0))
            .offset(y: active ? -3 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: active)
            .onHover { hovering = $0 }
    }
}

// MARK: - Components

/// A chunky, pill-shaped button: solid colour, a darker "pressed into the page" edge, and a squish
/// when pressed (not animated with Reduce Motion). For a view's main action. The label is white
/// where white reaches 4.5:1 on the fill and `Crayon.onFill` otherwise (every palette colour
/// today), worked out per appearance.
public struct CrayonButtonStyle: ButtonStyle {
    var color: Color

    public init(color: Color = Crayon.tomato) { self.color = color }

    public func makeBody(configuration: Configuration) -> some View {
        CrayonButton(configuration: configuration, color: color)
    }

    private struct CrayonButton: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(Crayon.font(.body, weight: .bold))
                .foregroundStyle(CrayonContrast.label(on: color, preferring: .white,
                                                      minimum: CrayonContrast.text, in: colorScheme))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(color)
                        .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: pressed ? 1 : 3)
                )
                .offset(y: pressed ? 2 : 0)
                .scaleEffect(pressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6), value: pressed)
                .contentShape(Capsule())
        }
    }
}

public extension ButtonStyle where Self == CrayonButtonStyle {
    static var crayon: CrayonButtonStyle { CrayonButtonStyle() }
    static func crayon(_ color: Color) -> CrayonButtonStyle { CrayonButtonStyle(color: color) }
}

/// A sticker-like capsule label: solid colour, bold rounded text, a thin white rim. The text is
/// white or `Crayon.onFill`, whichever reaches 4.5:1 (as `CrayonButtonStyle`).
public struct CrayonSticker: View {
    let text: String
    let systemImage: String?
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    public init(_ text: String, systemImage: String? = nil, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Crayon.font(.caption2, weight: .heavy))
        .foregroundStyle(CrayonContrast.label(on: color, preferring: .white,
                                              minimum: CrayonContrast.text, in: colorScheme))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color).shadow(color: Crayon.shadow, radius: 0, x: 0, y: 1.5))
        .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
    }
}

/// An empty or error state with personality: a symbol on a stack of coloured blobs, a rounded
/// title and message, then actions. Use instead of `ContentUnavailableView` in app chrome.
public struct CrayonEmptyState<Actions: View>: View {
    let title: String
    let message: String?
    let systemImage: String
    let color: Color
    let actions: Actions

    public init(_ title: String, systemImage: String, color: Color = Crayon.tomato, message: String? = nil,
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.color = color
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 16) {
            CrayonBlobIcon(systemImage: systemImage, color: color, size: 96)
            Text(title)
                .font(Crayon.font(.title, weight: .bold))
                .foregroundStyle(Crayon.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Crayon.font(.body, weight: .regular))
                    .foregroundStyle(Crayon.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            VStack(spacing: 10) { actions }
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A symbol sitting on two offset, tilted coloured blobs: the app's illustration motif.
public struct CrayonBlobIcon: View {
    let systemImage: String
    let color: Color
    let size: CGFloat

    public init(systemImage: String, color: Color = Crayon.tomato, size: CGFloat = 64) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(Crayon.sunflower)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(8))
                .offset(x: size * 0.08, y: size * 0.06)
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-6))
                .shadow(color: Crayon.shadow, radius: 0, x: 0, y: 3)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .accessibilityHidden(true)
    }
}

/// A section heading with a small coloured dot, in rounded heavy type.
public struct CrayonHeader: View {
    let title: String
    let color: Color

    public init(_ title: String, color: Color = Crayon.tomato) {
        self.title = title
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(Crayon.font(.headline, weight: .heavy)).foregroundStyle(Crayon.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
