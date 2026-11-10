import SwiftUI

/// The visual language: the base tokens, aligned with DSH desktop and Web (deepseek.com/harness).
/// The design kit (`design/kit/kit.css`) has the same values for the screens of `design/screens.json`.
/// System font (PingFang SC for Chinese), SF Mono for commands and paths. Thinking and tool calls
/// collapse to one line; tool calls are `verb · target · +/−` rows. The base values do not change:
/// a feature that needs a new token adds it in `Theme+<Feature>.swift`, named for the feature,
/// never for a plan item (`scripts/check-design`). The app always uses dark mode
/// (`.preferredColorScheme(.dark)` at the root).
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
