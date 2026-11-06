import SwiftUI

/// S18 · tokens of the approval sheet (05) that `DSHTheme` and `Theme+S15` do not have. The values
/// are the board's own (`design/board.html` `.sheet`, `.btn.tall`); `DSHTheme` stays frozen.
extension DSHTheme {
    /// The bottom sheet (`.sheet` background).
    static let sheet = Color(hex: 0x1C1C1F)
    /// Corner radius of the sheet's top edge (`.sheet` border-radius).
    static let sheetCorner: CGFloat = 30
    /// Height and radius of the two tall answer buttons (`.btn.tall`).
    static let tallButtonHeight: CGFloat = 50
    static let tallButtonCorner: CGFloat = 15
}
