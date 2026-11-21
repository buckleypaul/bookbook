import Foundation

extension RGBA {
    /// `#RRGGBB` (the `#` optional, surrounding whitespace ignored), opaque; anything else is nil.
    public init?(hex text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.utf8.count == 6, s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
              let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB` in uppercase, alpha dropped; channels are clamped to 0...1 and non-finite ones read as 0.
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
