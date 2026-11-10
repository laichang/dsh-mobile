import SwiftUI

/// Tokens of 所有任务 (03) that `DSHTheme` does not have. The values are the design kit's own
/// (`design/kit/kit.css` `:root`, `.card`, `.cmd`, `.tag`, `.btn`).
extension DSHTheme {
    /// Cards on the canvas (`--card`).
    static let card = Color(hex: 0x1E1F22)
    /// The second hairline, for the inline answer's rule (`--hair-2`).
    static let hairlineStrong = Color.white.opacity(0.12)
    /// Neutral button and chip fill (`--fill`).
    static let fill = Color.white.opacity(0.08)
    /// The command block behind a command (`.cmd`).
    static let commandBackground = Color(hex: 0x0E0E10)
    static let commandText = Color(hex: 0xE6E6E6)
    /// The amber tag and the border of a card that needs you (`--amber-soft`, `.card.needs`).
    static let amberSoft = Color(hex: 0xF5A524, opacity: 0.14)
    static let amberBorder = Color(hex: 0xF5A524, opacity: 0.35)
    /// Red text on a neutral button (deny).
    static let redText = Color(hex: 0xFF7B72)
    /// Links inside a card (工具参数 ›).
    static let link = Color(hex: 0x8EA2FF)
}
