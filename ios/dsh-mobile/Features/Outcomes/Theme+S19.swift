import SwiftUI

/// S19 · tokens of the done and failed states (screens 06 and X1). Built from the frozen
/// `DSHTheme` values; `DSHTheme` itself does not change (PLAN.md "Frozen tokens").
extension DSHTheme {
    /// The failure card: a red shade on the canvas, under a red border.
    static let s19FailFill = DSHTheme.red.opacity(0.06)
    static let s19FailBorder = DSHTheme.red.opacity(0.4)
    /// The milestone bar's border when the task failed.
    static let s19FailBarBorder = DSHTheme.red.opacity(0.35)
    /// Red text on the canvas (the board's #FF7B72), lighter than `red` so that it reads.
    static let s19FailText = Color(hex: 0xFF7B72)
    /// The raw error: SF Mono in a box a shade below the canvas.
    static let s19ErrorFill = Color.black.opacity(0.35)
    /// The stopped card: neutral, like the stopped bar.
    static let s19StoppedFill = Color.white.opacity(0.03)
    /// The secondary button in the card ("复制错误").
    static let s19SecondaryButton = Color.white.opacity(0.08)
}
