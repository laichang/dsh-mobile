import SwiftUI

/// S16 · tokens of the session page that DESIGN.md's palette leaves implicit. Built from the frozen
/// `DSHTheme` values; `DSHTheme` itself does not change (PLAN.md "Frozen tokens").
extension DSHTheme {
    /// The milestone bar: a shade above the canvas, under a hairline border.
    static let s16BarFill = Color.white.opacity(0.03)
    /// Code blocks in the transcript: a shade below the canvas (screen 04).
    static let s16CodeFill = Color.black.opacity(0.28)
    /// Inline code: the bubble color behind SF Mono.
    static let s16InlineCodeFill = DSHTheme.bubble
    /// Added and removed lines in a diff block.
    static let s16DiffAdded = DSHTheme.green.opacity(0.16)
    static let s16DiffRemoved = DSHTheme.red.opacity(0.16)
}
