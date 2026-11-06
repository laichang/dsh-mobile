import SwiftUI

/// The DESIGN.md "Visual language" tokens (T1). Frozen: UI slices do not change these values.
/// A slice that needs a new token adds it in `Theme+<Slice>.swift` (PLAN.md "How the UI slices
/// stay independent"). The app always uses dark mode (`.preferredColorScheme(.dark)` at the root).
enum DSHTheme {
    /// Session pages.
    static let canvas = Color(hex: 0x151517)
    /// The workspace drawer (the desktop sidebar).
    static let slate = Color(hex: 0x343A43)
    /// User messages, the composer.
    static let bubble = Color(hex: 0x2C2C2E)
    /// Separators, card borders.
    static let hairline = Color.white.opacity(0.08)

    static let textPrimary = Color(hex: 0xF9FAFB)
    static let textSecondary = Color(hex: 0xADB2B8)
    static let textTertiary = Color(hex: 0x71767E)

    /// Progress and primary actions only.
    static let blue = Color(hex: 0x4D6BFE)
    /// Needs you.
    static let amber = Color(hex: 0xF5A524)
    /// Failed, or high risk.
    static let red = Color(hex: 0xF85149)
    /// Done.
    static let green = Color(hex: 0x3FB950)

    /// SF Mono, for commands and paths.
    static func mono(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .monospaced) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
