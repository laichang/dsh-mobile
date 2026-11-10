import SwiftUI

/// Tokens of the done and failed states (screens 06 and X1), built from the base `DSHTheme` values.
extension DSHTheme {
    /// The failure card: a red shade on the canvas, under a red border.
    static let failFill = DSHTheme.red.opacity(0.06)
    static let failBorder = DSHTheme.red.opacity(0.4)
    /// The milestone bar's border when the task failed.
    static let failBarBorder = DSHTheme.red.opacity(0.35)
    /// Red text on the canvas (the board's #FF7B72), lighter than `red` so that it reads.
    static let failText = Color(hex: 0xFF7B72)
    /// The raw error: SF Mono in a box a shade below the canvas.
    static let errorFill = Color.black.opacity(0.35)
    /// The stopped card: neutral, like the stopped bar.
    static let stoppedFill = Color.white.opacity(0.03)
    /// The secondary button in the card ("复制错误").
    static let secondaryButton = Color.white.opacity(0.08)
}
