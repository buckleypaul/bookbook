import AppKit
import SwiftUI

/// BookBook's "crayon box" look: cream paper, bold friendly primaries, rounded type and chunky
/// soft shadows, with a night-time storybook variant in Dark Mode. App chrome only: the book's
/// own pages, thumbnails' page art and exports never use these colours.
public enum Crayon {
    // MARK: Palette (each adapts to light and dark)

    /// The accent: buttons, selection, focus.
    public static let tomato = adaptive(light: 0xFF6B4A, dark: 0xFF8466)
    public static let sunflower = adaptive(light: 0xFFC93C, dark: 0xFFD45E)
    public static let sky = adaptive(light: 0x3DA5F4, dark: 0x5DB6FF)
    public static let grass = adaptive(light: 0x4CC38A, dark: 0x5FD49B)
    public static let grape = adaptive(light: 0x9B6BFF, dark: 0xB08CFF)
    public static let bubblegum = adaptive(light: 0xFF7EB6, dark: 0xFF97C6)

    /// Window and sidebar backgrounds.
    public static let paper = adaptive(light: 0xFFF8EC, dark: 0x1E1B2E)
    /// A slightly deeper paper for wells, insets and the sidebar.
    public static let paperDeep = adaptive(light: 0xFCEFD9, dark: 0x171425)
    /// The desk under the book window's panel cards: a little deeper than `paperDeep`.
    public static let desk = adaptive(light: 0xF0E3D0, dark: 0x110E1C)
    /// Raised cards.
    public static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2640)
    /// Primary text on paper.
    public static let ink = adaptive(light: 0x2B2340, dark: 0xF5EEDC)
    /// Secondary text on paper.
    public static let inkSoft = adaptive(light: 0x7A6F8A, dark: 0xB3A9C4)
    /// The chunky shadow under cards and buttons.
    public static let shadow = adaptive(light: 0x2B2340, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.45)

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

    /// Rounded system type for display text.
    public static func font(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
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
/// when pressed. For a view's main action.
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

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(Crayon.font(.body, weight: .bold))
                .foregroundStyle(.white)
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
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
                .contentShape(Capsule())
        }
    }
}

public extension ButtonStyle where Self == CrayonButtonStyle {
    static var crayon: CrayonButtonStyle { CrayonButtonStyle() }
    static func crayon(_ color: Color) -> CrayonButtonStyle { CrayonButtonStyle(color: color) }
}

/// A sticker-like capsule label: solid colour, bold rounded text, a thin white rim.
public struct CrayonSticker: View {
    let text: String
    let systemImage: String?
    let color: Color

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
        .foregroundStyle(.white)
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
