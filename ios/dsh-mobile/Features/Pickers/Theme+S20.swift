import SwiftUI

/// S20 · tokens of the picker sheets (07, M, X4) that `DSHTheme` does not have. The values are
/// the board's own (`design/board.html` `.sheet`, `.lst`, `.field`); `DSHTheme` stays frozen.
extension DSHTheme {
    /// The bottom sheet (`.sheet`).
    static let sheet = Color(hex: 0x1C1C1F)
    /// The path field (`.field`).
    static let field = Color(hex: 0x0E0E10)
    /// The check mark of a picked row (`.lst .it .ck`).
    static let check = Color(hex: 0x8EA2FF)
}
