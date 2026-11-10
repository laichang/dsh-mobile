import SwiftUI

/// Tokens of the session page that the base palette leaves implicit, built from the base `DSHTheme` values.
extension DSHTheme {
    /// The milestone bar: a shade above the canvas, under a hairline border.
    static let milestoneBarFill = Color.white.opacity(0.03)
    /// Code blocks in the transcript: a shade below the canvas (screen 04).
    static let codeFill = Color.black.opacity(0.28)
    /// Inline code: the bubble color behind SF Mono.
    static let inlineCodeFill = DSHTheme.bubble
    /// Added and removed lines in a diff block.
    static let diffAdded = DSHTheme.green.opacity(0.16)
    static let diffRemoved = DSHTheme.red.opacity(0.16)
}
